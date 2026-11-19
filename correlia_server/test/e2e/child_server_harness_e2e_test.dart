@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/shared_cluster.dart';

const _timeout = Timeout(Duration(minutes: 4));

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _withDatabase(
  Future<void> Function(SharedClusterDatabase, List<ChildServer>, Directory)
  body,
) async {
  final database = await SharedClusterDatabase.create(Directory.current);
  final logs = Directory.systemTemp.createTempSync('correlia-child-harness-');
  final children = <ChildServer>[];
  try {
    await body(database, children, logs);
  } finally {
    await tearDownChildren(children);
    await database.drop();
    await logs.delete(recursive: true);
  }
}

void main() {
  test('database_key_is_private_canonical_and_stable', () async {
    await _withDatabase((db, children, logs) async {
      final path = db.secretKeyFile;
      final file = File(path);
      final encoded = await file.readAsString();
      expect(encoded, hasLength(43));
      final bytes = base64Url.decode('$encoded=');
      expect(bytes, hasLength(32));
      expect(base64Url.encode(bytes), '$encoded=');
      expect((await file.stat()).mode & 0x1ff, 0x180);
      expect(db.secretKeyFile, path);
      expect(await file.readAsString(), encoded);
    });
  }, timeout: _timeout);

  test('never_ready_fails_with_harness_error', () async {
    await _withDatabase((db, children, logs) async {
      final child = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: db,
        readyTimeout: const Duration(milliseconds: 1),
      );
      children.add(child);
      await expectLater(
        child.waitUntilReady(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('not ready in'), contains('Output:')),
          ),
        ),
      );
    });
  }, timeout: _timeout);

  test('lost_api_port_is_retried_on_fresh_ports', () async {
    final held = await ServerSocket.bind(InternetAddress.anyIPv6, 0);
    try {
      await _withDatabase((db, children, logs) async {
        var picks = 0;
        final child = await ChildServer.startOnSharedCluster(
          serverDir: Directory.current,
          database: db,
          readyTimeout: const Duration(seconds: 120),
          portPicker: () async => picks++ == 0 ? held.port : await _freePort(),
        );
        children.add(child);
        await child.waitUntilReady();
        expect(child.attempts, 2);
        expect(child.apiPort, isNot(held.port));
        expect(await child.statusOf('/startupz'), 200);
      });
    } finally {
      await held.close();
    }
  }, timeout: _timeout);

  test('port_lost_on_every_attempt_fails_after_three', () async {
    final held = <ServerSocket>[];
    try {
      await _withDatabase((db, children, logs) async {
        var picks = 0;
        final child = await ChildServer.startOnSharedCluster(
          serverDir: Directory.current,
          database: db,
          readyTimeout: const Duration(seconds: 120),
          portPicker: () async {
            if (picks++ % 3 != 0) return _freePort();
            final socket = await ServerSocket.bind(InternetAddress.anyIPv6, 0);
            held.add(socket);
            return socket.port;
          },
        );
        children.add(child);
        await expectLater(
          child.waitUntilReady(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('3 attempts'), contains('Failed to bind socket')),
            ),
          ),
        );
        expect(child.attempts, 3);
        expect(await child.exitCode, isNot(0));
      });
    } finally {
      for (final socket in held) {
        await socket.close();
      }
    }
  }, timeout: _timeout);

  test('non_bind_startup_failure_gets_one_attempt', () async {
    await _withDatabase((db, children, logs) async {
      final child = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: db,
        environment: {'CORRELIA_INGEST_CONFIG': '${logs.path}/missing.json'},
      );
      children.add(child);
      expect(await child.exitCode, 1);
      expect(child.attempts, 1);
      expect(child.output, contains('ingest bootstrap'));
    });
  }, timeout: _timeout);

  test('exit_and_readiness_race_sees_retried_attempt', () async {
    final held = await ServerSocket.bind(InternetAddress.anyIPv6, 0);
    try {
      await _withDatabase((db, children, logs) async {
        var picks = 0;
        final child = await ChildServer.startOnSharedCluster(
          serverDir: Directory.current,
          database: db,
          readyTimeout: const Duration(seconds: 120),
          portPicker: () async => picks++ == 0 ? held.port : await _freePort(),
        );
        children.add(child);
        final exit = child.exitCode;
        expect(
          await Future.any<int>([
            exit,
            child.waitUntilReady().then((_) => -999, onError: (_) => exit),
          ]),
          -999,
        );
        expect(identical(child.exitCode, exit), isTrue);
        expect(child.hasExited, isFalse);
        expect(child.attempts, 2);
      });
    } finally {
      await held.close();
    }
  }, timeout: _timeout);

  test('stolen_api_port_answering_200_is_not_ready', () async {
    final thief = await HttpServer.bind(InternetAddress.anyIPv6, 0);
    var requests = 0;
    final serving = thief.listen((request) {
      requests++;
      request.response.statusCode = 200;
      unawaited(request.response.close());
    });
    try {
      await _withDatabase((db, children, logs) async {
        var picks = 0;
        final child = await ChildServer.startOnSharedCluster(
          serverDir: Directory.current,
          database: db,
          readyTimeout: const Duration(seconds: 120),
          portPicker: () async => picks++ == 0 ? thief.port : await _freePort(),
        );
        children.add(child);
        await child.waitUntilReady();
        expect(requests, greaterThan(0));
        expect(child.attempts, 2);
        expect(child.apiPort, isNot(thief.port));
        expect(await child.statusOf('/startupz'), 200);
      });
    } finally {
      await thief.close(force: true);
      await serving.cancel();
    }
  }, timeout: _timeout);

  test('stop_during_pending_retry_starts_no_further_attempt', () async {
    final held = await ServerSocket.bind(InternetAddress.anyIPv6, 0);
    try {
      await _withDatabase((db, children, logs) async {
        var picks = 0;
        final stopping = Completer<void>();
        final release = Completer<void>();
        late ChildServer child;
        child = await ChildServer.startOnSharedCluster(
          serverDir: Directory.current,
          database: db,
          readyTimeout: const Duration(seconds: 120),
          // The argv includes this unique path, so /proc can prove no VM remains.
          vmArgs: ['--define=child_harness_log=${logs.path}'],
          portPicker: () async {
            final pick = picks++;
            if (pick == 0) return held.port;
            if (pick == 3) {
              child.kill();
              stopping.complete();
              await release.future;
            }
            return _freePort();
          },
        );
        children.add(child);
        final exit = child.exitCode;
        await stopping.future;
        release.complete();
        expect(await exit, isNot(0));
        expect(identical(child.exitCode, exit), isTrue);
        expect(child.attempts, lessThanOrEqualTo(2));
        expect(picks, lessThanOrEqualTo(6));
        expect(processesNaming(logs.path), isEmpty);
      });
    } finally {
      await held.close();
    }
  }, timeout: _timeout);
}
