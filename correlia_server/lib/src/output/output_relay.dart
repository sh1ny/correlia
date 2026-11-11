import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

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
  DeliveryClaim(
    this.createdAt,
    this.deliveryId,
    this.claimId,
    this.attemptNumber,
    this.intent,
    this.key,
  );
  final DateTime createdAt;
  final String deliveryId;
  final String claimId;
  final int attemptNumber;
  final DeliveryIntent intent;
  final Uint8List key;
}

/// Resolves a process-local signing reference.
typedef SigningKeyResolver = Uint8List? Function(String reference);

/// Performs short, fenced PostgreSQL relay transactions.
final class OutputRelayRepository {
  /// Creates a repository using a long-lived internal session.
  OutputRelayRepository(
    this.session,
    this.resolveKey, {
    this.onUnavailable,
    Set<String> loadedReferences = const {},
  }) : _commitments = {
         for (final reference in loadedReferences)
           if (resolveKey(reference) case final key?)
             reference: sha256.convert(key).toString(),
       };
  final Session session;
  final SigningKeyResolver resolveKey;

  /// Receives only bounded public output and reference identities.
  final void Function(String outputId, String reference)? onUnavailable;
  final Map<String, DateTime> _lastDiagnostic = {};
  final Map<String, String> _commitments;

  Uint8List? _key(String reference, String commitment) {
    final key = resolveKey(reference);
    return key != null && sha256.convert(key).toString() == commitment
        ? key
        : null;
  }

