@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:correlia_server/src/schema/schema_steps.dart'
    show defaultSchemaLockTimeout;

import '../support/child_server.dart';
import '../support/shared_cluster.dart';

const _source = '11111111-1111-4111-8111-111111111111';
const _output = '22222222-2222-4222-8222-222222222222';
const _schemaAdvisoryLock = 1129271885;

/// The short schema `lock_timeout` the failing children run with.
const _shortLockTimeoutMs = '500';

/// How long a child that must fail on a lock gets to exit.
const _exitWithin = Duration(seconds: 60);

String _credential(int value) =>
    base64Url.encode(List<int>.filled(32, value)).replaceAll('=', '');

/// One test's database, files, receiver and children.
final class _Upgrade {
  _Upgrade._(this.database, this.files, this.receiver);

  static Future<_Upgrade> create() async {
    final database = await SharedClusterDatabase.create(Directory.current);
    final files = Directory.systemTemp.createTempSync('icinga2-upgrade-');
    final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upgrade = _Upgrade._(database, files, receiver);
    receiver.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 204;
      await request.response.close();
      upgrade._delivered++;
      for (final (count, done) in List.of(upgrade._waiters)) {
        if (upgrade._delivered >= count && !done.isCompleted) done.complete();
      }
    });
    final config = File('${files.path}/config.json')
      ..writeAsStringSync(
        jsonEncode({
          'format_version': 1,
          'revision': 1,
          'sources': [
            {
              'id': _source,
              'enabled': true,
              'token_ref': 'token',
              'output_ids': [_output],
            },
          ],
          'outputs': [
            {
              'id': _output,
              'kind': 'webhook',
              'url': 'http://127.0.0.1:${receiver.port}/',
              'signing_key_ref': 'key',
            },
          ],
        }),
      );
    final secrets = File('${files.path}/secrets.json')
      ..writeAsStringSync(
        jsonEncode({'token': _credential(1), 'key': _credential(2)}),
      );
    final chmod = await Process.run('chmod', ['600', secrets.path]);
    expect(chmod.exitCode, 0);
    upgrade.environment = {
      'CORRELIA_INGEST_CONFIG': config.path,
      'CORRELIA_INGEST_SECRETS': secrets.path,
    };
    return upgrade;
  }

  final SharedClusterDatabase database;
  final Directory files;
  final HttpServer receiver;
  late final Map<String, String> environment;
  final children = <ChildServer>[];
  final connections = <Connection>[];
  int _delivered = 0;
  final _waiters = <(int, Completer<void>)>[];

  Future<ChildServer> start([Map<String, String> extra = const {}]) async {
    final child = await ChildServer.startOnSharedCluster(
      serverDir: Directory.current,
      database: database,
      environment: {...environment, ...extra},
    );
    children.add(child);
    return child;
  }

  Future<Connection> connect() async {
    final connection = await Connection.open(
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
    connections.add(connection);
    return connection;
  }

  /// Completes once [count] deliveries reached the receiver.
  Future<void> deliveries(int count) {
    if (_delivered >= count) return Future.value();
    final done = Completer<void>();
    _waiters.add((count, done));
    return done.future.timeout(const Duration(seconds: 90));
  }

  /// Builds the preceding SQL-owned schema on a fresh managed database.
  Future<Connection> prepareAt(int version) async {
    final connection = await connect();
    final managed = (await connection.execute(
      "SELECT to_regclass('serverpod_migrations')::text",
    )).single[0];
    if (managed == null) {
      final registry = File(
        'migrations/migration_registry.txt',
      ).readAsLinesSync();
      final latest = registry.lastWhere(
        (entry) => entry.isNotEmpty && !entry.startsWith('#'),
      );
      await connection.execute(
        File('migrations/$latest/definition.sql').readAsStringSync(),
        queryMode: QueryMode.simple,
      );
    }
    await connection.runTx((tx) async {
      await tx.execute(
        'CREATE TABLE correlia_schema_versions '
        '(version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())',
      );
      for (final step in schemaSteps) {
        if (step.version > version) break;
        await tx.execute(step.sql, queryMode: QueryMode.simple);
        await tx.execute(
          'INSERT INTO correlia_schema_versions (version) VALUES (${step.version})',
        );
      }
    });
    return connection;
  }

  Future<void> dispose() async {
    for (final connection in connections) {
      await connection.close();
    }
    try {
      await tearDownChildren(children);
    } finally {
      await receiver.close(force: true);
      await database.drop();
      files.deleteSync(recursive: true);
    }
  }
}

Future<List<int>> _versions(Connection connection) async => [
  for (final row in await connection.execute(
    'SELECT version FROM correlia_schema_versions ORDER BY version',
  ))
    row[0]! as int,
];

final _currentVersions = [for (final step in schemaSteps) step.version];

/// Checks the reported SQLSTATE-derived class and the step that attempted the
/// lock. The conflicting lock stays held until the child exits.
Future<void> _expectLockTimeout(ChildServer child, int step) async {
  final code = await child.exitCode.timeout(_exitWithin);
  expect(code, isNot(0), reason: child.output);
  expect(
    child.output,
    contains('Schema step $step failed: lock_timeout'),
  );
}

