import 'dart:io';

import 'package:serverpod/serverpod.dart';

import '../cache_busting.dart';
import '../web/routes/app_config_route.dart';
import 'process_options.dart';
import 'subsystem.dart';

/// The web routes of the Serverpod project template, kept as the `api`/`all`
/// web surface until the console group replaces them with the real console
/// subsystem. The `worker` role does not run it, so its web port answers 404.
final class TemplateWebSubsystem extends Subsystem {
  /// Creates the subsystem; [apiConfig] builds the app config route.
  const TemplateWebSubsystem(this.apiConfig);

  /// The API server configuration served to the Flutter app.
  final ServerConfig apiConfig;

  @override
  String get name => 'web';

  @override
  Set<ProcessRole> get roles => const {ProcessRole.api, ProcessRole.all};

  @override
  void mountRoutes(RouteHost host) {
    host.addRoute(
      StaticRoute.withCacheBusting(cacheBustingConfig),
      cacheBustingConfig.mountPrefix,
    );
    host.addRoute(
      AppConfigRoute(apiConfig: apiConfig),
      '/assets/assets/config.json',
    );

    final appDir = Directory(Uri(path: 'web/app').toFilePath());
    if (appDir.existsSync()) {
      host.addRoute(FlutterRoute(appDir, enableWasmHeaders: false), '/');
    } else {
      host.addRoute(
        StaticRoute.file(
          File(Uri(path: 'web/pages/build_flutter_app.html').toFilePath()),
        ),
        '/**',
      );
    }
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}
