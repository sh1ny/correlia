import 'process_options.dart';
import 'subsystem.dart';

/// A subsystem that exists only for end-to-end tests (run mode `test`): on
/// stop it can wait at a gate and then run a database probe, so a test can
/// observe when, and in what state, subsystems stop.
final class TestStopHooks extends Subsystem {
  /// Creates the hooks; [log] receives one line per step.
  const TestStopHooks({this.awaitGate, this.probe, required this.log});

  /// Completes when the gate opens; null means no gate.
  final Future<void> Function()? awaitGate;

  /// Runs a query and describes its result; null means no probe.
  final Future<String> Function()? probe;

  /// Receives the progress lines the tests read from the child's output.
  final void Function(String line) log;

  @override
  String get name => 'test-stop-hooks';

  @override
  Set<ProcessRole> get roles => ProcessRole.values.toSet();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    if (awaitGate case final gate?) {
      log('test gate: waiting');
      await gate();
      log('test gate: open');
    }
    if (probe case final probe?) {
      try {
        log('test probe: ${await probe()}');
      } catch (e) {
        log('test probe failed: $e');
        rethrow;
      }
    }
  }
}
