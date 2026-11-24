import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/icinga2/stream/supervisor.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/state/tombstone_sweep.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_consumer_loopback.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/secret_fixture.dart';

const _certs = '../correlia_icinga2_notify/test/fixtures';

void main() {
  withServerpod(
    'stream shutdown and reclamation',
    (builder, _) {
      late Session session;
      late pg.Connection observer;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute(
          '''TRUNCATE icinga2_admitted_batch,
          icinga2_stream_lease, icinga2_stream_status, icinga2_stream_resync''',
        );
        observer = await openStreamDatabase(session.serverpod);
        addTearDown(() async {
          if (observer.isOpen) await observer.close(force: true);
        });
      });

      Future<
        ({Icinga2StreamSupervisor supervisor, IcingaConsumerLoopback http})
      >
      startSupervisor({
        Future<void> Function(pg.TxSession)? beforeAdmissionCommit,
        Future<void> Function(pg.Connection)? onConsumerConnection,
        Future<void> Function(pg.TxSession)? beforeSweepCommit,
        Future<pg.Connection> Function(Duration)? openDatabase,
      }) async {
        final http = await IcingaConsumerLoopback.start();
        addTearDown(http.close);
        final snapshot = await publishStreamDb(
          session,
          apiUrl: 'https://127.0.0.1:${http.server.port}',
        );
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        final target = StreamTarget(
          sourceId: icinga2DbSourceId,
          snapshotId: snapshot,
          namespace: icinga2DbSourceId,
          options: IcingaStreamOptions(
            url: Uri.parse('https://127.0.0.1:${http.server.port}'),
            username: 'test',
            passwordRef: 'test-password',
            caRef: 'test-ca',
            syncInterval: const Duration(hours: 1),
            stateTypePolicy: StreamStateTypePolicy.softAndHard,
            maxPendingRows: 10000,
          ),
          password: utf8.encode('test-password'),
          ca: await File('$_certs/ca_one.pem').readAsBytes(),
        );
        final supervisor = Icinga2StreamSupervisor(
          loadTargets: () async => [target],
          openDatabase: openDatabase ?? (_) => endpoint.open(),
          holder: 'stop-test-holder',
          log: (_) {},
          runMode: 'test',
          beforeAdmissionCommit: beforeAdmissionCommit,
          onConsumerConnection: onConsumerConnection,
          beforeSweepCommit: beforeSweepCommit,
        );
        supervisor.start();
        addTearDown(supervisor.stop);
        return (supervisor: supervisor, http: http);
      }

      Future<void> backendGone(int pid, Stopwatch watch) async {
        while (watch.elapsed < const Duration(seconds: 5)) {
          final rows = await observer.execute(
            pg.Sql.named('SELECT 1 FROM pg_stat_activity WHERE pid=@pid'),
            parameters: {'pid': pid},
          );
          if (rows.isEmpty) return;
        }
        fail('Dedicated backend $pid did not exit within five seconds');
      }

      test('stop_during_a_stalled_insert', () async {
        final entered = Completer<int>();
        final resume = Completer<void>();
        final dedicated = Completer<pg.Connection>();
        final fixture = await startSupervisor(
          onConsumerConnection: (connection) async {
            if (!dedicated.isCompleted) dedicated.complete(connection);
          },
          beforeAdmissionCommit: (tx) async {
            final pid =
                (await tx.execute('SELECT pg_backend_pid()')).single[0]! as int;
            if (!entered.isCompleted) entered.complete(pid);
            await resume.future;
          },
        );
        addTearDown(() {
          if (!resume.isCompleted) resume.complete();
        });
        await fixture.http.send(streamDbCheck(DateTime.now().toUtc()));
        final pid = await entered.future.timeout(const Duration(seconds: 15));
        final watch = Stopwatch()..start();
        final stopping = fixture.supervisor.stop();
        try {
          await (await dedicated.future).closed.timeout(
            const Duration(milliseconds: 4500),
          );
          await backendGone(pid, watch);
          expect(
            (await observer.execute(
              'SELECT count(*) FROM raw_inbox',
            )).single[0],
            0,
          );
        } finally {
          resume.complete();
          await stopping.timeout(const Duration(seconds: 10));
        }
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      }, timeout: const Timeout(Duration(seconds: 35)));

      test('stop_during_a_running_statement', () async {
        final entered = Completer<int>();
        final fixture = await startSupervisor(
          beforeAdmissionCommit: (tx) async {
            await tx.execute("SET LOCAL statement_timeout = 0");
            final pid =
                (await tx.execute('SELECT pg_backend_pid()')).single[0]! as int;
            entered.complete(pid);
            await tx.execute(
              'SELECT pg_sleep(30)',
              timeout: const Duration(seconds: 35),
            );
          },
        );
        await fixture.http.send(streamDbCheck(DateTime.now().toUtc()));
        final pid = await entered.future.timeout(const Duration(seconds: 15));
        final running = Stopwatch()..start();
        while (true) {
          final rows = await observer.execute(
            pg.Sql.named(
              "SELECT 1 FROM pg_stat_activity WHERE pid=@pid AND query LIKE '%pg_sleep(30)%' AND state='active'",
            ),
            parameters: {'pid': pid},
          );
          if (rows.isNotEmpty) break;
          if (running.elapsed > const Duration(seconds: 5)) {
            fail('Statement did not start');
          }
        }
        final watch = Stopwatch()..start();
        final stopping = fixture.supervisor.stop();
        await backendGone(pid, watch);
        await stopping.timeout(const Duration(seconds: 10));
        expect(
          (await observer.execute('SELECT count(*) FROM raw_inbox')).single[0],
          0,
        );
      }, timeout: const Timeout(Duration(seconds: 35)));

      test('insert_finishing_as_stop_begins', () async {
        final entered = Completer<void>();
        final resume = Completer<void>();
        final fixture = await startSupervisor(
          beforeAdmissionCommit: (_) async {
            if (!entered.isCompleted) entered.complete();
            await resume.future;
          },
        );
        addTearDown(() {
          if (!resume.isCompleted) resume.complete();
        });
        await fixture.http.send(streamDbCheck(DateTime.now().toUtc()));
        await entered.future.timeout(const Duration(seconds: 15));
        await observer.execute('BEGIN');
        try {
          await observer.execute(
            'CREATE TEMP TABLE stop_unrelated_work (value int)',
          );
          await observer.execute('INSERT INTO stop_unrelated_work VALUES (1)');
          final stopping = fixture.supervisor.stop();
          resume.complete();
          await stopping.timeout(const Duration(seconds: 10));
          final rows =
              (await session.db.unsafeQuery(
                    'SELECT count(*) FROM raw_inbox',
                  )).single[0]!
                  as int;
          final receipts =
              (await session.db.unsafeQuery(
                    'SELECT count(*) FROM icinga2_admitted_batch',
                  )).single[0]!
                  as int;
          expect(rows, anyOf(0, 1));
          expect(receipts, rows);
          expect(
            (await observer.execute(
              'SELECT value FROM stop_unrelated_work',
            )).single[0],
            1,
          );
        } finally {
          if (!resume.isCompleted) resume.complete();
          await observer.execute('ROLLBACK');
        }
      }, timeout: const Timeout(Duration(seconds: 35)));

      test('stop_while_reading', () async {
        final fixture = await startSupervisor();
        await fixture.http.firstSubscription.future.timeout(
          const Duration(seconds: 10),
        );
        final watch = Stopwatch()..start();
        await fixture.supervisor.stop().timeout(const Duration(seconds: 10));
        await fixture.http.disconnected.future.timeout(
          const Duration(seconds: 2),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
        final leases = await observer.execute(
          "SELECT \"expiresAt\" <= clock_timestamp() FROM icinga2_stream_lease WHERE \"sourceId\"='$icinga2DbSourceId'",
        );
        expect(leases.single[0], isTrue);
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('lease_row_still_locked_at_stop', () async {
        final fixture = await startSupervisor();
        await fixture.http.firstSubscription.future.timeout(
          const Duration(seconds: 10),
        );
        await observer.execute('BEGIN');
        try {
          final before = await observer.execute(
            "SELECT \"expiresAt\" FROM icinga2_stream_lease WHERE \"sourceId\"='$icinga2DbSourceId' FOR UPDATE",
          );
          final watch = Stopwatch()..start();
          await fixture.supervisor.stop().timeout(const Duration(seconds: 10));
          expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
          final after = await observer.execute(
            "SELECT \"expiresAt\" FROM icinga2_stream_lease WHERE \"sourceId\"='$icinga2DbSourceId'",
          );
          expect(after.single[0], before.single[0]);
        } finally {
          await observer.execute('ROLLBACK');
        }
        final status = await session.db.unsafeQuery(
          "SELECT state FROM icinga2_stream_status WHERE \"sourceId\"='$icinga2DbSourceId'",
        );
        expect(status.single[0], isNot('released'));
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('database_unreachable_at_stop', () async {
        var reachable = true;
        final dedicated = Completer<pg.Connection>();
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        final fixture = await startSupervisor(
          onConsumerConnection: (connection) async {
            if (!dedicated.isCompleted) dedicated.complete(connection);
          },
          openDatabase: (_) {
            if (!reachable) {
              return Future.error(
                const SocketException('test database unavailable'),
              );
            }
            return endpoint.open();
          },
        );
        await fixture.http.firstSubscription.future.timeout(
          const Duration(seconds: 10),
        );
        final before = await observer.execute(
          "SELECT \"expiresAt\" FROM icinga2_stream_lease WHERE \"sourceId\"='$icinga2DbSourceId'",
        );
        reachable = false;
        await (await dedicated.future).close(force: true);
        final watch = Stopwatch()..start();
        await fixture.supervisor.stop().timeout(const Duration(seconds: 10));
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
        final after = await observer.execute(
          "SELECT \"expiresAt\" FROM icinga2_stream_lease WHERE \"sourceId\"='$icinga2DbSourceId'",
        );
        expect(after.single[0], before.single[0]);
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('session_settings_of_the_dedicated_connection', () async {
        final checked = Completer<void>();
        final fixture = await startSupervisor(
          onConsumerConnection: (connection) async {
            final settings = await connection.execute('''
              SELECT current_setting('client_connection_check_interval'),
                current_setting('idle_in_transaction_session_timeout'),
                inet_server_addr() IS NULL, pg_backend_pid()
            ''');
            expect(settings.single[0], '1s');
            expect(settings.single[1], '5s');
            expect(settings.single[2], isTrue);
            final observerPid = (await observer.execute(
              'SELECT pg_backend_pid()',
            )).single[0];
            expect(settings.single[3], isNot(observerPid));
            checked.complete();
          },
        );
        await checked.future.timeout(const Duration(seconds: 10));
        await fixture.supervisor.stop().timeout(const Duration(seconds: 10));
      });

      test('stop_cancels_a_live_reclamation_pass', () async {
        final entered = Completer<void>();
        final resume = Completer<void>();
        final fixture = await startSupervisor(
          beforeSweepCommit: (_) async {
            if (!entered.isCompleted) entered.complete();
            await resume.future;
          },
        );
        addTearDown(() {
          if (!resume.isCompleted) resume.complete();
        });
        await entered.future.timeout(const Duration(seconds: 15));
        final watch = Stopwatch()..start();
        try {
          await fixture.supervisor.stop().timeout(const Duration(seconds: 10));
          expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
        } finally {
          resume.complete();
        }
      }, timeout: const Timeout(Duration(seconds: 30)));

      Future<({List<StreamTarget> targets, IcingaConsumerLoopback http})>
      manyTargets() async {
        final http = await IcingaConsumerLoopback.start();
        addTearDown(http.close);
        final ids = List.generate(
          64,
          (i) =>
              '10000000-0000-4000-8000-${(i + 1).toString().padLeft(12, '0')}',
        );
        final sources = [
          for (final id in ids)
            streamSource(id)
              ..['api'] = {
                'url': 'https://127.0.0.1:${http.server.port}',
                'username': 'test',
                'password_ref': 'icinga-password',
                'ca_ref': 'icinga-ca',
                'sync_interval_seconds': 3600,
              },
        ];
        final snapshot =
            await IngestConfigRepository(
              session,
              secretStore: testSecretStore,
            ).publishConfig(
              streamBootstrap(1, sources),
              streamMaterial(),
              runMode: 'test',
            );
        final ca = await File('$_certs/ca_one.pem').readAsBytes();
        final options = IcingaStreamOptions(
          url: Uri.parse('https://127.0.0.1:${http.server.port}'),
          username: 'test',
          passwordRef: 'icinga-password',
          caRef: 'icinga-ca',
          syncInterval: const Duration(hours: 1),
          stateTypePolicy: StreamStateTypePolicy.softAndHard,
          maxPendingRows: 100,
        );
        return (
          targets: [
            for (final id in ids)
              StreamTarget(
                sourceId: id,
                snapshotId: snapshot.snapshotId,
                namespace: id,
                options: options,
                password: utf8.encode('fixture password'),
                ca: ca,
              ),
          ],
          http: http,
        );
      }

      Future<void> waitForCount(String sql, int count) async {
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(seconds: 30)) {
          if ((await observer.execute(sql)).single[0] == count) return;
        }
        fail('Timed out waiting for $count: $sql');
      }

      test('many_sources', () async {
        final fixture = await manyTargets();
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        final admitted = Completer<void>();
        final resume = Completer<void>();
        var inFlight = 0;
        final supervisor = Icinga2StreamSupervisor(
          loadTargets: () async => fixture.targets,
          openDatabase: (_) => endpoint.open(),
          holder: 'many-stop-test',
          log: (_) {},
          runMode: 'test',
          beforeAdmissionCommit: (_) async {
            inFlight++;
            if (inFlight == 64) admitted.complete();
            await resume.future;
          },
        );
        supervisor.start();
        addTearDown(supervisor.stop);
        addTearDown(() {
          if (!resume.isCompleted) resume.complete();
        });
        try {
          await waitForCount('SELECT count(*) FROM icinga2_stream_lease', 64);
          final watch = Stopwatch()..start();
          while (fixture.http.subscriptions.length < 64 &&
              watch.elapsed < const Duration(seconds: 30)) {
            await observer.execute('SELECT 1');
          }
          expect(fixture.http.subscriptions, hasLength(64));
          final event =
              '${jsonEncode(streamDbCheck(DateTime.now().toUtc()))}\n';
          for (final response in fixture.http.subscriptions) {
            response.write(event);
          }
          await Future.wait(fixture.http.subscriptions.map((r) => r.flush()));
          await admitted.future.timeout(const Duration(seconds: 30));
          final stopping = Stopwatch()..start();
          final stopped = supervisor.stop();
          await stopped.timeout(const Duration(seconds: 10));
          expect(stopping.elapsed, lessThan(const Duration(seconds: 10)));
        } finally {
          resume.complete();
        }
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('two_workers_64_sources', () async {
        final fixture = await manyTargets();
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        var firstTargets = fixture.targets.take(32).toList();
        var secondTargets = fixture.targets.skip(32).toList();
        var firstConnections = 0;
        var secondConnections = 0;
        Icinga2StreamSupervisor make(
          String holder,
          Future<List<StreamTarget>> Function() targets,
          Future<void> Function(pg.Connection) onConnection,
        ) => Icinga2StreamSupervisor(
          loadTargets: targets,
          openDatabase: (_) => endpoint.open(),
          holder: holder,
          log: (_) {},
          runMode: 'test',
          revisionInterval: const Duration(milliseconds: 100),
          onConsumerConnection: onConnection,
        );
        final first = make('first-holder', () async => firstTargets, (_) async {
          firstConnections++;
        });
        final second = make('second-holder', () async => secondTargets, (
          _,
        ) async {
          secondConnections++;
        });
        first.start();
        second.start();
        addTearDown(first.stop);
        addTearDown(second.stop);
        await waitForCount('SELECT count(*) FROM icinga2_stream_lease', 64);
        final subscribed = Stopwatch()..start();
        while (fixture.http.subscriptionsReady < 64 &&
            subscribed.elapsed < const Duration(seconds: 10)) {
          await observer.execute('SELECT 1');
        }
        expect(fixture.http.subscriptionsReady, 64);
        firstTargets = fixture.targets;
        secondTargets = fixture.targets;
        final watch = Stopwatch()..start();
        while ((firstConnections < 32 || secondConnections < 32) &&
            watch.elapsed < const Duration(seconds: 30)) {
          await observer.execute('SELECT 1');
        }
        expect(firstConnections, 32);
        expect(secondConnections, 32);
        final holders = await observer.execute(
          'SELECT holder, count(*) FROM icinga2_stream_lease GROUP BY holder ORDER BY holder',
        );
        expect(holders.map((row) => [row[0], row[1]]).toList(), [
          ['first-holder', 32],
          ['second-holder', 32],
        ]);
        await Future.wait([
          first.stop(),
          second.stop(),
        ]).timeout(const Duration(seconds: 10));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('batch_ids_of_a_removed_source', () async {
        await publishStreamDb(session);
        await observer.execute('''
          INSERT INTO icinga2_admitted_batch ("sourceId","batchId","admittedAt")
          VALUES ('$icinga2DbSourceId', gen_random_uuid(), clock_timestamp()-interval '61 minutes'),
                 ('$icinga2DbSourceId', gen_random_uuid(), clock_timestamp()-interval '59 minutes')
        ''');
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publishConfig(
          streamBootstrap(2, const []),
          const <String, Object?>{},
          runMode: 'test',
        );
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        final supervisor = Icinga2StreamSupervisor(
          loadTargets: () async => const [],
          openDatabase: (timeout) => endpoint.open(timeout: timeout),
          holder: 'batch-prune-test',
          log: (_) {},
        );
        addTearDown(supervisor.stop);
        supervisor.start();
        await waitForCount('SELECT count(*) FROM icinga2_admitted_batch', 1);
        final kept = await observer.execute('''
          SELECT "admittedAt" > clock_timestamp()-interval '1 hour'
          FROM icinga2_admitted_batch WHERE "sourceId"='$icinga2DbSourceId'
        ''');
        expect(kept.single[0], isTrue);
        expect(await countRows(session, 'icinga2_stream_lease'), 0);
      });

      test('reclamation_stops_without_waiting_for_locks', () async {
        Future<int> reclaim() async {
          final connection = await openStreamDatabase(session.serverpod);
          try {
            return await TombstoneSweep(connection).runOnce();
          } finally {
            await connection.close(force: true);
          }
        }

        final old = DateTime.now().toUtc().subtract(const Duration(days: 9));
        await session.db.unsafeExecute(
          '''INSERT INTO alerts
            (tenant,fingerprint,status,severity,summary,"sourceInstance",
             "fenceEffectiveSeconds","fenceEffectiveNanos","fenceObservedSeconds",
             "fenceObservedNanos","fenceEventId","lastObservedAt",version,
             "createdAt","updatedAt",silent_tombstone)
            SELECT 'default',lpad(n::text,64,'0'),'resolved','info','tombstone',
              '$icinga2DbSourceId',@seconds,0,@seconds,0,gen_random_uuid(),
              @old,1,@old,@old,true FROM generate_series(1,2) n''',
          parameters: QueryParameters.named({
            'seconds': old.millisecondsSinceEpoch ~/ 1000,
            'old': old,
          }),
        );
        await observer.execute('BEGIN');
        try {
          await observer.execute(
            "SELECT id FROM alerts WHERE fingerprint = lpad('1',64,'0') FOR UPDATE",
          );
          final watch = Stopwatch()..start();
          expect(await reclaim(), 1);
          expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
          final remaining = await session.db.unsafeQuery(
            'SELECT fingerprint FROM alerts',
          );
          expect(remaining.single[0], '1'.padLeft(64, '0'));
        } finally {
          await observer.execute('ROLLBACK');
        }

        // A separate transaction holds the cutoff, so a pass cannot begin.
        await observer.execute('BEGIN');
        try {
          await observer.execute(
            'SELECT singleton FROM raw_admission_cutoff FOR UPDATE',
          );
          final watch = Stopwatch()..start();
          expect(await reclaim(), 0);
          expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
          expect(
            (await session.db.unsafeQuery(
              'SELECT count(*) FROM alerts',
            )).single[0],
            1,
          );
        } finally {
          await observer.execute('ROLLBACK');
        }
        expect(await reclaim(), 1);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
