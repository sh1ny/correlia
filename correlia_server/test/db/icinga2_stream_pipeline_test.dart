import 'dart:async';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart' as webhook;
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_decode_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/ingest_schema.dart';

void main() {
  withServerpod(
    'stream pipeline reconcile persistence',
    (builder, _) {
      late Session session;
      late String snapshot;
      final now = streamDbNow;
      DateTime before(int seconds) => now.subtract(Duration(seconds: seconds));

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
        snapshot = await publishStreamDb(session);
      });

      Future<void> progress(int rows) => session.db.unsafeExecute('''
      INSERT INTO icinga2_sync_progress(sync_id,source_id,phase,rows_admitted,started_at)
      VALUES ('$streamDbSyncId','$icinga2DbSourceId','reading',$rows,now())
    ''');

      Future<String> process(
        List<Map<String, Object?>> checks, {
        bool sync = false,
      }) async {
        final raw = await seedStreamDb(session, snapshot, checks, sync: sync);
        await processIcinga2(session, now);
        return raw;
      }

      Future<void> firing() async {
        await process([streamDbCheck(before(60))]);
        expect((await theAlert(session))['status'], 'firing');
      }

      Future<Map<String, Object?>> counts() async => (await queryRows(
        session,
        "SELECT rows_done,rows_failed,counts->>'confirmed' AS confirmed,counts->>'tombstoned' AS tombstoned FROM icinga2_sync_progress WHERE sync_id='$streamDbSyncId'",
      )).single;

      test('silent_reconcile_leaves_no_key', () async {
        await firing();
        await progress(1);
        await session.db.unsafeExecute(
          '''UPDATE icinga2_sync_progress SET counts='{"bad_objects":4}' ''',
        );
        final original = await theAlert(session);
        final raw = await process([
          streamDbCheck(before(30), sync: true),
        ], sync: true);
        expect(await countRows(session, 'observation_keys'), 1);
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'outbox'), 1);
        expect(await countRows(session, 'activity'), 1);
        expect(await countRows(session, 'raw_inbox'), 1);
        expect(
          await queryRows(
            session,
            "SELECT raw_id FROM icinga2_raw_origin WHERE raw_id='$raw'",
          ),
          isEmpty,
        );
        expect(await counts(), containsPair('confirmed', '1'));
        expect((await counts())['rows_done'], 1);
        expect(
          (await queryRows(
            session,
            "SELECT counts->>'bad_objects' AS skipped FROM icinga2_sync_progress",
          )).single['skipped'],
          '4',
        );
        final confirmed = await theAlert(session);
        for (final key in [
          'version',
          'summary',
          'sourceInstance',
          'updatedAt',
        ]) {
          expect(confirmed[key], original[key], reason: key);
        }
        expect(
          (await theAlert(session))['fenceEffectiveSeconds'],
          before(30).millisecondsSinceEpoch ~/ 1000,
        );
      });

      test('hourly_sync_of_a_steady_installation', () async {
        const batches = 100;
        const items = 100;
        await progress(batches);
        for (var batch = 0; batch < batches; batch++) {
          await process([
            for (var item = 0; item < items; item++)
              streamDbCheck(
                before(60),
                state: 0,
                service: 'service-${batch * items + item}',
                sync: true,
              ),
          ], sync: true);
        }
        expect(await countRows(session, 'alerts'), 10000);
        expect(await counts(), containsPair('tombstoned', '10000'));
        await session.db.unsafeExecute(
          "UPDATE icinga2_sync_progress SET rows_done=0,counts='{}'",
        );
        for (var batch = 0; batch < batches; batch++) {
          await process([
            for (var item = 0; item < items; item++)
              streamDbCheck(
                before(59),
                state: 0,
                service: 'service-${batch * items + item}',
                sync: true,
              ),
          ], sync: true);
        }
        expect(
          await counts(),
          allOf(
            containsPair('confirmed', '10000'),
            containsPair('rows_done', batches),
          ),
        );
        for (final table in [
          'events',
          'observation_keys',
          'outbox',
          'raw_inbox',
          'activity',
        ]) {
          expect(await countRows(session, table), 0, reason: table);
        }
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('sync_with_one_repair', () async {
        await firing();
        await process([
          for (var i = 0; i < 99; i++)
            streamDbCheck(before(60), service: 'unchanged-$i'),
        ]);
        await progress(1);
        final raw = await process([
          streamDbCheck(before(30), state: 0, sync: true),
          for (var i = 0; i < 99; i++)
            streamDbCheck(before(30), service: 'unchanged-$i', sync: true),
        ], sync: true);
        expect(
          (await queryRows(
            session,
            "SELECT count(*) AS repaired FROM alerts WHERE status='resolved' AND version=2",
          )).single['repaired'],
          1,
        );
        expect(
          await outcomeOf(session, raw),
          allOf(
            containsPair('confirmed', 99),
            containsPair('repaired', 1),
          ),
        );
        for (final table in ['events', 'outbox', 'activity']) {
          expect(await countRows(session, table), 101, reason: table);
        }
      });

      test('older_stream_problem_after_a_tombstone', () async {
        await progress(1);
        await process([
          streamDbCheck(before(30), state: 0, sync: true),
        ], sync: true);
        expect(await counts(), containsPair('tombstoned', '1'));
        expect(await countRows(session, 'events'), 0);
        final raw = await process([streamDbCheck(before(60))]);
        expect(await outcomeOf(session, raw), containsPair('stale', 1));
        expect((await theAlert(session))['status'], 'resolved');
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'outbox'), 0);
        expect(await countRows(session, 'activity'), 0);
      });

      test('stale_webhook_observation', () async {
        await clearPipelineTables(session);
        snapshot = await publishStreamDb(session, shared: true);
        await firing();
        final raw = await seedIcinga2(
          session,
          webhook.delivery(
            set: {
              'host': 'stream-host',
              'service': 'stream-service',
              'last_state_change': timeText(before(120)),
              'notification_time': timeText(before(120)),
            },
          ),
          now,
          source: icinga2OtherDbSourceId,
        );
        await processIcinga2(session, now);
        expect(await outcomeOf(session, raw), containsPair('stale', 1));
        expect(
          await queryRows(
            session,
            "SELECT state_outcome FROM events WHERE raw_id='$raw'",
          ),
          [
            {'state_outcome': 'stale'},
          ],
        );
        expect(await countRows(session, 'events'), 2);
        expect(await countRows(session, 'outbox'), 2);
        expect(await countRows(session, 'activity'), 1);
      });

      test('original severity drives state and sync', () async {
        await clearPipelineTables(session);
        snapshot = await publishStreamDb(
          session,
          matcher: _matcher([
            {
              'type': 'map_severity',
              'values': {'critical': 'info'},
            },
          ]),
        );
        await firing();
        expect((await theAlert(session))['severity'], 'critical');
        final data = await session.db.unsafeQuery('SELECT payload FROM events');
        final event = CloudEvent.decode(data.single[0] as Uint8List).event;
        expect(event.severity, EventSeverity.info);
        await progress(1);
        await process([streamDbCheck(before(30), sync: true)], sync: true);
        expect(await counts(), containsPair('confirmed', '1'));
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'outbox'), 1);
        expect((await theAlert(session))['severity'], 'critical');
      });

      test('stale webhook routes but stale stream does not', () async {
        const output = '99999999-9999-4999-8999-999999999999';
        await clearPipelineTables(session);
        snapshot = await publishStreamDb(
          session,
          shared: true,
          matcherOutput: output,
          matcher: _matcher([
            {'type': 'route', 'output_id': output},
          ]),
        );
        await firing();
        final staleStream = await process([streamDbCheck(before(120))]);
        final staleWebhook = await seedIcinga2(
          session,
          webhook.delivery(
            set: {
              'host': 'stream-host',
              'service': 'stream-service',
              'last_state_change': timeText(before(121)),
              'notification_time': timeText(before(121)),
            },
          ),
          now,
          source: icinga2OtherDbSourceId,
        );
        await processIcinga2(session, now);
        Future<List<Map<String, Object?>>> routes(String raw) => queryRows(
          session,
          '''SELECT output_id::text AS output FROM outbox
JOIN events ON events.event_id=outbox.event_id AND events.observed_at=outbox.event_observed_at
WHERE raw_id='$raw' ORDER BY output_id''',
        );
        expect(await outcomeOf(session, staleStream), containsPair('stale', 1));
        expect(
          await outcomeOf(session, staleWebhook),
          containsPair('stale', 1),
        );
        expect(await routes(staleStream), isEmpty);
        expect(
          (await routes(staleWebhook)).map((row) => row['output']),
          unorderedEquals([icinga2DbOutputIds.first, output]),
        );
      });

      test('webhook_rows_unchanged', () async {
        await clearPipelineTables(session);
        snapshot = await publishStreamDb(session, shared: true);
        final raw = await seedIcinga2(
          session,
          webhook.delivery(
            set: {
              'last_state_change': timeText(before(60)),
              'notification_time': timeText(before(60)),
            },
          ),
          now,
          source: icinga2OtherDbSourceId,
        );
        await processIcinga2(session, now);
        expect(await outcomeOf(session, raw), {
          'upstream_omitted': 0,
          'unknown_top_level_fields': const <String>[],
          'unknown_top_level_overflow': 0,
          'committed': 1,
          'unrouted': 0,
          'duplicate_observation': 0,
          'future_dated': 0,
          'duplicate_quarantine': 0,
          'late': 0,
          'applied': 1,
          'stale': 0,
          'clamped': 0,
        });
      });

      test('mixed_sync_row', () async {
        await firing();
        await process([streamDbCheck(before(60), service: 'repair')]);
        await process([streamDbCheck(before(30), service: 'stale')]);
        await progress(1);
        final raw = await process([
          streamDbCheck(before(20), sync: true),
          streamDbCheck(before(20), state: 0, service: 'repair', sync: true),
          streamDbCheck(before(20), state: 0, service: 'tombstone', sync: true),
          streamDbCheck(before(40), state: 0, service: 'stale', sync: true),
        ], sync: true);
        final result = await outcomeOf(session, raw);
        for (final key in ['confirmed', 'repaired', 'tombstoned', 'stale']) {
          expect(result[key], 1, reason: key);
        }
        expect(await countRows(session, 'events'), 4);
        expect(await countRows(session, 'observation_keys'), 4);
        expect(await countRows(session, 'outbox'), 4);
      });

      test('clamped_silent_reconcile', () async {
        await firing();
        await progress(1);
        await process([
          streamDbCheck(now.add(const Duration(minutes: 30)), sync: true),
        ], sync: true);
        final stats = await queryRows(session, '''
          SELECT counts->>'clamped' AS clamped,counts->>'confirmed' AS confirmed
          FROM icinga2_sync_progress
        ''');
        expect(stats.single, {'clamped': '1', 'confirmed': '1'});
        expect(
          (await theAlert(session))['fenceEffectiveSeconds'],
          now.millisecondsSinceEpoch ~/ 1000 + 300,
        );
        expect(await countRows(session, 'events'), 1);
      });

      test('late_or_future_stream_item', () async {
        final raw = await process([
          streamDbCheck(now.subtract(const Duration(days: 8))),
          streamDbCheck(now.add(const Duration(days: 2))),
        ]);
        expect(await outcomeOf(session, raw), containsPair('late', 1));
        expect(await outcomeOf(session, raw), containsPair('future_dated', 1));
        for (final table in [
          'events',
          'observation_keys',
          'alerts',
          'outbox',
        ]) {
          expect(await countRows(session, table), 0, reason: table);
        }
        await progress(1);
        await process([
          streamDbCheck(now.subtract(const Duration(days: 8)), sync: true),
          streamDbCheck(now.add(const Duration(days: 2)), sync: true),
        ], sync: true);
        expect(
          (await queryRows(session, '''
          SELECT rows_done,counts->>'late' AS late,counts->>'future_dated' AS future,
            counts->>'diverged' AS diverged FROM icinga2_sync_progress
        ''')).single,
          {'rows_done': 1, 'late': '1', 'future': '1', 'diverged': '2'},
        );
        expect(await countRows(session, 'raw_inbox'), 1);
        expect(await countRows(session, 'events'), 0);
      });

      test('stream_and_sync_copies_of_one_result_at_once', () async {
        await progress(1);
        final start = before(30);
        await seedStreamDb(session, snapshot, [streamDbCheck(start)]);
        await seedStreamDb(session, snapshot, [
          streamDbCheck(start, sync: true),
        ], sync: true);
        final firstClaim = Completer<void>();
        final secondClaim = Completer<void>();
        final first = PipelineRepository(
          builder.build(),
          clock: () => now,
          afterClaim: () async {
            firstClaim.complete();
            await secondClaim.future;
          },
        );
        final second = PipelineRepository(
          builder.build(),
          clock: () => now,
          afterClaim: () async {
            secondClaim.complete();
            await firstClaim.future;
          },
        );
        expect(await first.pinOne(), isTrue);
        expect(await first.pinOne(), isTrue);
        expect(
          await Future.wait([first.processOne(), second.processOne()]),
          everyElement(isTrue),
        );
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'observation_keys'), 1);
        expect(await countRows(session, 'outbox'), 1);
        expect(await countRows(session, 'pipeline_failures'), 0);
        expect((await counts())['rows_done'], 1);
      });

      test('deadlock_retried', () async {
        final raw = await seedStreamDb(session, snapshot, [
          streamDbCheck(before(30)),
        ]);
        await session.db.unsafeSimpleExecute('''
          CREATE FUNCTION fail_test_event_once() RETURNS trigger LANGUAGE plpgsql AS \$\$
          BEGIN RAISE EXCEPTION USING ERRCODE='40P01', MESSAGE='test retry'; END; \$\$;
          CREATE TRIGGER fail_test_event_once BEFORE INSERT ON events
            FOR EACH ROW WHEN (NEW.raw_id = '$raw') EXECUTE FUNCTION fail_test_event_once();
        ''');
        final pipeline = PipelineRepository(
          session,
          clock: () => now,
          retryDelay: (_) => Duration.zero,
        );
        expect(await pipeline.pinOne(), isTrue);
        try {
          expect(await pipeline.processOne(), isTrue);
          expect(await countRows(session, 'observation_keys'), 0);
          expect(await countRows(session, 'alerts'), 0);
          final pending = (await queryRows(
            session,
            "SELECT status, attempt_count FROM raw_inbox WHERE raw_id='$raw'",
          )).single;
          expect(pending, {'status': 'pending', 'attempt_count': 0});
        } finally {
          await session.db.unsafeSimpleExecute(
            'DROP FUNCTION fail_test_event_once() CASCADE',
          );
        }
        expect(await pipeline.processOne(), isTrue);
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'activity'), 1);
        expect(await countRows(session, 'outbox'), 1);
      });

      test('sync_row_that_stored_nothing', () async {
        await firing();
        await progress(1);
        final raw = await seedStreamDb(session, snapshot, [
          streamDbCheck(before(30), sync: true),
        ], sync: true);
        final pipeline = PipelineRepository(
          session,
          clock: () => now,
          retryDelay: (_) => Duration.zero,
        );
        expect(await pipeline.pinOne(), isTrue);
        await session.db.unsafeSimpleExecute('''
        CREATE FUNCTION reject_test_sync_delete() RETURNS trigger LANGUAGE plpgsql AS \$\$
        BEGIN RAISE EXCEPTION 'test raw delete refusal'; END; \$\$;
        CREATE TRIGGER reject_test_sync_delete BEFORE DELETE ON raw_inbox
          FOR EACH ROW WHEN (OLD.raw_id = '$raw') EXECUTE FUNCTION reject_test_sync_delete();
      ''');
        try {
          expect(await pipeline.processOne(), isTrue);
          expect((await counts())['rows_done'], 0);
          expect((await counts())['rows_failed'], 0);
          expect((await counts())['confirmed'], isNull);
          expect(
            (await theAlert(session))['fenceEffectiveSeconds'],
            before(60).millisecondsSinceEpoch ~/ 1000,
          );
          expect(
            await queryRows(
              session,
              "SELECT status FROM raw_inbox WHERE raw_id='$raw'",
            ),
            [
              {'status': 'pending'},
            ],
          );
        } finally {
          await session.db.unsafeSimpleExecute(
            'DROP FUNCTION reject_test_sync_delete() CASCADE',
          );
        }
        expect(await pipeline.processOne(), isTrue);
        expect(
          await queryRows(
            session,
            "SELECT raw_id FROM raw_inbox WHERE raw_id='$raw'",
          ),
          isEmpty,
        );
        expect(
          await counts(),
          allOf(containsPair('rows_done', 1), containsPair('confirmed', '1')),
        );
        expect(await pipeline.processOne(), isFalse);
        expect((await counts())['rows_done'], 1);
      });

      test('acknowledgement_publishes_without_alert_change', () async {
        await firing();
        final initial = await theAlert(session);
        final lines = capturedStreamEvents(streamCaptures.last).where(
          (line) => (line['type']! as String).startsWith('Acknowledgement'),
        );
        for (final line in lines) {
          await process([
            {...line, 'timestamp': now.millisecondsSinceEpoch / 1000},
          ]);
        }
        expect(await theAlert(session), initial);
        expect(await countRows(session, 'outbox'), 3);
        expect(await countRows(session, 'activity'), 1);
      });

      test('stale_sync_item_before_an_eligible_stream_copy', () async {
        await firing();
        final first = now.add(const Duration(minutes: 1));
        await seedStreamDb(session, snapshot, [
          streamDbCheck(now.add(const Duration(minutes: 6))),
        ], observed: first);
        await processIcinga2(session, first);
        await progress(1);
        final start = now.add(const Duration(minutes: 30));
        final sync = await seedStreamDb(session, snapshot, [
          streamDbCheck(start, state: 0, sync: true),
        ], sync: true);
        await processIcinga2(session, now);
        expect(
          await queryRows(
            session,
            "SELECT raw_id FROM raw_inbox WHERE raw_id='$sync'",
          ),
          isEmpty,
        );
        final receipt = now.add(const Duration(minutes: 2));
        await seedStreamDb(session, snapshot, [
          streamDbCheck(start, state: 0),
        ], observed: receipt);
        await processIcinga2(session, receipt);
        expect((await theAlert(session))['status'], 'resolved');
        expect(await countRows(session, 'outbox'), 3);
      });

      test('stale_stream_copy_beyond_the_skew', () async {
        for (final syncFirst in [false, true]) {
          await clearPipelineTables(session);
          snapshot = await publishStreamDb(session);
          final first = now.add(const Duration(minutes: 1));
          await seedStreamDb(session, snapshot, [
            streamDbCheck(now.add(const Duration(minutes: 6))),
          ], observed: first);
          await processIcinga2(session, first);
          await progress(1);
          final start = now.add(const Duration(minutes: 30));
          Future<void> resync() async {
            final receipt = now.add(const Duration(minutes: 2));
            await seedStreamDb(
              session,
              snapshot,
              [
                streamDbCheck(start, state: 0, sync: true),
              ],
              observed: receipt,
              sync: true,
            );
            await processIcinga2(session, receipt);
          }

          if (syncFirst) await resync();
          final raw = await process([streamDbCheck(start, state: 0)]);
          if (!syncFirst) await resync();
          expect(
            await outcomeOf(session, raw),
            containsPair(syncFirst ? 'duplicate_observation' : 'stale', 1),
          );
          expect(
            (await theAlert(session))['status'],
            syncFirst ? 'resolved' : 'firing',
          );
          expect(await countRows(session, 'observation_keys'), 2);
          expect(await countRows(session, 'outbox'), syncFirst ? 2 : 1);
        }
      });

      test('terminal_sync_failure_is_counted_once', () async {
        await progress(1);
        final raw = await seedStreamDb(session, snapshot, [
          {'type': 'Unknown'},
        ], sync: true);
        await processIcinga2(session, now);
        expect(
          await queryRows(
            session,
            "SELECT status FROM raw_inbox WHERE raw_id='$raw'",
          ),
          [
            {'status': 'failed'},
          ],
        );
        expect(
          await counts(),
          allOf(containsPair('rows_done', 0), containsPair('rows_failed', 1)),
        );
        expect(
          await PipelineRepository(session, clock: () => now).processOne(),
          isFalse,
        );
        expect((await counts())['rows_failed'], 1);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}

Map<String, Object?> _matcher(List<Map<String, Object?>> actions) => {
  'language': 'matcher',
  'version': 1,
  'rules': [
    {
      'id': 'example',
      'when': {'field': 'summary', 'op': 'exists'},
      'actions': actions,
    },
  ],
};
