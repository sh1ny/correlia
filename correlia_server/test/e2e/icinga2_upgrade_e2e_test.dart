@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:correlia_server/src/schema/schema_steps.dart';

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

  /// Starts a server of this release, stops it, and rewinds the database to
  /// what the release before step 4 left: no column, no function, no version.
  Future<Connection> prepareBeforeStep4() async {
    final first = await start();
    await first.waitUntilReady();
    expect(await first.closeStdin(), 0);
    final connection = await connect();
    await connection.execute(
      'DROP FUNCTION events_effective_source_time(events)',
    );
    await connection.execute(
      'ALTER TABLE events DROP COLUMN effective_source_time',
    );
    await connection.runTx((tx) async {
      await tx.execute('DROP FUNCTION correlia_event_subject(bytea) CASCADE');
      await tx.execute(
        'DROP FUNCTION correlia_enforce_raw_admission_cutoff() CASCADE',
      );
      await tx.execute('DROP FUNCTION icinga2_finalize_sync(uuid, boolean)');
      await tx.execute('DROP TABLE icinga2_sync_progress,raw_admission_cutoff');
      await tx.execute('ALTER TABLE alerts DROP COLUMN silent_tombstone');
      await tx.execute(
        'DROP INDEX raw_pending_receipt_idx,activity_entity_idx,observation_keys_fingerprint_idx,raw_stream_retained_idx',
      );
      await tx.execute(
        'DROP FUNCTION correlia_require_publisher_version() CASCADE',
      );
      await tx.execute(
        'DROP FUNCTION correlia_keep_retired_credential_digest() CASCADE',
      );
      await tx.execute(
        'DROP TABLE secret_reuse_digest,secret_reuse_backfill,secret_reuse_retired_credential,icinga2_raw_origin',
      );
      await tx.execute(
        'DELETE FROM correlia_schema_versions WHERE version >= 4',
      );
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

/// How long a lock request of another backend of [observer]'s database waits
/// before it is no longer waiting: from when it is first seen ungranted in
/// `pg_locks` until it is gone.
Future<Duration> _lockWait(Connection observer) async {
  Future<bool> waiting() async =>
      (await observer.execute(
            '''SELECT count(*) FROM pg_locks
               WHERE NOT granted AND pid <> pg_backend_pid()
                 AND database = (SELECT oid FROM pg_database
                                 WHERE datname = current_database())''',
          )).single[0]!
          as int >
      0;
  final deadline = DateTime.now().add(_exitWithin);
  while (!await waiting()) {
    if (DateTime.now().isAfter(deadline)) fail('no lock request waited');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final waited = Stopwatch()..start();
  while (await waiting()) {
    if (DateTime.now().isAfter(deadline)) fail('the lock request never ended');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return waited.elapsed;
}

/// Asserts that [child]'s schema attempt gave up on its lock after the
/// injected timeout, well before the production default, then that it exits
/// non-zero and names [step] and `lock_timeout`.
Future<void> _expectLockTimeout(
  ChildServer child,
  int step,
  Connection observer,
) async {
  final waited = await _lockWait(observer);
  expect(
    waited,
    lessThan(defaultSchemaLockTimeout ~/ 3),
    reason: 'the injected ${_shortLockTimeoutMs}ms timeout was not applied',
  );
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
        final connection = await upgrade.prepareBeforeStep4();
        final blocker = await upgrade.connect();
        await blocker.execute('BEGIN');
        await blocker.execute('LOCK TABLE events IN ACCESS SHARE MODE');
        final blocked = await upgrade.start({
          'CORRELIA_TEST_SCHEMA_LOCK_TIMEOUT_MS': _shortLockTimeoutMs,
        });
        await _expectLockTimeout(blocked, 4, connection);
        expect(await _versions(connection), [1, 2, 3]);
        await blocker.execute('ROLLBACK');
        final restarted = await upgrade.start();
        await restarted.waitUntilReady();
        expect(await _versions(connection), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
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
        final connection = await upgrade.prepareBeforeStep4();
        final other = await upgrade.connect();
        await other.execute('BEGIN');
        await other.execute(
          'SELECT pg_advisory_xact_lock($_schemaAdvisoryLock)',
        );
        final blocked = await upgrade.start({
          'CORRELIA_TEST_SCHEMA_LOCK_TIMEOUT_MS': _shortLockTimeoutMs,
        });
        // The first transaction of the runner waits for the advisory lock.
        await _expectLockTimeout(blocked, 0, connection);
        expect(await _versions(connection), [1, 2, 3]);
        await other.execute('ROLLBACK');
        final restarted = await upgrade.start();
        await restarted.waitUntilReady();
        expect(await _versions(connection), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
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
        // The older release is simulated by the rewound schema: no older
        // process exists to run, so every process has stopped before the
        // upgraded ones start.
        final connection = await upgrade.prepareBeforeStep4();
        expect(upgrade.children.every((child) => child.hasExited), isTrue);
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
        expect(await _versions(connection), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
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
}
