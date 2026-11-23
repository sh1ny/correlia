import 'package:postgres/postgres.dart';

import 'lease.dart';

/// The durable consumer state, or the effective state derived by a reader.
enum StreamConsumerState {
  connecting,
  syncing,
  connected,
  backoff,
  paused,
  stopped,
  retired,
  stale,
}

/// A read-only snapshot of a source's consumer status.
class StreamStatus {
  /// Creates a status snapshot from persisted and derived values.
  const StreamStatus({
    required this.sourceId,
    required this.state,
    required this.connectionId,
    required this.connectionSeq,
    required this.connectedAt,
    required this.lastEventAt,
    required this.gapCount,
    required this.lastGapSeq,
    required this.lastGapAt,
    required this.oversizeLines,
    required this.lagMs,
    required this.lastErrorClass,
    required this.servedResyncSeq,
    required this.syncTimeoutsInARow,
    required this.currentSyncId,
    required this.lastSyncId,
  });

  /// The source this status describes.
  final String sourceId;

  /// The effective state, derived from lease expiry when necessary.
  final StreamConsumerState state;

  /// The most recently numbered connection's identifier.
  final String? connectionId;

  /// The most recently assigned connection number.
  final int connectionSeq;

  /// The time the consumer most recently reported a connected state.
  final DateTime? connectedAt;

  /// The last recorded event time.
  final DateTime? lastEventAt;

  /// The number of connection gaps recorded.
  final int gapCount;

  /// The greatest connection number whose gap was recorded.
  final int lastGapSeq;

  /// The time the last gap was recorded.
  final DateTime? lastGapAt;

  /// The number of oversize lines recorded.
  final int oversizeLines;

  /// The last recorded consumer lag in milliseconds.
  final int? lagMs;

  /// The last recorded error class, without error details.
  final String? lastErrorClass;

  /// The greatest resync request number served.
  final int servedResyncSeq;

  /// The number of consecutive sync timeouts.
  final int syncTimeoutsInARow;

  /// The current sync identifier, if any.
  final String? currentSyncId;

  /// The last sync identifier, if any.
  final String? lastSyncId;
}

/// Persists consumer status under the source's lease fence.
class StreamStatusStore {
  /// Uses the dedicated consumer database connection.
  StreamStatusStore(this._connection) : _leases = StreamLeaseStore(_connection);

  final Connection _connection;
  final StreamLeaseStore _leases;

