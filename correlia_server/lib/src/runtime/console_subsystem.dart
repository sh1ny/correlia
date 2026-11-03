import 'dart:io';

import 'package:serverpod/serverpod.dart';

import 'process_options.dart';
import 'subsystem.dart';
import 'test_mode_switches.dart';

/// Serves the operator console, a Flutter web app, from an app directory.
///
/// Runs in the `api` and `all` roles. The `worker` role mounts no console
/// route, so its web port answers 404. When the app directory has no
/// `index.html`, every console path answers 503 with a page naming
/// `mise run build:web`, and a warning is logged at startup; health is not
/// affected.
final class ConsoleSubsystem extends Subsystem {
  /// Creates the subsystem serving [appDir]; warnings go to [log].
  const ConsoleSubsystem({required this.appDir, required this.log});

  /// Chooses the app directory for [runMode]: `CORRELIA_TEST_CONSOLE_DIR`
  /// in run mode `test` only, [defaultAppDir] otherwise.
  factory ConsoleSubsystem.forRunMode(
    String runMode,
    Map<String, String> environment, {
    required void Function(String line) log,
  }) {
    final switches = TestModeSwitches.fromEnvironment(runMode, environment);
    return ConsoleSubsystem(
      appDir: Directory(switches.consoleDir ?? defaultAppDir),
      log: log,
    );
  }

  /// Where `mise run build:web` puts the built app, relative to the server.
  static const String defaultAppDir = 'web/app';

  /// The directory the console is served from.
  final Directory appDir;

  /// Receives the startup warning.
  final void Function(String line) log;

  @override
  String get name => 'console';

  @override
  Set<ProcessRole> get roles => const {ProcessRole.api, ProcessRole.all};

  @override
  void mountRoutes(RouteHost host) {
    final index = File('${appDir.path}/index.html');
    if (index.existsSync()) {
      host.addRoute(FlutterRoute(appDir, enableWasmHeaders: false), '/');
      return;
    }
    log(
      'Warning: no index.html in ${appDir.path}; the console answers 503 '
      'until it is built with `mise run build:web`.',
    );
    host.addRoute(_ConsoleNotBuiltRoute(), '/**');
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// The 503 response for a console that has not been built.
Response consoleNotBuiltResponse() => Response(
  503,
  body: Body.fromString(_notBuiltPage, mimeType: MimeType.html),
);

const String _notBuiltPage = '''
<!DOCTYPE html>
<html lang="en">
  <head><meta charset="utf-8"><title>Console not built</title></head>
  <body>
    <h1>Console not built</h1>
    <p>The console has not been built yet. Run:</p>
    <pre>mise run build:web</pre>
    <p>then reload this page.</p>
  </body>
</html>
''';

/// Answers every request with [consoleNotBuiltResponse].
final class _ConsoleNotBuiltRoute extends Route {
  _ConsoleNotBuiltRoute() : super(methods: {Method.get, Method.head});

  // The page needs no session, so skip the session lookup of [Route.call].
  @override
  Future<Result> call(Request req) async => consoleNotBuiltResponse();

  @override
  Result handleCall(Session session, Request request) =>
      consoleNotBuiltResponse();
}
