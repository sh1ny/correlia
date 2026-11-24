@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/status.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/supervisor.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_consumer_loopback.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/icinga2_test_db_changes.dart';
import '../support/stream_reader_clock.dart';

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
      late IcingaTestDbChanges changes;
      late Completer<void> backoffScheduled;
      late Completer<void> backoffLogged;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute(
          'TRUNCATE icinga2_stream_lease,icinga2_stream_status,icinga2_admitted_batch,icinga2_stream_resync',
        );
        await session.db.unsafeSimpleExecute('''
          CREATE SCHEMA backpressure_clock;
          CREATE TABLE backpressure_clock.instant AS SELECT clock_timestamp() AS value;
          CREATE FUNCTION backpressure_clock.clock_timestamp()
          RETURNS timestamptz VOLATILE LANGUAGE sql
          AS 'SELECT value FROM backpressure_clock.instant';
        ''');
        addTearDown(
          () => session.db.unsafeSimpleExecute(
            'DROP SCHEMA backpressure_clock CASCADE',
          ),
        );
        server = await IcingaConsumerLoopback.start();
        changes = await IcingaTestDbChanges.start(session.serverpod, [
          'icinga2_stream_status',
          'raw_inbox',
        ]);
        addTearDown(changes.close);
        addTearDown(server.close);
        snapshot = await publishStreamDb(
          session,
          apiUrl: server.url.toString(),
        );
        clock = StreamReaderClock();
        logs = [];
        backoffLogged = Completer<void>();
        backoff = StreamReaderClock();
        backoffDelays = [];
        backoffScheduled = Completer<void>();
        backoff.onSchedule = (delay) {
          backoffDelays.add(delay);
          final previous = backoffScheduled;
          backoffScheduled = Completer<void>();
          previous.complete();
        };
      });

      Future<void> start({
        Future<void> Function(pg.TxSession)? beforeCommit,
        Future<void> Function(pg.TxSession, StreamRawBatch)? beforeWrite,
        void Function(StreamRawBatch, pg.ServerException)? writeError,
      }) async {
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        Future<pg.Connection> open() async {
          final connection = beforeWrite == null
              ? await endpoint.open()
              : await endpoint.open(queryTimeout: const Duration(minutes: 5));
          try {
            await connection.execute(
              'SET search_path=backpressure_clock,pg_catalog,public',
            );
            return connection;
          } catch (_) {
            await connection.close(force: true);
            rethrow;
          }
        }

        final probe = await open();
        addTearDown(probe.close);
        status = StreamStatusStore(probe);
        final leaseClock = StreamReaderClock();
        final supervisor = Icinga2StreamSupervisor(
          holder: 'live-backpressure-tests',
          openDatabase: (_) => open(),
          revisionInterval: const Duration(milliseconds: 25),
          runMode: 'test',
          readerClockForTest: () => clock.elapsed,
          readerScheduleForTest: clock.schedule,
          leaseClockForTest: () => leaseClock.elapsed,
          leaseScheduleForTest: leaseClock.schedule,
          backoffScheduleForTest: backoff.schedule,
          backoffRandomForTest: () => 0.5,
          beforeRawWriteForTest: beforeWrite,
          rawWriteErrorForTest: writeError,
          beforeAdmissionCommit: beforeCommit,
          log: (line) {
            logs.add(line);
            if (line.contains(' backoff ') && !backoffLogged.isCompleted) {
              backoffLogged.complete();
            }
          },
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
        await server.waitForSubscriptions(1);
        await changes.until(
          () async =>
              (await status.read(icinga2DbSourceId))?.state ==
              StreamConsumerState.connected,
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
        await scheduled.future;
        clock.onSchedule = null;
        clock.advance(const Duration(seconds: 1));
      }

      Future<void> expectGap(String reason) async {
        await server.waitForDisconnects(1);
        await changes.until(() async {
          final value = await status.read(icinga2DbSourceId);
          return value?.state == StreamConsumerState.backoff &&
              value?.lastErrorClass == reason;
        });
        final value = (await status.read(icinga2DbSourceId))!;
        expect(value.gapCount, 1);
        expect(value.lastGapSeq, 1);
        await backoffLogged.future;
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
        await changes.until(
          () async =>
              (await status.read(icinga2DbSourceId))?.state ==
              StreamConsumerState.paused,
        );
        clock.advance(const Duration(seconds: 29));
        expect((await status.read(icinga2DbSourceId))!.gapCount, 0);
        clock.advance(const Duration(seconds: 1));
        await expectGap('backpressure');
        expect(await countRows(session, 'raw_inbox'), lessThanOrEqualTo(101));
      });

      test('insert_blocked_below_the_cap', () async {
        final attempts = StreamController<(String, String?, String)>();
        final failures = StreamIterator(attempts.stream);
        addTearDown(() async {
          await failures.cancel();
          await attempts.close();
        });
        Duration? blockedAt;
        final retries = StreamController<Duration>();
        final retry = StreamIterator(retries.stream);
        addTearDown(() async {
          await retry.cancel();
          await retries.close();
        });
        await start(
          beforeWrite: (tx, _) async {
            expect(
              (await tx.execute('SHOW statement_timeout')).single[0],
              '2s',
            );
            expect((await tx.execute('SHOW lock_timeout')).single[0], '2s');
            await tx.execute('SET LOCAL statement_timeout=0');
          },
          writeError: (batch, error) =>
              attempts.add((batch.id, error.code, error.message)),
        );
        final lockConnection = await openStreamDatabase(session.serverpod);
        addTearDown(lockConnection.close);
        final locked = Completer<void>();
        final unlock = Completer<void>();
        final locker = lockConnection.runTx((tx) async {
          await tx.execute('SET LOCAL idle_in_transaction_session_timeout=0');
          await tx.execute('LOCK TABLE icinga2_raw_origin IN SHARE MODE');
          locked.complete();
          await unlock.future;
        });
        try {
          await Future.any([
            locked.future,
            locker.then<void>((_) => throw StateError('Blocker ended early')),
          ]);
          final sent = Completer<void>();
          clock.onSchedule = (delay) {
            if (delay == const Duration(seconds: 30)) blockedAt = clock.elapsed;
            if (delay != const Duration(seconds: 1)) return;
            if (!sent.isCompleted) {
              sent.complete();
            } else {
              retries.add(clock.elapsed + delay);
            }
          };
          await server.send(streamDbCheck(DateTime.now().toUtc()));
          await sent.future;
          clock.advance(const Duration(seconds: 1));
          expect(await failures.moveNext(), isTrue);
          final (batchId, code, message) = failures.current;
          expect(code, '55P03');
          expect(message, contains('lock timeout'));
          expect(await countRows(session, 'raw_inbox'), 0);
          expect(await retry.moveNext(), isTrue);
          final outage = blockedAt! + const Duration(seconds: 30);
          expect(retry.current, lessThan(outage));
          clock.advance(retry.current - clock.elapsed);
          expect(await failures.moveNext(), isTrue);
          expect(failures.current, (batchId, code, message));
          clock.advance(outage - clock.elapsed);
          await expectGap('backpressure');
        } finally {
          unlock.complete();
          await locker;
        }
        expect(await countRows(session, 'raw_inbox'), lessThanOrEqualTo(1));
        expect(
          await countRows(session, 'icinga2_admitted_batch'),
          lessThanOrEqualTo(1),
        );
      });

      test('repeated_short_pauses', () async {
        final entered = StreamController<Completer<void>>.broadcast();
        final releases = <Completer<void>>[];
        await start(
          beforeCommit: (tx) async {
            await tx.execute('SET LOCAL idle_in_transaction_session_timeout=0');
            final release = Completer<void>();
            releases.add(release);
            entered.add(release);
            await release.future;
          },
        );
        addTearDown(() async {
          for (final release in releases) {
            if (!release.isCompleted) release.complete();
          }
          await entered.close();
        });

        Future<void> delayedFlush(DateTime timestamp) async {
          final next = entered.stream.first;
          await flushEvent(timestamp);
          final release = await next;
          clock.advance(const Duration(seconds: 19));
          release.complete();
          final expected = releases.length;
          await changes.until(
            () async => await countRows(session, 'raw_inbox') >= expected,
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
        await start(
          beforeCommit: (tx) async {
            await tx.execute('SET LOCAL idle_in_transaction_session_timeout=0');
            final release = Completer<void>();
            releases.add(release);
            entered.add(release);
            await release.future;
          },
        );
        addTearDown(() async {
          for (final release in releases) {
            if (!release.isCompleted) release.complete();
          }
          await entered.close();
        });
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
          onError: (Object error, StackTrace stack) {
            // The consumer closes this socket with queued writes when lag wins.
            if (error is SocketException &&
                (error.osError?.errorCode == 32 ||
                    error.osError?.errorCode == 104)) {
              return;
            }
            Error.throwWithStackTrace(error, stack);
          },
        );
        sending
            .ignore(); // Teardown joins the write even after the expected gap.
        addTearDown(() async {
          socket.destroy();
          await sending;
        });
        for (var batch = 0; batch < 7; batch++) {
          final release = await next;
          if (batch < 6) next = entered.stream.first;
          clock.advance(const Duration(seconds: 20));
          release.complete();
          final expected = batch + 1;
          await changes.until(
            () async => await countRows(session, 'raw_inbox') >= expected,
          );
          await processIcinga2(session, DateTime.now().toUtc());
        }
        await expectGap('lag');
      });

      Future<void> waitBackoff(int count) async {
        while (backoffDelays.length < count) {
          await backoffScheduled.future;
        }
      }

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
        await synced.future;
        await changes.until(
          () async =>
              (await status.read(icinga2DbSourceId))?.state ==
              StreamConsumerState.connected,
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
