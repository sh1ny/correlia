import 'dart:convert';

import 'package:postgres/postgres.dart';

import 'database.dart';
import 'lease.dart';
import 'sync_result.dart';

const _interrupted = 'interrupted';
const _holderLost = 'holder_lost';
const _sourceRetired = 'source_retired';
const _syncSpacingSeconds = 60;
const _retentionDays = 30;

/// The durable phase of a sync and its admitted work.
enum SyncPhase { reading, applying, complete, failed, stalled }

/// The outcome of an attempt to start reading a sync.
enum SyncStartDisposition { started, busy, paused, tooSoon, leaseLost }

/// The outcome and request sequence captured by a sync start.
class SyncStart {
  const SyncStart(
    this.disposition, {
    this.syncId,
    this.retryAfter,
    this.servedResyncSeq,
  });

  final SyncStartDisposition disposition;
  final String? syncId;
  final Duration? retryAfter;
  final int? servedResyncSeq;
}

/// A persisted sync outcome, including reader and pipeline counts.
class SyncProgress {
  const SyncProgress({
    required this.phase,
    required this.reason,
    required this.readProblem,
    required this.readEndAt,
    required this.rowsAdmitted,
    required this.rowsDone,
    required this.rowsFailed,
    required this.counts,
    required this.samples,
    required this.lastObject,
  });

  final SyncPhase phase;
  final String? reason;
  final String? readProblem;
  final DateTime? readEndAt;
  final int rowsAdmitted;
  final int rowsDone;
  final int rowsFailed;
  final Map<String, int> counts;
  final List<SyncBadObject> samples;
  final String? lastObject;
}

/// Fenced reader operations and retention for durable sync progress.
class SyncProgressStore {
  SyncProgressStore(this._connection) : _leases = StreamLeaseStore(_connection);

  final Connection _connection;
  final StreamLeaseStore _leases;

  /// Starts one reading under the lease and snapshots the request sequence.
  Future<SyncStart> start(
    StreamLease lease, {
    required String connectionId,
    bool paused = false,
  }) async {
    return await _leases.fenced<SyncStart>(lease, (tx) async {
          // A numbered status row serializes starts even when no progress exists.
          final status = await tx.execute(
            Sql.named('''
        SELECT "connectionId" FROM icinga2_stream_status
        WHERE "sourceId"=@source:uuid FOR UPDATE
      '''),
            parameters: {'source': lease.sourceId},
          );
          if (status.isEmpty) {
            throw StateError('Stream connection is not numbered');
          }
          if (status.single[0] != connectionId) {
            return const SyncStart(SyncStartDisposition.busy);
          }
          if (paused) return const SyncStart(SyncStartDisposition.paused);

          final open = await tx.execute(
            Sql.named('''
        SELECT sync_id::text, generation, connection_id
        FROM icinga2_sync_progress
        WHERE source_id=@source:uuid AND read_end_at IS NULL
        ORDER BY started_at DESC FOR UPDATE
      '''),
            parameters: {'source': lease.sourceId},
          );
          for (final row in open) {
            if (row[1] == lease.generation && row[2] == connectionId) {
              return const SyncStart(SyncStartDisposition.busy);
            }
          }
          for (final row in open) {
            await _closeReading(
              tx,
              row[0]! as String,
              row[1] == lease.generation ? _interrupted : _holderLost,
            );
          }
          if (open.isNotEmpty) {
            await tx.execute(
              Sql.named('''
          UPDATE icinga2_stream_status SET
            "lastSyncId"=COALESCE("currentSyncId", "lastSyncId"),
            "currentSyncId"=NULL
          WHERE "sourceId"=@source:uuid
        '''),
              parameters: {'source': lease.sourceId},
            );
          }

          final spacing = await tx.execute(
            Sql.named('''
        SELECT GREATEST(0, CEIL(EXTRACT(EPOCH FROM
          (started_at + @spacing:int4 * interval '1 second' - clock_timestamp())) * 1000000))::bigint
        FROM icinga2_sync_progress WHERE source_id=@source:uuid
        ORDER BY started_at DESC LIMIT 1
      '''),
            parameters: {
              'source': lease.sourceId,
              'spacing': _syncSpacingSeconds,
            },
          );
          if (spacing.isNotEmpty && (spacing.single[0]! as int) > 0) {
            return SyncStart(
              SyncStartDisposition.tooSoon,
              retryAfter: Duration(microseconds: spacing.single[0]! as int),
            );
          }
          final requests = await tx.execute(
            Sql.named('''
        SELECT COALESCE((SELECT "requestSeq" FROM icinga2_stream_resync
          WHERE "sourceId"=@source:uuid), 0)
      '''),
            parameters: {'source': lease.sourceId},
          );
          final served = requests.single[0]! as int;
          final inserted = await tx.execute(
            Sql.named('''
        INSERT INTO icinga2_sync_progress
          (sync_id, source_id, generation, connection_id, phase, started_at)
        VALUES (gen_random_uuid(), @source:uuid, @generation:int8,
          @connection:text, 'reading', clock_timestamp())
        RETURNING sync_id::text
      '''),
            parameters: {
              'source': lease.sourceId,
              'generation': lease.generation,
              'connection': connectionId,
            },
          );
          final id = inserted.single[0]! as String;
          await tx.execute(
            Sql.named('''
        UPDATE icinga2_stream_status SET "servedResyncSeq"=GREATEST("servedResyncSeq", @served:int8),
          "lastSyncId"=COALESCE("currentSyncId", "lastSyncId"),
          "currentSyncId"=@sync:uuid
        WHERE "sourceId"=@source:uuid
      '''),
            parameters: {
              'source': lease.sourceId,
              'served': served,
              'sync': id,
            },
          );
          return SyncStart(
            SyncStartDisposition.started,
            syncId: id,
            servedResyncSeq: served,
          );
        }) ??
        const SyncStart(SyncStartDisposition.leaseLost);
  }

