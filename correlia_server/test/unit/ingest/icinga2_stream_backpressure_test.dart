import 'package:correlia_server/src/ingest/icinga2/stream/read_timing.dart';
import 'package:test/test.dart';

void main() {
  late _Clock clock;
  late List<StreamReadEnd> closes;
  late ReaderHealth health;

  setUp(() {
    clock = _Clock();
    closes = [];
    health = ReaderHealth(
      now: () => clock.now,
      schedule: clock.schedule,
      onClose: closes.add,
    );
  });

  tearDown(() => health.close());

  test('pipeline_briefly_behind', () {
    health.setBlocked(true);
    clock.advance(const Duration(seconds: 5));
    health.setBlocked(false);
    clock.advance(const Duration(minutes: 1));
    expect(closes, isEmpty);

    health.setBlocked(true);
    clock.advance(const Duration(seconds: 29));
    expect(closes, isEmpty);
    clock.advance(const Duration(seconds: 1));
    expect(closes, [StreamReadEnd.backpressure]);
  });

  test('pipeline_stopped', () {
    health.setBlocked(true);
    clock.advance(const Duration(seconds: 29, milliseconds: 999));
    expect(closes, isEmpty);
    clock.advance(const Duration(milliseconds: 1));
    expect(closes, [StreamReadEnd.backpressure]);
    clock.advance(const Duration(minutes: 5));
    health.setBlocked(true);
    health.observeLag(const Duration(minutes: 10));
    health.close();
    expect(closes, [StreamReadEnd.backpressure]);
  });

  test('quiet_connection', () {
    clock.advance(const Duration(minutes: 10));
    expect(closes, isEmpty);
  });

  test('insert_blocked_below_the_cap', () {
    health.setBlocked(true);
    for (var i = 0; i < 14; i++) {
      clock.advance(const Duration(seconds: 2));
      health.setBlocked(true);
      expect(closes, isEmpty);
    }
    clock.advance(const Duration(seconds: 2));
    expect(closes, [StreamReadEnd.backpressure]);
    clock.advance(const Duration(seconds: 10));
    expect(closes, [StreamReadEnd.backpressure]);
  });

  test('repeated_short_pauses', () {
    health.observeLag(Duration.zero);
    health.observeLag(const Duration(seconds: 61));
    for (var i = 0; i < 6; i++) {
      health.setBlocked(true);
      clock.advance(const Duration(seconds: 19));
      health.setBlocked(false);
      clock.advance(const Duration(seconds: 1));
      health.observeLag(Duration(seconds: 62 + i));
      if (i < 5) expect(closes, isEmpty);
    }
    expect(closes, [StreamReadEnd.lag]);
    clock.advance(const Duration(minutes: 5));
    expect(closes, [StreamReadEnd.lag]);
  });

  test('initial_backlog_with_constant_excess_lag', () {
    health.observeLag(const Duration(hours: 2));
    for (var i = 0; i < 20; i++) {
      clock.advance(const Duration(seconds: 20));
      health.observeLag(const Duration(hours: 2, seconds: 59));
    }
    expect(closes, isEmpty);
    health.setBlocked(true);
    clock.advance(const Duration(seconds: 30));
    expect(closes, [StreamReadEnd.backpressure]);
  });

  test('initial_backlog_with_growing_excess_lag', () {
    health.observeLag(const Duration(hours: 2));
    health.observeLag(const Duration(hours: 2, seconds: 60));
    clock.advance(const Duration(minutes: 3));
    health.observeLag(const Duration(hours: 2, seconds: 60));
    expect(closes, isEmpty);

    health.observeLag(const Duration(hours: 2, seconds: 61));
    clock.advance(const Duration(seconds: 119));
    health.observeLag(const Duration(hours: 2, seconds: 62));
    expect(closes, isEmpty);
    clock.advance(const Duration(seconds: 1));
    health.observeLag(const Duration(hours: 2, seconds: 63));
    expect(closes, [StreamReadEnd.lag]);
    health.close();
    expect(closes, [StreamReadEnd.lag]);
  });

  test('constant_clock_offset', () {
    for (var i = 0; i < 20; i++) {
      health.observeLag(const Duration(minutes: 10));
      clock.advance(const Duration(seconds: 30));
    }
    expect(closes, isEmpty);

    // A lower observed lag becomes the baseline for subsequent events.
    health.observeLag(const Duration(minutes: 9));
    health.observeLag(const Duration(minutes: 10, seconds: 1));
    clock.advance(const Duration(seconds: 120));
    health.observeLag(const Duration(minutes: 10, seconds: 1));
    expect(closes, [StreamReadEnd.lag]);
  });
}

class _Clock {
  Duration now = Duration.zero;
  final List<_Scheduled> _scheduled = [];

  void Function() schedule(Duration delay, void Function() callback) {
    final scheduled = _Scheduled(now + delay, callback);
    _scheduled.add(scheduled);
    return () => scheduled.cancelled = true;
  }

  void advance(Duration duration) {
    final target = now + duration;
    while (true) {
      _Scheduled? next;
      for (final scheduled in _scheduled) {
        if (!scheduled.cancelled &&
            scheduled.at <= target &&
            (next == null || scheduled.at < next.at)) {
          next = scheduled;
        }
      }
      if (next == null) break;
      _scheduled.remove(next);
      now = next.at;
      next.callback();
    }
    now = target;
  }
}

class _Scheduled {
  _Scheduled(this.at, this.callback);

  final Duration at;
  final void Function() callback;
  bool cancelled = false;
}
