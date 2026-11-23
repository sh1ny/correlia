import 'dart:async';

import 'package:postgres/postgres.dart';

import 'database.dart';

/// A source lease's holder and fencing generation.
class StreamLease {
  /// Creates a lease identity returned by an acquisition.
  const StreamLease({
    required this.sourceId,
    required this.holder,
    required this.generation,
  });

  /// The source governed by this lease.
  final String sourceId;

  /// The process identity that acquired this generation.
  final String holder;

  /// The generation granted at acquisition.
  final int generation;
}

/// Locks and checks a lease in an existing write transaction.
///
/// The shared row lock remains held until the transaction finishes, so a
/// takeover cannot grant a new generation before the fenced write commits.
Future<bool> lockStreamLease(TxSession tx, StreamLease lease) async {
  final rows = await tx.execute(
    Sql.named('''
      WITH held AS MATERIALIZED (
        SELECT "expiresAt" FROM icinga2_stream_lease
        WHERE "sourceId" = @source:uuid AND holder = @holder:text
          AND generation = @generation:int8
        FOR SHARE
      )
      SELECT 1 FROM held WHERE "expiresAt" > clock_timestamp()
    '''),
    parameters: {
      'source': lease.sourceId,
      'holder': lease.holder,
      'generation': lease.generation,
    },
  );
  return rows.isNotEmpty;
}

/// Acquires and fences stream leases on a dedicated database connection.
class StreamLeaseStore {
  /// Uses [connection] for lease transactions.
  StreamLeaseStore(this.connection);

  /// The database connection used by this store.
  final Connection connection;

  /// Acquires an expired lease for an enabled stream source, if available.
  Future<StreamLease?> acquire(String sourceId, String holder) =>
      runStreamWrite(connection, (tx) async {
        final source = await tx.execute(
          Sql.named('''
            SELECT 1 FROM ingest_source
            WHERE "sourceId" = @source:uuid AND enabled
              AND kind = 'icinga2' AND mode = 'event_streams'
            FOR SHARE
          '''),
          parameters: {'source': sourceId},
        );
        if (source.isEmpty) return null;

        await tx.execute(
          Sql.named('''
            INSERT INTO icinga2_stream_lease
              ("sourceId", holder, generation, "expiresAt")
            VALUES (@source:uuid, @holder:text, 0, '-infinity'::timestamp)
            ON CONFLICT ("sourceId") DO NOTHING
          '''),
          parameters: {'source': sourceId, 'holder': holder},
        );
        final rows = await tx.execute(
          Sql.named('''
            UPDATE icinga2_stream_lease
            SET holder = @holder:text, generation = generation + 1,
                "expiresAt" = clock_timestamp() + interval '30 seconds'
            WHERE "sourceId" = @source:uuid AND "expiresAt" <= clock_timestamp()
            RETURNING generation
          '''),
          parameters: {'source': sourceId, 'holder': holder},
        );
        if (rows.isEmpty) return null;
        await tx.execute(
          Sql.named('''
          UPDATE icinga2_stream_status SET state='connecting'
          WHERE "sourceId"=@source:uuid
        '''),
          parameters: {'source': sourceId},
        );
        return StreamLease(
          sourceId: sourceId,
          holder: holder,
          generation: rows.single[0]! as int,
        );
      });

  /// Renews this generation only while it is still unexpired.
  Future<bool> renew(StreamLease lease) => _retime(lease, 30);

  /// Releases this generation only while it remains the live holder.
  Future<bool> release(StreamLease lease) => _retime(lease, 0);

  // PostgreSQL can evaluate a WHERE condition before it waits on a row lock.
  // Only the outer statement checks expiry, after the materialized lock read.
  Future<bool> _retime(StreamLease lease, int seconds) =>
      runStreamWrite(connection, (tx) async {
        final result = await tx.execute(
          Sql.named('''
            WITH held AS MATERIALIZED (
              SELECT id,"expiresAt" FROM icinga2_stream_lease
              WHERE "sourceId"=@source:uuid AND holder=@holder:text
                AND generation=@generation:int8
              FOR NO KEY UPDATE
            )
            UPDATE icinga2_stream_lease AS lease
            SET "expiresAt"=clock_timestamp()+@seconds:int4*interval '1 second'
            FROM held WHERE lease.id=held.id AND held."expiresAt">clock_timestamp()
          '''),
          parameters: {
            'source': lease.sourceId,
            'holder': lease.holder,
            'generation': lease.generation,
            'seconds': seconds,
          },
        );
        return result.affectedRows == 1;
      });

  /// Runs [work] under the lease's shared lock, or returns null if refused.
  Future<T?> fenced<T>(
    StreamLease lease,
    Future<T> Function(TxSession) work, {
    Duration timeout = const Duration(seconds: 2),
  }) => runStreamWrite(connection, (tx) async {
    if (!await lockStreamLease(tx, lease)) return null;
    return work(tx);
  }, timeout: timeout);
}

void Function() _scheduleTimer(Duration delay, void Function() callback) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}

/// A monotonic local cutoff for a holder's external connections.
class StreamLeaseDeadline {
  /// Uses a monotonic clock and invokes the loss callback at most once.
  StreamLeaseDeadline({
    required this._now,
    required this._onLost,
    void Function() Function(Duration, void Function())? schedule,
  }) : _schedule = schedule ?? _scheduleTimer;

  static const _lifetime = Duration(seconds: 20);
  final Duration Function() _now;
  final void Function() _onLost;
  final void Function() Function(Duration, void Function()) _schedule;
  Duration? _deadline;
  Duration? _lastSent;
  void Function()? _cancel;
  bool _lost = false;
  bool _closed = false;

  /// Whether an acknowledged lease remains within its local deadline.
  bool get isLive {
    if (_closed || _lost || _deadline == null) return false;
    if (_now() >= _deadline!) {
      _lose();
      return false;
    }
    return true;
  }

  /// Acknowledges a successful acquisition or renewal sent at [sentAt].
  ///
  /// A success arriving after the prior or its own deadline cannot revive a
  /// lost holder. Older acknowledgements cannot move a newer deadline back.
  bool acknowledge(Duration sentAt) {
    if (_closed || _lost) return false;
    if (_deadline != null && !isLive) return false;
    if (_lastSent != null && sentAt <= _lastSent!) return true;
    final deadline = sentAt + _lifetime;
    if (_now() >= deadline) {
      _lose();
      return false;
    }
    _lastSent = sentAt;
    _deadline = deadline;
    _arm();
    return true;
  }

  void _arm() {
    _cancel?.call();
    _cancel = _schedule(_deadline! - _now(), () {
      _cancel = null;
      if (_closed || _lost) return;
      if (_now() >= _deadline!) {
        _lose();
      } else {
        _arm();
      }
    });
  }

  void _lose() {
    if (_closed || _lost) return;
    _lost = true;
    _cancel?.call();
    _cancel = null;
    _onLost();
  }

  /// Cancels the deadline without reporting lease loss.
  void close() {
    if (_closed) return;
    _closed = true;
    _cancel?.call();
    _cancel = null;
  }
}
