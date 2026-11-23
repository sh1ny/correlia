import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/status.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/supervisor.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/targets.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_consumer_loopback.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/secret_fixture.dart';
import '../support/stream_reader_clock.dart';

void main() {
  withServerpod(
    'live stream lease fencing',
    (builder, _) {
      late Session session;
      late pg.Connection observer;
      late IcingaConsumerLoopback http;
      late StreamDatabaseEndpoint endpoint;
      late StreamTarget target;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute('''
          TRUNCATE icinga2_admitted_batch, icinga2_stream_lease,
            icinga2_stream_status, icinga2_stream_resync
        ''');
        observer = await openStreamDatabase(session.serverpod);
        addTearDown(() async {
          if (observer.isOpen) await observer.close(force: true);
        });
        http = await IcingaConsumerLoopback.start();
        addTearDown(http.close);
        final snapshot = await publishStreamDb(
          session,
          apiUrl: http.url.toString(),
        );
        endpoint = await StreamDatabaseEndpoint.resolve(session.serverpod);
        target = StreamTarget(
          sourceId: icinga2DbSourceId,
          snapshotId: snapshot,
          namespace: icinga2DbSourceId,
          options: IcingaStreamOptions(
            url: http.url,
            username: 'test',
            passwordRef: 'test-password',
            caRef: 'test-ca',
            syncInterval: const Duration(hours: 1),
            stateTypePolicy: StreamStateTypePolicy.softAndHard,
            maxPendingRows: 10000,
          ),
          password: utf8.encode('test-password'),
          ca: http.ca,
        );
      });

      _Worker start(
        String name, {
        Future<void> Function()? afterRenewCommit,
        Future<void> Function()? beforeAdmit,
        Future<void> Function()? beforeNumberCommit,
        Duration? headerDeadline,
        void Function(String message)? onLog,
        Future<pg.Connection> Function(Duration)? openDatabase,
        Future<List<StreamTarget>> Function()? loadTargets,
        Duration revisionInterval = const Duration(hours: 1),
      }) {
        final clock = StreamReaderClock();
        var resumeAt = Duration.zero;
        final connected = Completer<void>();
        final database = Completer<pg.Connection>();
        final supervisor = Icinga2StreamSupervisor(
          loadTargets: loadTargets ?? () async => [target],
          openDatabase: openDatabase ?? (_) => endpoint.open(),
          holder: name,
          log: (message) {
            onLog?.call(message);
            if (message.endsWith(' connected') && !connected.isCompleted) {
              connected.complete();
            }
          },
          revisionInterval: revisionInterval,
          runMode: 'test',
          leaseClockForTest: () => clock.elapsed,
          leaseScheduleForTest: (delay, callback) => clock.schedule(delay, () {
            if (clock.elapsed < resumeAt) clock.elapsed = resumeAt;
            callback();
          }),
          afterRenewCommitForTest: afterRenewCommit,
          beforeAdmitForTest: beforeAdmit,
          beforeNumberCommitForTest: beforeNumberCommit,
          headerDeadlineForTest: headerDeadline,
          onConsumerConnection: (connection) async {
            if (!database.isCompleted) database.complete(connection);
          },
        );
        supervisor.start();
        addTearDown(supervisor.stop);
        return _Worker(supervisor, clock, connected, database, (elapsed) {
          resumeAt = elapsed;
          clock.elapsed = elapsed;
        });
      }

      Future<void> expire() => session.db.unsafeSimpleExecute('''
        UPDATE icinga2_stream_lease
        SET "expiresAt" = clock_timestamp() - interval '1 second'
        WHERE "sourceId" = '$icinga2DbSourceId'
      ''');

      Future<void> ageSync() => session.db.unsafeSimpleExecute('''
        UPDATE icinga2_sync_progress
        SET started_at=started_at-interval '61 seconds'
        WHERE source_id='$icinga2DbSourceId'
      ''');

      Future<StreamStatus> status() async =>
          (await StreamStatusStore(observer).read(icinga2DbSourceId))!;

      Future<List<Object?>> leaseRow() async => (await observer.execute('''
        SELECT holder, generation, "expiresAt" > clock_timestamp()
        FROM icinga2_stream_lease WHERE "sourceId" = '$icinga2DbSourceId'
      ''')).single;

      Future<void> waitForConnections(int count) async {
        final watch = Stopwatch()..start();
        while (http.subscriptionsReady < count) {
          if (watch.elapsed > const Duration(seconds: 10)) {
            fail('Expected $count subscriptions');
          }
          await observer.execute('SELECT 1');
        }
      }

      test('first_start_of_a_new_source', () async {
        expect(
          await observer.execute('SELECT 1 FROM icinga2_stream_lease'),
          isEmpty,
        );
        final worker = start('first');
        await worker.ready();
        expect(await leaseRow(), ['first', 1, true]);
        final current = await status();
        expect(current.connectionSeq, 1);
        expect(current.connectionId, isNotNull);
        expect(current.gapCount, 0);
        expect(http.subscriptionsReady, 1);
      });

      test('two_workers_start', () async {
        final a = start(
          'worker-a',
          revisionInterval: const Duration(milliseconds: 100),
        );
        final b = start(
          'worker-b',
          revisionInterval: const Duration(milliseconds: 100),
        );
        await Future.any([a.ready(), b.ready()]);
        final row = await leaseRow();
        expect(row[1], 1);
        expect(http.subscriptionsReady, 1);
        final winner = row[0] == 'worker-a' ? a : b;
        final successor = identical(winner, a) ? b : a;
        await ageSync();
        await winner.supervisor.stop();
        await successor.ready();
        expect((await leaseRow())[1], 2);
        final current = await status();
        expect(current.connectionSeq, 2);
        expect(current.gapCount, 1);
        expect(http.subscriptionsReady, 2);
      });

      test('holder_renews_after_expiry', () async {
        final first = start(
          'worker-a',
          revisionInterval: const Duration(milliseconds: 100),
        );
        await first.ready();
        final previous = await status();
        await expire();
        first.clock.advance(const Duration(seconds: 10));
        await http.disconnected.future.timeout(const Duration(seconds: 5));
        await waitForConnections(2);
        final row = await leaseRow();
        expect(row[0], 'worker-a');
        expect(row[1], greaterThan(1));
        final current = await status();
        expect(current.connectionSeq, 2);
        expect(current.connectionId, isNot(previous.connectionId));
        expect(current.gapCount, 1);
        expect(current.lastGapSeq, 1);
      });

      test('holder_frozen_past_expiry', () async {
        final old = start('worker-a');
        await old.ready();
        await ageSync();
        await expire();
        final next = start('worker-b');
        await next.ready();
        old.freezeUntil(const Duration(seconds: 31));
        expect((await leaseRow())[1], 2);
        final before = await status();
        final rawBefore = await observer.execute(
          'SELECT raw_id FROM raw_inbox',
        );
        old.clock.advance(Duration.zero);
        await http.disconnected.future.timeout(const Duration(seconds: 5));
        final after = await status();
        expect(after.connectionId, before.connectionId);
        expect(after.connectionSeq, before.connectionSeq);
        expect(after.gapCount, before.gapCount);
        expect(
          await observer.execute('SELECT raw_id FROM raw_inbox'),
          rawBefore,
        );
      });

      test('database_lost_before_the_first_renewal', () async {
        final worker = start('worker-a');
        await worker.ready();
        await (await worker.database.future).close(force: true);
        worker.clock.advance(const Duration(seconds: 19));
        expect(http.disconnected.isCompleted, isFalse);
        worker.clock.advance(const Duration(seconds: 1));
        await http.disconnected.future.timeout(const Duration(seconds: 5));
        expect((await leaseRow())[2], isTrue);
      });

      test('database_unreachable_for_the_holder', () async {
        final renewed = Completer<void>();
        final worker = start('worker-a');
        await worker.ready();
        worker.clock.onSchedule = (delay) {
          if (worker.clock.elapsed == const Duration(seconds: 10) &&
              delay == const Duration(seconds: 20) &&
              !renewed.isCompleted) {
            renewed.complete();
          }
        };
        worker.clock.advance(const Duration(seconds: 10));
        await renewed.future.timeout(const Duration(seconds: 5));
        await (await worker.database.future).close(force: true);
        worker.clock.advance(const Duration(seconds: 19));
        expect(http.disconnected.isCompleted, isFalse);
        worker.clock.advance(const Duration(seconds: 1));
        await http.disconnected.future.timeout(const Duration(seconds: 5));
        expect((await leaseRow())[2], isTrue);
      });

      test('paused_old_holder_after_takeover', () async {
        final entered = Completer<void>();
        final resume = Completer<void>();
        final old = start(
          'worker-a',
          beforeAdmit: () async {
            if (!entered.isCompleted) entered.complete();
            await resume.future;
          },
        );
        addTearDown(() {
          if (!resume.isCompleted) resume.complete();
        });
        await old.ready();
        await http.send(streamDbCheck(DateTime.now().toUtc()));
        await entered.future.timeout(const Duration(seconds: 10));
        await ageSync();
        await expire();
        final next = start('worker-b');
        await next.ready();
        expect((await leaseRow())[1], 2);
        final before = await status();
        final rows = await observer.execute('SELECT raw_id FROM raw_inbox');
        resume.complete();
        await http.disconnected.future.timeout(const Duration(seconds: 5));
        final after = await status();
        expect(after.state, before.state);
        expect(after.connectionId, before.connectionId);
        expect(after.connectionSeq, before.connectionSeq);
        expect(after.gapCount, before.gapCount);
        expect(after.lastGapSeq, before.lastGapSeq);
        expect(after.lastEventAt, before.lastEventAt);
        expect(after.lastSyncId, before.lastSyncId);
        expect(await observer.execute('SELECT raw_id FROM raw_inbox'), rows);
      });

      test('renewal_acknowledged_after_the_deadline', () async {
        final committed = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final old = start(
          'worker-a',
          afterRenewCommit: () async {
            if (!committed.isCompleted) committed.complete();
            await release.future;
          },
        );
        await old.ready();
        old.clock.advance(const Duration(seconds: 10));
        await committed.future.timeout(const Duration(seconds: 5));
        old.clock.advance(const Duration(seconds: 10));
        await http.disconnected.future.timeout(const Duration(seconds: 5));
        old.clock.advance(const Duration(seconds: 2));
        release.complete();
        await old.supervisor.stop();
        expect(http.subscriptionsReady, 1);
        await ageSync();
        await expire();
        final next = start('worker-b');
        await next.ready();
        expect((await leaseRow())[1], greaterThan(1));
        expect((await status()).connectionSeq, 2);
        expect(http.subscriptionsReady, 2);
      });

      for (final committed in [true, false]) {
        test(
          'numbering_acknowledgement_lost_${committed ? 'commit' : 'rollback'}',
          () async {
            const budget = Duration(milliseconds: 731);
            final armed = Completer<void Function()>();
            final entered = Completer<void>();
            final finish = Completer<void>();
            var number = 0;
            final worker = runZoned(
              () => start(
                'numbering-test',
                headerDeadline: budget,
                beforeNumberCommit: () async {
                  if (++number != 1) return;
                  entered.complete();
                  await finish.future;
                  if (!committed) throw StateError('test rollback');
                },
              ),
              zoneSpecification: ZoneSpecification(
                createTimer: (self, parent, zone, duration, callback) {
                  if (duration == budget && !armed.isCompleted) {
                    armed.complete(zone.bindCallback(callback));
                    return parent.createTimer(
                      zone,
                      const Duration(hours: 1),
                      () {},
                    );
                  }
                  return parent.createTimer(zone, duration, callback);
                },
              ),
            );
            addTearDown(() {
              if (!finish.isCompleted) finish.complete();
            });
            await entered.future.timeout(const Duration(seconds: 5));
            final cancel = await armed.future;
            cancel();
            expect(http.subscriptions, isEmpty);
            expect((await status()).connectionSeq, 0);
            expect(number, 1);
            finish.complete();
            await worker.ready();
            final current = await status();
            expect(http.subscriptionsReady, 1);
            expect(current.connectionSeq, committed ? 2 : 1);
            expect(current.gapCount, committed ? 1 : 0);
            expect(number, 2);
          },
        );
      }

      test('takeover_inside_the_spacing_window', () async {
        final old = start('first');
        await old.ready();
        final initial = (await status()).lastSyncId;
        await expire();
        old.clock.advance(const Duration(seconds: 20));
        await http.disconnected.future.timeout(const Duration(seconds: 5));
        await session.db.unsafeExecute('''
          UPDATE icinga2_sync_progress SET started_at=clock_timestamp()-interval '31 seconds'
          WHERE sync_id=CAST(@id AS uuid)
        ''', parameters: QueryParameters.named({'id': initial}));
        final next = start(
          'second',
          revisionInterval: const Duration(milliseconds: 25),
        );
        await waitForConnections(2);
        expect(await countRows(session, 'icinga2_sync_progress'), 1);
        expect((await status()).state, StreamConsumerState.connecting);
        await session.db.unsafeExecute('''
          UPDATE icinga2_sync_progress SET started_at=clock_timestamp()-interval '60 seconds'
          WHERE sync_id=CAST(@id AS uuid)
        ''', parameters: QueryParameters.named({'id': initial}));
        await next.ready();
        expect(await countRows(session, 'icinga2_sync_progress'), 2);
        expect((await status()).lastSyncId, isNot(initial));
        expect((await leaseRow())[1], 2);
      });

      test('wrong_password_never_starts_sync', () async {
        http.expectedAuthorization =
            'Basic ${base64Encode(utf8.encode('test:rotated-password'))}';
        final refused = Completer<void>();
        final worker = start(
          'unauthorized',
          onLog: (message) {
            if (message.endsWith(' backoff unauthorized') &&
                !refused.isCompleted) {
              refused.complete();
            }
          },
        );
        await refused.future.timeout(const Duration(seconds: 5));
        final failure = await status();
        expect(failure.lastErrorClass, 'unauthorized');
        expect(failure.connectionSeq, 1);
        expect(failure.gapCount, 1);
        expect(await countRows(session, 'icinga2_sync_progress'), 0);
        expect(await countRows(session, 'raw_inbox'), 0);
        await worker.supervisor.stop();
      });

      for (final remove in [false, true]) {
        test(
          remove
              ? 'source_removed_during_a_database_outage'
              : 'status_write_during_a_database_outage',
          () async {
            var offline = false;
            final leaseLeftToExpire = Completer<void>();
            final reading = Completer<void>();
            final release = Completer<void>();
            addTearDown(() {
              if (!release.isCompleted) release.complete();
            });
            if (remove) {
              http.serveServices = (response) async {
                response.bufferOutput = false;
                response.write('{"results":[');
                await response.flush();
                reading.complete();
                await release.future;
                await response.close();
              };
            }
            final targets = StreamTargetLoader(
              session.serverpod,
              testSecretResolver(session),
            );
            final worker = start(
              'database-outage',
              revisionInterval: const Duration(milliseconds: 25),
              loadTargets: () => offline
                  ? Future.error(StateError('consumer database unavailable'))
                  : targets.load(),
              openDatabase: (_) => offline
                  ? Future.error(StateError('consumer database unavailable'))
                  : endpoint.open(),
              onLog: (message) {
                if (message.endsWith(' lease expires') &&
                    !leaseLeftToExpire.isCompleted) {
                  leaseLeftToExpire.complete();
                }
              },
            );
            if (remove) {
              await reading.future.timeout(const Duration(seconds: 5));
              expect((await status()).state, StreamConsumerState.syncing);
            } else {
              await worker.ready();
            }
            offline = true;
            await (await worker.database.future).close(force: true);
            await http.subscriptions.single.close();
            await http.disconnected.future.timeout(const Duration(seconds: 5));
            await leaseLeftToExpire.future.timeout(const Duration(seconds: 5));
            expect((await status()).gapCount, 0);
            if (remove) {
              await IngestConfigRepository(
                session,
                secretStore: testSecretStore,
              ).publishConfig(
                streamBootstrap(2, []),
                <String, Object?>{},
                runMode: 'test',
              );
            }
            await expire();
            if (!remove) await ageSync();
            offline = false;
            final expected = remove
                ? StreamConsumerState.retired
                : StreamConsumerState.connected;
            final deadline = Stopwatch()..start();
            StreamStatus current;
            do {
              current = await status();
              if (deadline.elapsed > const Duration(seconds: 8)) {
                fail(
                  'Recovery did not reach ${expected.name}: ${current.state.name}',
                );
              }
            } while (current.state != expected);
            expect(current.gapCount, 1);
            expect(current.lastGapSeq, 1);
            if (remove) {
              expect(current.connectionSeq, 1);
              expect(http.subscriptionsReady, 1);
              final ended = (await observer.execute('''
              SELECT phase, read_problem, read_end_at IS NOT NULL
              FROM icinga2_sync_progress
            ''')).single;
              expect(ended.toList(), ['failed', 'source_retired', true]);
            } else {
              expect(current.connectionSeq, 2);
              expect(http.subscriptionsReady, 2);
            }
          },
        );
      }
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}

final class _Worker {
  _Worker(
    this.supervisor,
    this.clock,
    this.connected,
    this.database,
    this.freezeUntil,
  );

  final Icinga2StreamSupervisor supervisor;
  final StreamReaderClock clock;
  final Completer<void> connected;
  final Completer<pg.Connection> database;
  final void Function(Duration) freezeUntil;

  Future<void> ready() => connected.future.timeout(const Duration(seconds: 10));
}
