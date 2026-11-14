@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/shared_cluster.dart';

const source = '11111111-1111-4111-8111-111111111111';
const output = '22222222-2222-4222-8222-222222222222';
String credential(int value) =>
    base64Url.encode(List<int>.filled(32, value)).replaceAll('=', '');

void main() {
  test('pin_survives_crash_and_activation', () async {
    final database = await SharedClusterDatabase.create(Directory.current);
    final files = Directory.systemTemp.createTempSync('pipeline-recovery-');
    final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>();
    receiver.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 204;
      await request.response.close();
      if (!received.isCompleted) received.complete();
    });
    final children = <ChildServer>[];
    Connection? connection;
    try {
      final config = File('${files.path}/config.json');
      final secrets = File('${files.path}/secrets.json')
        ..writeAsStringSync(
          jsonEncode({'token': credential(1), 'key': credential(2)}),
        );
      final chmod = await Process.run('chmod', ['600', secrets.path]);
      expect(chmod.exitCode, 0);
      void configure(int revision) => config.writeAsStringSync(
        jsonEncode({
          'format_version': 1,
          'revision': revision,
          'sources': [
            {
              'id': source,
              'enabled': true,
              'token_ref': 'token',
              'namespace': 'version-$revision',
              'output_ids': [output],
            },
          ],
          'outputs': [
            {
              'id': output,
              'kind': 'webhook',
              'url': 'http://127.0.0.1:${receiver.port}/',
              'signing_key_ref': 'key',
            },
          ],
        }),
      );
      final gate = '${files.path}/pin';
      final entered = File('$gate.entered');
      final events = files.watch();
      final enteredFuture = events
          .firstWhere((event) => event.path == entered.path)
          .timeout(const Duration(seconds: 60));
      configure(1);
      final env = {
        'CORRELIA_INGEST_CONFIG': config.path,
        'CORRELIA_INGEST_SECRETS': secrets.path,
      };
      final first = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: database,
        environment: {...env, 'CORRELIA_TEST_PIPELINE_PIN_GATE': gate},
      );
      children.add(first);
      await first.waitUntilReady();
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
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:${first.webPort}/hooks/alertmanager/$source',
          ),
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('Authorization', 'Bearer ${credential(1)}');
        request.write(
          jsonEncode({
            'version': '4',
            'status': 'firing',
            'alerts': [
              {
                'status': 'firing',
                'labels': {'alertname': 'Recovery'},
                'annotations': <String, String>{},
                'startsAt': DateTime.now().toUtc().toIso8601String(),
              },
            ],
          }),
        );
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 202);
      } finally {
        client.close(force: true);
      }
      await enteredFuture;
      final pin =
          (await connection.execute(
                'SELECT config_snapshot_id FROM raw_inbox',
              )).single[0]
              as String;
      first.kill();
      await first.exitCode;
      configure(2);
      final replacement = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: database,
        environment: env,
      );
      children.add(replacement);
      await replacement.waitUntilReady();
      await received.future.timeout(const Duration(seconds: 60));
      final active = (await connection.execute(
        'SELECT "snapshotId" FROM ingest_active_config',
      )).single[0];
      expect(active, isNot(pin));
      expect(
        (await connection.execute(
          'SELECT config_snapshot_id FROM events',
        )).single[0],
        pin,
      );
      expect(
        (await connection.execute(
          'SELECT config_snapshot_id FROM outbox',
        )).single[0],
        pin,
      );
    } finally {
      await connection?.close();
      await tearDownChildren(children);
      await receiver.close(force: true);
      await database.drop();
      files.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
