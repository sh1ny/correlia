import 'package:serverpod/serverpod.dart';

import 'matcher_condition.dart';

/// The stable key of one stored event disposition.
typedef MatcherCursor = ({
  DateTime observedAt,
  String eventId,
  String disposition,
});

/// A query failure caused by PostgreSQL canceling the filter statement.
final class MatcherFilterCancelled implements Exception {
  const MatcherFilterCancelled();
}

/// Searches a bounded page of stored event keys with a typed matcher.
final class StoredMatcherFilter {
  /// Creates a filter with a transaction-local statement deadline.
  StoredMatcherFilter(
    this._session, {
    Duration statementTimeout = const Duration(seconds: 5),
  }) : _statementTimeout = statementTimeout.inMilliseconds {
    if (_statementTimeout < 1 || _statementTimeout > 2147483647) {
      throw ArgumentError.value(statementTimeout, 'statementTimeout');
    }
  }

  final Session _session;
  final int _statementTimeout;

  /// Evaluates up to [limit] stored rows in the half-open `[start, end)` range.
  ///
  /// The continuation is the last scanned candidate, even on a page with no
  /// matches. It is absent at the end of the range.
  Future<({List<MatcherCursor> matches, MatcherCursor? next})> scan(
    MatcherCondition condition, {
    required DateTime start,
    required DateTime end,
    int limit = 1000,
    MatcherCursor? after,
  }) async {
    final range = end.difference(start);
    if (range <= Duration.zero || range > const Duration(hours: 24)) {
      throw ArgumentError(
        'Matcher scan requires a positive range of at most 24 hours',
      );
    }
    RangeError.checkValueInInterval(limit, 1, 1000, 'limit');
    final (:expression, :parameters) = condition.compileSql();
    try {
      return await _session.db.transaction((transaction) async {
        await _session.db.unsafeSimpleExecute(
          "SET LOCAL statement_timeout = '${_statementTimeout}ms'",
          transaction: transaction,
        );
        final rows = await _session.db.unsafeQuery(
          '''
WITH keys AS MATERIALIZED (
  SELECT observed_at, event_id, disposition
  FROM events
  WHERE observed_at >= @start AND observed_at < @end
    ${after == null ? '' : 'AND (observed_at, event_id, disposition) > (@after_at, @after_id::uuid, @after_disposition)'}
  ORDER BY observed_at, event_id, disposition
  LIMIT @cursor_probe
), candidates AS MATERIALIZED (
  SELECT k.observed_at, k.event_id, k.disposition,
         correlia_matcher_data(e.payload) AS data
  FROM (SELECT * FROM keys ORDER BY observed_at, event_id, disposition LIMIT @limit) k
  JOIN events e USING (observed_at, event_id, disposition)
)
SELECT observed_at, event_id::text, disposition, $expression,
       (SELECT count(*) > @limit FROM keys)
FROM candidates AS event
ORDER BY observed_at, event_id, disposition
''',
          parameters: QueryParameters.named({
            ...parameters,
            'start': start.toUtc(),
            'end': end.toUtc(),
            'limit': limit,
            'cursor_probe': limit + 1,
            if (after != null) ...{
              'after_at': after.observedAt,
              'after_id': after.eventId,
              'after_disposition': after.disposition,
            },
          }),
          transaction: transaction,
        );
        final matches = <MatcherCursor>[];
        MatcherCursor? next;
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i];
          final matched = row[3] as bool;
          final lastWithMore = i == rows.length - 1 && row[4] == true;
          if (!matched && !lastWithMore) continue;
          final key = (
            observedAt: row[0] as DateTime,
            eventId: row[1] as String,
            disposition: row[2] as String,
          );
          if (matched) matches.add(key);
          if (lastWithMore) next = key;
        }
        return (matches: matches, next: next);
      });
    } on DatabaseQueryException catch (error) {
      if (error.code == '57014') throw const MatcherFilterCancelled();
      rethrow;
    }
  }
}