  /// Records the end of reading and merges its diagnostics with pipeline counts.
  Future<bool> finish(
    StreamLease lease,
    String syncId,
    SyncReadReport report,
  ) async {
    return await _leases.fenced<bool>(lease, (tx) async {
          // Match start's status-before-progress lock order.
          await tx.execute(
            Sql.named('''
        SELECT id FROM icinga2_stream_status
        WHERE "sourceId"=@source:uuid FOR UPDATE
      '''),
            parameters: {'source': lease.sourceId},
          );
          final updated = await tx.execute(
            Sql.named('''
        UPDATE icinga2_sync_progress AS p SET
          read_end_at=clock_timestamp(), read_problem=@problem:text,
          counts=p.counts || COALESCE((
            SELECT jsonb_object_agg(k, COALESCE((p.counts->>k)::bigint, 0) + v::bigint)
            FROM jsonb_each_text(CAST(@counts:text AS jsonb)) AS entry(k,v)
          ), '{}'::jsonb),
          samples=CAST(@samples:text AS jsonb), last_object=@last:text
        WHERE sync_id=@sync:uuid AND source_id=@source:uuid
          AND generation=@generation:int8 AND read_end_at IS NULL
        RETURNING sync_id
      '''),
            parameters: {
              'sync': syncId,
              'source': lease.sourceId,
              'generation': lease.generation,
              'problem': report.problem?.wire,
              'counts': jsonEncode(report.counts),
              'samples': jsonEncode([
                for (final sample in report.samples)
                  {'identifier': sample.identifier, 'code': sample.code},
              ]),
              'last': report.lastObject,
            },
          );
          if (updated.isEmpty) return false;
          await _finalize(tx, syncId, false);
          await tx.execute(
            Sql.named('''
        UPDATE icinga2_stream_status SET
          "currentSyncId"=CASE WHEN "currentSyncId"=@sync:uuid THEN NULL ELSE "currentSyncId" END,
          "lastSyncId"=@sync:uuid,
          "syncTimeoutsInARow"=CASE WHEN @problem:text='timeout'
            THEN "syncTimeoutsInARow"+1 ELSE 0 END
        WHERE "sourceId"=@source:uuid
      '''),
            parameters: {
              'sync': syncId,
              'source': lease.sourceId,
              'problem': report.problem?.wire,
            },
          );
          return true;
        }) ??
        false;
  }

  /// Marks overdue applying syncs stalled without changing their counters.
  Future<bool> markStalled(StreamLease lease) async =>
      await _leases.fenced<bool>(lease, (tx) async {
        final rows = await tx.execute(
          Sql.named('''
          SELECT sync_id::text FROM icinga2_sync_progress
          WHERE source_id=@source:uuid AND phase IN ('applying','stalled')
          ORDER BY started_at FOR UPDATE
        '''),
          parameters: {'source': lease.sourceId},
        );
        for (final row in rows) {
          await _finalize(tx, row[0]! as String, true);
        }
        return true;
      }) ??
      false;

