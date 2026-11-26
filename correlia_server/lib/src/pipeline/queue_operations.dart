import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import '../generated/protocol.dart';
import '../output/queue_intents.dart';
import '../secrets/secret_store.dart';

const _defaultPage = 50;
const _maxPage = 100;
final _uuid = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');
final _code = RegExp(r'^[a-z][a-z0-9_.-]{0,63}$');
const _failureColumns =
    'occurrence_id,scope_id::text,work_at,work_id::text,failed_at,error_class,snapshot_id,field_path';

Never _invalid(String code) => throw QueueOperatorException(code: code);

/// Bounds the directory reads and replays exact committed failure occurrences.
final class QueueOperations {
  const QueueOperations(
    this.session, {
    this.secretStore,
    this.clock,
    this.beforeWorkLockForTest,
    this.beforeConfigLockForTest,
  });

  final Session session;
  final SecretStore? secretStore;
  final DateTime Function()? clock;

  /// Test barrier after page selection, before work locks.
  final Future<void> Function()? beforeWorkLockForTest;

  /// Test barrier after work locks, before the active policy lock.
  final Future<void> Function()? beforeConfigLockForTest;

  Future<DateTime> _now(Transaction tx) async =>
      clock?.call().toUtc() ??
      ((await session.db.unsafeQuery(
                'SELECT clock_timestamp()',
                transaction: tx,
              )).single[0]!
              as DateTime)
          .toUtc();

  Future<T> _transaction<T>(Future<T> Function(Transaction) body) =>
      session.db.transaction((tx) async {
        await session.db.unsafeSimpleExecute(
          "SET LOCAL lock_timeout='2s'; SET LOCAL statement_timeout='5s'",
          transaction: tx,
        );
        return body(tx);
      });

  /// Lists active failure metadata without reading sender or output payloads.
  Future<QueueFailurePage> list(
    QueueFailureFilter filter, {
    int limit = _defaultPage,
    String? cursor,
  }) => _transaction((tx) async {
    final now = await _now(tx);
    final page = await _page(tx, filter, now, limit, cursor, replay: false);
    return QueueFailurePage(failures: page.failures, continuation: page.next);
  });

  /// Replays exactly the named occurrence, not a later failure of the same row.
  Future<QueueReplayResult> replayOne(
    QueueFailureKind kind,
    int occurrence,
    String actor,
  ) => _transaction((tx) async {
    if (occurrence < 1) _invalid('invalid_occurrence');
    final now = await _now(tx);
    final row = (await session.db.unsafeQuery(
      'SELECT $_failureColumns FROM pipeline_dead_letter WHERE kind=@kind AND occurrence_id=@id',
      parameters: QueryParameters.named({'kind': kind.name, 'id': occurrence}),
      transaction: tx,
    )).singleOrNull;
    if (row == null) {
      return QueueReplayResult(
        queued: 0,
        refused: 1,
        items: [QueueReplayItem(occurrence: occurrence, outcome: 'not_active')],
      );
    }
    return _replay(tx, kind, [_failure(row, kind, now)], actor, now, null);
  });

  /// Replays one filtered page using the same fixed upper bound as its cursor.
  Future<QueueReplayResult> replayBatch(
    QueueFailureFilter filter,
    String actor, {
    int limit = _defaultPage,
    String? cursor,
  }) => _transaction((tx) async {
    final now = await _now(tx);
    final page = await _page(tx, filter, now, limit, cursor, replay: true);
    return _replay(tx, filter.kind, page.failures, actor, now, page.next);
  });