  /// Finds available output lanes with one bounded shared discovery query.
  Future<Set<String>> discover(Set<String> busy) async {
    final rows = await session.db.unsafeQuery(
      '''
      WITH due AS (
        SELECT output_id::text AS output_id, signing_key_ref,
          signing_key_commitment,
          (CAST(@keys AS jsonb)->>signing_key_ref = signing_key_commitment) IS TRUE AS available
        FROM outbox
        WHERE status='queued'
          AND (next_attempt_at IS NULL OR next_attempt_at<=clock_timestamp())
          AND NOT (CAST(@busy AS jsonb) ? output_id::text)
          AND NOT EXISTS (
            SELECT 1 FROM outbox active
            WHERE active.output_id=outbox.output_id AND active.status='delivering'
          )
      )
      SELECT output_id, signing_key_ref, available FROM (
        SELECT DISTINCT ON (output_id) output_id, signing_key_ref, available
        FROM due WHERE available ORDER BY output_id, signing_key_ref
      ) candidates
      UNION ALL
      SELECT DISTINCT output_id, signing_key_ref, available FROM due WHERE NOT available
      ORDER BY available DESC, output_id, signing_key_ref LIMIT 8192
    ''',
      parameters: QueryParameters.named({
        'keys': jsonEncode(_commitments),
        'busy': jsonEncode(busy.toList()),
      }),
      timeoutInSeconds: 5,
    );
    final result = <String>{};
    for (final row in rows) {
      final m = row.toColumnMap();
      final id = m['output_id'] as String;
      final ref = m['signing_key_ref'] as String;
      if (m['available'] as bool) {
        result.add(id);
      } else {
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

  /// Acquires and records a started attempt before any network operation.
  Future<DeliveryClaim?> claim(String outputId) async {
    final refs = await session.db.unsafeQuery(
      '''SELECT signing_key_ref,signing_key_commitment FROM outbox
      WHERE output_id=CAST(@output AS uuid) AND status='queued'
        AND (next_attempt_at IS NULL OR next_attempt_at<=clock_timestamp())
        AND CAST(@keys AS jsonb)->>signing_key_ref = signing_key_commitment
      ORDER BY created_at,delivery_id LIMIT 1''',
      parameters: QueryParameters.named({
        'output': outputId,
        'keys': jsonEncode(_commitments),
      }),
      timeoutInSeconds: 5,
    );
    for (final row in refs) {
      final ref = row[0] as String;
      final commitment = row[1] as String;
      final key = _key(ref, commitment);
      if (key == null) continue;
      final claim = await session.db.transaction((tx) async {
        final lock = await session.db.unsafeQuery(
          '''
          SELECT pg_try_advisory_xact_lock(hashtextextended(@output, 1129271885))
        ''',
          parameters: QueryParameters.named({'output': outputId}),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (lock.single[0] != true) return null;
        final active = await session.db.unsafeQuery(
          '''
          SELECT 1 FROM outbox WHERE output_id=CAST(@output AS uuid)
            AND status='delivering' LIMIT 1
        ''',
          parameters: QueryParameters.named({'output': outputId}),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (active.isNotEmpty) return null;
        final candidates = await session.db.unsafeQuery(
          '''SELECT created_at,delivery_id::text,event_id::text,target_url,payload,attempt_count
          FROM outbox WHERE output_id=CAST(@output AS uuid) AND status='queued'
          AND signing_key_ref=@ref AND signing_key_commitment=@commitment
          AND (next_attempt_at IS NULL OR next_attempt_at<=clock_timestamp())
          ORDER BY created_at,delivery_id FOR UPDATE SKIP LOCKED LIMIT 1''',
          parameters: QueryParameters.named({
            'output': outputId,
            'ref': ref,
            'commitment': commitment,
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (candidates.isEmpty) return null;
        final r = candidates.single;
        final created = r[0] as DateTime;
        final id = r[1] as String;
        final claimId = const Uuid().v4();
        final number = (r[5] as int) + 1;
        final params = QueryParameters.named({
          'created': created,
          'id': id,
          'claim': claimId,
          'number': number,
        });
        await session.db.unsafeExecute(
          '''UPDATE outbox SET status='delivering',claim_id=CAST(@claim AS uuid),lease_until=clock_timestamp()+interval '30 seconds',attempt_count=@number,next_attempt_at=NULL
          WHERE created_at=@created AND delivery_id=CAST(@id AS uuid)''',
          parameters: params,
          transaction: tx,
          timeoutInSeconds: 5,
        );
        await session.db.unsafeExecute(
          '''INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
          VALUES (@created,CAST(@id AS uuid),@number,CAST(@claim AS uuid),clock_timestamp(),'started')''',
          parameters: params,
          transaction: tx,
          timeoutInSeconds: 5,
        );
        final data = r[4];
        final bytes = data is ByteData
            ? data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
            : data as Uint8List;
        return DeliveryClaim(
          created,
          id,
          claimId,
          number,
          DeliveryIntent(
            eventId: r[2] as String,
            targetUrl: r[3] as String,
            payload: bytes,
          ),
          key,
        );
      });
      if (claim != null) return claim;
    }
    return null;
  }

  /// Finalizes both records only while the claim remains current and unexpired.
  Future<bool> complete(DeliveryClaim claim, DeliveryOutcome outcome) async {
    return session.db.transaction((tx) async {
      final (status, attemptOutcome, error) = switch (outcome) {
        DeliveryAcknowledged() => ('delivered', 'acknowledged', null),
        DeliveryPermanent(:final errorClass) => (
          'dead',
          'permanent',
          errorClass,
        ),
        DeliveryRetryable(:final errorClass) when claim.attemptNumber >= 20 => (
          'dead',
          'retryable',
          errorClass,
        ),
        DeliveryRetryable(:final errorClass) => (
          'queued',
          'retryable',
          errorClass,
        ),
      };
      final delay = math.min(300, 1 << math.min(19, claim.attemptNumber - 1));
      final updated = await session.db.unsafeExecute(
        '''UPDATE outbox SET status=@status,claim_id=NULL,lease_until=NULL,
        next_attempt_at=CASE WHEN @status='queued' THEN clock_timestamp()+@delay*interval '1 second' ELSE NULL END,
        dead_reason=CASE WHEN @status='dead' THEN @error ELSE NULL END
        WHERE created_at=@created AND delivery_id=CAST(@id AS uuid)
          AND status='delivering' AND claim_id=CAST(@claim AS uuid)
          AND lease_until>clock_timestamp()''',
        parameters: QueryParameters.named({
          'created': claim.createdAt,
          'id': claim.deliveryId,
          'claim': claim.claimId,
          'status': status,
          'error': error,
          'delay': delay,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (updated == 0) return false;
      await session.db.unsafeExecute(
        '''UPDATE delivery_attempts SET "finishedAt"=clock_timestamp(),outcome=@outcome,"errorClass"=@error
        WHERE "outboxCreatedAt"=@created AND "deliveryId"=CAST(@id AS uuid) AND "claimId"=CAST(@claim AS uuid) AND "attemptNumber"=@number AND outcome='started' ''',
        parameters: QueryParameters.named({
          'created': claim.createdAt,
          'id': claim.deliveryId,
          'claim': claim.claimId,
          'number': claim.attemptNumber,
          'outcome': attemptOutcome,
          'error': error,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      return true;
    });
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
