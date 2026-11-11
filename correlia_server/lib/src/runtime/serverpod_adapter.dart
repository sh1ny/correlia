import 'package:serverpod/serverpod.dart';

import '../schema/schema_steps.dart';
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

  /// Starts Serverpod.
  ///
  /// Serverpod opens the web port only when a route is mounted. A role whose
  /// subsystems mount none (the `worker` role) gets a catch-all route that
  /// answers 404, so its web port still listens and a console request is
  /// answered with 404 rather than refused (D11).
  @override
  Future<void> start() async {
    if (!pod.webServer.hasApp) {
      pod.webServer.addRoute(_NotFoundRoute(), '/**');
    }
    await pod.start();
    final session = await pod.createSession(enableLogging: false);
    try {
      await initializeSchema(session);
    } finally {
      await session.close();
    }
  }

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

/// Answers every request with 404.
final class _NotFoundRoute extends Route {
  _NotFoundRoute() : super(methods: Method.values.toSet());

  // A 404 needs no session, so skip the session lookup of [Route.call].
  @override
  Future<Result> call(Request req) async => Response.notFound();

  @override
  Result handleCall(Session session, Request request) => Response.notFound();
}
