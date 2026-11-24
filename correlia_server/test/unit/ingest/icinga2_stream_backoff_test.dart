import 'package:correlia_server/src/ingest/icinga2/stream/read_timing.dart';
import 'package:test/test.dart';

void main() {
  test('icinga_2_restarts', () {
    final backoff = StreamBackoff(random: () => 0.5);
    expect(backoff.nextDelay(), const Duration(seconds: 1));
    expect(backoff.nextDelay(), const Duration(seconds: 2));
    expect(backoff.nextDelay(), const Duration(seconds: 4));
    expect(backoff.nextDelay(), const Duration(seconds: 8));
    expect(backoff.nextDelay(), const Duration(seconds: 16));
    expect(
      backoff.nextDelay(connectedFor: const Duration(minutes: 5)),
      const Duration(seconds: 1),
    );
    expect(
      backoff.nextDelay(connectedFor: const Duration(minutes: 4, seconds: 59)),
      const Duration(seconds: 2),
    );
  });

  test('icinga_2_down_for_an_hour', () {
    final low = StreamBackoff(random: () => 0);
    final high = StreamBackoff(random: () => 1);
    final expectedBases = [1, 2, 4, 8, 16, 32, 60];
    var elapsed = Duration.zero;
    var attempt = 0;
    while (elapsed < const Duration(hours: 1)) {
      final base = expectedBases[attempt < 7 ? attempt : 6];
      final minimum = Duration(milliseconds: base * 800);
      final maximum = Duration(milliseconds: base * 1200);
      final lowDelay = low.nextDelay();
      final highDelay = high.nextDelay();
      expect(lowDelay, minimum);
      expect(highDelay, maximum);
      elapsed += highDelay;
      attempt++;
    }
    expect(attempt, greaterThan(7));
  });
}
