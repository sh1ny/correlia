import 'dart:io';

import 'package:correlia_server/src/runtime/console_subsystem.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

final class _RecordingHost implements RouteHost {
  final List<(Route, String)> mounted = [];

  @override
  void addRoute(Route route, String path) => mounted.add((route, path));
}

void main() {
  late Directory appDir;
  late List<String> logged;
  late _RecordingHost host;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('console_subsystem_test');
    addTearDown(() => appDir.deleteSync(recursive: true));
    logged = [];
    host = _RecordingHost();
  });

  test('runs in the api and all roles only', () {
    final subsystem = ConsoleSubsystem(appDir: appDir, log: logged.add);
    expect(subsystem.roles, {ProcessRole.api, ProcessRole.all});
    expect(subsystem.roles, isNot(contains(ProcessRole.worker)));
  });

  group('with an index.html in the app directory', () {
    setUp(() => File('${appDir.path}/index.html').writeAsStringSync('<html>'));

    test('serves the directory at the root and logs no warning', () {
      ConsoleSubsystem(appDir: appDir, log: logged.add).mountRoutes(host);

      expect(host.mounted, hasLength(1));
      expect(host.mounted.single.$1, isA<FlutterRoute>());
      expect(host.mounted.single.$2, '/');
      expect(logged, isEmpty);
    });
  });

  group('without an index.html in the app directory', () {
    test('mounts the 503 route for every path', () {
      ConsoleSubsystem(appDir: appDir, log: logged.add).mountRoutes(host);

      expect(host.mounted, hasLength(1));
      expect(host.mounted.single.$2, '/**');
      expect(host.mounted.single.$1, isNot(isA<FlutterRoute>()));
    });

    test('the 503 page names mise run build:web', () async {
      final response = consoleNotBuiltResponse();
      expect(response.statusCode, 503);
      expect(response.mimeType, MimeType.html);
      expect(await response.readAsString(), contains('mise run build:web'));
    });

    test('logs a startup warning naming the task and the directory', () {
      ConsoleSubsystem(appDir: appDir, log: logged.add).mountRoutes(host);

      expect(logged, hasLength(1));
      expect(logged.single, contains('mise run build:web'));
      expect(logged.single, contains(appDir.path));
    });

    test('treats a missing directory the same way', () {
      final missing = Directory('${appDir.path}/nope');
      ConsoleSubsystem(appDir: missing, log: logged.add).mountRoutes(host);

      expect(host.mounted.single.$2, '/**');
      expect(logged, hasLength(1));
    });
  });

  group('forRunMode', () {
    test('serves CORRELIA_TEST_CONSOLE_DIR in run mode test', () {
      final subsystem = ConsoleSubsystem.forRunMode(
        'test',
        {'CORRELIA_TEST_CONSOLE_DIR': appDir.path},
        log: logged.add,
      );
      expect(subsystem.appDir.path, appDir.path);
    });

    test('ignores CORRELIA_TEST_CONSOLE_DIR in any other run mode', () {
      final subsystem = ConsoleSubsystem.forRunMode(
        'production',
        {'CORRELIA_TEST_CONSOLE_DIR': appDir.path},
        log: logged.add,
      );
      expect(subsystem.appDir.path, ConsoleSubsystem.defaultAppDir);
    });

    test('defaults to web/app without the variable', () {
      final subsystem = ConsoleSubsystem.forRunMode(
        'test',
        const {},
        log: logged.add,
      );
      expect(subsystem.appDir.path, 'web/app');
    });
  });
}
