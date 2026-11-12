import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import 'delivery_permit.dart';
import 'relay_deadline.dart';

/// Immutable webhook input, including the exact persisted event bytes.
final class DeliveryIntent {
  /// Creates an immutable delivery value.
  DeliveryIntent({
    required this.eventId,
    required this.targetUrl,
    required Uint8List payload,
  }) : payload = Uint8List.fromList(payload).asUnmodifiableView();

  /// The canonical event identifier.
  final String eventId;

  /// The pinned destination.
  final String targetUrl;

  /// The structured CloudEvent bytes.
  final Uint8List payload;
}

/// The result of an output attempt.
sealed class DeliveryOutcome {
  const DeliveryOutcome();
}

/// The destination acknowledged the event.
final class DeliveryAcknowledged extends DeliveryOutcome {
  const DeliveryAcknowledged();
}

/// The attempt may be retried.
final class DeliveryRetryable extends DeliveryOutcome {
  /// Creates a sanitized retryable outcome.
  const DeliveryRetryable(this.errorClass);

  /// The fixed error category.
  final String errorClass;
}

/// The attempt cannot succeed without intervention.
final class DeliveryPermanent extends DeliveryOutcome {
  /// Creates a sanitized permanent outcome.
  const DeliveryPermanent(this.errorClass);

  /// The fixed error category.
  final String errorClass;
}

/// A destination capable of sending an immutable delivery value.
abstract interface class Output {
  /// Sends an intent using its locally resolved signing key.
  Future<DeliveryOutcome> send(DeliveryIntent intent, Uint8List key);
}

/// A claimed intent and its fencing token.
final class DeliveryClaim {
  /// Creates a claimed event with optional webhook delivery information.
  DeliveryClaim(
    this.createdAt,
    this.deliveryId,
    this.claimId,
    this.attemptNumber,
    this.eventId,
    this.payload,
    this.intent,
    this.key,
  );

  final DateTime createdAt;
  final String deliveryId;
  final String claimId;
  final int attemptNumber;
  final String eventId;
  final Uint8List payload;
  final DeliveryIntent? intent;
  final Uint8List? key;
}

/// One output's fenced set of claimed intents and its shared time budget.
final class DeliveryBatch {
  /// Creates a batch pinned to one output definition.
  DeliveryBatch(
    this.claimId,
    this.definitionDigest,
    this.claims,
    this.deadline,
  );
  final String claimId;
  final String? definitionDigest;
  final List<DeliveryClaim> claims;
  final RelayDeadline deadline;
}

final class _RollbackClaim implements Exception {}

final class _RollbackCompletion implements Exception {}

/// Resolves a process-local signing reference.
typedef SigningKeyResolver = Uint8List? Function(String reference);

/// Performs short, fenced PostgreSQL relay transactions.
final class OutputRelayRepository {
  /// Creates a repository using a long-lived internal session.
  OutputRelayRepository(
    this.session,
    this.resolveKey, {
    this.onUnavailable,
    this.beforeClaimCommit,
    Set<String> loadedReferences = const {},
  }) : _commitments = {
         for (final reference in loadedReferences)
           if (resolveKey(reference) case final key?)
             reference: sha256.convert(key).toString(),
       };
  final Session session;
  final SigningKeyResolver resolveKey;

  /// Receives bounded public output and reference identities.
  final void Function(String outputId, String reference)? onUnavailable;

  /// Optional barrier immediately before the claim's commit-boundary check.
  final Future<void> Function()? beforeClaimCommit;
  final Map<String, DateTime> _lastDiagnostic = {};
  final Map<String, String> _commitments;

  Uint8List? _key(String reference, String commitment) {
    final key = resolveKey(reference);
    return key != null && sha256.convert(key).toString() == commitment
        ? key
        : null;
  }

