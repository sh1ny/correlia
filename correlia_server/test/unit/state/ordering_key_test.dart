import 'package:correlia_server/src/event/event_timestamp.dart';
import 'package:correlia_server/src/state/ordering_key.dart';
import 'package:test/test.dart';

EventTimestamp _time(int seconds, [int nanos = 0]) =>
    EventTimestamp.fromParts(seconds, nanos);

OrderingKey _key(int effective, int observed, String id, {int nanos = 0}) =>
    OrderingKey(
      effectiveAt: _time(effective, nanos),
      observedAt: _time(observed),
      eventId: id,
    );

void main() {
  const low = '00000000-0000-4000-8000-000000000001';
  const high = '00000000-0000-4000-8000-000000000002';

  group('OrderingKey', () {
    test('source_clock_ahead_within_future_limit', () {
      final source = _time(8200, 123);
      final observed = _time(1000, 123);
      final key = OrderingKey.fromSource(
        sourceTime: source,
        observedAt: observed,
        eventId: low,
        skewAllowance: const Duration(minutes: 5),
      );

      expect(key.effectiveAt, _time(1300, 123));
      expect(key.observedAt, observed);
      expect(key.compareTo(_key(1301, 1, high)), lessThan(0));
    });

    test('clamp retains source time at and below the limit', () {
      final observed = _time(1000, 999999900);
      for (final source in [_time(1299, 999999999), _time(1300, 999999900)]) {
        final key = OrderingKey.fromSource(
          sourceTime: source,
          observedAt: observed,
          eventId: low,
          skewAllowance: const Duration(minutes: 5),
        );
        expect(key.effectiveAt, source);
      }
      final above = OrderingKey.fromSource(
        sourceTime: _time(1300, 999999901),
        observedAt: observed,
        eventId: low,
        skewAllowance: const Duration(minutes: 5),
      );
      expect(above.effectiveAt, _time(1300, 999999900));
    });

    test('compares full nanoseconds before observed time and id', () {
      final earlier = _key(100, 300, high, nanos: 800);
      final later = _key(100, 200, low, nanos: 900);
      expect(earlier.compareTo(later), lessThan(0));
      expect(later.compareTo(earlier), greaterThan(0));
    });

    test('breaks ties by observed nanoseconds then canonical event id', () {
      final earlier = OrderingKey(
        effectiveAt: _time(100),
        observedAt: _time(200, 800),
        eventId: high,
      );
      final later = OrderingKey(
        effectiveAt: _time(100),
        observedAt: _time(200, 900),
        eventId: low,
      );
      expect(earlier.compareTo(later), lessThan(0));
      expect(later.compareTo(earlier), greaterThan(0));
      final lowId = _key(100, 200, low);
      final highId = _key(100, 200, high);
      expect(lowId.compareTo(highId), lessThan(0));
      expect(highId.compareTo(lowId), greaterThan(0));
      expect(lowId.compareTo(_key(100, 200, low)), 0);
      expect(
        _key(100, 200, 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA').compareTo(
          _key(100, 200, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
        ),
        0,
      );
    });
  });
}