  /// Records a connection before subscription, first accounting for its predecessor.
  ///
  /// Returns the assigned sequence, or `null` if the lease no longer authorizes
  /// writes. The predecessor gap and the new number commit together.
  Future<int?> startConnection(StreamLease lease, String connectionId) =>
      _leases.fenced<int>(lease, (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            INSERT INTO icinga2_stream_status
              ("sourceId", state, "connectionId", "connectionSeq")
            VALUES (CAST(@source AS uuid), 'connecting', @connection, 1)
            ON CONFLICT ("sourceId") DO UPDATE SET
              "gapCount" = icinga2_stream_status."gapCount" +
                CASE WHEN icinga2_stream_status."connectionSeq" > icinga2_stream_status."lastGapSeq" THEN 1 ELSE 0 END,
              "lastGapAt" = CASE
                WHEN icinga2_stream_status."connectionSeq" > icinga2_stream_status."lastGapSeq"
                THEN clock_timestamp() ELSE icinga2_stream_status."lastGapAt" END,
              "lastGapSeq" = GREATEST(icinga2_stream_status."lastGapSeq", icinga2_stream_status."connectionSeq"),
              "connectionSeq" = icinga2_stream_status."connectionSeq" + 1,
              "connectionId" = EXCLUDED."connectionId",
              state = 'connecting'
            RETURNING "connectionSeq"
          '''),
          parameters: {'source': lease.sourceId, 'connection': connectionId},
        );
        return rows.single[0] as int;
      });

  /// Records a state and optional error class if the lease is still valid.
  Future<bool> setState(
    StreamLease lease,
    StreamConsumerState state, {
    String? errorClass,
  }) async =>
      await _leases.fenced<bool>(lease, (tx) async {
        await tx.execute(
          Sql.named('''
            INSERT INTO icinga2_stream_status
              ("sourceId", state, "lastErrorClass", "connectedAt")
            VALUES (CAST(@source AS uuid), @state, @error,
              CASE WHEN @state = 'connected' THEN clock_timestamp() ELSE NULL END)
            ON CONFLICT ("sourceId") DO UPDATE SET
              state = EXCLUDED.state,
              "lastErrorClass" = EXCLUDED."lastErrorClass",
              "connectedAt" = CASE WHEN EXCLUDED.state = 'connected'
                THEN clock_timestamp() ELSE icinga2_stream_status."connectedAt" END
          '''),
          parameters: {
            'source': lease.sourceId,
            'state': state.name,
            'error': errorClass,
          },
        );
        return true;
      }) ??
      false;

  /// Counts a numbered connection's gap at most once under the lease fence.
  ///
  /// Returns false for a lost lease or a number not yet assigned to this source.
  Future<bool> recordGap(StreamLease lease, int connectionSeq) async =>
      await _leases.fenced<bool>(lease, (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            UPDATE icinga2_stream_status SET
              "gapCount" = "gapCount" + CASE WHEN "lastGapSeq" < @seq THEN 1 ELSE 0 END,
              "lastGapAt" = CASE WHEN "lastGapSeq" < @seq THEN clock_timestamp() ELSE "lastGapAt" END,
              "lastGapSeq" = GREATEST("lastGapSeq", @seq)
            WHERE "sourceId" = CAST(@source AS uuid)
              AND @seq > 0 AND @seq <= "connectionSeq"
            RETURNING "connectionSeq"
          '''),
          parameters: {'source': lease.sourceId, 'seq': connectionSeq},
        );
        return rows.isNotEmpty;
      }) ??
      false;

  /// Counts one oversize line independently of connection gap accounting.
  Future<bool> recordOversize(StreamLease lease) async =>
      await _leases.fenced<bool>(lease, (tx) async {
        await tx.execute(
          Sql.named('''
            INSERT INTO icinga2_stream_status ("sourceId", state, "oversizeLines")
            VALUES (CAST(@source AS uuid), 'connecting', 1)
            ON CONFLICT ("sourceId") DO UPDATE SET
              "oversizeLines" = icinga2_stream_status."oversizeLines" + 1
          '''),
          parameters: {'source': lease.sourceId},
        );
        return true;
      }) ??
      false;

  /// Reads status without modifying it, deriving stale from database lease time.
  Future<StreamStatus?> read(String sourceId) async {
    final rows = await _connection.execute(
      Sql.named('''
        SELECT s."sourceId"::text,
          CASE WHEN s.state IN ('connecting', 'syncing', 'connected', 'backoff', 'paused')
            AND (l."sourceId" IS NULL OR l."expiresAt" <= clock_timestamp())
            THEN 'stale' ELSE s.state END,
          s."connectionId", s."connectionSeq", s."connectedAt", s."lastEventAt",
          s."gapCount", s."lastGapSeq", s."lastGapAt", s."oversizeLines", s."lagMs",
          s."lastErrorClass", s."servedResyncSeq", s."syncTimeoutsInARow",
          s."currentSyncId"::text, s."lastSyncId"::text
        FROM icinga2_stream_status s
        LEFT JOIN icinga2_stream_lease l ON l."sourceId" = s."sourceId"
        WHERE s."sourceId" = CAST(@source AS uuid)
      '''),
      parameters: {'source': sourceId},
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return StreamStatus(
      sourceId: row[0] as String,
      state: StreamConsumerState.values.byName(row[1] as String),
      connectionId: row[2] as String?,
      connectionSeq: row[3] as int,
      connectedAt: row[4] as DateTime?,
      lastEventAt: row[5] as DateTime?,
      gapCount: row[6] as int,
      lastGapSeq: row[7] as int,
      lastGapAt: row[8] as DateTime?,
      oversizeLines: row[9] as int,
      lagMs: row[10] as int?,
      lastErrorClass: row[11] as String?,
      servedResyncSeq: row[12] as int,
      syncTimeoutsInARow: row[13] as int,
      currentSyncId: row[14] as String?,
      lastSyncId: row[15] as String?,
    );
  }
}