  /// Finds webhook lanes with loaded keys and plugin lanes with ready definitions.
  Future<Set<String>> discover(
    Set<String> busy, {
    Map<String, Set<String>> readyDefinitions = const {},
  }) async {
    final rows = await session.db.unsafeQuery(
      '''WITH due AS (
        SELECT output_id::text AS output_id, signing_key_ref, output_kind,
          CASE WHEN output_kind='webhook'
            THEN (CAST(@keys AS jsonb)->>signing_key_ref = signing_key_commitment) IS TRUE
            ELSE (CAST(@ready AS jsonb)->output_id::text ? definition_digest) IS TRUE END AS available
        FROM outbox
        WHERE status='queued'
          AND (next_attempt_at IS NULL OR next_attempt_at<=clock_timestamp())
          AND NOT (CAST(@busy AS jsonb) ? output_id::text)
          AND NOT EXISTS (SELECT 1 FROM outbox active
            WHERE active.output_id=outbox.output_id AND active.status='delivering')
      )
      SELECT DISTINCT output_id, signing_key_ref, available FROM due
      WHERE available OR output_kind='webhook'
      ORDER BY available DESC, output_id, signing_key_ref LIMIT 8192''',
      parameters: QueryParameters.named({
        'keys': jsonEncode(_commitments),
        'busy': jsonEncode(busy.toList()),
        'ready': jsonEncode({
          for (final e in readyDefinitions.entries) e.key: e.value.toList(),
        }),
      }),
      timeoutInSeconds: 5,
    );
    final result = <String>{};
    for (final row in rows) {
      final m = row.toColumnMap();
      final id = m['output_id'] as String;
      if (m['available'] as bool) {
        result.add(id);
      } else {
        final ref = m['signing_key_ref'] as String;
        final diagnostic = '$id/$ref';
        final now = DateTime.now();
        final previous = _lastDiagnostic[diagnostic];
        if (previous == null ||
            now.difference(previous) >= const Duration(seconds: 60)) {
          if (_lastDiagnostic.length >= 8192 && previous == null) {
            _lastDiagnostic.remove(_lastDiagnostic.keys.first);
          }
          _lastDiagnostic[diagnostic] = now;
          onUnavailable?.call(id, ref);
        }
      }
    }
    return result;
  }

  /// Finds the oldest due definition served by a ready plugin instance.
  Future<String?> oldestReadyDigest(
    String outputId,
    Set<String> digests,
  ) async {
    if (digests.isEmpty) return null;
    final rows = await session.db.unsafeQuery(
      '''SELECT definition_digest FROM outbox
      WHERE output_id=CAST(@output AS uuid) AND output_kind='plugin' AND status='queued'
      AND (next_attempt_at IS NULL OR next_attempt_at<=clock_timestamp())
      AND CAST(@ready AS jsonb) ? definition_digest
      ORDER BY created_at,delivery_id LIMIT 1''',
      parameters: QueryParameters.named({
        'output': outputId,
        'ready': jsonEncode(digests.toList()),
      }),
      timeoutInSeconds: 5,
    );
    return rows.isEmpty ? null : rows.single[0] as String;
  }

