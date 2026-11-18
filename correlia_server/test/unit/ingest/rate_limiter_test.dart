import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  final start = DateTime.utc(2026, 11, 18);
  const rate = SourceRateLimit(perSecond: 2, burst: 3);

  test('burst_within_budget', () {
    final limiter = IngressRateLimiter();
    for (var i = 0; i < rate.burst; i++) {
      expect(limiter.take('source-a', 1, rate, start), isNull);
    }
    expect(limiter.take('source-a', 1, rate, start), 1);
    expect(limiter.take('source-b', 1, rate, start), isNull);
  });

  test(
    'retains fractional refill and does not grant credit on clock rollback',
    () {
      final limiter = IngressRateLimiter();
      const single = SourceRateLimit(perSecond: 2, burst: 1);
      expect(limiter.take('source', 1, single, start), isNull);
      final quarter = start.add(const Duration(milliseconds: 250));
      final half = start.add(const Duration(milliseconds: 500));
      expect(limiter.take('source', 1, single, quarter), 1);
      expect(limiter.take('source', 1, single, start), 1);
      expect(limiter.take('source', 1, single, half), isNull);
      expect(limiter.take('source', 1, single, half), 1);
    },
  );

  test(
    'new revision rekeys the budget and stale requests cannot roll it back',
    () {
      final limiter = IngressRateLimiter();
      const single = SourceRateLimit(perSecond: 1, burst: 1);
      expect(limiter.take('source', 1, single, start), isNull);
      expect(limiter.take('source', 2, single, start), isNull);
      expect(limiter.take('source', 1, single, start), 1);
      expect(limiter.take('source', 2, single, start), 1);
    },
  );
}
