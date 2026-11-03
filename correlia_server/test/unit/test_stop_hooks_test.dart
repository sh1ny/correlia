import 'dart:async';

import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:correlia_server/src/runtime/test_stop_hooks.dart';
import 'package:test/test.dart';

void main() {
  group('TestStopHooks', () {
    test('runs in every role', () {
      final hooks = TestStopHooks(log: (_) {});
      expect(hooks.roles, ProcessRole.values.toSet());
    });

    test('start does nothing and logs nothing', () async {
      final lines = <String>[];
      await TestStopHooks(log: lines.add).start();
      expect(lines, isEmpty);
    });

    test('stop waits at the gate, then runs the probe', () async {
      final lines = <String>[];
      final gate = Completer<void>();
      final hooks = TestStopHooks(
        awaitGate: () {
          lines.add('gate reached');
          return gate.future;
        },
        probe: () async => 'database d',
        log: lines.add,
      );

      var stopped = false;
      final stopping = hooks.stop().then((_) => stopped = true);
      await pumpEventQueue();
      expect(stopped, isFalse, reason: 'held at the gate');
      expect(lines, ['test gate: waiting', 'gate reached']);

      gate.complete();
      await stopping;
      expect(lines, [
        'test gate: waiting',
        'gate reached',
        'test gate: open',
        'test probe: database d',
      ]);
    });

    test('stop without gate or probe logs nothing', () async {
      final lines = <String>[];
      await TestStopHooks(log: lines.add).stop();
      expect(lines, isEmpty);
    });

    test('a failing probe is logged and rethrown', () async {
      final lines = <String>[];
      final hooks = TestStopHooks(
        probe: () async => throw StateError('pool closed'),
        log: lines.add,
      );
      await expectLater(hooks.stop(), throwsStateError);
      expect(lines.single, startsWith('test probe failed:'));
    });
  });
}
