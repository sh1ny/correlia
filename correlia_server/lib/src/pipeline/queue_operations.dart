import 'dart:async';
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

const _dbBudget = Duration(seconds: 5);

final class _QueueTransaction {
  const _QueueTransaction(this._session, this.tx, this._elapsed);

  final Session _session;
  final Transaction tx;
  final Duration Function() _elapsed;

  Duration remaining() {
    final left = _dbBudget - _elapsed();
    if (left <= Duration.zero) {
      throw TimeoutException('queue operation deadline');
    }
    return left;
  }

  Future<void> beforeStatement() => _session.db.unsafeSimpleExecute(
    "SET LOCAL statement_timeout='${remaining().inMilliseconds.clamp(1, 5000)}ms'",
    transaction: tx,
    timeoutInSeconds: 5,
  );

  Future<DatabaseResult> query(
    String sql, {
    QueryParameters? parameters,
    Future<void> Function(Transaction)? beforeQueryForTest,
  }) async {
    await beforeStatement();
    await beforeQueryForTest?.call(tx);
    return _session.db.unsafeQuery(
      sql,
      parameters: parameters,
      transaction: tx,
      timeoutInSeconds: 5,
    );
  }

  Future<void> execute(String sql, {QueryParameters? parameters}) async {
    await beforeStatement();
    await _session.db.unsafeExecute(
      sql,
      parameters: parameters,
      transaction: tx,
      timeoutInSeconds: 5,
    );
  }
}

/// Bounds the directory reads and replays exact committed failure occurrences.
final class QueueOperations {
  const QueueOperations(
    this.session, {
    this.secretStore,
    this.clock,
    this.beforeWorkLockForTest,
    this.beforeConfigLockForTest,
    this.elapsedForTest,
    this.beforeCommitForTest,
    this.beforePendingLockForTest,
    this.beforeDeliveryKeysLockForTest,
    this.observePageQueryForTest,
  });

  final Session session;
  final SecretStore? secretStore;
  final DateTime Function()? clock;

  /// Test barrier after page selection, before work locks.
  final Future<void> Function()? beforeWorkLockForTest;

  /// Test barrier after work locks, before the active policy lock.
  final Future<void> Function()? beforeConfigLockForTest;

  /// Supplies fixture elapsed time instead of a stopwatch.
  final Duration Function()? elapsedForTest;

  /// Observes staged work and audit rows before the deadline check at commit.
  final Future<void> Function(Transaction)? beforeCommitForTest;

  /// Observes the replay transaction immediately before reserving pending rows.
  final Future<void> Function(Transaction)? beforePendingLockForTest;

  /// Observes the delivery replay transaction just before its final key locks.
  final Future<void> Function(Transaction)? beforeDeliveryKeysLockForTest;

  /// Inspects the same bound query and parameters that select a failure page.
  final Future<void> Function(Transaction, String, QueryParameters)?
  observePageQueryForTest;

  Future<DateTime> _now(_QueueTransaction tx) async =>
      clock?.call().toUtc() ??
      ((await tx.query('SELECT clock_timestamp()')).single[0]! as DateTime)
          .toUtc();

