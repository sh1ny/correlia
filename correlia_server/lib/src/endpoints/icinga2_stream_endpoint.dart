import 'dart:convert';

import 'package:serverpod/serverpod.dart';

import '../console/console_access_policy.dart';
import '../feed/feed_runtime.dart';
import '../generated/protocol.dart';
import '../ingest/icinga2/stream/status.dart';

/// Local operator status for Icinga2 Event Streams.
class Icinga2StreamEndpoint extends Endpoint {
  /// Reads one source without renewing its lease or changing any counters.
  Future<Icinga2ConsumerStatus?> status(
    Session session,
    UuidValue sourceId,
  ) async {
    ConsoleAccessPolicy.check(
      session.serverpod.runMode,
      FeedRuntime.role,
      session.request,
    );
    final rows = await session.db.unsafeQuery('''
      SELECT ${StreamStatusStore.effectiveStateSql}, s."connectionId", s."connectionSeq",
        s."connectedAt", s."lastEventAt", s."gapCount", s."lastGapAt", s."oversizeLines",
        s."lagMs", s."lastErrorClass", COALESCE(r."requestSeq",0) > s."servedResyncSeq",
        s."syncTimeoutsInARow", ${_sync('running')}, ${_sync('last')}
      FROM icinga2_stream_status s
      LEFT JOIN icinga2_stream_lease l USING ("sourceId")
      LEFT JOIN icinga2_stream_resync r USING ("sourceId")
      LEFT JOIN icinga2_sync_progress running ON running.sync_id=s."currentSyncId"
      LEFT JOIN icinga2_sync_progress last ON last.sync_id=s."lastSyncId"
      WHERE s."sourceId"=CAST(@source AS uuid)
    ''', parameters: QueryParameters.named({'source': sourceId.toString()}));
    if (rows.isEmpty) return null;
    final row = rows.single;
    return Icinga2ConsumerStatus(
      sourceId: sourceId,
      state: row[0]! as String,
      connectionId: row[1] as String?,
      connectionSeq: row[2]! as int,
      connectedAt: row[3] as DateTime?,
      lastEventAt: row[4] as DateTime?,
      gapCount: row[5]! as int,
      lastGapAt: row[6] as DateTime?,
      oversizeLines: row[7]! as int,
      lagMs: row[8] as int?,
      lastErrorClass: row[9] as String?,
      unservedSyncRequest: row[10]! as bool,
      syncTimeoutsInARow: row[11]! as int,
      currentSync: _decodeSync(row[12] as String?),
      lastSync: _decodeSync(row[13] as String?),
    );
  }

  static String _sync(String alias) =>
      '''
    CASE WHEN $alias.sync_id IS NOT NULL THEN jsonb_build_object(
      'id', $alias.sync_id,
      'phase', $alias.phase,
      'reason', COALESCE($alias.read_problem, $alias.reason),
      'startedAt', $alias.started_at,
      'readEndAt', $alias.read_end_at,
      'endedAt', $alias.ended_at,
      'rowsAdmitted', $alias.rows_admitted,
      'rowsDone', $alias.rows_done,
      'rowsFailed', $alias.rows_failed,
      'counts', $alias.counts
    )::text END
  ''';

  static Icinga2ConsumerSync? _decodeSync(String? json) => json == null
      ? null
      : Icinga2ConsumerSync.fromJson(jsonDecode(json) as Map<String, Object?>);
}