void main() {
  test(
    'schema_step_4_under_lock_contention',
    () async {
      final upgrade = await _Upgrade.create();
      try {
        final connection = await upgrade.prepareAt(3);
        final blocker = await upgrade.connect();
        await blocker.execute('BEGIN');
        await blocker.execute('LOCK TABLE events IN ACCESS SHARE MODE');
        final blocked = await upgrade.start({
          'CORRELIA_TEST_SCHEMA_LOCK_TIMEOUT_MS': _shortLockTimeoutMs,
        });
        await _expectLockTimeout(blocked, 4);
        expect(await _versions(connection), [1, 2, 3]);
        await blocker.execute('ROLLBACK');
        final restarted = await upgrade.start();
        await restarted.waitUntilReady();
        expect(await _versions(connection), _currentVersions);
      } finally {
        await upgrade.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'schema_runner_waits_behind_another_starter',
    () async {
      final upgrade = await _Upgrade.create();
      try {
        final connection = await upgrade.prepareAt(3);
        final other = await upgrade.connect();
        await other.execute('BEGIN');
        await other.execute(
          'SELECT pg_advisory_xact_lock($_schemaAdvisoryLock)',
        );
        final blocked = await upgrade.start({
          'CORRELIA_TEST_SCHEMA_LOCK_TIMEOUT_MS': _shortLockTimeoutMs,
        });
        // The first transaction of the runner waits for the advisory lock.
        await _expectLockTimeout(blocked, 0);
        expect(await _versions(connection), [1, 2, 3]);
        await other.execute('ROLLBACK');
        final restarted = await upgrade.start();
        await restarted.waitUntilReady();
        expect(await _versions(connection), _currentVersions);
      } finally {
        await upgrade.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'offline_upgrade_with_pending_work',
    () async {
      final upgrade = await _Upgrade.create();
      try {
        final connection = await upgrade.prepareAt(3);
        final observed = DateTime.now().toUtc();
        for (final name in ['PendingOne', 'PendingTwo']) {
          final body = utf8.encode(
            jsonEncode({
              'version': '4',
              'status': 'firing',
              'alerts': [
                {
                  'status': 'firing',
                  'labels': {'alertname': name},
                  'annotations': <String, String>{},
                  'startsAt': observed
                      .subtract(const Duration(minutes: 1))
                      .toIso8601String(),
                },
              ],
            }),
          );
          await connection.execute(
            Sql.named(
              'INSERT INTO raw_inbox '
              '(observed_at, raw_id, source_id, body, body_sha256, content_type) '
              "VALUES (@observed, gen_random_uuid(), @source::uuid, @body, @digest, 'application/json')",
            ),
            parameters: {
              'observed': observed,
              'source': _source,
              'body': body,
              'digest': sha256.convert(body).toString(),
            },
          );
        }
        expect(await _versions(connection), [1, 2, 3]);
        final upgraded = await upgrade.start();
        await upgraded.waitUntilReady();
        await upgrade.deliveries(2);
        expect(await _versions(connection), _currentVersions);
        final raws = await connection.execute(
          'SELECT status FROM raw_inbox',
        );
        expect(raws.map((row) => row[0]), ['done', 'done']);
        final events = await connection.execute(
          'SELECT effective_source_time IS NOT NULL FROM events',
        );
        expect(events.map((row) => row[0]), [true, true]);
      } finally {
        await upgrade.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'step_11_upgrades_the_existing_subject_index_without_changing_payloads',
    () async {
      final upgrade = await _Upgrade.create();
      addTearDown(upgrade.dispose);
      final connection = await upgrade.prepareAt(10);
      final indexOid = (await connection.execute(
        "SELECT 'events_subject_idx'::regclass::oid::bigint",
      )).single[0];
      expect(await _versions(connection), List.generate(10, (i) => i + 1));

      final oldSubject = 'a' * 64;
      final newSubject = 'b' * 64;
      final oldPayload = jsonEncode({
        'subject': oldSubject,
        'data': {'description': r'verbatim \u0000 text'},
      });
      final newPayload = jsonEncode({
        'subject': newSubject,
        'data': {'description': 'before\u0000after'},
      });
      Future<void> insert(String payload) async {
        await connection.execute(
          Sql.named('''
INSERT INTO events
  (observed_at, event_id, disposition, raw_observed_at, raw_id, source_id,
   config_snapshot_id, source_time, payload)
VALUES
  (CURRENT_TIMESTAMP, gen_random_uuid(), 'ready', CURRENT_TIMESTAMP,
   gen_random_uuid(), @source::uuid, 'upgrade-fixture', CURRENT_TIMESTAMP,
   convert_to(@payload::text, 'UTF8'))
'''),
          parameters: {'source': _source, 'payload': payload},
        );
      }

      await insert(oldPayload);
      await expectLater(
        insert(newPayload),
        throwsA(
          isA<ServerException>().having((e) => e.code, 'SQLSTATE', '22P05'),
        ),
      );

      final restarted = await upgrade.start();
      await restarted.waitUntilReady();
      expect(await _versions(connection), _currentVersions);
      expect(
        (await connection.execute(
          "SELECT inhrelid::bigint FROM pg_inherits "
          "WHERE inhparent = 'events_subject_idx'::regclass "
          "AND inhrelid = 'legacy_events_subject_idx'::regclass",
        )).single[0],
        indexOid,
      );
      await insert(newPayload);
      await connection.runTx((tx) async {
        await tx.execute('SET LOCAL enable_seqscan=off');
        const lookup =
            "SELECT convert_from(payload, 'UTF8') FROM events "
            'WHERE correlia_event_subject(payload) = @subject';
        final plan = await tx.execute(
          Sql.named('EXPLAIN $lookup'),
          parameters: {'subject': oldSubject},
        );
        expect(
          plan.map((row) => row[0]).join('\n'),
          contains('events_subject_idx'),
        );
        for (final (subject, payload) in [
          (oldSubject, oldPayload),
          (newSubject, newPayload),
        ]) {
          final rows = await tx.execute(
            Sql.named(lookup),
            parameters: {'subject': subject},
          );
          expect(rows.single[0], payload);
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
