import 'package:serverpod/serverpod.dart';

import 'role_runtime.dart';
import 'subsystem.dart';

/// The thin real [ServerpodPort] over a [Serverpod] instance.
final class ServerpodAdapter implements ServerpodPort {
  /// Wraps [pod].
  ServerpodAdapter(this.pod);

  /// The wrapped server.
  final Serverpod pod;

  static int _taskCounter = 0;

  @override
  void mountRoutes(Subsystem subsystem) =>
      subsystem.mountRoutes(_WebServerRoutes(pod.webServer));

  @override
  Future<void> start() => pod.start();

  @override
  void addShutdownTask(Future<void> Function() task) =>
      pod.experimental.shutdownTasks.addTask(
        'correlia-subsystems-${_taskCounter++}',
        task,
      );
}

final class _WebServerRoutes implements RouteHost {
  _WebServerRoutes(this._server);

  final WebServer _server;

  @override
  void addRoute(Route route, String path) => _server.addRoute(route, path);
}
