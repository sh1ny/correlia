import 'dart:async';

import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:correlia_server/src/runtime/role_runtime.dart';
import 'package:correlia_server/src/runtime/startup_state.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

final class _Gated extends Subsystem {
  final gate = Completer<void>();
  final entered = Completer<void>();

  @override
  String get name => 'gated';
  @override
  Set<ProcessRole> get roles => const {ProcessRole.all};
  @override
  Future<void> start() async {
    entered.complete();
    await gate.future;
  }

  @override
  Future<void> stop() async {}
}

final class _Port implements ServerpodPort {
  final registered = Completer<void>();
  @override
  void mountRoutes(Subsystem subsystem) {}
  @override
  Future<void> start() async {}
  @override
  void addShutdownTask(Future<void> Function() task) => registered.complete();
}

void main() {
  test(
    'the indicator is unhealthy until subsystems started and callback registered',
    () async {
      final state = StartupState();
      final indicator = CorreliaStartupIndicator(state);
      expect((await indicator.check()).status, HealthStatus.fail);

      final subsystem = _Gated();
      final port = _Port();
      final runtime = RoleRuntime(
        role: ProcessRole.all,
        registry: [subsystem],
        port: port,
        startup: state,
        log: (_) {},
      );
      final started = runtime.start();
      await subsystem.entered.future;
      expect(port.registered.isCompleted, isTrue);
      expect(state.shutdownCallbackRegistered, isTrue);
      expect(state.isReady, isFalse, reason: 'subsystem still starting');
      expect((await indicator.check()).status, HealthStatus.fail);

      subsystem.gate.complete();
      expect(await started, isA<Started>());
      expect(state.isReady, isTrue);
      expect((await indicator.check()).status, HealthStatus.pass);
    },
  );

  test('the callback alone does not make the state ready', () {
    final state = StartupState()..shutdownCallbackRegistered = true;
    expect(state.isReady, isFalse);
  });
}
