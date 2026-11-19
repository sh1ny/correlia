@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_client/correlia_client.dart';
import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../plugin/support/plugin_fixture_support.dart';
import '../support/child_server.dart';
import '../support/output_process.dart';
import '../support/shared_cluster.dart';

const _namespace = 'legacy-source-namespace';
const _canary = 'sec3_fixture_private_canary';
const _timeout = Timeout(Duration(minutes: 7));
const _awaitEvent = Duration(seconds: 45);

String _base64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Map<String, Object?> _config(int revision, {Map<String, Object?>? output}) => {
  'format_version': 1,
  'revision': revision,
  'sources': [
    {
      'id': outputSource,
      'enabled': true,
      'token_ref': 'token',
      'namespace': _namespace,
      'output_ids': [if (output != null) outputId],
    },
  ],
  'outputs': [?output],
};

Future<void> _private(File file, String content) async {
  await file.writeAsString(content);
  expect((await Process.run('chmod', ['0600', file.path])).exitCode, 0);
}

final class _Fixture {
  _Fixture(this.db, this.files);
  final SharedClusterDatabase db;
  final Directory files;
  final children = <ChildServer>[];
  final logs = <Directory>[];

  File get config => File('${files.path}/config.json');
  File get secrets => File('${files.path}/secrets.json');
  File get key => File('${files.path}/key');

  Future<ChildServer> start({
    bool configured = true,
    bool import = true,
    Directory? plugins,
  }) async {
    final log = Directory('${files.path}/logs-${children.length}');
    final child = await ChildServer.startOnSharedCluster(
      serverDir: Directory.current,
      database: db,
      logs: log,
      environment: {
        if (configured) ...{
          'CORRELIA_INGEST_CONFIG': config.path,
          'CORRELIA_SECRET_KEY_FILE': key.path,
          if (import) 'CORRELIA_INGEST_SECRETS': secrets.path,
        },
        if (plugins != null) 'CORRELIA_PLUGIN_DIR': plugins.path,
      },
    );
    children.add(child);
    logs.add(log);
    return child;
  }

  Future<void> scanLogs(List<String> forbidden) async {
    for (final child in children) {
      _absent(child.output, forbidden, 'captured child output');
    }
    for (final directory in logs) {
      final files = await directory
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      expect(files, isNotEmpty);
      for (final file in files) {
        _absent(await file.readAsString(), forbidden, 'child log file');
      }
    }
  }
}

Future<void> _withFixture(
  Future<void> Function(_Fixture, Connection) run,
) async {
  final db = await SharedClusterDatabase.create(Directory.current);
  final files = await Directory.systemTemp.createTemp('correlia-secret-e2e-');
  final fixture = _Fixture(db, files);
  try {
    await _private(
      fixture.key,
      _base64(utf8.encode('0123456789-secret-store-key-ABCD')),
    );
    await _private(fixture.secrets, jsonEncode({'token': outputToken}));
    await fixture.config.writeAsString(jsonEncode(_config(1)));
    final connection = await outputConnection(db);
    try {
      await run(fixture, connection);
    } finally {
      await connection.close();
    }
  } finally {
    try {
      await tearDownChildren(fixture.children);
    } finally {
      try {
        await db.drop();
      } finally {
        await files.delete(recursive: true);
      }
    }
  }
}

void _absent(String text, List<String> forbidden, String surface) {
  for (final value in forbidden) {
    // Do not print the captured data or needle even when the assertion fails.
    expect(text.contains(value), isFalse, reason: 'Secret in $surface');
  }
}

Future<void> _scanTables(Connection db, List<String> forbidden) async {
  final tables = await db.execute('''SELECT format('%I.%I',schemaname,tablename)
    FROM pg_tables WHERE schemaname='public' ORDER BY tablename''');
  expect(tables.length, greaterThan(10));
  for (final row in tables) {
    final table = row[0]! as String;
    final data = await db.execute('SELECT to_jsonb(t)::text FROM $table t');
    for (final record in data) {
      _absent(record[0]! as String, forbidden, table);
    }
  }
}

