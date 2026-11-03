import 'package:serverpod/serverpod.dart';

/// What `/startupz` needs to know beyond Serverpod's own `start()` check.
///
/// Serverpod's startup indicator passes as soon as `start()` returns, which is
/// before the role's subsystems have started and before the shutdown callback
/// exists. This state is ready only when both are true.
final class StartupState {
  /// Whether the single shutdown callback has been registered.
  bool shutdownCallbackRegistered = false;

  /// Whether every subsystem of the role has started.
  bool subsystemsStarted = false;

  /// Whether the process is ready to serve and ready to be stopped.
  bool get isReady => shutdownCallbackRegistered && subsystemsStarted;
}

/// The Correlia startup indicator, added through
/// `HealthConfig.additionalStartupIndicators`.
final class CorreliaStartupIndicator extends HealthIndicator<bool> {
  /// Creates an indicator reading [state].
  const CorreliaStartupIndicator(this.state);

  /// The state this indicator reports.
  final StartupState state;

  @override
  String get name => 'correlia:startup';

  @override
  Future<HealthCheckResult> check() async => state.isReady
      ? pass(observedValue: true)
      : fail(
          observedValue: false,
          output: state.shutdownCallbackRegistered
              ? 'subsystems are still starting'
              : 'shutdown callback is not registered yet',
        );
}
