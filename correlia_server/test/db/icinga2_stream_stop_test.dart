@Timeout(Duration(minutes: 5))
library;

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
import '../support/icinga2_test_db_changes.dart';
import '../support/secret_fixture.dart';

const _certs = '../correlia_icinga2_notify/test/fixtures';
// Longer than the test hang guard, so the driver's default two-second query
// timeout does not preempt deliberately blocked fixture statements.
const _blockedQueryTimeout = Duration(minutes: 10);
const _workLock = 7100;
const _entryLock = 7101;
const _sessionLock = 7103;

// Capture only the timers armed synchronously by stop(), not timers created
// later by real socket and database I/O. Drive the admission abort explicitly.
final class _StopTimers {
  final _timers = <_ManualTimer>[];

  Future<void> stop(Icinga2StreamSupervisor supervisor) {
    var arming = true;
    try {
      return runZoned(
        supervisor.stop,
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, delay, callback) {
            if (!arming) return parent.createTimer(zone, delay, callback);
            final timer = _ManualTimer(delay, zone.bindCallback(callback));
            _timers.add(timer);
            return timer;
          },
        ),
      );
    } finally {
      arming = false;
    }
  }

  _ManualTimer abortAdmissions(int count) {
    const abort = Duration(seconds: 4);
    const stop = Duration(seconds: 10);
    expect(
      _timers.map((timer) => timer.delay),
      unorderedEquals([
        for (var i = 0; i < count; i++) abort,
        stop,
      ]),
    );
    for (final timer in _timers) {
      if (timer.delay == abort) timer.fire();
    }
    return _timers.singleWhere((timer) => timer.delay == stop);
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick = 1;
    _callback();
  }
}