Future<String> _activeJson(Connection db) async =>
    (await db.execute('''
    SELECT s."publicJson" FROM ingest_active_config a JOIN ingest_config_snapshot s
    ON s."snapshotId"=a."snapshotId" WHERE a.singleton=1''')).single[0]!
        as String;

Future<void> _bootstrapSchema(_Fixture fixture) async {
  final unconfigured = await fixture.start(configured: false);
  await unconfigured.waitUntilReady();
  expect(await unconfigured.closeStdin(), 0);
}

void main() {
  test(
    'key_file_accepted',
    () => _withFixture((fixture, db) async {
      final child = await fixture.start();
      await child.waitUntilReady();
      await postOutputAlert(child);
      expect(await child.closeStdin(), 0);
      expect(
        (await db.execute('SELECT count(*) FROM secret_record')).single[0],
        1,
      );
      final text = await fixture.key.readAsString();
      final bytes = base64Url.decode(base64Url.normalize(text));
      final forbidden = [text, utf8.decode(bytes), ..._encodedBytea(bytes)];
      await _scanTables(db, forbidden);
      await fixture.scanLogs(forbidden);
    }),
    timeout: _timeout,
  );

  test(
    'version_1_file_still_starts',
    () => _withFixture((fixture, db) async {
      await _bootstrapSchema(fixture);
      final tokenDigest = sha256
          .convert(base64Url.decode(base64Url.normalize(outputToken)))
          .toString();
      // Historical public format, not a v1 input serialized by the v2 publisher.
      final legacy = jsonEncode({
        'format_version': 1,
        'revision': 1,
        'sources': [
          {
            'id': outputSource,
            'namespace': _namespace,
            'enabled': true,
            'token_ref': 'token',
            'token_digest': tokenDigest,
            'path_token_enabled': false,
            'body_limit_bytes': 1048576,
            'excluded_identity_labels': <String>[],
            'output_ids': <String>[],
          },
        ],
        'outputs': <Object?>[],
      });
      final snapshot = sha256.convert(utf8.encode(legacy)).toString();
      await db.execute(
        Sql.named(
          'INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson") VALUES (@id,1,@json)',
        ),
        parameters: {'id': snapshot, 'json': legacy},
      );
      await db.execute(
        Sql.named(
          'INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,@id)',
        ),
        parameters: {'id': snapshot},
      );
      final rejected = await fixture.start();
      expect(await rejected.exitCode.timeout(_awaitEvent), 1);
      expect(rejected.output, contains('activation_conflict'));
      expect(await _activeJson(db), legacy);
      expect(await db.execute('SELECT reference FROM secret_record'), isEmpty);
      await fixture.config.writeAsString(jsonEncode(_config(2)));
      final upgraded = await fixture.start();
      await upgraded.waitUntilReady();
      await postOutputAlert(upgraded);
      final active = jsonDecode(await _activeJson(db)) as Map<String, Object?>;
      expect(active['format_version'], 2);
      expect(active['revision'], 2);
      final source =
          (active['sources']! as List<Object?>).single as Map<String, Object?>;
      expect(source['id'], outputSource);
      expect(source['namespace'], _namespace);
      expect(
        (await db.execute('SELECT source_id::text FROM raw_inbox')).single[0],
        outputSource,
      );
    }),
    timeout: _timeout,
  );

  test(
    'm1_pending_raw_delivers_with_historical_signing_key',
    () => _withFixture((fixture, db) async {
      await _bootstrapSchema(fixture);
      final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<(List<int>, String?)>();
      receiver.listen((request) async {
        final body = await request.fold(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        );
        final signature = request.headers.value('x-correlia-signature');
        request.response.statusCode = 204;
        await request.response.close();
        if (!received.isCompleted) received.complete((body, signature));
      });
      try {
        final key = List<int>.filled(32, 2);
        final legacy = jsonEncode(
          {
            'format_version': 1,
            'revision': 1,
            'sources': [
              {
                'id': outputSource,
                'enabled': true,
                'namespace': _namespace,
                'token_ref': 'token',
                'token_digest': sha256
                    .convert(base64Url.decode(base64Url.normalize(outputToken)))
                    .toString(),
                'body_limit_bytes': 1048576,
                'path_token_enabled': false,
                'excluded_identity_labels': <String>[],
                'output_ids': [outputId],
              },
            ],
            'outputs': [
              {
                'id': outputId,
                'kind': 'webhook',
                'url': 'http://127.0.0.1:${receiver.port}/events',
                'signing_key_ref': 'old-output-key',
                'signing_key_commitment': sha256.convert(key).toString(),
              },
            ],
          },
        );
        final snapshot = sha256.convert(utf8.encode(legacy)).toString();
        await db.execute(
          Sql.named(
            'INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson") VALUES (@id,1,@json)',
          ),
          parameters: {'id': snapshot, 'json': legacy},
        );
        await db.execute(
          Sql.named(
            'INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,@id)',
          ),
          parameters: {'id': snapshot},
        );
        final observed = DateTime.now().toUtc();
        final body = utf8.encode(
          jsonEncode({
            'version': '4',
            'status': 'firing',
            'alerts': [
              {
                'status': 'firing',
                'labels': {'alertname': 'PinnedBeforeUpgrade'},
                'annotations': <String, String>{},
                'startsAt': observed.toIso8601String(),
              },
            ],
          }),
        );
        await db.execute(
          Sql.named(
            '''INSERT INTO raw_inbox
            (observed_at,raw_id,source_id,body,body_sha256,content_type,config_snapshot_id)
            VALUES (@observed,gen_random_uuid(),CAST(@source AS uuid),@body,@digest,'application/json',@pin)''',
          ),
          parameters: {
            'observed': observed,
            'source': outputSource,
            'body': body,
            'digest': sha256.convert(body).toString(),
            'pin': snapshot,
          },
        );
        expect(await db.execute('SELECT 1 FROM outbox'), isEmpty);
        await fixture.config.writeAsString(jsonEncode(_config(2)));
        await _private(
          fixture.secrets,
          jsonEncode({'token': outputToken, 'old-output-key': _base64(key)}),
        );
        final upgraded = await fixture.start();
        await upgraded.waitUntilReady();
        expect(
          (await db.execute(
            "SELECT reference FROM secret_record WHERE reference='old-output-key'",
          )).map((row) => row[0]),
          ['old-output-key'],
        );
        final (event, signature) = await received.future.timeout(
          _awaitEvent,
          onTimeout: () async {
            final outcomes = await db.execute(
              'SELECT status,outcome_json FROM raw_inbox',
            );
            final failures = await db.execute(
              'SELECT "errorClass","fieldPath" FROM pipeline_failures',
            );
            throw StateError(
              'No webhook received: raw=$outcomes failures=$failures',
            );
          },
        );
        expect(signature, 'sha256=${Hmac(sha256, key).convert(event)}');
        expect(
          (await db.execute('SELECT config_snapshot_id FROM outbox')).single[0],
          snapshot,
        );
      } finally {
        await receiver.close(force: true);
      }
    }),
    timeout: _timeout,
  );

  test(
    'secret_file_not_needed_after_import',
    () => _withFixture((fixture, db) async {
      final imported = await fixture.start();
      await imported.waitUntilReady();
      expect(await imported.closeStdin(), 0);
      final stored = (await db.execute(
        'SELECT to_jsonb(s)::text FROM secret_record s',
      )).single[0];
      await fixture.secrets.delete();
      final restarted = await fixture.start(import: false);
      await restarted.waitUntilReady();
      await postOutputAlert(restarted);
      expect((await db.execute('SELECT count(*) FROM raw_inbox')).single[0], 1);
      expect(
        (await db.execute(
          'SELECT to_jsonb(s)::text FROM secret_record s',
        )).single[0],
        stored,
      );
    }),
    timeout: _timeout,
  );

  test(
    'sec_3_plugin_config_secret',
    () => _withFixture((fixture, db) async {
      final suite = PluginFixtureSuite.create();
      addTearDown(suite.dispose);
      final built = await suite.build();
      final executable = await built
          .binaries[PluginFixtureBinary.outputProduction]!
          .copy('${fixture.files.path}/output-production');
      expect(
        (await Process.run('chmod', [
          '0700',
          executable.parent.path,
          executable.path,
        ])).exitCode,
        0,
      );
      final secret = utf8.encode(_canary);
      final encoded = _base64(secret);
      final forbidden = [_canary, encoded, ..._encodedBytea(secret)];
      await _private(
        fixture.secrets,
        jsonEncode({
          'token': outputToken,
          'private': {'bytes': encoded},
        }),
      );
      await fixture.config.writeAsString(
        jsonEncode(
          _config(
            1,
            output: {
              'id': outputId,
              'kind': 'plugin',
              'plugin': 'output-production',
              'sha256': sha256
                  .convert(await executable.readAsBytes())
                  .toString(),
              'config': {'echo_configure_secret': true},
              'secret_refs': {'token': 'private'},
            },
          ),
        ),
      );
      await _bootstrapSchema(fixture);
      await db.execute(
        '''CREATE FUNCTION notify_sec3() RETURNS TRIGGER LANGUAGE plpgsql AS \$\$
      BEGIN
        IF NEW."lastErrorClass" = 'plugin_config_rejected' THEN
          PERFORM pg_notify('sec3_configure', coalesce(NEW."lastPluginErrorClass", 'sanitized'));
        END IF;
        RETURN NEW;
      END \$\$''',
      );
      await db.execute(
        '''CREATE TRIGGER notify_sec3 AFTER INSERT OR UPDATE ON plugin_instance_status
      FOR EACH ROW EXECUTE FUNCTION notify_sec3()''',
      );
      await db.execute('LISTEN sec3_configure');
      final notification = StreamIterator(
        db.channels.all.where((event) => event.channel == 'sec3_configure'),
      );
      try {
        final next = notification.moveNext();
        final child = await fixture.start(plugins: executable.parent);
        await child.waitUntilReady();
        final api = Client('http://127.0.0.1:${child.apiPort}/');
        try {
          final before = await api.alertConsole.snapshot();
          final wakeUps = StreamIterator(api.alertConsole.wakeUps());
          try {
            final wake = wakeUps.moveNext();
            await postOutputAlert(child);
            expect(await next.timeout(_awaitEvent), isTrue);
            expect(notification.current.payload, 'sanitized');
            expect(await wake.timeout(_awaitEvent), isTrue);
            _absent(jsonEncode(wakeUps.current.toJson()), forbidden, 'wakeUps');
          } finally {
            await wakeUps.cancel();
          }
          final snapshot = await api.alertConsole.snapshot();
          final page = await api.alertConsole.feed(before.cursor, 100);
          expect(snapshot.alerts, isNotEmpty);
          expect(page.entries, isNotEmpty);
          _absent(
            jsonEncode(snapshot.toJson()),
            forbidden,
            'snapshot endpoint',
          );
          _absent(jsonEncode(page.toJson()), forbidden, 'feed endpoint');
        } finally {
          api.close();
        }
        for (final path in ['/livez', '/readyz', '/startupz']) {
          for (final web in [false, true]) {
            final response = await child.fetch(path, web: web);
            expect(response?.status, 200);
            _absent(response!.body, forbidden, path);
          }
        }
        final console = await child.fetch('/', web: true);
        expect(console?.status, anyOf(200, 503));
        _absent(console!.body, forbidden, 'console route');
        _absent(await _activeJson(db), forbidden, 'public snapshot');
        final record = (await db.execute(
          '''SELECT algorithm,octet_length(nonce),
        octet_length(ciphertext),commitment FROM secret_record WHERE reference='private' ''',
        )).single;
        expect(record.take(3), ['aes-256-gcm-v1', 12, secret.length + 16]);
        expect(record[3], startsWith('hmac-sha256:'));
        expect(await child.closeStdin(), 0);
        expect(
          await db.execute('SELECT 1 FROM serverpod_session_log'),
          isNotEmpty,
        );
        await _scanTables(db, forbidden);
        await fixture.scanLogs(forbidden);
      } finally {
        await notification.cancel();
      }
    }),
    timeout: _timeout,
  );
}

Iterable<String> _encodedBytea(List<int> bytes) sync* {
  yield bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
