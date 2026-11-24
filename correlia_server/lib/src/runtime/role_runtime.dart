import 'process_options.dart';
import 'startup_state.dart';
import 'subsystem.dart';

/// Receives one log line.
typedef LogSink = void Function(String line);

/// The narrow view of Serverpod that [RoleRuntime] needs.
///
/// The real implementation is a thin adapter over `Serverpod`; unit tests
/// supply a fake so no server or database is involved.
abstract interface class ServerpodPort {
  /// Mounts the routes of [subsystem] on the web server.
  void mountRoutes(Subsystem subsystem);

  /// Starts Serverpod.
  Future<void> start();

  /// Registers [task] as a Serverpod shutdown task, which runs after request
  /// intake stops and before the database pool closes.
  void addShutdownTask(Future<void> Function() task);
}

/// The result of [RoleRuntime.start].
sealed class StartResult {
  const StartResult();
}

/// The server and every subsystem of the role started.
final class Started extends StartResult {
  /// Creates the result.
  const Started();
}

/// Serverpod or a subsystem failed to start.
final class StartFailed extends StartResult {
  /// Creates the result.
  const StartFailed(this.component, this.error, this.stackTrace);

  /// `serverpod` or the name of the failing subsystem.
  final String component;

  /// What was thrown.
  final Object error;

  /// Where it was thrown.
  final StackTrace stackTrace;

  /// Error output naming the failing component.
  String get message => 'Failed to start $component: $error';

  /// The process exit code.
  int get exitCode => ExitCodes.failure;
}

/// Thrown by the shutdown callback when one or more subsystems failed to stop.
final class SubsystemStopException implements Exception {
  /// Creates an exception for [failures], keyed by subsystem name.
  SubsystemStopException(this.failures);

  /// The thrown error of every subsystem that failed to stop.
  final Map<String, Object> failures;

  @override
  String toString() =>
      'Failed to stop ${failures.length} subsystem(s): '
      '${failures.entries.map((e) => '${e.key}: ${e.value}').join('; ')}';
}

/// Starts the subsystems of one process role and stops them on shutdown.
///
/// One shutdown callback is registered with Serverpod, before the first
/// subsystem starts. Serverpod runs separately registered callbacks
/// concurrently, so a single callback is what gives the reverse, sequential
/// stop order.
final class RoleRuntime {
  /// Creates a runtime for [role] over [registry].
  RoleRuntime({
    required this.role,
    required List<Subsystem> registry,
    required this.port,
    required this.startup,
    required this.log,
  }) : subsystems = [
         for (final s in registry)
           if (s.roles.contains(role)) s,
       ];

  /// The role in force.
  final ProcessRole role;

  /// The Serverpod adapter.
  final ServerpodPort port;

  /// Reported through the startup health indicator.
  final StartupState startup;

  /// Where progress and failures are logged.
  final LogSink log;

  /// The subsystems this role runs, in start order.
  final List<Subsystem> subsystems;

  final List<Subsystem> _started = [];

  /// Mounts routes, starts Serverpod, registers the shutdown callback and
  /// starts each subsystem in order.
  Future<StartResult> start() async {
    log(
      'Process role: ${role.name}; subsystems: '
      '${subsystems.map((s) => s.name).join(', ')}',
    );
    try {
      subsystems.forEach(port.mountRoutes);
      await port.start();
    } catch (e, s) {
      return StartFailed('serverpod', e, s);
    }

    port.addShutdownTask(_stopStarted);
    startup.shutdownCallbackRegistered = true;

    for (final subsystem in subsystems) {
      try {
        await subsystem.start();
      } catch (e, s) {
        return StartFailed(subsystem.name, e, s);
      }
      _started.add(subsystem);
      log('Started ${subsystem.name}');
    }
    startup.subsystemsStarted = true;
    log('Ready to serve');
    return const Started();
  }

  Future<void> _stopStarted() async {
    final failures = <String, Object>{};
    while (_started.isNotEmpty) {
      final subsystem = _started.removeLast();
      try {
        await subsystem.stop();
        log('Stopped ${subsystem.name}');
      } catch (e) {
        failures[subsystem.name] = e;
        log('Failed to stop ${subsystem.name}: $e');
      }
    }
    if (failures.isNotEmpty) throw SubsystemStopException(failures);
  }
}
