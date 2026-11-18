import 'dart:math' as math;

import 'bootstrap.dart';

/// Per-process admission budgets, bounded by the validated source registry.
final class IngressRateLimiter {
  final _buckets = <String, _Bucket>{};
  int _revision = 0;

  /// Clears stale buckets on a newly observed configuration revision.
  void rekey(int revision) {
    if (revision <= _revision) return;
    _revision = revision;
    _buckets.clear();
  }

  /// Spends a token or returns a whole-second Retry-After for a rejection.
  int? take(String id, int revision, SourceRateLimit rate, DateTime now) {
    if (revision < _revision) return 1;
    rekey(revision);
    final capacity = rate.burst * Duration.microsecondsPerSecond;
    final bucket = _buckets.putIfAbsent(id, () => _Bucket(now, capacity));
    if (now.isAfter(bucket.updatedAt)) {
      final elapsed = now.difference(bucket.updatedAt).inMicroseconds;
      bucket.credit = math.min(
        capacity,
        bucket.credit + elapsed * rate.perSecond,
      );
      bucket.updatedAt = now;
    }
    const cost = Duration.microsecondsPerSecond;
    if (bucket.credit < cost) {
      final perSecond = rate.perSecond * cost;
      return (cost - bucket.credit + perSecond - 1) ~/ perSecond;
    }
    bucket.credit -= cost;
    return null;
  }
}

final class _Bucket {
  _Bucket(this.updatedAt, this.credit);
  DateTime updatedAt;
  int credit;
}
