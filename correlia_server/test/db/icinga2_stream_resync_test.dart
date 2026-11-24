import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/status.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/supervisor.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_consumer_loopback.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/stream_reader_clock.dart';

Future<void> _until(Future<bool> Function() condition, String cause) async {
  final clock = Stopwatch()..start();
  while (!await condition()) {
    if (clock.elapsed > const Duration(seconds: 5)) fail(cause);
  }
}

void main() {
  withServerpod(
    'Live Icinga2 stream resync scheduling',
    (builder, _) {
      late Session session;
      late IcingaConsumerLoopback server;
      late String snapshot;
      late DateTime now;

      final messages = <String>[];

      setUp(() async {
        messages.clear();
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
        now = DateTime.now().toUtc();
      });

      Future<StreamStatusStore> start({
        Duration? interval,
        StreamReaderClock? clock,
        bool immediateBackoff = false,
      }) async {
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        final probe = await endpoint.open();
        addTearDown(probe.close);
        final supervisor = Icinga2StreamSupervisor(
          holder: 'resync-tests',
          openDatabase: (_) => endpoint.open(),
          revisionInterval: const Duration(milliseconds: 25),
          runMode: 'test',
          readerClockForTest: clock == null ? null : () => clock.elapsed,
          readerScheduleForTest: clock?.schedule,
          backoffScheduleForTest: immediateBackoff
              ? (delay, callback) => Timer(Duration.zero, callback).cancel
              : null,
          log: messages.add,
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
                syncInterval: interval ?? const Duration(hours: 1),
                stateTypePolicy: StreamStateTypePolicy.softAndHard,
                maxPendingRows: 1000,
              ),
            ),
          ],
        );
        addTearDown(supervisor.stop);
        supervisor.start();
        await server.firstSubscription.future.timeout(
          const Duration(seconds: 5),
        );
        return StreamStatusStore(probe);
      }

      Future<void> ready(StreamStatusStore status) => _until(
        () async =>
            (await status.read(icinga2DbSourceId))?.state ==
            StreamConsumerState.connected,
        'Initial sync did not connect',
      );

      Future<void> expireSpacing() => session.db.unsafeExecute(
        "UPDATE icinga2_sync_progress SET started_at=started_at-interval '61 seconds'",
      );

      Future<void> exhaustPending() async {
        final worker = PipelineRepository(
          session,
          clock: () => now.add(const Duration(seconds: 1)),
          retryDelay: (_) => Duration.zero,
          afterClaim: () => throw StateError('injected processing failure'),
        );
        await _until(worker.pinOne, 'No admitted row reached the pipeline');
        for (var attempt = 0; attempt < 5; attempt++) {
          expect(await worker.processOne(), isTrue);
        }
        expect(
          (await queryRows(
            session,
            'SELECT "errorClass" FROM pipeline_failures',
          )).single,
          {'errorClass': 'processing_exhausted'},
        );
      }

      test('stream_row_exhausts_its_retries', () async {
        await seedStreamDb(session, snapshot, [
          streamDbCheck(now.subtract(const Duration(minutes: 1))),
        ], observed: now);
        await processIcinga2(session, now);
        final status = await start();
        await ready(status);
        final recovery = now.subtract(const Duration(seconds: 1));
        server.services = [streamDbCheck(recovery, state: 0, sync: true)];
        final secondSync = server.serviceQueries.stream.firstWhere(
          (n) => n == 2,
        );
        await expireSpacing();
        await server.send(streamDbCheck(recovery, state: 0));
        await exhaustPending();
        await secondSync.timeout(const Duration(seconds: 5));
        final worker = PipelineRepository(
          session,
          clock: () => now.add(const Duration(seconds: 1)),
        );
        await _until(worker.pinOne, 'No repair admitted');
        expect(await worker.processOne(), isTrue);
        expect((await theAlert(session))['status'], 'resolved');
        expect((await status.read(icinga2DbSourceId))!.servedResyncSeq, 1);
      });

      test('failure_before_any_status_exists', () async {
        await seedStreamDb(session, snapshot, [
          streamDbCheck(now),
        ], observed: now);
        await exhaustPending();
        expect(await countRows(session, 'icinga2_stream_status'), 0);
        final status = await start();
        await ready(status);
        expect((await status.read(icinga2DbSourceId))!.servedResyncSeq, 1);
      });

      test('sync_row_fails', () async {
        server.services = [streamDbCheck(now, sync: true)];
        final status = await start();
        await ready(status);
        await exhaustPending();
        await expireSpacing();
        expect(await countRows(session, 'icinga2_stream_resync'), 0);
        final sync = (await queryRows(
          session,
          'SELECT phase,rows_failed FROM icinga2_sync_progress',
        )).single;
        expect(sync, {'phase': 'failed', 'rows_failed': 1});
        expect(server.reads, 1);
      });

      test('no_failure', () async {
        final status = await start(interval: const Duration(milliseconds: 25));
        await ready(status);
        final secondSync = server.serviceQueries.stream.firstWhere(
          (n) => n == 2,
        );
        await expireSpacing();
        await secondSync.timeout(const Duration(seconds: 5));
        expect(await countRows(session, 'icinga2_stream_resync'), 0);
        expect((await status.read(icinga2DbSourceId))!.servedResyncSeq, 0);
      });

      for (final (name, recoveryAge) in [
        ('recovery_missed_while_disconnected', const Duration(minutes: 2)),
        (
          'recovery_missed_nine_days_ago_checked_since',
          const Duration(days: 9),
        ),
      ]) {
        test(name, () async {
          final failure = now.subtract(
            recoveryAge + const Duration(minutes: 1),
          );
          await seedStreamDb(session, snapshot, [
            streamDbCheck(failure),
          ], observed: failure);
          await processIcinga2(session, now);
          final status = await start();
          await ready(status);
          expect((await theAlert(session))['status'], 'firing');
          final fresh = now.subtract(const Duration(seconds: 1));
          server.services = [streamDbCheck(fresh, state: 0, sync: true)];
          await expireSpacing();
          await server.subscriptions.single.close();
          await _until(
            () async =>
                (await status.read(icinga2DbSourceId))!.connectionSeq >= 2,
            'Consumer did not reconnect after EOF',
          );
          await ready(status);
          await processIcinga2(session, now);
          expect((await theAlert(session))['status'], 'resolved');
          expect(await countRows(session, 'events'), 2);
          expect((await status.read(icinga2DbSourceId))!.gapCount, 1);
        });
      }

      for (final (name, code, error) in [
        ('sync_request_fails', 500, 'http_status'),
        ('sync_denial_is_forbidden', 403, 'forbidden'),
        ('object_query_404_is_not_empty_success', 404, 'http_status'),
      ]) {
        test(name, () async {
          server.hostsStatus = code;
          final status = await start();
          await _until(() async {
            final row = await status.read(icinga2DbSourceId);
            return row?.lastErrorClass == error && row?.gapCount == 1;
          }, 'Fatal sync did not persist status and exactly one gap');
          expect(
            await queryRows(
              session,
              'SELECT phase,read_problem FROM icinga2_sync_progress',
            ),
            [
              {'phase': 'failed', 'read_problem': error},
            ],
          );
          expect(await countRows(session, 'raw_inbox'), 0);
          server.hostsStatus = 200;
          await expireSpacing();
          await _until(
            () async =>
                (await status.read(icinga2DbSourceId))!.connectionSeq == 2,
            'No retry after a fatal sync',
          );
          await ready(status);
          expect((await status.read(icinga2DbSourceId))!.gapCount, 1);
        });
      }

      for (final (name, prefix, broken, error) in [
        (
          'truncated_response_after_a_valid_prefix',
          500,
          ',{"bad":4',
          'truncated',
        ),
        ('unterminated_string', 1, ',{"bad":"unfinished', 'invalid_framing'),
        (
          'structural_nesting_exceeds_the_framing_ceiling',
          1,
          ',${'[' * 1048577}0${']' * 1048577}] }',
          'invalid_framing',
        ),
      ]) {
        test(name, () async {
          final projected = jsonEncode(
            streamDbCheck(now.subtract(const Duration(seconds: 1)), sync: true),
          );
          server.servicesBody =
              '{"results":[${List.filled(prefix, projected).join(',')}$broken';
          final status = await start();
          await _until(() async {
            final row = await status.read(icinga2DbSourceId);
            return row?.lastErrorClass == error && row?.gapCount == 1;
          }, 'Broken framing did not close and record the gap');
          expect(
            await queryRows(
              session,
              'SELECT phase,read_problem FROM icinga2_sync_progress',
            ),
            [
              {'phase': 'failed', 'read_problem': error},
            ],
          );
          final worker = PipelineRepository(session, clock: () => now);
          while (await worker.pinOne()) {
            expect(await worker.processOne(), isTrue);
          }
          expect(await countRows(session, 'events'), 1);
          server.servicesBody = null;
          await expireSpacing();
          await ready(status);
          expect((await status.read(icinga2DbSourceId))!.connectionSeq, 2);
        });
      }

      test('syncs_that_never_finish', () async {
        final clock = StreamReaderClock();
        final object = jsonEncode(
          streamDbCheck(now.subtract(const Duration(seconds: 1)), sync: true),
        );
        final headers = StreamController<HttpResponse>.broadcast();
        addTearDown(headers.close);
        final responses = <HttpResponse>[];
        server.serveServices = (response) async {
          response.bufferOutput = false;
          response.write('{"results":[');
          await response.flush();
          responses.add(response);
          headers.add(response);
        };
        final status = await start(clock: clock);
        for (var attempt = 1; attempt <= 3; attempt++) {
          if (responses.length < attempt) await headers.stream.first;
          final response = responses[attempt - 1];
          final consumed = Completer<void>();
          // The batching flush timer means the reader parsed the object.
          clock.onSchedule = (delay) {
            if (delay == const Duration(seconds: 1) && !consumed.isCompleted) {
              consumed.complete();
            }
          };
          // The server had only sent the envelope, so this is the first frame.
          response.write('$object,');
          await response.flush();
          await consumed.future.timeout(const Duration(seconds: 2));
          clock.onSchedule = null;
          clock.elapsed += const Duration(minutes: 15);
          response.write(' ');
          await response.flush();
          await _until(() async {
            final row = await status.read(icinga2DbSourceId);
            return row!.syncTimeoutsInARow == attempt &&
                row.lastErrorClass == 'timeout';
          }, 'Whole sync deadline did not persist timeout $attempt');
          await expireSpacing();
        }
        final failures = await queryRows(
          session,
          'SELECT read_problem,last_object FROM icinga2_sync_progress ORDER BY started_at',
        );
        expect(
          failures,
          List.filled(3, {
            'read_problem': 'timeout',
            'last_object': 'stream-host!stream-service',
          }),
        );
      });

      test('application_blocked_on_a_reachable_database', () async {
        server.services = [streamDbCheck(now, sync: true)];
        final status = await start();
        await ready(status);
        await session.db.unsafeExecute('''
          UPDATE icinga2_sync_progress SET read_end_at=clock_timestamp()-interval '16 minutes'
          WHERE phase='applying'
        ''');
        await _until(
          () async =>
              (await queryRows(
                session,
                'SELECT phase FROM icinga2_sync_progress',
              )).single['phase'] ==
              'stalled',
          'Periodic holder pass did not mark applying progress stalled',
        );
        await processIcinga2(session, now);
        expect(
          await queryRows(
            session,
            'SELECT phase,rows_done FROM icinga2_sync_progress',
          ),
          [
            {'phase': 'complete', 'rows_done': 1},
          ],
        );
      });

      for (final name in [
        'request_during_a_sync',
        'request_and_start_at_the_same_moment',
      ]) {
        test(name, () async {
          final reading = Completer<HttpResponse>();
          final finish = Completer<void>();
          addTearDown(() {
            if (!finish.isCompleted) finish.complete();
          });
          server.serveServices = (response) async {
            server.serveServices = null;
            response.bufferOutput = false;
            response.write('{"results":[');
            await response.flush();
            reading.complete(response);
            await finish.future;
            response.write(']}');
            await response.close();
          };
          if (name == 'request_and_start_at_the_same_moment') {
            await seedStreamDb(session, snapshot, [
              streamDbCheck(now),
            ], observed: now);
          }
          final status = await start();
          await reading.future.timeout(const Duration(seconds: 5));
          expect((await status.read(icinga2DbSourceId))!.servedResyncSeq, 0);
          if (name == 'request_during_a_sync') {
            await server.send(streamDbCheck(now));
          }
          await exhaustPending();
          expect((await status.read(icinga2DbSourceId))!.servedResyncSeq, 0);
          expect(await countRows(session, 'icinga2_sync_progress'), 1);
          await expireSpacing();
          finish.complete();
          await _until(
            () async =>
                (await status.read(icinga2DbSourceId))!.servedResyncSeq == 1,
            'Request raised while reading was not served by the next sync',
          );
          await _until(
            () async =>
                (await queryRows(
                  session,
                  "SELECT count(*)::int AS complete FROM icinga2_sync_progress WHERE phase='complete'",
                )).single['complete'] ==
                2,
            'Both syncs did not finish reading',
          );
          expect(
            await queryRows(
              session,
              'SELECT phase FROM icinga2_sync_progress ORDER BY started_at',
            ),
            [
              {'phase': 'complete'},
              {'phase': 'complete'},
            ],
          );
        });
      }

      test('request_while_paused', () async {
        final clock = StreamReaderClock();
        final status = await start(clock: clock);
        await ready(status);
        await session.db.unsafeExecute('''
          INSERT INTO raw_inbox (raw_id, source_id, observed_at, body, body_sha256, content_type, status)
          SELECT gen_random_uuid(), '$icinga2DbSourceId', clock_timestamp(),
            '{}'::bytea, repeat('0',64), 'application/json', 'failed' FROM generate_series(1,99)
        ''');
        await seedStreamDb(session, snapshot, [
          streamDbCheck(now),
        ], observed: now);
        final queued = Completer<void>();
        clock.onSchedule = (delay) {
          if (delay == const Duration(seconds: 1) && !queued.isCompleted) {
            queued.complete();
          }
        };
        await server.send(streamDbCheck(now.add(const Duration(seconds: 1))));
        await queued.future.timeout(const Duration(seconds: 2));
        clock.onSchedule = null;
        clock.advance(const Duration(seconds: 1));
        await _until(
          () async =>
              (await status.read(icinga2DbSourceId))!.state ==
              StreamConsumerState.paused,
          'Source did not pause at retained-work cap',
        );
        await exhaustPending();
        expect((await status.read(icinga2DbSourceId))!.servedResyncSeq, 0);
        await expireSpacing();
        clock.advance(const Duration(seconds: 30));
        await session.db.unsafeExecute(
          "DELETE FROM raw_inbox WHERE status='failed'",
        );
        await _until(
          () async =>
              (await status.read(icinga2DbSourceId))!.servedResyncSeq == 1,
          'Reconnected source did not serve the paused request',
        );
        await ready(status);
        final result = (await status.read(icinga2DbSourceId))!;
        expect(result.connectionSeq, 2);
        expect(result.gapCount, 1);
      });

      test('connection_flapping', () async {
        final status = await start(immediateBackoff: true);
        await ready(status);
        // Advance the database spacing clock for each observed five-second
        // socket interruption. Ten minutes of steps, without wall-time sleeps.
        for (var step = 1; step < 120; step++) {
          await session.db.unsafeExecute('''
            UPDATE icinga2_sync_progress SET started_at=clock_timestamp()-interval '${5 * (step % 12 == 0 ? 12 : step % 12)} seconds'
            WHERE sync_id=(SELECT sync_id FROM icinga2_sync_progress ORDER BY started_at DESC LIMIT 1)
          ''');
          await server.subscriptions.last.close();
          await _until(
            () async {
              final current = await status.read(icinga2DbSourceId);
              return current!.connectionSeq == step + 1 &&
                  server.subscriptionsReady == step + 1;
            },
            'Missing subscription ${step + 1}; logs: $messages',
          );
          if (step % 12 == 0) await ready(status);
        }
        final current = (await status.read(icinga2DbSourceId))!;
        expect(current.connectionSeq, 120);
        expect(current.gapCount, 119);
        expect(await countRows(session, 'icinga2_sync_progress'), 10);
      }, timeout: const Timeout(Duration(minutes: 2)));
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