void main() {
  withServerpod(
    'stream shutdown and reclamation',
    (builder, _) {
      late Session session;
      late pg.Connection observer;
      late IcingaTestDbChanges changes;

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
        // The observer owns deliberately held locks and releases them itself.
        await observer.execute('SET idle_in_transaction_session_timeout = 0');
        changes = await IcingaTestDbChanges.start(session.serverpod, [
          'icinga2_stream_status',
          'icinga2_admitted_batch',
        ]);
        addTearDown(changes.close);
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

      Future<void> connected(int count) => changes.until(() async {
        final rows = await observer.execute('''
          SELECT count(*) FROM icinga2_stream_status s
          JOIN icinga2_sync_progress p ON s."lastSyncId" = p.sync_id
            AND s."connectionId" = p.connection_id
          WHERE s.state = 'connected' AND p.read_end_at IS NOT NULL
            AND p.read_problem IS NULL
        ''');
        return rows.single[0] == count;
      });

      for (final running in [false, true]) {
        test(
          running
              ? 'stop_during_a_running_statement'
              : 'stop_during_a_stalled_insert',
          () async {
            final entered = Completer<void>();
            final resume = Completer<void>();
            final dedicated = Completer<pg.Connection>();
            await observer.execute('BEGIN');
            try {
              await observer.execute(
                'CREATE TEMP TABLE stop_unrelated_work (value int) ON COMMIT DROP',
              );
              await observer.execute(
                'INSERT INTO stop_unrelated_work VALUES (1)',
              );
              final fixture = await startSupervisor(
                onConsumerConnection: (connection) async {
                  if (!dedicated.isCompleted) dedicated.complete(connection);
                },
                beforeAdmissionCommit: (tx) async {
                  await tx.execute(
                    'SET LOCAL idle_in_transaction_session_timeout = 0',
                  );
                  await tx.execute('SELECT pg_advisory_xact_lock($_workLock)');
                  await tx.execute('SELECT pg_advisory_lock($_sessionLock)');
                  if (running) {
                    await tx.execute('SET LOCAL statement_timeout = 0');
                    await tx.execute('SELECT pg_advisory_lock($_entryLock)');
                  }
                  entered.complete();
                  if (running) {
                    await tx.execute('''
                      DO \$\$ BEGIN
                        PERFORM pg_advisory_unlock($_entryLock);
                        LOOP PERFORM pg_sleep(30); END LOOP;
                      END \$\$
                    ''', timeout: _blockedQueryTimeout);
                  } else {
                    await resume.future;
                  }
                },
              );
              await connected(1);
              await fixture.http.send(streamDbCheck(DateTime.now().toUtc()));
              await entered.future;
              if (running) {
                // The backend releases this lock from inside the blocking SQL.
                await observer.execute(
                  'SELECT pg_advisory_xact_lock($_entryLock)',
                  timeout: _blockedQueryTimeout,
                );
              }
              expect(
                (await observer.execute(
                  'SELECT pg_try_advisory_xact_lock($_workLock)',
                )).single[0],
                isFalse,
                reason: 'The admission transaction must still be in flight',
              );
              final timers = _StopTimers();
              final stopping = timers.stop(fixture.supervisor);
              final deadline = timers.abortAdmissions(1);
              await (await dedicated.future).closed;
              await observer.execute(
                'SELECT pg_advisory_xact_lock($_workLock)',
                timeout: _blockedQueryTimeout,
              );
              // This session lock survives transaction rollback. The test
              // never unlocks it on the client, so it witnesses backend exit.
              await observer.execute(
                'SELECT pg_advisory_xact_lock($_sessionLock)',
                timeout: _blockedQueryTimeout,
              );
              expect(
                (await observer.execute(
                  'SELECT count(*) FROM raw_inbox',
                )).single[0],
                0,
              );
              expect(
                (await observer.execute(
                  'SELECT value FROM stop_unrelated_work',
                )).single[0],
                1,
              );
              await stopping;
              expect(deadline.isActive, isFalse);
            } finally {
              resume.complete();
              await observer.execute('ROLLBACK');
            }
          },
        );
      }

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
        await entered.future;
        await observer.execute('BEGIN');
        try {
          await observer.execute(
            'CREATE TEMP TABLE stop_unrelated_work (value int)',
          );
          await observer.execute('INSERT INTO stop_unrelated_work VALUES (1)');
          final stopping = fixture.supervisor.stop();
          resume.complete();
          await stopping;
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
      });

      test('stop_while_reading', () async {
        final fixture = await startSupervisor();
        await connected(1);
        await fixture.supervisor.stop();
        await fixture.http.disconnected.future;
        final leases = await observer.execute(
          "SELECT \"expiresAt\" <= clock_timestamp() FROM icinga2_stream_lease WHERE \"sourceId\"='$icinga2DbSourceId'",
        );
        expect(leases.single[0], isTrue);
      });

      test('lease_row_still_locked_at_stop', () async {
        final fixture = await startSupervisor();
        await connected(1);
        await observer.execute('BEGIN');
        try {
          final before = await observer.execute(
            "SELECT \"expiresAt\" FROM icinga2_stream_lease WHERE \"sourceId\"='$icinga2DbSourceId' FOR UPDATE",
          );
          await fixture.supervisor.stop();
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
      });

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
        await connected(1);
        final before = await observer.execute(
          "SELECT \"expiresAt\" FROM icinga2_stream_lease WHERE \"sourceId\"='$icinga2DbSourceId'",
        );
        reachable = false;
        await (await dedicated.future).close(force: true);
        await fixture.supervisor.stop();
        final after = await observer.execute(
          "SELECT \"expiresAt\" FROM icinga2_stream_lease WHERE \"sourceId\"='$icinga2DbSourceId'",
        );
        expect(after.single[0], before.single[0]);
      });

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
        await checked.future;
        await fixture.supervisor.stop();
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
        await entered.future;
        try {
          await fixture.supervisor.stop();
        } finally {
          resume.complete();
        }
      });

      Future<({List<StreamTarget> targets, IcingaConsumerLoopback http})>
      manyTargets({bool strictSocketErrors = false}) async {
        final http = await IcingaConsumerLoopback.start(
          strictSocketErrors: strictSocketErrors,
        );
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

      test('many_sources', () async {
        final fixture = await manyTargets();
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        final admitted = Completer<void>();
        final resume = Completer<void>();
        var inFlight = 0;
        final dedicated = <pg.Connection>[];
        final supervisor = Icinga2StreamSupervisor(
          loadTargets: () async => fixture.targets,
          openDatabase: (_) => endpoint.open(),
          holder: 'many-stop-test',
          log: (_) {},
          runMode: 'test',
          onConsumerConnection: (connection) async => dedicated.add(connection),
          beforeAdmissionCommit: (tx) async {
            await tx.execute(
              'SET LOCAL idle_in_transaction_session_timeout = 0',
            );
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
          await connected(64);
          await fixture.http.waitForObjectResponses(64);
          expect(fixture.http.subscriptionsReady, 64);
          final event =
              '${jsonEncode(streamDbCheck(DateTime.now().toUtc()))}\n';
          for (final response in fixture.http.subscriptions) {
            response.write(event);
          }
          await Future.wait(fixture.http.subscriptions.map((r) => r.flush()));
          await admitted.future;
          final timers = _StopTimers();
          final stopped = timers.stop(supervisor);
          final deadline = timers.abortAdmissions(64);
          await Future.wait(dedicated.map((connection) => connection.closed));
          await stopped;
          expect(deadline.isActive, isFalse);
        } finally {
          resume.complete();
        }
      });

      test('two_workers_64_sources', () async {
        final fixture = await manyTargets(strictSocketErrors: true);
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        var firstTargets = fixture.targets.take(32).toList();
        var secondTargets = fixture.targets.skip(32).toList();
        final expandedFirst = Completer<void>();
        final expandedSecond = Completer<void>();
        final opens = <(String, String), List<Future<pg.Connection>>>{};
        Icinga2StreamSupervisor make(
          String holder,
          List<StreamTarget> Function() targets,
          Completer<void> expanded,
        ) => Icinga2StreamSupervisor(
          loadTargets: () async => targets(),
          openDatabase: (_) => endpoint.open(),
          holder: holder,
          log: (_) {},
          runMode: 'test',
          revisionInterval: const Duration(milliseconds: 100),
          onConsumerOpenForTest: (source, opening) {
            (opens[(holder, source)] ??= []).add(opening);
          },
          afterAcquisitionScanForTest: (count) {
            if (count == 64 && !expanded.isCompleted) expanded.complete();
          },
        );
        final first = make('first-holder', () => firstTargets, expandedFirst);
        final second = make(
          'second-holder',
          () => secondTargets,
          expandedSecond,
        );
        first.start();
        second.start();
        addTearDown(first.stop);
        addTearDown(second.stop);
        await fixture.http.checked(connected(64));
        await fixture.http.waitForObjectResponses(64);
        expect(fixture.http.subscriptionsReady, 64);
        final expected = {
          for (final target in firstTargets) (target.sourceId, 'first-holder'),
          for (final target in secondTargets)
            (target.sourceId, 'second-holder'),
        };
        firstTargets = fixture.targets;
        secondTargets = fixture.targets;
        await fixture.http.checked(
          Future.wait([
            expandedFirst.future,
            expandedSecond.future,
          ]),
        );
        final holders = await observer.execute(
          'SELECT "sourceId"::text, holder FROM icinga2_stream_lease',
        );
        expect(
          holders.map((row) => (row[0]! as String, row[1]! as String)),
          unorderedEquals(expected),
        );
        expect(
          fixture.http.eventRequests.map(
            (request) =>
                (jsonDecode(request.$2) as Map<String, Object?>)['queue'],
          ),
          unorderedEquals(expected.map((pair) => pair.$1)),
        );
        expect(
          opens.keys,
          unorderedEquals(expected.map((pair) => (pair.$2, pair.$1))),
        );
        for (final opened in opens.values) {
          expect(opened, hasLength(1));
          expect((await opened.single).isOpen, isTrue);
        }
        fixture.http.expectSubscriptionDisconnects();
        await fixture.http.checked(Future.wait([first.stop(), second.stop()]));
        await fixture.http.waitForDisconnects(64);
      });

      test('batch_ids_of_a_removed_source', () async {
        await publishStreamDb(session);
        await observer.execute('''
          INSERT INTO icinga2_admitted_batch ("sourceId","batchId","admittedAt")
          VALUES ('$icinga2DbSourceId', gen_random_uuid(), clock_timestamp()-interval '61 minutes'),
                 ('$icinga2DbSourceId', gen_random_uuid(), clock_timestamp())
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
        await changes.until(
          () async => await countRows(session, 'icinga2_admitted_batch') == 1,
        );
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
          expect(await reclaim(), 1);
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
          expect(await reclaim(), 0);
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
