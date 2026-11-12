import 'package:correlia_server/src/plugin/plugin_health_repository.dart';
import 'package:correlia_server/src/plugin/plugin_status_repository.dart';
import 'package:correlia_server/src/plugin/slot_scheduler.dart';
import 'package:correlia_server/src/plugin/supervision_policy.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

void main() {
  withServerpod('durable plugin health', (builder, _) {
    test('failing_definitions_cycle_through_slots', () async {
      final session = builder.build();
      final repository = PluginHealthRepository(session, 'test-host');
      var now = DateTime.utc(2026);
      final scheduler = SlotScheduler(clock: () => now);
      for (var round = 0; round < 6; round++) {
        for (var i = 0; i < 40; i++) {
          final key = PluginKey('output', i.toString().padLeft(64, '0'));
          scheduler.admit(key);
          final policy = await repository.load(key, () => now);
          policy.start();
          policy.failed('plugin_start_timeout');
          expect(policy.backoffStep, round + 1);
          if (round < 5) {
            expect(policy.nextStartAt, now.add(Duration(seconds: 1 << round)));
          } else {
            expect(policy.circuit, PluginCircuit.open);
          }
          await repository.save(key, policy);
          scheduler.release(key);
          expect(scheduler.running, isEmpty);
        }
        now = now.add(Duration(seconds: 1 << round));
      }
      for (var i = 0; i < 40; i++) {
        final policy = await repository.load(
          PluginKey('output', i.toString().padLeft(64, '0')),
          () => now,
        );
        expect(policy.circuit, PluginCircuit.open);
        expect(policy.failures, hasLength(6));
      }
    });
    for (final probe in [false, true]) {
      test(
        'local_clock_${probe ? 'probe' : 'restart'}_deadline_retains_instant',
        () async {
          final session = builder.build();
          final repository = PluginHealthRepository(
            session,
            'local-clock-host',
          );
          final now = DateTime(2026, 1, 2, 3, 4, 5);
          final key = PluginKey('output', probe ? 'probe' : 'restart');
          final policy = SupervisionPolicy(
            clock: () => now,
            circuit: probe ? PluginCircuit.probing : PluginCircuit.closed,
          );
          policy.start();
          policy.failed('plugin_connection_lost');
          await repository.save(key, policy);
          final restored = await repository.load(key, () => now);
          expect(restored.nextStartAt!.toUtc(), policy.nextStartAt!.toUtc());
          expect(restored.nextProbeAt?.toUtc(), policy.nextProbeAt?.toUtc());
        },
      );
    }
  }, testGroupTagsOverride: ['db']);
  withServerpod(
    'plugin status transactions',
    (builder, _) {
      test(
        'circuit activity is atomic and written once per transition',
        () async {
          final session = builder.build();
          await initializeIngestSchema(session);
          final repository = PluginStatusRepository(session, 'status-host');
          var now = DateTime.utc(2026);
          const key = PluginKey('output', 'digest');
          final health = SupervisionPolicy(clock: () => now);
          PluginStatusSnapshot status(String state) => PluginStatusSnapshot(
            key: key,
            state: state,
            restartCount: 0,
            crashesInWindow: health.failures.length,
            heartbeatAt: now,
          );
          for (var i = 0; i < 6; i++) {
            health.start();
            health.failed('crash');
          }
          await repository.write(
            status('degraded'),
            health,
            activity: 'plugin_degraded',
          );
          await repository.write(
            status('degraded'),
            health,
            activity: 'plugin_degraded',
          );
          expect(
            await repository.isStale(key, now.add(const Duration(seconds: 61))),
            isTrue,
          );
          health.start();
          await repository.write(status('starting'), health);
          health.ready();
          now = now.add(const Duration(seconds: 60));
          expect(health.tick(), isTrue);
          await repository.write(
            status('ready'),
            health,
            activity: 'plugin_recovered',
          );
          await repository.write(
            status('ready'),
            health,
            activity: 'plugin_recovered',
          );
          final rows = await session.db.unsafeQuery(
            "SELECT change_kind FROM activity WHERE entity_kind='plugin' ORDER BY id",
          );
          expect(rows.map((row) => row[0]).toList(), [
            'plugin_degraded',
            'plugin_recovered',
          ]);
        },
      );
      test('probe_recovery_is_recorded_once_before_boundary_crash', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        var now = DateTime.utc(2026);
        final policy = SupervisionPolicy(
          clock: () => now,
          circuit: PluginCircuit.probing,
          failures: [now.subtract(const Duration(minutes: 5))],
        );
        policy.start();
        policy.ready();
        const key = PluginKey('boundary-output', 'boundary-digest');
        final repository = PluginStatusRepository(session, 'boundary-host');
        PluginStatusSnapshot status() => PluginStatusSnapshot(
          key: key,
          state: policy.state.name,
          restartCount: 0,
          crashesInWindow: policy.failures.length,
          heartbeatAt: now,
          lastErrorClass: policy.lastError,
        );
        await repository.write(status(), policy);
        now = now.add(const Duration(seconds: 60));
        expect(policy.tick(), isTrue);
        await repository.write(status(), policy, activity: 'plugin_recovered');
        policy.failed('plugin_connection_lost');
        await repository.write(status(), policy);
        await repository.write(status(), policy, activity: 'plugin_recovered');
        final rows = await session.db.unsafeQuery(
          '''SELECT a.change_kind
        FROM activity a JOIN plugin_instance_status s ON s.id=a.entity_id
        WHERE a.entity_kind='plugin' AND s."hostInstanceId"='boundary-host' ORDER BY a.id''',
        );
        expect(rows.map((row) => row[0]).toList(), ['plugin_recovered']);
        expect(policy.state, PluginState.backoff);
        expect(policy.circuit, PluginCircuit.closed);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
