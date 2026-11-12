import 'package:serverpod/serverpod.dart';

import '../generated/protocol.dart';
import 'feed_cursor.dart';

/// Reads a consistent alert snapshot and the durable activity feed.
final class FeedReader {
  /// Creates a reader for the request's database session.
  FeedReader(this.session);

  /// The request session used for each transaction.
  final Session session;

  Future<BigInt> _watermark(Transaction tx) async {
    final rows = await session.db.unsafeQuery(
      'SELECT pg_snapshot_xmin(pg_current_snapshot())::text',
      transaction: tx,
    );
    return BigInt.parse(rows.single[0] as String);
  }

  AlertView _view(Map<String, Object?> row) => AlertView(
    id: row['id'] as int,
    version: row['version'] as int,
    status: row['status'] as String,
    severity: row['severity'] as String,
    summary: row['summary'] as String,
    sourceInstance: row['sourceInstance'] as String,
    firingSince: row['firingSince'] as DateTime?,
    lastObservedAt: row['lastObservedAt'] as DateTime,
    generatorUrl: row['generatorUrl'] as String?,
  );

  /// Reads the bounded firing list and handover cursor in one snapshot.
  Future<AlertSnapshot> snapshot() => session.db.transaction((tx) async {
    await session.db.unsafeExecute(
      'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ',
      transaction: tx,
    );
    final watermark = await _watermark(tx);
    final rows = await session.db.unsafeQuery('''
SELECT id, version, status, severity, summary, "sourceInstance", "firingSince",
       "lastObservedAt", "generatorUrl", count(*) OVER() AS total
FROM alerts WHERE status = 'firing'
ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'error' THEN 1
  WHEN 'warning' THEN 2 WHEN 'unknown' THEN 3 WHEN 'info' THEN 4 ELSE 3 END,
  "firingSince" DESC NULLS LAST, id
LIMIT 500
''', transaction: tx);
    final total = rows.isEmpty ? 0 : rows.first.toColumnMap()['total'] as int;
    return AlertSnapshot(
      alerts: rows.map((row) => _view(row.toColumnMap())).toList(),
      omittedCount: total - rows.length,
      cursor: FeedCursor(watermark, BigInt.zero).encode(),
    );
  });

  /// Reads a page and current entity views below the snapshot watermark.
  Future<FeedPage> feed(String cursor, int limit) async {
    final FeedCursor position;
    try {
      position = FeedCursor.parse(cursor);
    } on FormatException {
      throw InvalidCursorException(message: 'Invalid feed cursor');
    }
    final pageLimit = limit.clamp(1, 1000);
    return session.db.transaction((tx) async {
      await session.db.unsafeExecute(
        'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ',
        transaction: tx,
      );
      final watermark = await _watermark(tx);
      if (position.txid > watermark) {
        throw InvalidCursorException(message: 'Invalid feed cursor');
      }
      final rows = await session.db.unsafeQuery(
        '''
SELECT txid::text AS tx, id::text AS position_id, occurred_at, entity_kind,
       entity_id, entity_version, change_kind
FROM activity
WHERE (txid, id) > (CAST(@tx AS xid8), CAST(@id AS bigint))
  AND txid < CAST(@watermark AS xid8)
ORDER BY txid, id LIMIT @limit
''',
        parameters: QueryParameters.named({
          'tx': position.txid.toString(),
          'id': position.id.toString(),
          'watermark': watermark.toString(),
          'limit': pageLimit + 1,
        }),
        transaction: tx,
      );
      final more = rows.length > pageLimit;
      final page = rows
          .take(pageLimit)
          .map((row) => row.toColumnMap())
          .toList();
      final ids = page
          .where((row) => row['entity_kind'] == 'alert')
          .map((row) => row['entity_id'] as int)
          .toSet();
      final alerts = ids.isEmpty
          ? <AlertView>[]
          : (await session.db.unsafeQuery(
              '''
SELECT id, version, status, severity, summary, "sourceInstance", "firingSince",
       "lastObservedAt", "generatorUrl" FROM alerts WHERE id = ANY(@ids)
''',
              parameters: QueryParameters.named({'ids': ids.toList()}),
              transaction: tx,
            )).map((row) => _view(row.toColumnMap())).toList();
      final held = await session.db.unsafeQuery(
        'SELECT EXISTS(SELECT 1 FROM activity WHERE txid >= CAST(@watermark AS xid8))',
        parameters: QueryParameters.named({'watermark': watermark.toString()}),
        transaction: tx,
      );
      final next = page.isEmpty
          ? position
          : FeedCursor(
              BigInt.parse(page.last['tx'] as String),
              BigInt.parse(page.last['position_id'] as String),
            );
      return FeedPage(
        entries: page
            .map(
              (row) => FeedEntry(
                entityKind: row['entity_kind'] as String,
                entityId: row['entity_id'] as int,
                entityVersion: row['entity_version'] as int,
                changeKind: row['change_kind'] as String,
                occurredAt: row['occurred_at'] as DateTime,
              ),
            )
            .toList(),
        alerts: alerts,
        nextCursor: next.encode(),
        more: more,
        heldBack: held.single[0] as bool,
      );
    });
  }
}
