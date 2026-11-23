@Tags(['e2e'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/holding_proxy.dart';
import '../support/shared_cluster.dart';

const _source = '33333333-3333-4333-8333-333333333333';
const _timeout = Timeout(Duration(minutes: 5));

/// The sender's per-source cap on overlapping signed requests (spec: 2).
const _signedPerSource = 2;

String _credential(int value) =>
    base64Url.encode(List<int>.filled(32, value)).replaceAll('=', '');

/// One real Correlia child with an `icinga2` source, and the built sender.
final class _Rig {
  _Rig._(this.database, this.files, this.child, this.connection, this.binary);

  static Future<_Rig> create(String binary) async {
    final database = await SharedClusterDatabase.create(Directory.current);
    final files = Directory.systemTemp.createTempSync('icinga2-sender-');
    ChildServer? child;
    Connection? connection;
    try {
      _writeConfig(files, revision: 1, bearer: true);
      final secrets = File('${files.path}/secrets.json')
        ..writeAsStringSync(
          jsonEncode({'token': _credential(1), 'key': _credential(2)}),
        );
      await _chmod(secrets.path);
      child = await _start(database, files);
      connection = await Connection.open(
        Endpoint(
          host: socketHostFor(
            database.socketPath,
            workingDirectory: Directory.current.path,
          ),
          port: database.port,
          database: database.name,
          username: 'postgres',
          isUnixSocket: true,
        ),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
      return _Rig._(database, files, child, connection, binary);
    } catch (_) {
      await connection?.close();
      if (child != null) await tearDownChildren([child]);
      await database.drop();
      files.deleteSync(recursive: true);
      rethrow;
    }
  }

  final SharedClusterDatabase database;
  final Directory files;
  ChildServer child;
  final Connection connection;
  final String binary;

  /// Publishes configuration [revision] without the source's bearer
  /// credential, as an operator revoking the token does, and restarts the
  /// child so it applies it.
  Future<void> revokeToken(int revision) async {
    _writeConfig(files, revision: revision, bearer: false);
    await tearDownChildren([child]);
    child = await _start(database, files);
  }

  /// Writes a credential file (mode 600) and returns its path.
  Future<String> credentialFile(String name, String content) async {
    final file = File('${files.path}/$name')..writeAsStringSync(content);
    await _chmod(file.path);
    return file.path;
  }

  /// Starts the sender with an empty environment and the given credential.
  Future<Process> send({
    required int port,
    required String credentialOption,
    required String credentialPath,
    String state = 'DOWN',
    String lastStateChange = '1763571234.123456',
  }) {
    String lit(String value) => jsonEncode(value);
    return Process.start('/usr/bin/env', [
      '-i',
      binary,
      '--base-url',
      lit('http://127.0.0.1:$port'),
      '--source',
      lit(_source),
      credentialOption,
      lit(credentialPath),
      '--object-type',
      lit('host'),
      '--host',
      lit('web1'),
      '--state',
      lit(state),
      '--state-type',
      lit('HARD'),
      '--last-state-change',
      lit(lastStateChange),
      '--output',
      lit('PING CRITICAL'),
      '--notification-type',
      lit('PROBLEM'),
      '--notification-time',
      lit('1763571240.500000'),
    ], includeParentEnvironment: false);
  }

  Future<int> count(String table) async =>
      (await connection.execute('SELECT count(*) FROM $table')).single[0]!
          as int;

  /// Polls the database until [table] holds [rows] rows.
  Future<void> waitForRows(String table, int rows) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (await count(table) < rows) {
      if (DateTime.now().isAfter(deadline)) {
        fail('$table never reached $rows rows\n${child.output}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> dispose() async {
    await connection.close();
    try {
      await tearDownChildren([child]);
    } finally {
      await database.drop();
      files.deleteSync(recursive: true);
    }
  }
}

/// Writes the ingest configuration: the `icinga2` source with its HMAC key
/// and, when [bearer], its token.
void _writeConfig(
  Directory files, {
  required int revision,
  required bool bearer,
}) {
  File('${files.path}/config.json').writeAsStringSync(
    jsonEncode({
      'format_version': 2,
      'revision': revision,
      'outputs': <Object?>[],
      'sources': [
        {
          'id': _source,
          'kind': 'icinga2',
          'enabled': true,
          'credentials': [
            if (bearer) {'ref': 'token', 'type': 'bearer'},
            {'ref': 'key', 'type': 'hmac'},
          ],
          'output_ids': <Object?>[],
        },
      ],
    }),
  );
}

/// Starts a Correlia child on [database] with the configuration in [files].
Future<ChildServer> _start(
  SharedClusterDatabase database,
  Directory files,
) async {
  final child = await ChildServer.startOnSharedCluster(
    serverDir: Directory.current,
    database: database,
    environment: {
      'CORRELIA_INGEST_CONFIG': '${files.path}/config.json',
      'CORRELIA_INGEST_SECRETS': '${files.path}/secrets.json',
    },
  );
  try {
    await child.waitUntilReady();
  } catch (_) {
    await tearDownChildren([child]);
    rethrow;
  }
  return child;
}

Future<void> _chmod(String path) async {
  final result = await Process.run('chmod', ['600', path]);
  expect(result.exitCode, 0);
}

/// The sender's exit code, stdout and stderr once it has ended.
Future<({int code, String out, String err})> _finish(Process process) async {
  final out = utf8.decodeStream(process.stdout);
  final err = utf8.decodeStream(process.stderr);
  final code = await process.exitCode.timeout(const Duration(seconds: 30));
  return (code: code, out: await out, err: await err);
}

void main() {
  late Directory temp;
  late String binary;
  late _Rig rig;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('icinga2-sender-bin-');
    binary = '${temp.path}/correlia-icinga2-notify';
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '../correlia_icinga2_notify/bin/main.dart',
      '-o',
      binary,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    rig = await _Rig.create(binary);
  });

  tearDownAll(() async {
    try {
      await rig.dispose();
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test(
    'rejected_delivery',
    () async {
      // The token is admitted first, so the later 401 is its revocation and
      // not a token Correlia never knew.
      final token = await rig.credentialFile('token', _credential(1));
      final before = await rig.count('raw_inbox');
      final events = await rig.count('events');
      final admitted = await _finish(
        await rig.send(
          port: rig.child.webPort,
          credentialOption: '--token-file',
          credentialPath: token,
          lastStateChange: '1763571200.000001',
        ),
      );
      expect(admitted.code, 0, reason: admitted.err);
      expect(admitted.err, isEmpty);
      expect(await rig.count('raw_inbox'), before + 1);
      await rig.waitForRows('events', events + 1);

      await rig.revokeToken(2);
      final result = await _finish(
        await rig.send(
          port: rig.child.webPort,
          credentialOption: '--token-file',
          credentialPath: token,
          lastStateChange: '1763571200.000002',
        ),
      );
      expect(result.code, 1);
      expect(result.err, 'status 401\n');
      expect(result.out, isEmpty);
      expect(result.err, isNot(contains(_credential(1))));
      expect(await rig.count('raw_inbox'), before + 1);
      expect(await rig.count('events'), events + 1);
    },
    timeout: _timeout,
  );

  test(
    'canonical_unpadded_key_file',
    () async {
      final key = _credential(2);
      expect(key, hasLength(43));
      final before = await rig.count('raw_inbox');
      for (final (name, content, time) in [
        ('key-plain', key, '1763571234.000001'),
        ('key-newline', '$key\n', '1763571234.000002'),
      ]) {
        final path = await rig.credentialFile(name, content);
        final result = await _finish(
          await rig.send(
            port: rig.child.webPort,
            credentialOption: '--hmac-key-file',
            credentialPath: path,
            lastStateChange: time,
          ),
        );
        expect(result.code, 0, reason: '$name: ${result.err}');
        expect(result.err, isEmpty);
      }
      await rig.waitForRows('events', 2);
      expect(await rig.count('raw_inbox'), before + 2);

      // A 44-character key file never reaches the network.
      final padded = await rig.credentialFile('key-padded', '${key}A');
      final refused = await _finish(
        await rig.send(
          port: rig.child.webPort,
          credentialOption: '--hmac-key-file',
          credentialPath: padded,
        ),
      );
      expect(refused.code, 2);
      expect(await rig.count('raw_inbox'), before + 2);
    },
    timeout: _timeout,
  );

  test(
    'concurrent_signed_notifications_beyond_the_cap',
    () async {
      final key = await rig.credentialFile('key-cap', _credential(2));
      final before = await rig.count('raw_inbox');
      final proxy = await HoldingProxy.start(rig.child.webPort);
      try {
        final senders = [
          for (var i = 0; i < _signedPerSource + 1; i++)
            await rig.send(
              port: proxy.port,
              credentialOption: '--hmac-key-file',
              credentialPath: key,
              lastStateChange: '1763571300.00000$i',
            ),
        ];
        // Ingress logs the refusal when it makes it, before it answers; the
        // two admitted requests are still waiting for their last body byte.
        await rig.child.waitForOutput(RegExp('outcome=503'));
        proxy.release();
        final results = await Future.wait(senders.map(_finish));
        final codes = results.map((r) => r.code).toList()..sort();
        expect(codes, [0, 0, 1], reason: results.map((r) => r.err).join());
        final refused = results.singleWhere((r) => r.code == 1);
        expect(refused.err, 'status 503\n');
        expect(refused.out, isEmpty);
        for (final admitted in results.where((r) => r.code == 0)) {
          expect(admitted.err, isEmpty);
        }
        expect(await rig.count('raw_inbox'), before + _signedPerSource);
      } finally {
        await proxy.close();
      }
    },
    timeout: _timeout,
  );
}
