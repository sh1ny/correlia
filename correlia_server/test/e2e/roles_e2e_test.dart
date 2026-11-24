@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_child.dart';

const _timeout = Timeout(Duration(minutes: 3));

void main() {
  final serverDir = Directory.current;
  late Directory consoleDir;
  final children = <ChildServer>[];
  E2eRoot? root;

  setUpAll(() {
    consoleDir = Directory.systemTemp.createTempSync('correlia_console_');
    File(
      p.join(consoleDir.path, 'index.html'),
    ).writeAsStringSync('<!DOCTYPE html><title>fixture console</title>');
  });

  tearDownAll(() => consoleDir.deleteSync(recursive: true));

  tearDown(() async {
    final owned = root;
    root = null;
    await tearDownChildren(children, root: owned);
    children.clear();
  });

  /// Starts a child with the role arguments in the stable root of [testId].
  Future<ChildServer> start(String testId, List<String> roleArgs) async {
    final e2eRoot = root = E2eRoot(serverDir, testId);
    final child = await ChildServer.start(
      serverDir: serverDir,
      root: e2eRoot.dir,
      args: ['--mode', 'test', '--apply-migrations', ...roleArgs],
      environment: {'CORRELIA_TEST_CONSOLE_DIR': consoleDir.path},
    );
    children.add(child);
    return child;
  }

  test('worker role is logged as worker', () async {
    final child = await start('roles-worker', ['--process-role', 'worker']);
    await child.waitUntilReady();

    expect(child.output, contains('process role: worker'));
    expect(child.output, isNot(contains('process role: all')));
  }, timeout: _timeout);

  test('no role runs as all and logs all', () async {
    final child = await start('roles-default', []);
    await child.waitUntilReady();

    expect(child.output, contains('process role: all'));
  }, timeout: _timeout);

  test(
    'unknown role exits non-zero before any listener or cluster',
    () async {
      final child = await start('roles-unknown', [
        '--process-role',
        'frontend',
      ]);

      expect(await child.exitCode, isNonZero, reason: child.output);
      expect(child.output, contains('frontend'));
      for (final role in ['api', 'worker', 'all']) {
        expect(child.output, contains(role));
      }
      expect(
        child.output,
        isNot(contains('SERVERPOD version')),
        reason: 'Serverpod was never constructed',
      );
      expect(await child.statusOf('/livez'), isNull, reason: 'no listener');
      expect(
        Directory(root!.pgdata).existsSync(),
        isFalse,
        reason: 'no cluster was created',
      );
    },
    timeout: _timeout,
  );

  test('unrecognised option exits non-zero naming it', () async {
    final child = await start('roles-bad-option', [
      '--mode',
      'production',
      '--frobnicate',
    ]);

    expect(await child.exitCode, isNonZero, reason: child.output);
    expect(child.output, contains('frobnicate'));
    expect(
      child.output,
      isNot(contains('Run mode:')),
      reason: 'it did not start in some default run mode',
    );
    expect(Directory(root!.pgdata).existsSync(), isFalse);
  }, timeout: _timeout);

  test(
    'api role serves the console',
    () async {
      final child = await start('roles-api', ['--process-role', 'api']);
      await child.waitUntilReady();

      final page = await child.fetch('/', web: true);
      expect(page?.status, 200, reason: child.output);
      expect(page?.body, contains('fixture console'));
    },
    timeout: _timeout,
  );

  test('api_role_does_not_start_a_configured_stream', () async {
    final scenario = await Icinga2StreamChild.create();
    final child = await scenario.start(role: 'api', revision: 1);
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final request = await http.post(
      '127.0.0.1',
      child.apiPort,
      '/icinga2Stream/status',
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'sourceId': icinga2DbSourceId}));
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(await utf8.decoder.bind(response).join(), 'null');
    expect(await scenario.count('icinga2_stream_lease'), 0);
    expect(scenario.upstream.eventRequests, isEmpty);
    expect(child.output, isNot(contains('icinga2-stream source=')));
  }, timeout: _timeout);

  test('worker role answers 404 for the console', () async {
    final child = await start('roles-worker-console', [
      '--process-role',
      'worker',
    ]);
    await child.waitUntilReady();

    expect(await child.statusOf('/', web: true), 404, reason: child.output);
    expect(await child.statusOf('/index.html', web: true), 404);
    expect(child.output, contains('Process role: worker; subsystems: '));
    expect(child.output, isNot(contains('Started console')));
  }, timeout: _timeout);
}
