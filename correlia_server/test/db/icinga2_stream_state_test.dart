import 'dart:convert';

import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart' as webhook;
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/ingest_schema.dart';

void main() {
  withServerpod(
    'stream alert-state fences',
    (builder, _) {
      late Session session;
      late String snapshot;
      final now = streamDbNow;
      final older = now.subtract(const Duration(minutes: 2));
      final newer = now.subtract(const Duration(minutes: 1));

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
        snapshot = await publishStreamDb(session);
      });

      Future<void> syncProgress() => session.db.unsafeExecute('''
      INSERT INTO icinga2_sync_progress(sync_id,source_id,phase,rows_admitted,started_at)
      VALUES ('$streamDbSyncId','$icinga2DbSourceId','reading',1,now())
    ''');

      Future<String> deliver(
        Map<String, Object?> line, {
        String? admissionSnapshot,
        DateTime? receipt,
        bool sync = false,
      }) async {
        if (sync) await syncProgress();
        final id = await seedStreamDb(
          session,
          admissionSnapshot ?? snapshot,
          [line],
          sync: sync,
          observed: receipt,
        );
        await processIcinga2(session, receipt ?? now);
        return id;
      }

      test('keyed_sync_copy_of_the_losing_result', () async {
        await deliver(streamDbCheck(older, state: 0));
        await deliver(
          streamDbCheck(older),
          receipt: now.add(const Duration(seconds: 1)),
        );
        final prior = await theAlert(session);
        await deliver(
          streamDbCheck(older, state: 0, sync: true),
          sync: true,
          receipt: now.add(const Duration(seconds: 2)),
        );
        final after = await theAlert(session);
        expect(after['status'], 'firing');
        expect(after['version'], prior['version']);
        expect(await countRows(session, 'events'), 2);
        final counts = (await queryRows(session, '''SELECT
        counts->>'diverged' AS divergence,
        counts->>'duplicate_observation' AS duplicate FROM icinga2_sync_progress
      ''')).single;
        expect(counts, containsPair('divergence', '1'));
        expect(counts, containsPair('duplicate', '1'));
      });

      test('late_stream_item_after_resolution', () async {
        await deliver(streamDbCheck(older, state: 0));
        final original = await theAlert(session);
        final late = await deliver(
          streamDbCheck(now.subtract(const Duration(days: 8))),
        );
        expect(await outcomeOf(session, late), containsPair('late', 1));
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'observation_keys'), 1);
        expect(await theAlert(session), original);
      });

      test('host_raw_warning_resolves_alert', () async {
        await deliver(streamDbCheck(older, service: null));
        expect((await theAlert(session))['status'], 'firing');
        await deliver(streamDbCheck(newer, state: 1, service: null));
        final alert = await theAlert(session);
        expect(alert['status'], 'resolved');
        expect(alert['summary'], 'stream-host UP');
      });

      test('hard_only_stores_no_soft_problem', () async {
        final hard = await publishStreamDb(
          session,
          revision: 2,
          policy: 'hard_only',
        );
        final soft = await deliver(
          streamDbCheck(older, stateType: 0),
          admissionSnapshot: hard,
        );
        expect(await outcomeOf(session, soft), containsPair('soft_info', 1));
        for (final table in [
          'events',
          'observation_keys',
          'alerts',
          'outbox',
        ]) {
          expect(await countRows(session, table), 0, reason: table);
        }
        await deliver(streamDbCheck(newer, state: 0), admissionSnapshot: hard);
        expect((await theAlert(session))['status'], 'resolved');
      });

      test('soft_and_hard_fires_then_resolves', () async {
        await deliver(streamDbCheck(older, stateType: 0));
        expect((await theAlert(session))['status'], 'firing');
        await deliver(streamDbCheck(newer, state: 0));
        expect((await theAlert(session))['status'], 'resolved');
      });

      test('missed_recovery_leaves_alert_firing', () async {
        final hard = await publishStreamDb(
          session,
          revision: 2,
          policy: 'hard_only',
        );
        await deliver(streamDbCheck(older), admissionSnapshot: hard);
        await deliver(
          streamDbCheck(newer, stateType: 0, sync: true),
          admissionSnapshot: hard,
          sync: true,
        );
        expect((await theAlert(session))['status'], 'firing');
        expect(await countRows(session, 'events'), 1);
        final counts = (await queryRows(session, '''SELECT
        counts->>'soft_info' AS soft,coalesce(counts->>'diverged','0') AS divergence
        FROM icinga2_sync_progress
      ''')).single;
        expect(counts, containsPair('soft', '1'));
        expect(counts, containsPair('divergence', '0'));
      });

      test('copies_of_one_result_under_two_policies', () async {
        for (final strictFirst in [true, false]) {
          await clearPipelineTables(session);
          final strict = await publishStreamDb(session, policy: 'hard_only');
          final permissive = await publishStreamDb(session, revision: 2);
          final copy = streamDbCheck(newer, stateType: 0);
          final first = await deliver(
            copy,
            admissionSnapshot: strictFirst ? strict : permissive,
          );
          final last = await deliver(
            copy,
            admissionSnapshot: strictFirst ? permissive : strict,
          );
          expect(
            await outcomeOf(session, strictFirst ? first : last),
            containsPair('soft_info', 1),
          );
          expect((await theAlert(session))['status'], 'firing');
          expect(await countRows(session, 'events'), 1);
          expect(await countRows(session, 'observation_keys'), 1);
        }
      });

      test(
        'recovery_by_sync_before_an_older_stream_problem_on_an_empty_database',
        () async {
          for (final syncFirst in [true, false]) {
            await clearPipelineTables(session);
            snapshot = await publishStreamDb(session);
            final recovery = streamDbCheck(newer, state: 0, sync: true);
            if (syncFirst) await deliver(recovery, sync: true);
            final old = await deliver(streamDbCheck(older));
            if (!syncFirst) await deliver(recovery, sync: true);
            expect((await theAlert(session))['status'], 'resolved');
            expect(
              await outcomeOf(session, old),
              containsPair('stale', syncFirst ? 1 : 0),
            );
            expect(await countRows(session, 'outbox'), syncFirst ? 0 : 2);
          }
        },
      );

      test('stream_copy_after_a_silent_confirm', () async {
        for (final syncFirst in [true, false]) {
          await clearPipelineTables(session);
          snapshot = await publishStreamDb(session);
          if (!syncFirst) await deliver(streamDbCheck(older));
          await deliver(streamDbCheck(newer, sync: true), sync: true);
          final receipt = now.add(const Duration(seconds: 1));
          final copy = await deliver(streamDbCheck(newer), receipt: receipt);
          if (syncFirst) await deliver(streamDbCheck(older));
          final alert = await theAlert(session);
          expect(
            alert['fenceEffectiveSeconds'],
            newer.millisecondsSinceEpoch ~/ 1000,
          );
          expect(
            alert['fenceObservedSeconds'],
            (syncFirst ? now : receipt).millisecondsSinceEpoch ~/ 1000,
          );
          expect(
            await outcomeOf(session, copy),
            containsPair('duplicate_observation', syncFirst ? 1 : 0),
          );
        }
      });

      test('webhook_and_sync_in_both_orders', () async {
        for (final webhookFirst in [true, false]) {
          await clearPipelineTables(session);
          snapshot = await publishStreamDb(session, shared: true);
          Future<void> notify() async {
            await seedIcinga2(
              session,
              webhook.delivery(
                set: {
                  'host': 'stream-host',
                  'service': 'stream-service',
                  'last_state_change': timeText(older),
                  'notification_time': timeText(older),
                },
              ),
              now,
              source: icinga2OtherDbSourceId,
            );
            await processIcinga2(session, now);
          }

          if (webhookFirst) await notify();
          await deliver(streamDbCheck(newer, sync: true), sync: true);
          if (!webhookFirst) await notify();
          expect(
            await theAlert(session),
            allOf(
              containsPair('status', 'firing'),
              containsPair('severity', 'critical'),
              containsPair(
                'fenceEffectiveSeconds',
                newer.millisecondsSinceEpoch ~/ 1000,
              ),
              containsPair(
                'sourceInstance',
                webhookFirst ? icinga2OtherDbSourceId : icinga2DbSourceId,
              ),
            ),
          );
        }
      });

      test('equal_start_times', () async {
        final start = newer.millisecondsSinceEpoch ~/ 1000;
        for (final nanos in [0, 238]) {
          for (final sameReceipt in [false, true]) {
            await clearPipelineTables(session);
            snapshot = await publishStreamDb(session);
            final secondReceipt = sameReceipt
                ? now
                : now.add(const Duration(seconds: 1));
            final first = await deliver(streamDbCheck(newer));
            final next = await seedStreamDb(
              session,
              snapshot,
              [
                streamDbCheck(newer, state: 0),
              ],
              observed: secondReceipt,
              encodeLine: (json) => jsonEncode(json).replaceFirst(
                '"execution_start":$start.0',
                '"execution_start":$start.${nanos.toString().padLeft(9, '0')}',
              ),
            );
            await processIcinga2(session, secondReceipt);
            final ids = await queryRows(
              session,
              'SELECT raw_id::text,event_id::text FROM events',
            );
            final byRaw = {
              for (final row in ids) row['raw_id']: row['event_id']! as String,
            };
            final secondWins =
                !sameReceipt || byRaw[next]!.compareTo(byRaw[first]!) > 0;
            expect(
              await theAlert(session),
              allOf(
                containsPair('fenceEffectiveSeconds', start),
                containsPair('fenceEffectiveNanos', 0),
                containsPair('fenceEventId', byRaw[secondWins ? next : first]),
                containsPair('status', secondWins ? 'resolved' : 'firing'),
              ),
            );
          }
        }
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
