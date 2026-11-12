import 'package:correlia_server/src/plugin/supervision_policy.dart';
import 'package:test/test.dart';

void main() {
  test('repeated_startup_failure_grows_delay', () {
    var now = DateTime.utc(2026);
    final policy = SupervisionPolicy(clock: () => now);
    for (final seconds in [1, 2, 4, 8, 16, 32, 60, 60]) {
      // Keep failures outside the crash window to isolate backoff growth.
      policy.start();
      policy.failed('startup');
      expect(policy.nextStartAt, now.add(Duration(seconds: seconds)));
      now = now.add(const Duration(minutes: 11));
    }
    policy.start();
    policy.ready();
    now = now.add(const Duration(minutes: 10));
    policy.tick();
    policy.failed('crash');
    expect(policy.nextStartAt, now.add(const Duration(seconds: 1)));
  });

  test('degraded_plugin_recovers', () {
    var now = DateTime.utc(2026);
    final policy = SupervisionPolicy(clock: () => now);
    for (var i = 0; i < 6; i++) {
      policy.start();
      policy.failed('crash');
      now = policy.nextStartAt!;
    }
    expect(policy.circuit, PluginCircuit.open);
    expect(policy.nextProbeAt, now);
    policy.start();
    expect(policy.circuit, PluginCircuit.probing);
    policy.ready();
    now = now.add(const Duration(seconds: 59));
    expect(policy.tick(), isFalse);
    expect(policy.circuit, PluginCircuit.probing);
    now = now.add(const Duration(seconds: 1));
    expect(policy.tick(), isTrue);
    expect(policy.circuit, PluginCircuit.closed);
  });

  test(
    'health failures are consecutive and voluntary probe stop is not a crash',
    () {
      var now = DateTime.utc(2026);
      final policy = SupervisionPolicy(clock: () => now);
      policy.start();
      policy.ready();
      expect(policy.health(false), isFalse);
      expect(policy.health(false), isFalse);
      expect(policy.health(true), isFalse);
      expect(policy.health(false), isFalse);
      expect(policy.health(false), isFalse);
      expect(policy.health(false), isTrue);
      expect(policy.failures, hasLength(1));
      for (var i = 1; i < 6; i++) {
        now = policy.nextStartAt!;
        policy.start();
        policy.failed('crash');
      }
      now = policy.nextProbeAt!;
      policy.start();
      final nextProbe = policy.nextProbeAt;
      policy.ready();
      policy.stop();
      expect(policy.circuit, PluginCircuit.open);
      expect(policy.nextProbeAt, nextProbe);
      expect(policy.nextStartAt, nextProbe);
      expect(policy.failures, hasLength(6));
    },
  );

  test('probe_failure_does_not_silently_consume_recovery_transition', () {
    var now = DateTime.utc(2026);
    final policy = SupervisionPolicy(
      clock: () => now,
      circuit: PluginCircuit.probing,
      failures: [now.subtract(const Duration(minutes: 5))],
    );
    policy.start();
    policy.ready();
    now = now.add(const Duration(seconds: 60));
    policy.failed('plugin_connection_lost');
    // A failure must not consume an unobserved recovery; only tick reports it.
    expect(policy.circuit, PluginCircuit.open);
    expect(policy.state, PluginState.degraded);
  });
}
