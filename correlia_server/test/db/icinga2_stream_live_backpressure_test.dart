import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/status.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/supervisor.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_consumer_loopback.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/stream_reader_clock.dart';

Future<void> _until(Future<bool> Function() condition, String message) async {
  final watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed > const Duration(seconds: 5)) fail(message);
  }
}

void main() {
  withServerpod(
    'Live Icinga2 stream backpressure',
    (builder, _) {
      late Session session;
      late IcingaConsumerLoopback server;
      late String snapshot;
      late StreamReaderClock clock;
      late StreamStatusStore status;
      late StreamReaderClock backoff;
      late List<Duration> backoffDelays;
      late List<String> logs;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute(
          'TRUNCATE icinga2_stream_lease,icinga2_stream_status,icinga2_admitted_batch,icinga2_stream_resync',
        );
        server = await IcingaConsumerLoopback.start();
        addTearDown(server.close);
        snapshot = await publishStreamDb(
          session,
          apiUrl: server.url.toString(),
        );
        clock = StreamReaderClock();
        logs = [];
        backoff = StreamReaderClock();
        backoffDelays = [];
        backoff.onSchedule = backoffDelays.add;
      });

      Future<void> start({
        Future<void> Function(pg.TxSession)? beforeCommit,
        Future<void> Function()? beforeAdmit,
        bool realReaderTime = false,
      }) async {
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        final probe = await endpoint.open();
        addTearDown(probe.close);
        status = StreamStatusStore(probe);
        final supervisor = Icinga2StreamSupervisor(
          holder: 'live-backpressure-tests',
          openDatabase: (_) => endpoint.open(),
          revisionInterval: const Duration(milliseconds: 25),
          runMode: 'test',
          readerClockForTest: realReaderTime ? null : () => clock.elapsed,
          readerScheduleForTest: realReaderTime ? null : clock.schedule,
          backoffScheduleForTest: backoff.schedule,
          backoffRandomForTest: () => 0.5,
          beforeAdmitForTest: beforeAdmit,
          beforeAdmissionCommit: beforeCommit,
          log: logs.add,
          loadTargets: () async => [
            StreamTarget(
              sourceId: icinga2DbSourceId,
              snapshotId: snapshot,
              namespace: icinga2DbSourceId,
              password: utf8.encode('valid-fixture-password'),
              ca: server.ca,
              options: IcingaStreamOptions(
                url: server.url,
                username: 'correlia',
                passwordRef: 'password',
                caRef: 'ca',
                syncInterval: const Duration(hours: 1),
                stateTypePolicy: StreamStateTypePolicy.softAndHard,
                maxPendingRows: 100,
              ),
            ),
          ],
        );
        addTearDown(supervisor.stop);
        supervisor.start();
        await server.firstSubscription.future.timeout(
          const Duration(seconds: 5),
        );
        await _until(
          () async =>
              (await status.read(icinga2DbSourceId))?.state ==
              StreamConsumerState.connected,
          'Initial sync did not connect',
        );
      }

      Future<void> flushEvent(DateTime at) async {
        final scheduled = Completer<void>();
        clock.onSchedule = (delay) {
          if (delay == const Duration(seconds: 1) && !scheduled.isCompleted) {
            scheduled.complete();
          }
        };
        await server.send(streamDbCheck(at));
        await scheduled.future.timeout(const Duration(seconds: 5));
        clock.onSchedule = null;
        clock.advance(const Duration(seconds: 1));
      }

      Future<void> expectGap(String reason) async {
        await server.disconnected.future.timeout(const Duration(seconds: 5));
        await _until(() async {
          final value = await status.read(icinga2DbSourceId);
          return value?.state == StreamConsumerState.backoff &&
              value?.lastErrorClass == reason;
        }, 'Missing $reason backoff status');
        final value = (await status.read(icinga2DbSourceId))!;
        expect(value.gapCount, 1);
        expect(value.lastGapSeq, 1);
        expect(
          logs.where((line) => line.endsWith('backoff $reason')),
          hasLength(1),
        );
      }

      test('pipeline_stopped', () async {
        await start();
        await session.db.unsafeExecute('''
          INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type,status)
          SELECT clock_timestamp(),gen_random_uuid(),'$icinga2DbSourceId',decode('00','hex'),'seed','application/json','pending'
          FROM generate_series(1,100)
        ''');
        await flushEvent(DateTime.now().toUtc());
        await _until(
          () async =>
              (await status.read(icinga2DbSourceId))?.state ==
              StreamConsumerState.paused,
          'Reader did not pause at the retained-work cap',
        );
        clock.advance(const Duration(seconds: 29));
        expect((await status.read(icinga2DbSourceId))!.gapCount, 0);
        clock.advance(const Duration(seconds: 1));
        await expectGap('backpressure');
        expect(await countRows(session, 'raw_inbox'), lessThanOrEqualTo(101));
      });

      test('insert_blocked_below_the_cap', () async {
        var attempts = 0;
        await start(
          realReaderTime: true,
          beforeAdmit: () async {
            attempts++;
          },
        );
        final lockConnection = await openStreamDatabase(session.serverpod);
        addTearDown(lockConnection.close);
        final locked = Completer<int>();
        final unlock = Completer<void>();
        final locker = lockConnection.runTx((tx) async {
          await tx.execute('SET LOCAL idle_in_transaction_session_timeout=0');
          await tx.execute('LOCK TABLE icinga2_raw_origin IN SHARE MODE');
          locked.complete(
            (await tx.execute('SELECT pg_backend_pid()')).single[0]! as int,
          );
          await unlock.future;
        });
        final pid = await locked.future;
        final heldFor = Stopwatch()..start();
        try {
          await server.send(streamDbCheck(DateTime.now().toUtc()));
          await _until(() async {
            final rows = await session.db.unsafeQuery('''
              SELECT 1 FROM pg_stat_activity
              WHERE $pid=ANY(pg_blocking_pids(pid))
                AND datname=current_database()
            ''');
            return rows.isNotEmpty;
          }, 'Admission never waited on the database lock');
          expect(await countRows(session, 'raw_inbox'), 0);
          await server.disconnected.future.timeout(const Duration(seconds: 35));
          await expectGap('backpressure');
          expect(
            heldFor.elapsed,
            greaterThanOrEqualTo(const Duration(seconds: 30)),
          );
          expect(attempts, greaterThan(1));
          final remaining = const Duration(seconds: 40) - heldFor.elapsed;
          if (remaining > Duration.zero) await Future<void>.delayed(remaining);
        } finally {
          unlock.complete();
          await locker;
        }
        expect(await countRows(session, 'raw_inbox'), lessThanOrEqualTo(1));
        expect(
          await countRows(session, 'icinga2_admitted_batch'),
          lessThanOrEqualTo(1),
        );
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('repeated_short_pauses', () async {
        final entered = StreamController<Completer<void>>.broadcast();
        final releases = <Completer<void>>[];
        addTearDown(() async {
          for (final release in releases) {
            if (!release.isCompleted) release.complete();
          }
          await entered.close();
        });
        await start(
          beforeCommit: (_) async {
            final release = Completer<void>();
            releases.add(release);
            entered.add(release);
            await release.future;
          },
        );

        Future<void> delayedFlush(DateTime timestamp) async {
          final next = entered.stream.first;
          await flushEvent(timestamp);
          final release = await next.timeout(const Duration(seconds: 5));
          clock.advance(const Duration(seconds: 19));
          release.complete();
          final expected = releases.length;
          await _until(
            () async => await countRows(session, 'raw_inbox') >= expected,
            'Admission did not complete after the short pause',
          );
        }

        await delayedFlush(DateTime.now().toUtc());
        for (var i = 0; i < 6; i++) {
          await delayedFlush(
            DateTime.now().toUtc().subtract(Duration(seconds: 62 + i)),
          );
          expect((await status.read(icinga2DbSourceId))!.gapCount, 0);
        }
        await server.send(
          streamDbCheck(
            DateTime.now().toUtc().subtract(const Duration(seconds: 69)),
          ),
        );
        await expectGap('lag');
      });

      test('initial_backlog_with_growing_excess_lag', () async {
        final entered = StreamController<Completer<void>>.broadcast();
        final releases = <Completer<void>>[];
        addTearDown(() async {
          for (final release in releases) {
            if (!release.isCompleted) release.complete();
          }
          await entered.close();
        });
        await start(
          beforeCommit: (_) async {
            final release = Completer<void>();
            releases.add(release);
            entered.add(release);
            await release.future;
          },
        );
        final socket = server.subscriptions.single;
        final now = DateTime.now().toUtc();
        final baseline =
            '${jsonEncode(streamDbCheck(now.subtract(const Duration(hours: 2))))}\n';
        final delayed = List.generate(
          999,
          (index) =>
              '${jsonEncode(streamDbCheck(now.subtract(Duration(hours: 2, seconds: 62 + index))))}\n',
        );
        var next = entered.stream.first;
        for (var i = 0; i < 100000; i++) {
          socket.write(i < 100 ? baseline : delayed[(i ~/ 100) - 1]);
        }
        final sending = socket.flush().then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        addTearDown(() async {
          socket.destroy();
          await sending;
        });
        for (var batch = 0; batch < 7; batch++) {
          final release = await next.timeout(const Duration(seconds: 20));
          if (batch < 6) next = entered.stream.first;
          clock.advance(const Duration(seconds: 20));
          release.complete();
          final expected = batch + 1;
          await _until(
            () async => await countRows(session, 'raw_inbox') >= expected,
            'Queued batch did not reach the pipeline',
          );
          await processIcinga2(session, DateTime.now().toUtc());
        }
        await expectGap('lag');
      }, timeout: const Timeout(Duration(minutes: 2)));

      Future<void> waitBackoff(int count) => _until(() async {
        await status.read(icinga2DbSourceId);
        return backoffDelays.length >= count;
      }, 'The supervisor did not schedule reconnect $count');

      Future<void> takeIcingaDown() async {
        for (final socket in server.subscriptions) {
          socket.destroy();
        }
        await server.server.close(force: true);
      }

      test('icinga_2_down_for_an_hour', () async {
        await start();
        await takeIcingaDown();
        var attempts = 0;
        while (backoff.elapsed < const Duration(hours: 1)) {
          await waitBackoff(++attempts);
          final delay = backoffDelays.last;
          expect(delay, lessThanOrEqualTo(const Duration(seconds: 72)));
          final state = (await status.read(icinga2DbSourceId))!;
          expect(state.state, StreamConsumerState.backoff);
          expect(state.lastErrorClass, isNotNull);
          expect(state.gapCount, 1);
          expect(state.connectionSeq, 1);
          backoff.advance(delay);
        }
        expect(attempts, greaterThan(7));
      });

      test('icinga_2_restarts', () async {
        await start();
        final port = server.server.port;
        await takeIcingaDown();
        for (var attempt = 1; attempt <= 4; attempt++) {
          await waitBackoff(attempt);
          backoff.advance(backoffDelays.last);
        }
        await waitBackoff(5);
        expect(backoff.elapsed, const Duration(seconds: 15));
        backoff.advance(const Duration(seconds: 5));
        final replacement = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          port,
          SecurityContext()
            ..useCertificateChain(
              '../correlia_icinga2_notify/test/fixtures/server_one.pem',
            )
            ..usePrivateKey(
              '../correlia_icinga2_notify/test/fixtures/server_one.key',
            ),
        );
        final sockets = <Socket>[];
        final synced = Completer<void>();
        replacement.listen((request) async {
          await request.drain<void>();
          if (request.uri.path == '/v1/events') {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            sockets.add(socket);
            socket.listen((_) {}, onError: (Object _) {});
            socket.write(
              'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n',
            );
            await socket.flush();
          } else {
            request.response.write(jsonEncode({'results': <Object?>[]}));
            await request.response.close();
            if (request.uri.path == '/v1/objects/services' &&
                !synced.isCompleted) {
              synced.complete();
            }
          }
        });
        addTearDown(() async {
          for (final socket in sockets) {
            socket.destroy();
          }
          await replacement.close(force: true);
        });
        await session.db.unsafeExecute(
          "UPDATE icinga2_sync_progress SET started_at=started_at-interval '61 seconds'",
        );
        backoff.advance(const Duration(seconds: 11));
        await synced.future.timeout(const Duration(seconds: 5));
        await _until(
          () async =>
              (await status.read(icinga2DbSourceId))?.state ==
              StreamConsumerState.connected,
          'Reconnected stream did not finish its sync',
        );
        final reconnected = (await status.read(icinga2DbSourceId))!;
        expect(reconnected.gapCount, 1);
        expect(reconnected.connectionSeq, 2);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