  Future<void> _timeout(
    Transaction tx,
    RelayDeadline deadline, {
    bool claim = false,
  }) async {
    final millis = deadline.remainingMillis(claim: claim);
    await session.db.unsafeQuery(
      "SELECT set_config('statement_timeout', @timeout, true), set_config('lock_timeout', @timeout, true)",
      parameters: QueryParameters.named({'timeout': '${millis}ms'}),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    deadline.remainingMillis(claim: claim);
  }

  /// Claims one webhook or a bounded batch of one ready plugin definition.
  Future<DeliveryBatch?> claim(
    String outputId, {
    int limit = 1,
    int byteLimit = 1024 * 1024,
    Set<String> readyDigests = const {},
    DeliveryPermit? permit,
    RelayDeadline? deadline,
  }) async {
    if (limit < 1 || limit > 64) throw ArgumentError.value(limit, 'limit');
    if (byteLimit < 1 || byteLimit > 1024 * 1024)
      throw ArgumentError.value(byteLimit, 'byteLimit');
    final budget = deadline ?? RelayDeadline();
    try {
      return await session.db.transaction((tx) async {
        await _timeout(tx, budget, claim: true);
        final lock = await session.db.unsafeQuery(
          'SELECT pg_try_advisory_xact_lock(hashtextextended(@output, 1129271885))',
          parameters: QueryParameters.named({'output': outputId}),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (lock.single[0] != true) return null;
        await _timeout(tx, budget, claim: true);
        final active = await session.db.unsafeQuery(
          "SELECT 1 FROM outbox WHERE output_id=CAST(@output AS uuid) AND status='delivering' LIMIT 1",
          parameters: QueryParameters.named({'output': outputId}),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (active.isNotEmpty) return null;
        await _timeout(tx, budget, claim: true);
        final selected = await session.db.unsafeQuery(
          '''SELECT output_kind,definition_digest,signing_key_ref,signing_key_commitment
          FROM outbox WHERE output_id=CAST(@output AS uuid) AND status='queued'
          AND (next_attempt_at IS NULL OR next_attempt_at<=clock_timestamp())
          AND ((NOT @plugin AND output_kind='webhook' AND CAST(@keys AS jsonb)->>signing_key_ref=signing_key_commitment)
            OR (@plugin AND output_kind='plugin' AND CAST(@ready AS jsonb) ? definition_digest))
          ORDER BY created_at,delivery_id LIMIT 1''',
          parameters: QueryParameters.named({
            'output': outputId,
            'keys': jsonEncode(_commitments),
            'plugin': permit != null,
            'ready': jsonEncode(readyDigests.toList()),
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (selected.isEmpty) return null;
        final selection = selected.single;
        final plugin = selection[0] == 'plugin';
        final digest = selection[1] as String?;
        if (plugin && (permit == null || !permit.isValid)) return null;
        final key = plugin
            ? null
            : _key(selection[2] as String, selection[3] as String);
        if (!plugin && key == null) return null;
        await _timeout(tx, budget, claim: true);
        final candidates = await session.db.unsafeQuery(
          '''SELECT created_at,delivery_id::text,event_id::text,target_url,payload,attempt_count
          FROM outbox WHERE output_id=CAST(@output AS uuid) AND status='queued'
            AND (next_attempt_at IS NULL OR next_attempt_at<=clock_timestamp())
            AND ((@plugin AND output_kind='plugin' AND definition_digest=@digest)
              OR (NOT @plugin AND output_kind='webhook' AND signing_key_ref=@ref
                AND signing_key_commitment=@commitment))
          ORDER BY created_at,delivery_id FOR UPDATE SKIP LOCKED LIMIT @limit''',
          parameters: QueryParameters.named({
            'output': outputId,
            'plugin': plugin,
            'digest': digest,
            'ref': selection[2],
            'commitment': selection[3],
            'limit': plugin ? limit : 1,
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (candidates.isEmpty) return null;
        await _timeout(tx, budget, claim: true);
        final lease =
            (await session.db.unsafeQuery(
                  "SELECT clock_timestamp()+interval '30 seconds'",
                  transaction: tx,
                  timeoutInSeconds: 5,
                )).single[0]
                as DateTime;
        final id = const Uuid().v4();
        final claims = <DeliveryClaim>[];
        var total = 0;
        for (final row in candidates) {
          final data = row[4];
          final bytes = data is ByteData
              ? data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
              : data as Uint8List;
          if (total + bytes.length > byteLimit) break;
          total += bytes.length;
          final created = row[0] as DateTime;
          final deliveryId = row[1] as String;
          final eventId = row[2] as String;
          final number = (row[5] as int) + 1;
          final params = QueryParameters.named({
            'created': created,
            'id': deliveryId,
            'claim': id,
            'number': number,
            'lease': lease,
          });
          await _timeout(tx, budget, claim: true);
          await session.db.unsafeExecute(
            '''UPDATE outbox SET status='delivering',claim_id=CAST(@claim AS uuid),
            lease_until=@lease,attempt_count=@number,next_attempt_at=NULL
            WHERE created_at=@created AND delivery_id=CAST(@id AS uuid)''',
            parameters: params,
            transaction: tx,
            timeoutInSeconds: 5,
          );
          await _timeout(tx, budget, claim: true);
          await session.db.unsafeExecute(
            '''INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
            VALUES (@created,CAST(@id AS uuid),@number,CAST(@claim AS uuid),clock_timestamp(),'started')''',
            parameters: QueryParameters.named({
              'created': created,
              'id': deliveryId,
              'claim': id,
              'number': number,
            }),
            transaction: tx,
            timeoutInSeconds: 5,
          );
          final intent = plugin
              ? null
              : DeliveryIntent(
                  eventId: eventId,
                  targetUrl: row[3] as String,
                  payload: bytes,
                );
          claims.add(
            DeliveryClaim(
              created,
              deliveryId,
              id,
              number,
              eventId,
              intent?.payload ?? bytes,
              intent,
              key,
            ),
          );
        }
        if (claims.isEmpty) return null;
        if (beforeClaimCommit != null) await beforeClaimCommit!();
        budget.checkClaim();
        if (plugin && !permit!.isValid) throw _RollbackClaim();
        return DeliveryBatch(id, digest, claims, budget);
      });
    } on _RollbackClaim {
      return null;
    }
  }

  /// Completes a webhook claim under its batch's remaining deadline.
  Future<bool> complete(
    DeliveryClaim claim,
    DeliveryOutcome outcome, {
    RelayDeadline? deadline,
  }) => completeBatch(
    DeliveryBatch(claim.claimId, null, [claim], deadline ?? RelayDeadline()),
    [outcome],
  );

  /// Atomically persists a whole batch while every lease remains current.
  Future<bool> completeBatch(
    DeliveryBatch batch,
    List<DeliveryOutcome> outcomes,
  ) async {
    if (outcomes.length != batch.claims.length || outcomes.isEmpty) {
      throw ArgumentError('A batch requires one outcome per claim');
    }
    final values = <Map<String, Object?>>[];
    for (var i = 0; i < outcomes.length; i++) {
      final claim = batch.claims[i];
      final (status, attempt, error) = switch (outcomes[i]) {
        DeliveryAcknowledged() => ('delivered', 'acknowledged', null),
        DeliveryPermanent(:final errorClass) => (
          'dead',
          'permanent',
          errorClass,
        ),
        DeliveryRetryable(:final errorClass) => (
          claim.attemptNumber >= 20 ? 'dead' : 'queued',
          'retryable',
          errorClass,
        ),
      };
      values.add({
        'created': claim.createdAt.toUtc().toIso8601String(),
        'id': claim.deliveryId,
        'number': claim.attemptNumber,
        'status': status,
        'outcome': attempt,
        'error': error,
        'delay': math.min(300, 1 << math.min(19, claim.attemptNumber - 1)),
      });
    }
    final params = QueryParameters.named({
      'values': jsonEncode(values),
      'claim': batch.claimId,
    });
    const input = '''SELECT * FROM unnest(
      ARRAY(SELECT (v->>'created')::timestamptz FROM jsonb_array_elements(CAST(@values AS jsonb)) v),
      ARRAY(SELECT (v->>'id')::uuid FROM jsonb_array_elements(CAST(@values AS jsonb)) v),
      ARRAY(SELECT (v->>'number')::integer FROM jsonb_array_elements(CAST(@values AS jsonb)) v),
      ARRAY(SELECT v->>'status' FROM jsonb_array_elements(CAST(@values AS jsonb)) v),
      ARRAY(SELECT v->>'outcome' FROM jsonb_array_elements(CAST(@values AS jsonb)) v),
      ARRAY(SELECT v->>'error' FROM jsonb_array_elements(CAST(@values AS jsonb)) v),
      ARRAY(SELECT (v->>'delay')::integer FROM jsonb_array_elements(CAST(@values AS jsonb)) v)
    ) AS x(created,id,number,status,outcome,error,delay)''';
    try {
      return await session.db.transaction((tx) async {
        await _timeout(tx, batch.deadline);
        final attempts = await session.db.unsafeExecute(
          '''UPDATE delivery_attempts a SET "finishedAt"=clock_timestamp(),outcome=x.outcome,"errorClass"=x.error
          FROM ($input) x, outbox o WHERE a."outboxCreatedAt"=x.created AND a."deliveryId"=x.id
          AND a."attemptNumber"=x.number AND a."claimId"=CAST(@claim AS uuid) AND a.outcome='started'
          AND o.created_at=x.created AND o.delivery_id=x.id AND o.status='delivering'
          AND o.claim_id=CAST(@claim AS uuid) AND o.lease_until>clock_timestamp()''',
          parameters: params,
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (attempts != batch.claims.length) throw _RollbackCompletion();
        await _timeout(tx, batch.deadline);
        final updated = await session.db.unsafeExecute(
          '''UPDATE outbox o SET status=x.status,claim_id=NULL,lease_until=NULL,
          next_attempt_at=CASE WHEN x.status='queued' THEN clock_timestamp()+x.delay*interval '1 second' ELSE NULL END,
          dead_reason=CASE WHEN x.status='dead' THEN x.error ELSE NULL END
          FROM ($input) x WHERE o.created_at=x.created AND o.delivery_id=x.id
          AND o.status='delivering' AND o.claim_id=CAST(@claim AS uuid)
          AND o.lease_until>clock_timestamp()''',
          parameters: params,
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (updated != batch.claims.length) throw _RollbackCompletion();
        batch.deadline.check();
        return true;
      });
    } on _RollbackCompletion {
      return false;
    }
  }

  /// Recovers one expired started attempt, preserving its consumed budget.
  Future<bool> recoverExpired() async {
    return session.db.transaction((tx) async {
      final rows = await session.db.unsafeQuery(
        '''SELECT created_at,delivery_id::text,claim_id::text,attempt_count FROM outbox
        WHERE status='delivering' AND lease_until<=clock_timestamp() ORDER BY lease_until FOR UPDATE SKIP LOCKED LIMIT 1''',
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (rows.isEmpty) return false;
      final row = rows.single;
      final number = row[3] as int;
      final status = number >= 20 ? 'dead' : 'queued';
      final delay = math.min(300, 1 << math.min(19, number - 1));
      await session.db.unsafeExecute(
        '''UPDATE delivery_attempts SET "finishedAt"=clock_timestamp(),outcome='interrupted',"errorClass"='interrupted'
        WHERE "outboxCreatedAt"=@created AND "deliveryId"=CAST(@id AS uuid) AND "claimId"=CAST(@claim AS uuid) AND "attemptNumber"=@number AND outcome='started' ''',
        parameters: QueryParameters.named({
          'created': row[0],
          'id': row[1],
          'claim': row[2],
          'number': number,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      await session.db.unsafeExecute(
        '''UPDATE outbox SET status=@status,claim_id=NULL,lease_until=NULL,
        next_attempt_at=CASE WHEN @status='queued' THEN clock_timestamp()+@delay*interval '1 second' ELSE NULL END,
        dead_reason=CASE WHEN @status='dead' THEN 'interrupted' ELSE NULL END
        WHERE created_at=@created AND delivery_id=CAST(@id AS uuid) AND claim_id=CAST(@claim AS uuid)''',
        parameters: QueryParameters.named({
          'created': row[0],
          'id': row[1],
          'claim': row[2],
          'status': status,
          'delay': delay,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      return true;
    });
  }
}