  /// Closes abandoned readings only while the source is retired and lease expired.
  Future<bool> retire(String sourceId, {required int generation}) =>
      runStreamWrite(_connection, (tx) async {
        final source = await tx.execute(
          Sql.named('''
          SELECT enabled FROM ingest_source WHERE "sourceId"=@source:uuid FOR UPDATE
        '''),
          parameters: {'source': sourceId},
        );
        if (source.isNotEmpty && source.single[0] == true) return false;
        final lease = await tx.execute(
          Sql.named('''
          WITH held AS MATERIALIZED (
            SELECT generation, "expiresAt" FROM icinga2_stream_lease
            WHERE "sourceId"=@source:uuid FOR UPDATE
          )
          SELECT 1 FROM held WHERE generation=@generation:int8
            AND "expiresAt"<=clock_timestamp()
        '''),
          parameters: {'source': sourceId, 'generation': generation},
        );
        if (lease.isEmpty) return false;
        final rows = await tx.execute(
          Sql.named('''
          SELECT sync_id::text FROM icinga2_sync_progress
          WHERE source_id=@source:uuid AND read_end_at IS NULL
          ORDER BY started_at FOR UPDATE
        '''),
          parameters: {'source': sourceId},
        );
        for (final row in rows) {
          await _closeReading(tx, row[0]! as String, _sourceRetired);
        }
        await tx.execute(
          Sql.named('''
          UPDATE icinga2_stream_status SET
            "gapCount"="gapCount"+CASE WHEN "connectionSeq">"lastGapSeq" THEN 1 ELSE 0 END,
            "lastGapAt"=CASE WHEN "connectionSeq">"lastGapSeq"
              THEN clock_timestamp() ELSE "lastGapAt" END,
            "lastGapSeq"=GREATEST("lastGapSeq", "connectionSeq"),
            "lastSyncId"=COALESCE("currentSyncId", "lastSyncId"),
            "currentSyncId"=NULL, state='retired'
          WHERE "sourceId"=@source:uuid
        '''),
          parameters: {'source': sourceId},
        );
        return true;
      });

  /// Deletes fully accounted progress retained for at least thirty days.
  Future<int> prune(String sourceId) => runStreamWrite(_connection, (tx) async {
    final result = await tx.execute(
      Sql.named('''
      DELETE FROM icinga2_sync_progress WHERE source_id=@source:uuid
        AND read_end_at IS NOT NULL AND ended_at IS NOT NULL
        AND ended_at<=clock_timestamp()-@days:int4 * interval '1 day'
        AND rows_done+rows_failed=rows_admitted
    '''),
      parameters: {'source': sourceId, 'days': _retentionDays},
    );
    return result.affectedRows;
  });

  /// Reads a sync independently of the lifetime of its raw rows.
  Future<SyncProgress?> read(String syncId) async {
    final rows = await _connection.execute(
      Sql.named('''
      SELECT phase, reason, read_problem, read_end_at, rows_admitted, rows_done,
        rows_failed, counts::text, samples::text, last_object
      FROM icinga2_sync_progress WHERE sync_id=@sync:uuid
    '''),
      parameters: {'sync': syncId},
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final counts = jsonDecode(row[7]! as String) as Map<String, Object?>;
    final samples = (jsonDecode(row[8]! as String) as List<Object?>)
        .cast<Map<String, Object?>>();
    return SyncProgress(
      phase: SyncPhase.values.byName(row[0]! as String),
      reason: row[1] as String?,
      readProblem: row[2] as String?,
      readEndAt: row[3] as DateTime?,
      rowsAdmitted: row[4]! as int,
      rowsDone: row[5]! as int,
      rowsFailed: row[6]! as int,
      counts: {
        for (final entry in counts.entries) entry.key: entry.value as int,
      },
      samples: [
        for (final item in samples)
          SyncBadObject(item['identifier']! as String, item['code']! as String),
      ],
      lastObject: row[9] as String?,
    );
  }
}

Future<void> _closeReading(TxSession tx, String syncId, String problem) async {
  await tx.execute(
    Sql.named('''
    UPDATE icinga2_sync_progress SET read_end_at=clock_timestamp(), read_problem=@problem:text
    WHERE sync_id=@sync:uuid AND read_end_at IS NULL
  '''),
    parameters: {'sync': syncId, 'problem': problem},
  );
  await _finalize(tx, syncId, false);
}

Future<void> _finalize(TxSession tx, String syncId, bool stalled) async {
  await tx.execute(
    Sql.named(
      'SELECT icinga2_finalize_sync(@sync:uuid, CAST(@stalled AS boolean))',
    ),
    parameters: {'sync': syncId, 'stalled': stalled},
  );
}
