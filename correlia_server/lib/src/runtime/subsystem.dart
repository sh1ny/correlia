import 'package:serverpod/serverpod.dart';

import 'process_options.dart';

/// Somewhere a subsystem can mount its HTTP routes on the web server.
abstract interface class RouteHost {
  /// Mounts [route] at [path].
  void addRoute(Route route, String path);
}

/// A unit of Correlia that runs in some process roles.
///
/// A role runs exactly the subsystems that list it in [roles]. Subsystems are
/// started in registry order and stopped in the reverse order.
abstract class Subsystem {
  /// Creates a subsystem.
  const Subsystem();

  /// The name used in logs and error output.
  String get name;

  /// The process roles this subsystem runs in.
  Set<ProcessRole> get roles;

  /// Mounts routes before the server starts. Does nothing by default.
  void mountRoutes(RouteHost host) {}

  /// Starts the subsystem. Throwing aborts the process start.
  Future<void> start();

  /// Stops the subsystem. Called only if [start] completed.
  Future<void> stop();
}