  Future<({List<QueueFailure> failures, String? next})> _page(
    Transaction tx,
    QueueFailureFilter filter,
    DateTime now,
    int limit,
    String? cursor, {
    required bool replay,
  }) async {
    final scope = filter.scopeId;
    final error = filter.errorClass;
    final lower = filter.from?.toUtc();
    final through = filter.through?.toUtc();
    bool validTime(DateTime? date) =>
        date == null || (date.year >= 1 && date.year <= 9999);
    if (limit < 1 ||
        limit > _maxPage ||
        (scope != null && !_uuid.hasMatch(scope)) ||
        (error != null && !_code.hasMatch(error)) ||
        !validTime(lower) ||
        !validTime(through) ||
        (lower != null && through != null && lower.isAfter(through))) {
      _invalid('invalid_filter');
    }
    final filterKey = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              replay,
              filter.kind.name,
              scope,
              error,
              lower?.microsecondsSinceEpoch,
              through?.microsecondsSinceEpoch,
            ]),
          ),
        )
        .toString();
    var high = through != null && through.isBefore(now) ? through : now;
    DateTime? after;
    int? occurrence;
    if (cursor != null) {
      if (cursor.length > 256) _invalid('invalid_continuation');
      try {
        final decoded = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
        );
        if (decoded case [
          final String key,
          final int highUs,
          final int afterUs,
          final int id,
        ] when key == filterKey && id > 0) {
          final bound = DateTime.fromMicrosecondsSinceEpoch(
            highUs,
            isUtc: true,
          );
          after = DateTime.fromMicrosecondsSinceEpoch(afterUs, isUtc: true);
          if (!validTime(after) ||
              !validTime(bound) ||
              bound.isAfter(high) ||
              after.isAfter(bound) ||
              (lower != null && after.isBefore(lower))) {
            _invalid('invalid_continuation');
          }
          high = bound;
          occurrence = id;
        } else {
          _invalid('invalid_continuation');
        }
      } catch (_) {
        _invalid('invalid_continuation');
      }
    }
    final rows = await session.db.unsafeQuery(
      '''
      SELECT $_failureColumns FROM pipeline_dead_letter
      WHERE kind=@kind AND failed_at<=@high
        ${scope == null ? '' : 'AND scope_id=@scope::uuid'}
        ${error == null ? '' : 'AND error_class=@error'}
        ${lower == null ? '' : 'AND failed_at>=@lower'}
        ${after == null ? '' : 'AND (failed_at,occurrence_id)>(@after,@occurrence)'}
      ORDER BY failed_at,occurrence_id LIMIT @limit
    ''',
      parameters: QueryParameters.named({
        'kind': filter.kind.name,
        'high': high,
        'limit': limit + 1,
        'scope': ?scope,
        'error': ?error,
        'lower': ?lower,
        'after': ?after,
        'occurrence': ?occurrence,
      }),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    final page = [
      for (final row in rows.take(limit)) _failure(row, filter.kind, now),
    ];
    final next = rows.length <= limit
        ? null
        : base64Url
              .encode(
                utf8.encode(
                  jsonEncode([
                    filterKey,
                    high.microsecondsSinceEpoch,
                    page.last.failedAt.microsecondsSinceEpoch,
                    page.last.occurrence,
                  ]),
                ),
              )
              .replaceAll('=', '');
    return (failures: page, next: next);
  }

  static QueueFailure _failure(
    DatabaseResultRow row,
    QueueFailureKind kind,
    DateTime now,
  ) {
    final failed = (row[4]! as DateTime).toUtc();
    final code = row[5]! as String;
    final pin = row[6] as String?;
    final path = row[7] as String?;
    return QueueFailure(
      occurrence: row[0]! as int,
      scopeId: row[1]! as String,
      kind: kind,
      workAt: (row[2]! as DateTime).toUtc(),
      workId: row[3]! as String,
      failedAt: failed,
      ageSeconds: failed.isAfter(now) ? 0 : now.difference(failed).inSeconds,
      errorClass: _code.hasMatch(code) ? code : 'unknown_failure',
      snapshotId:
          kind == QueueFailureKind.raw &&
              pin != null &&
              _snapshotId.hasMatch(pin)
          ? pin
          : null,
      fieldPath:
          kind == QueueFailureKind.raw && path != null && path.length <= 256
          ? path
          : null,
    );
  }

  static final _snapshotId = RegExp(r'^[a-f0-9]{64}$');

  Future<QueueReplayResult> _replay(
    Transaction tx,
    QueueFailureKind kind,
    List<QueueFailure> page,
    String actor,
    DateTime now,
    String? continuation,
  ) async {
    var ready = <int, DatabaseResultRow>{};
    final outcomes = <int, String>{};
    if (page.isNotEmpty) {
      final ids = jsonEncode([for (final entry in page) entry.occurrence]);
      final raw = kind == QueueFailureKind.raw;
      final table = raw ? 'raw_inbox' : 'outbox';
      final at = raw ? 'observed_at' : 'created_at';
      final id = raw ? 'raw_id' : 'delivery_id';
      final status = raw ? 'failed' : 'dead';
      await beforeWorkLockForTest?.call();
      final locked = await session.db.unsafeQuery(
        '''
        SELECT f.occurrence_id FROM jsonb_array_elements_text(@ids::jsonb) ids(id)
        JOIN pipeline_dead_letter f ON f.occurrence_id=ids.id::bigint
        JOIN $table w ON (w.$at,w.$id)=(f.work_at,f.work_id)
        WHERE f.kind=@kind AND w.status='$status'
        ORDER BY w.$at,w.$id FOR UPDATE OF w
      ''',
        parameters: QueryParameters.named({'ids': ids, 'kind': kind.name}),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      DatabaseResultRow? lockedSnapshot;
      if (locked.isNotEmpty) {
        await beforeConfigLockForTest?.call();
        lockedSnapshot = (await session.db.unsafeQuery(
          '''
          SELECT "snapshotId" FROM ingest_active_config WHERE singleton=1
          FOR ${raw ? 'SHARE' : 'UPDATE'}
        ''',
          transaction: tx,
          timeoutInSeconds: 5,
        )).singleOrNull;
        // Once locked, check the occurrence again in a fresh snapshot. A raw
        // row or intent may have completed a replay/failure cycle since selection.
        final lockedIds = jsonEncode([for (final row in locked) row[0]]);
        final fields = raw
            ? "w.source_id::text, EXISTS (SELECT 1 FROM icinga2_raw_origin o WHERE o.raw_id=w.raw_id)"
            : 'w.output_id::text,w.output_kind,w.config_snapshot_id,w.signing_key_ref,w.signing_key_commitment';
        final rows = await session.db.unsafeQuery(
          '''
          SELECT f.occurrence_id,f.work_at,f.work_id::text,
            f.failed_at<=@now::timestamptz-make_interval(days=>p.dead_letter_retention_days), $fields
          FROM jsonb_array_elements_text(@ids::jsonb) ids(id)
          JOIN pipeline_dead_letter f ON f.occurrence_id=ids.id::bigint
          JOIN $table w ON (w.$at,w.$id)=(f.work_at,f.work_id)
          CROSS JOIN pipeline_queue_policy p WHERE p.singleton=1 AND w.status='$status'
        ''',
          parameters: QueryParameters.named({
            'ids': lockedIds,
            'now': await _now(tx),
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        ready = {for (final row in rows) row[0]! as int: row};
      }
      for (final entry in page) {
        final row = ready[entry.occurrence];
        if (row == null) {
          outcomes[entry.occurrence] = 'not_active';
        } else if (row[3] == true) {
          outcomes[entry.occurrence] = 'expired';
          ready.remove(entry.occurrence);
        }
      }
      if (ready.isNotEmpty) {
        final active = lockedSnapshot == null
            ? null
            : (await session.db.unsafeQuery(
                'SELECT "snapshotId","publicJson" FROM ingest_config_snapshot WHERE "snapshotId"=@pin',
                parameters: QueryParameters.named({'pin': lockedSnapshot[0]}),
                transaction: tx,
                timeoutInSeconds: 5,
              )).single;
        if (raw) {
          await _replayRaw(tx, ready, page, active, outcomes, now);
        } else {
          await _replayDelivery(tx, ready, page, active, outcomes);
        }
      }
    }
    final items = [
      for (final entry in page)
        QueueReplayItem(
          occurrence: entry.occurrence,
          outcome: outcomes[entry.occurrence]!,
        ),
    ];
    final queued = items.where((item) => item.outcome == 'queued').length;
    if (queued > 0) {
      await session.db.unsafeExecute(
        '''
        INSERT INTO activity (occurred_at,entity_kind,entity_id,entity_version,change_kind,actor_kind,actor_ref,cause_raw_id)
        VALUES (@now,@kind,@occurrence,@count,'dead_letter_replayed','machine',@actor,@raw_id::uuid)
      ''',
        parameters: QueryParameters.named({
          'now': now,
          'kind': kind == QueueFailureKind.raw
              ? 'pipeline_failure'
              : 'delivery_failure',
          'count': queued,
          'actor': actor,
          'occurrence': page.length == 1 ? page.single.occurrence : 0,
          'raw_id': kind == QueueFailureKind.raw && page.length == 1
              ? page.single.workId
              : null,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
    }
    return QueueReplayResult(
      queued: queued,
      refused: items.length - queued,
      items: items,
      continuation: continuation,
    );
  }

  static Map<String, Object?> _snapshot(DatabaseResultRow active) =>
      jsonDecode(active[1]! as String) as Map<String, Object?>;

  Future<void> _replayRaw(
    Transaction tx,
    Map<int, DatabaseResultRow> work,
    List<QueueFailure> plan,
    DatabaseResultRow? active,
    Map<int, String> outcomes,
    DateTime now,
  ) async {
    final sources = <String, String>{};
    if (active != null) {
      for (final source
          in (_snapshot(active)['sources']! as List<Object?>)
              .cast<Map<String, Object?>>()) {
        if (source['enabled'] == true) {
          sources[source['id']! as String] =
              source['mode'] as String? ?? 'webhook';
        }
      }
    }
    final candidates = <DatabaseResultRow>[];
    for (final entry in plan) {
      final row = work[entry.occurrence];
      if (row == null) continue;
      final mode = sources[row[4]! as String];
      if (mode == null || (mode == 'event_streams') != row[5]) {
        outcomes[entry.occurrence] = 'source_unavailable';
      } else {
        candidates.add(row);
      }
    }
    if (candidates.isEmpty) return;
    final pin = active![0]! as String;
    final args = QueryParameters.named({
      'pin': pin,
      'sources': jsonEncode({for (final r in candidates) r[4]}.toList()),
    });
    await session.db.unsafeQuery(
      'SELECT correlia_lock_replay_pins(@pin,@sources::jsonb)',
      parameters: args,
      transaction: tx,
      timeoutInSeconds: 5,
    );
    final available =
        (await session.db.unsafeQuery(
              '''
      SELECT greatest(0,p.pending_max_rows-q.pending_rows) FROM pipeline_pending q
      CROSS JOIN pipeline_queue_policy p WHERE q.singleton=1 AND p.singleton=1 FOR UPDATE OF q
    ''',
              transaction: tx,
              timeoutInSeconds: 5,
            )).single[0]!
            as int;
    for (final (index, row) in candidates.indexed) {
      final occurrence = row[0]! as int;
      if (index >= available) {
        outcomes[occurrence] = 'inbox_capacity';
        continue;
      }
      await session.db.unsafeExecute(
        '''
        UPDATE raw_inbox SET status='pending',config_snapshot_id=@pin,queued_at=@now,
          attempt_count=0,next_attempt_at=NULL,outcome_json=NULL,processing_epoch=processing_epoch+1
        WHERE observed_at=@at AND raw_id=@id::uuid
      ''',
        parameters: QueryParameters.named({
          'at': row[1],
          'id': row[2],
          'pin': pin,
          'now': now,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      outcomes[occurrence] = 'queued';
    }
    await session.db.unsafeQuery(
      'SELECT correlia_cleanup_replay_pins(@pin,@sources::jsonb)',
      parameters: args,
      transaction: tx,
      timeoutInSeconds: 5,
    );
  }

  Future<void> _replayDelivery(
    Transaction tx,
    Map<int, DatabaseResultRow> work,
    List<QueueFailure> plan,
    DatabaseResultRow? active,
    Map<int, String> outcomes,
  ) async {
    if (active == null) {
      for (final id in work.keys) {
        outcomes[id] = 'output_unavailable';
      }
      return;
    }
    final outputs = <String>{
      for (final row in await session.db.unsafeQuery(
        'SELECT output_id FROM correlia_retained_output_ids()',
        transaction: tx,
        timeoutInSeconds: 5,
      ))
        row[0]! as String,
      for (final output
          in (_snapshot(active)['outputs']! as List<Object?>)
              .cast<Map<String, Object?>>())
        output['id']! as String,
    };
    if (outputs.length >= 64) {
      // Upgraded installations can already exceed the bounded inventory.
      final existing = await session.db.unsafeQuery(
        '''
        SELECT c.output_id::text FROM jsonb_array_elements_text(@ids::jsonb) ids(id)
        JOIN pipeline_output_capacity c ON c.output_id=ids.id::uuid
        WHERE c.live_rows>0 OR c.pinned_rows>0
      ''',
        parameters: QueryParameters.named({
          'ids': jsonEncode({for (final row in work.values) row[4]}.toList()),
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      outputs.addAll(existing.map((row) => row[0]! as String));
    }
    final store = secretStore;
    final references = {
      for (final row in work.values)
        if (row[5] == 'webhook') row[7]! as String,
    };
    var material = const <String, Uint8List>{};
    if (store != null) {
      try {
        material = await store.readMany(session, references, transaction: tx);
      } on SecretResolutionError {
        // One corrupt record must not prevent other lanes in the page replaying.
        material = {};
        for (final reference in references) {
          try {
            final bytes = await store.read(session, reference, transaction: tx);
            if (bytes != null) material[reference] = bytes;
          } on SecretResolutionError {
            continue;
          }
        }
      }
    }
    final accepted = <DatabaseResultRow>[];
    for (final entry in plan) {
      final row = work[entry.occurrence];
      if (row == null) continue;
      if (row[5] == 'webhook') {
        final reference = row[7]! as String;
        final bytes = material[reference];
        if (bytes == null ||
            !store!.commitments.verify(reference, row[8]! as String, bytes)) {
          outcomes[entry.occurrence] = 'signing_key_unavailable';
          continue;
        }
      }
      final output = row[4]! as String;
      if (outputs.length >= 64 && !outputs.contains(output)) {
        outcomes[entry.occurrence] = 'live_output_bound';
        continue;
      }
      outputs.add(output);
      accepted.add(row);
    }
    if (accepted.isEmpty) return;
    // Every replay holds its outbox row and the exclusive registry fence.
    await lockOutputCapacity(session, tx, {
      for (final row in accepted) row[4]! as String,
    });
    final commitments = QueryParameters.named({
      'rows': jsonEncode([
        for (final row in accepted)
          {
            'output': row[4],
            'kind': row[5],
            'pin': row[6],
            'reference': row[7],
            'commitment': row[8],
          },
      ]),
    });
    await session.db.unsafeQuery(
      'SELECT correlia_lock_delivery_replay_keys(@rows::jsonb)',
      parameters: commitments,
      transaction: tx,
      timeoutInSeconds: 5,
    );
    for (final row in accepted) {
      await session.db.unsafeExecute(
        '''
        UPDATE outbox SET status='queued',claim_id=NULL,lease_until=NULL,next_attempt_at=NULL,
          dead_reason=NULL,retry_base=attempt_count WHERE created_at=@at AND delivery_id=@id::uuid
      ''',
        parameters: QueryParameters.named({'at': row[1], 'id': row[2]}),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      outcomes[row[0]! as int] = 'queued';
    }
  }

  /// Reports bounded operational metadata and the same pressure as admission.
  Future<QueueStatus> status() => _transaction((tx) async {
    final row = (await session.db.unsafeQuery(
      '''
      SELECT p.pending_max_rows,p.pending_max_age_seconds,p.disk_budget_bytes,p.disk_watermark_percent,
        q.pending_rows,correlia_queue_pressure(q.pending_rows,1),
        (SELECT greatest(0,extract(epoch FROM clock_timestamp()-coalesce(queued_at,observed_at)))::bigint
          FROM raw_inbox WHERE status='pending' ORDER BY coalesce(queued_at,observed_at) LIMIT 1),
        EXISTS(SELECT 1 FROM pipeline_partition_retry r WHERE problem IS NOT NULL
          AND day>=(clock_timestamp() AT TIME ZONE 'UTC')::date
          AND NOT correlia_partition_covered(r.parent_name,r.day))
      FROM pipeline_queue_policy p CROSS JOIN pipeline_pending q WHERE p.singleton=1 AND q.singleton=1
    ''',
      transaction: tx,
      timeoutInSeconds: 5,
    )).single;
    final sample = row[2] == null
        ? null
        : (await session.db.unsafeQuery(
                'SELECT database_bytes FROM pipeline_disk_sample WHERE singleton=1',
                transaction: tx,
              )).single[0]
              as int?;
    final lanes = await session.db.unsafeQuery(
      '''
      SELECT output_id::text,max_rows,max_payload_bytes,overflow_policy,used_rows,used_bytes,
        discarded_count,overflow_activity_id,
        overflow_policy='block_ingest' AND (used_rows>=max_rows OR used_bytes>=max_payload_bytes
          OR demand_rows>max_rows-used_rows OR demand_bytes>max_payload_bytes-used_bytes) AS blocks
      FROM pipeline_output_capacity WHERE active OR used_rows>0 OR pinned_rows>0 OR overflow_activity_id IS NOT NULL
        OR overflow_policy='block_ingest'
      ORDER BY blocks DESC,output_id LIMIT 65
    ''',
      transaction: tx,
      timeoutInSeconds: 5,
    );
    final maintenance = (await session.db.unsafeQuery('''
      SELECT lane,outcome,finished_at,affected FROM pipeline_maintenance_outcome WHERE singleton=1
    ''', transaction: tx)).singleOrNull;
    return QueueStatus(
      pendingMaxRows: row[0]! as int,
      pendingMaxAgeSeconds: row[1]! as int,
      diskBudgetBytes: row[2] as int?,
      diskWatermarkPercent: row[3]! as int,
      pendingRows: row[4]! as int,
      pressure: row[5] as String?,
      oldestPendingAgeSeconds: row[6] as int?,
      partitionDegraded: row[7]! as bool,
      databaseBytes: sample,
      outputsTruncated: lanes.length > 64,
      outputs: [
        for (final lane in lanes.take(64))
          QueueOutputStatus(
            outputId: lane[0]! as String,
            maxRows: lane[1]! as int,
            maxPayloadBytes: lane[2]! as int,
            overflowPolicy: lane[3]! as String,
            usedRows: lane[4]! as int,
            usedBytes: lane[5]! as int,
            discardedCount: lane[6]! as int,
            overflowActivityId: lane[7] as int?,
            blocksIngress: lane[8]! as bool,
          ),
      ],
      maintenance: maintenance == null
          ? null
          : QueueMaintenanceStatus(
              lane: maintenance[0]! as String,
              outcome: maintenance[1]! as String,
              finishedAt: (maintenance[2]! as DateTime).toUtc(),
              affected: maintenance[3]! as int,
            ),
    );
  });
}