  Future<T> _transaction<T>(Future<T> Function(_QueueTransaction) body) {
    final stopwatch = elapsedForTest == null ? (Stopwatch()..start()) : null;
    final elapsed = elapsedForTest ?? () => stopwatch!.elapsed;
    return session.db.transaction((tx) async {
      final operation = _QueueTransaction(session, tx, elapsed);
      operation.remaining();
      await session.db.unsafeSimpleExecute(
        "SET LOCAL lock_timeout='2s'; SET LOCAL statement_timeout='5s'",
        transaction: tx,
        timeoutInSeconds: 5,
      );
      final result = await body(operation);
      await beforeCommitForTest?.call(tx);
      operation.remaining();
      return result;
    });
  }

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
    final row = (await tx.query(
      'SELECT $_failureColumns FROM pipeline_dead_letter WHERE kind=@kind AND occurrence_id=@id',
      parameters: QueryParameters.named({'kind': kind.name, 'id': occurrence}),
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

  /// Replays one filtered page within the continuation's time and ID bounds.
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
    _QueueTransaction tx,
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
    final int highOccurrence;
    if (cursor == null) {
      final bound = (await tx.query(
        'SELECT coalesce(max(occurrence_id),0) FROM pipeline_dead_letter',
      )).single;
      highOccurrence = bound[0]! as int;
    } else {
      if (cursor.length > 256) _invalid('invalid_continuation');
      try {
        final decoded = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
        );
        if (decoded case [
          final String key,
          final int highUs,
          final int highId,
          final int afterUs,
          final int id,
        ] when key == filterKey && id > 0 && id <= highId) {
          final bound = DateTime.fromMicrosecondsSinceEpoch(
            highUs,
            isUtc: true,
          );
          after = DateTime.fromMicrosecondsSinceEpoch(afterUs, isUtc: true);
          if (!validTime(after) ||
              !validTime(bound) ||
              (through != null && bound.isAfter(through)) ||
              after.isAfter(bound) ||
              (lower != null && after.isBefore(lower))) {
            _invalid('invalid_continuation');
          }
          high = bound;
          highOccurrence = highId;
          occurrence = id;
        } else {
          _invalid('invalid_continuation');
        }
      } catch (_) {
        _invalid('invalid_continuation');
      }
    }
    final sql =
        '''
      SELECT $_failureColumns FROM pipeline_dead_letter
      WHERE kind=@kind AND failed_at<=@high AND occurrence_id<=@highOccurrence
        ${scope == null ? '' : 'AND scope_id=@scope::uuid'}
        ${error == null ? '' : 'AND error_class=@error'}
        ${lower == null ? '' : 'AND failed_at>=@lower'}
        ${after == null ? '' : 'AND (failed_at,occurrence_id)>(@after,@occurrence)'}
      ORDER BY failed_at,occurrence_id LIMIT @limit
    ''';
    final parameters = QueryParameters.named({
      'kind': filter.kind.name,
      'high': high,
      'highOccurrence': highOccurrence,
      'limit': limit + 1,
      'scope': ?scope,
      'error': ?error,
      'lower': ?lower,
      'after': ?after,
      'occurrence': ?occurrence,
    });
    await observePageQueryForTest?.call(tx.tx, sql, parameters);
    final rows = await tx.query(sql, parameters: parameters);
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
                    highOccurrence,
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
    _QueueTransaction tx,
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
      final locked = await tx.query(
        '''
        SELECT f.occurrence_id FROM jsonb_array_elements_text(@ids::jsonb) ids(id)
        JOIN pipeline_dead_letter f ON f.occurrence_id=ids.id::bigint
        JOIN $table w ON (w.$at,w.$id)=(f.work_at,f.work_id)
        WHERE f.kind=@kind AND w.status='$status'
        ORDER BY w.$at,w.$id FOR UPDATE OF w
      ''',
        parameters: QueryParameters.named({'ids': ids, 'kind': kind.name}),
      );
      DatabaseResultRow? lockedSnapshot;
      if (locked.isNotEmpty) {
        await beforeConfigLockForTest?.call();
        lockedSnapshot = (await tx.query(
          '''
          SELECT "snapshotId" FROM ingest_active_config WHERE singleton=1
          FOR ${raw ? 'SHARE' : 'UPDATE'}
        ''',
        )).singleOrNull;
        // Once locked, check the occurrence again in a fresh snapshot. A raw
        // row or intent may have completed a replay/failure cycle since selection.
        final lockedIds = jsonEncode([for (final row in locked) row[0]]);
        final fields = raw
            ? "w.source_id::text, EXISTS (SELECT 1 FROM icinga2_raw_origin o WHERE o.raw_id=w.raw_id), f.legacy_raw_failure"
            : 'w.output_id::text,w.output_kind,w.config_snapshot_id,w.signing_key_ref,w.signing_key_commitment';
        final rows = await tx.query(
          '''
          SELECT f.occurrence_id,f.work_at,f.work_id::text,
            f.failed_at<=correlia_retention_cutoff(@now::timestamptz,p.dead_letter_retention_days), $fields
          FROM jsonb_array_elements_text(@ids::jsonb) ids(id)
          JOIN pipeline_dead_letter f ON f.occurrence_id=ids.id::bigint
          JOIN $table w ON (w.$at,w.$id)=(f.work_at,f.work_id)
          CROSS JOIN pipeline_queue_policy p WHERE p.singleton=1 AND w.status='$status'
        ''',
          parameters: QueryParameters.named({
            'ids': lockedIds,
            'now': await _now(tx),
          }),
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
            : (await tx.query(
                'SELECT "snapshotId","publicJson" FROM ingest_config_snapshot WHERE "snapshotId"=@pin',
                parameters: QueryParameters.named({'pin': lockedSnapshot[0]}),
              )).single;
        if (raw) {
          await _replayRaw(tx, ready, page, active, outcomes);
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
      await tx.execute(
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

  Future<DateTime> _expiryCutoff(_QueueTransaction tx, DateTime now) async =>
      (await tx.query(
            '''
        SELECT correlia_retention_cutoff(@now::timestamptz,dead_letter_retention_days)
        FROM pipeline_queue_policy WHERE singleton=1
        ''',
            parameters: QueryParameters.named({'now': now}),
          )).single[0]!
          as DateTime;

  Future<void> _replayRaw(
    _QueueTransaction tx,
    Map<int, DatabaseResultRow> work,
    List<QueueFailure> plan,
    DatabaseResultRow? active,
    Map<int, String> outcomes,
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
    final candidates = <(DatabaseResultRow, QueueFailure)>[];
    for (final entry in plan) {
      final row = work[entry.occurrence];
      if (row == null) continue;
      final mode = sources[row[4]! as String];
      if (mode == null || (mode == 'event_streams') != row[5]) {
        outcomes[entry.occurrence] = 'source_unavailable';
      } else {
        candidates.add((row, entry));
      }
    }
    if (candidates.isEmpty) return;
    final pin = active![0]! as String;
    final args = QueryParameters.named({
      'pin': pin,
      'sources': jsonEncode(
        {for (final (row, _) in candidates) row[4]}.toList(),
      ),
    });
    await tx.query(
      'SELECT correlia_lock_replay_pins(@pin,@sources::jsonb)',
      parameters: args,
    );
    final available =
        (await tx.query(
              '''
      SELECT greatest(0,p.pending_max_rows-q.pending_rows) FROM pipeline_pending q
      CROSS JOIN pipeline_queue_policy p WHERE q.singleton=1 AND p.singleton=1 FOR UPDATE OF q
    ''',
              beforeQueryForTest: beforePendingLockForTest,
            )).single[0]!
            as int;
    final enqueuedAt = await _now(tx);
    final cutoff = await _expiryCutoff(tx, enqueuedAt);
    var remaining = available;
    for (final (row, entry) in candidates) {
      final occurrence = entry.occurrence;
      if (!entry.failedAt.isAfter(cutoff)) {
        outcomes[occurrence] = 'expired';
        continue;
      }
      if (remaining == 0) {
        outcomes[occurrence] = 'inbox_capacity';
        continue;
      }
      await tx.execute(
        '''
        UPDATE raw_inbox SET status='pending',config_snapshot_id=@pin,queued_at=@now,
          legacy_failure=legacy_failure OR @legacy,
          attempt_count=0,next_attempt_at=NULL,outcome_json=NULL,processing_epoch=processing_epoch+1
        WHERE observed_at=@at AND raw_id=@id::uuid
      ''',
        parameters: QueryParameters.named({
          'at': row[1],
          'id': row[2],
          'pin': pin,
          'now': enqueuedAt,
          'legacy': row[6],
        }),
      );
      outcomes[occurrence] = 'queued';
      remaining--;
    }
    await tx.query(
      'SELECT correlia_cleanup_replay_pins(@pin,@sources::jsonb)',
      parameters: args,
    );
  }

  Future<void> _replayDelivery(
    _QueueTransaction tx,
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
      for (final row in await tx.query(
        'SELECT output_id FROM correlia_retained_output_ids()',
      ))
        row[0]! as String,
      for (final output
          in (_snapshot(active)['outputs']! as List<Object?>)
              .cast<Map<String, Object?>>())
        output['id']! as String,
    };
    if (outputs.length >= 64) {
      // Upgraded installations can already exceed the bounded inventory.
      final existing = await tx.query(
        '''
        SELECT c.output_id::text FROM jsonb_array_elements_text(@ids::jsonb) ids(id)
        JOIN pipeline_output_capacity c ON c.output_id=ids.id::uuid
        WHERE c.live_rows>0 OR c.pinned_rows>0
      ''',
        parameters: QueryParameters.named({
          'ids': jsonEncode({for (final row in work.values) row[4]}.toList()),
        }),
      );
      outputs.addAll(existing.map((row) => row[0]! as String));
    }
    final store = secretStore;
    final references = {
      for (final row in work.values)
        if (row[5] == 'webhook') row[7]! as String,
    };
    var material = const <String, Uint8List>{};
    if (store != null && references.isNotEmpty) {
      try {
        await tx.beforeStatement();
        material = await store.readMany(
          session,
          references,
          transaction: tx.tx,
        );
      } on SecretResolutionError {
        // One corrupt record must not prevent other lanes in the page replaying.
        material = {};
        for (final reference in references) {
          try {
            await tx.beforeStatement();
            final bytes = await store.read(
              session,
              reference,
              transaction: tx.tx,
            );
            if (bytes != null) material[reference] = bytes;
          } on SecretResolutionError {
            continue;
          }
        }
      }
    }
    final candidates = <(DatabaseResultRow, QueueFailure)>[];
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
      candidates.add((row, entry));
    }
    if (candidates.isEmpty) return;
    // Every replay holds its outbox row and the exclusive registry fence.
    await tx.beforeStatement();
    await lockOutputCapacity(session, tx.tx, {
      for (final (row, _) in candidates) row[4]! as String,
    });
    final commitments = QueryParameters.named({
      'rows': jsonEncode([
        for (final (row, _) in candidates)
          {
            'output': row[4],
            'kind': row[5],
            'pin': row[6],
            'reference': row[7],
            'commitment': row[8],
          },
      ]),
    });
    await tx.query(
      'SELECT correlia_delivery_replay_keys(@rows::jsonb)',
      parameters: commitments,
      beforeQueryForTest: beforeDeliveryKeysLockForTest,
    );
    final cutoff = await _expiryCutoff(tx, await _now(tx));
    var cleanUnusedKeys = false;
    for (final (row, entry) in candidates) {
      final occurrence = entry.occurrence;
      if (!entry.failedAt.isAfter(cutoff)) {
        outcomes[occurrence] = 'expired';
        cleanUnusedKeys = true;
        continue;
      }
      final output = row[4]! as String;
      if (outputs.length >= 64 && !outputs.contains(output)) {
        outcomes[occurrence] = 'live_output_bound';
        cleanUnusedKeys = true;
        continue;
      }
      outputs.add(output);
      await tx.execute(
        '''
        UPDATE outbox SET status='queued',claim_id=NULL,lease_until=NULL,next_attempt_at=NULL,
          dead_reason=NULL,retry_base=attempt_count WHERE created_at=@at AND delivery_id=@id::uuid
      ''',
        parameters: QueryParameters.named({'at': row[1], 'id': row[2]}),
      );
      outcomes[occurrence] = 'queued';
    }
    if (cleanUnusedKeys) {
      await tx.query(
        'SELECT correlia_delivery_replay_keys(@rows::jsonb,true)',
        parameters: commitments,
      );
    }
  }

  /// Reports bounded operational metadata and the same pressure as admission.
  Future<QueueStatus> status() => _transaction((tx) async {
    final rows = await tx.query(
      '''
      WITH lanes AS MATERIALIZED (
        SELECT output_id,max_rows,max_payload_bytes,overflow_policy,used_rows,used_bytes,
          discarded_count,overflow_activity_id,
          overflow_policy='block_ingest' AND (used_rows>=max_rows OR used_bytes>=max_payload_bytes
            OR demand_rows>max_rows-used_rows OR demand_bytes>max_payload_bytes-used_bytes) AS blocks
        FROM pipeline_output_capacity WHERE active OR used_rows>0 OR pinned_rows>0 OR overflow_activity_id IS NOT NULL
        ORDER BY blocks DESC,output_id LIMIT 65
      ), oldest AS MATERIALIZED (
        SELECT coalesce(queued_at,observed_at) AS queued FROM raw_inbox
        WHERE status='pending' ORDER BY queued LIMIT 1
      ), measured AS MATERIALIZED (
        SELECT p AS policy,correlia_sample_database(p.disk_budget_bytes) AS database_bytes
        FROM pipeline_queue_policy p WHERE p.singleton=1
      ), summary AS MATERIALIZED (
        SELECT (m.policy).pending_max_rows,(m.policy).pending_max_age_seconds,
          (m.policy).disk_budget_bytes,(m.policy).disk_watermark_percent,
          q.pending_rows,correlia_queue_pressure(m.policy,q.pending_rows,1,
            EXISTS(SELECT 1 FROM lanes WHERE blocks),(SELECT queued FROM oldest),m.database_bytes),
          (SELECT greatest(0,floor(extract(epoch FROM clock_timestamp()-queued)))::bigint FROM oldest),
          EXISTS(SELECT 1 FROM pipeline_partition_retry r WHERE problem IS NOT NULL
            AND day>=(clock_timestamp() AT TIME ZONE 'UTC')::date
            AND NOT correlia_partition_covered(r.parent_name,r.day)),
          m.database_bytes
        FROM measured m CROSS JOIN pipeline_pending q WHERE q.singleton=1
      )
      SELECT s.*,l.output_id::text,l.max_rows,l.max_payload_bytes,l.overflow_policy,l.used_rows,l.used_bytes,
        l.discarded_count,l.overflow_activity_id,l.blocks
      FROM summary s LEFT JOIN lanes l ON true ORDER BY l.blocks DESC,l.output_id
    ''',
    );
    final row = rows.first;
    final maintenance = await tx.query('''
      SELECT lane,outcome,finished_at,affected FROM pipeline_maintenance_outcome
      ORDER BY completion_order DESC
    ''');
    QueueMaintenanceStatus batch(DatabaseResultRow row) =>
        QueueMaintenanceStatus(
          lane: row[0]! as String,
          outcome: row[1]! as String,
          finishedAt: (row[2]! as DateTime).toUtc(),
          affected: row[3]! as int,
        );
    return QueueStatus(
      pendingMaxRows: row[0]! as int,
      pendingMaxAgeSeconds: row[1]! as int,
      diskBudgetBytes: row[2] as int?,
      diskWatermarkPercent: row[3]! as int,
      pendingRows: row[4]! as int,
      pressure: row[5] as String?,
      oldestPendingAgeSeconds: row[6] as int?,
      partitionDegraded: row[7]! as bool,
      databaseBytes: row[8] as int?,
      outputsTruncated: rows.length > 64,
      outputs: [
        if (row[9] != null)
          for (final lane in rows.take(64))
            QueueOutputStatus(
              outputId: lane[9]! as String,
              maxRows: lane[10]! as int,
              maxPayloadBytes: lane[11]! as int,
              overflowPolicy: lane[12]! as String,
              usedRows: lane[13]! as int,
              usedBytes: lane[14]! as int,
              discardedCount: lane[15]! as int,
              overflowActivityId: lane[16] as int?,
              blocksIngress: lane[17]! as bool,
            ),
      ],
      maintenance: maintenance.isEmpty ? null : batch(maintenance.first),
      maintenanceFailures: [
        for (final row in maintenance)
          if (row[1] != 'ok') batch(row),
      ],
    );
  });
}
