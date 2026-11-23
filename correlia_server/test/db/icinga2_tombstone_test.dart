import 'dart:async';

import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/state/tombstone_sweep.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart' as webhook;
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/ingest_schema.dart';

void main() {
  withServerpod(
    'stream tombstone reclamation',
    (builder, _) {
      late Session session;
      final boundary = streamDbNow;
      final fence = boundary.subtract(const Duration(days: 7));

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
      });

      Future<void> mark(
        int count,
        DateTime at, {
        bool silent = true,
        int offset = 0,
      }) => session.db.unsafeExecute(
        '''INSERT INTO alerts
          (tenant,fingerprint,status,severity,summary,"sourceInstance","fenceEffectiveSeconds",
           "fenceEffectiveNanos","fenceObservedSeconds","fenceObservedNanos","fenceEventId",
           "lastObservedAt",version,"createdAt","updatedAt",silent_tombstone)
          SELECT 'default',lpad((n + @offset)::text,64,'0'),'resolved','info','tombstone',
            '$icinga2DbSourceId',@second,0,@second,0,gen_random_uuid(),@at,1,@at,@at,@silent
          FROM generate_series(1,@count) n''',
        parameters: QueryParameters.named({
          'count': count,
          'at': at,
          'second': at.millisecondsSinceEpoch ~/ 1000,
          'offset': offset,
          'silent': silent,
        }),
      );

      Future<int> sweep() => TombstoneSweep(
        session,
        clock: () => boundary.add(const Duration(hours: 1)),
      ).runOnce();

      Future<void> rawAt(Session writer, DateTime receipt, {Transaction? tx}) =>
          writer.db.unsafeExecute(
            '''INSERT INTO raw_inbox
          (observed_at,raw_id,source_id,body,body_sha256,content_type)
          VALUES (@receipt,gen_random_uuid(),'$icinga2OtherDbSourceId',decode('00','hex'),'test','application/json')''',
            parameters: QueryParameters.named({'receipt': receipt}),
            transaction: tx,
          );

      test('objects_deleted_upstream', () async {
        await mark(100000, fence.subtract(const Duration(seconds: 1)));
        await mark(
          100000,
          fence.add(const Duration(seconds: 1)),
          offset: 100000,
        );
        expect(await sweep(), 500);
        expect(await countRows(session, 'alerts'), 199500);
        for (var pass = 1; pass < 200; pass++) {
          expect(await sweep(), 500, reason: 'pass $pass');
        }
        expect(await sweep(), 0);
        expect(await countRows(session, 'alerts'), 100000);
        expect(
          await session.db
              .unsafeQuery(
                'SELECT DISTINCT "fenceEffectiveSeconds" FROM alerts',
              )
              .then((rows) => rows.single[0]),
          fence.millisecondsSinceEpoch ~/ 1000 + 1,
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('tombstone_at_horizon_is_not_reclaimed', () async {
        await mark(1, fence);
        expect(await sweep(), 0);
        expect(await countRows(session, 'alerts'), 1);
      });

      test('ordinary_resolution_keeps_fence', () async {
        await mark(1, fence.subtract(const Duration(days: 1)), silent: false);
        expect(await sweep(), 0);
        expect(await countRows(session, 'alerts'), 1);
      });

      test('pending_problem_keeps_tombstone', () async {
        await mark(1, fence.subtract(const Duration(seconds: 1)));
        await rawAt(session, fence.add(const Duration(seconds: 1)));
        expect(await sweep(), 0);
        expect(await countRows(session, 'alerts'), 1);
        await session.db.unsafeExecute("UPDATE raw_inbox SET status='done'");
        expect(await sweep(), 1);
      });

      Future<String> actualTombstone({bool shared = false}) async {
        final snapshot = await publishStreamDb(session, shared: shared);
        await session.db.unsafeExecute('''INSERT INTO icinga2_sync_progress
          (sync_id,source_id,phase,rows_admitted,started_at)
          VALUES ('$streamDbSyncId','$icinga2DbSourceId','reading',1,now())''');
        final time = fence.subtract(const Duration(seconds: 1));
        await seedStreamDb(
          session,
          snapshot,
          [streamDbCheck(time, state: 0, sync: true)],
          sync: true,
          observed: time,
        );
        await processIcinga2(session, time);
        expect((await theAlert(session))['silent_tombstone'], true);
        return snapshot;
      }

      test('older_problem_after_reclamation', () async {
        final snapshot = await actualTombstone();
        expect(await sweep(), 1);
        final raw = await seedStreamDb(session, snapshot, [
          streamDbCheck(fence.subtract(const Duration(seconds: 2))),
        ], observed: boundary);
        await processIcinga2(session, boundary);
        expect(await outcomeOf(session, raw), containsPair('late', 1));
        for (final table in ['events', 'alerts', 'observation_keys']) {
          expect(await countRows(session, table), 0, reason: table);
        }
      });

      test('refire_keeps_alert_identity', () async {
        final snapshot = await actualTombstone();
        final initial = await theAlert(session);
        await seedStreamDb(session, snapshot, [
          streamDbCheck(boundary),
        ], observed: boundary);
        await processIcinga2(session, boundary);
        final refired = await theAlert(session);
        expect(refired['id'], initial['id']);
        expect(refired['version'], (initial['version']! as int) + 1);
        expect(refired['silent_tombstone'], false);
        expect(await sweep(), 0);
      });

      test('retries_alert_acquisition_after_sweep', () async {
        final snapshot = await actualTombstone();
        final previousId = (await theAlert(session))['id'];
        await seedStreamDb(session, snapshot, [
          streamDbCheck(boundary),
        ], observed: boundary);
        final conflicted = Completer<void>();
        final release = Completer<void>();
        final worker = PipelineRepository(
          builder.build(),
          clock: () => boundary,
          afterAlertInsertConflict: () {
            if (!conflicted.isCompleted) conflicted.complete();
            return release.future;
          },
        );
        expect(await worker.pinOne(), isTrue);
        final processing = worker.processOne();
        try {
          await Future.any([conflicted.future, processing]);
          expect(conflicted.isCompleted, isTrue);
          expect(await sweep(), 1);
        } finally {
          release.complete();
          await processing;
        }
        final alert = await theAlert(session);
        expect(alert['id'], isNot(previousId));
        expect(alert['version'], 1);
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'activity'), 1);
        expect(await countRows(session, 'outbox'), 1);
      });

      Future<void> sweepDuringKeyReservation() async {
        final worker = PipelineRepository(
          builder.build(),
          clock: () => boundary,
        );
        expect(await worker.pinOne(), isTrue);
        const lock = 1129271990;
        await session.db.unsafeSimpleExecute('''
          CREATE FUNCTION wait_test_reservation() RETURNS trigger LANGUAGE plpgsql AS \$\$
          BEGIN PERFORM pg_advisory_xact_lock($lock); RETURN NEW; END; \$\$;
          CREATE TRIGGER wait_test_reservation AFTER INSERT ON observation_keys
            FOR EACH ROW EXECUTE FUNCTION wait_test_reservation();
        ''');
        final held = Completer<void>();
        final release = Completer<void>();
        final locker = builder.build();
        final gate = locker.db.transaction((tx) async {
          await locker.db.unsafeQuery(
            'SELECT pg_advisory_xact_lock($lock)',
            transaction: tx,
          );
          held.complete();
          await release.future;
        });
        await held.future;
        final writing = worker.processOne();
        try {
          final elapsed = Stopwatch()..start();
          while (true) {
            final rows = await session.db.unsafeQuery('''SELECT 1 FROM pg_locks
              WHERE locktype='advisory' AND objid=$lock AND NOT granted''');
            if (rows.isNotEmpty) break;
            if (elapsed.elapsed > const Duration(seconds: 3)) {
              fail('Worker did not reserve the key before alert acquisition');
            }
          }
          expect(await sweep(), 1);
        } finally {
          release.complete();
          await gate;
          await writing;
          await session.db.unsafeSimpleExecute(
            'DROP FUNCTION wait_test_reservation() CASCADE',
          );
        }
      }

      test('provisional_key_does_not_prevent_reclamation', () async {
        final snapshot = await actualTombstone();
        final previousId = (await theAlert(session))['id'];
        await seedStreamDb(session, snapshot, [
          streamDbCheck(boundary),
        ], observed: boundary);
        await sweepDuringKeyReservation();
        final alert = await theAlert(session);
        expect(alert['id'], isNot(previousId));
        expect(alert['version'], 1);
        expect(alert['status'], 'firing');
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'outbox'), 1);
        expect(await countRows(session, 'activity'), 1);
      });

      Future<String> seedWebhook(DateTime start, DateTime receipt) =>
          seedIcinga2(
            session,
            webhook.delivery(
              set: {
                'host': 'stream-host',
                'service': 'stream-service',
                'last_state_change': timeText(start),
                'notification_time': timeText(start),
              },
            ),
            receipt,
            source: icinga2OtherDbSourceId,
          );

      test('pending_webhook_keeps_shared_tombstone', () async {
        await actualTombstone(shared: true);
        await seedWebhook(fence.subtract(const Duration(seconds: 2)), fence);
        expect(await sweep(), 0);
        await processIcinga2(session, boundary);
        expect((await theAlert(session))['status'], 'resolved');
      });

      test('committed_evidence_keeps_tombstone', () async {
        await actualTombstone(shared: true);
        final receipt = boundary;
        final raw = await seedWebhook(
          fence.subtract(const Duration(seconds: 2)),
          receipt,
        );
        await processIcinga2(builder.build(), receipt);
        expect(await outcomeOf(session, raw), containsPair('late', 1));
        expect(await countRows(session, 'observation_keys'), 1);
        // The retained event alone protects the tombstone when the key is gone.
        await session.db.unsafeExecute('DELETE FROM observation_keys');
        expect(await sweep(), 0);
        expect((await theAlert(session))['silent_tombstone'], true);
        await session.db.unsafeExecute('DELETE FROM events');
        expect(await sweep(), 1);
      });

      test('late_webhook_does_not_recreate_reclaimed_tombstone', () async {
        await actualTombstone(shared: true);
        // The late webhook has reserved its key, but has not yet locked the alert.
        final raw = await seedWebhook(
          fence.subtract(const Duration(seconds: 2)),
          boundary,
        );
        await sweepDuringKeyReservation();
        expect(await outcomeOf(session, raw), containsPair('late', 1));
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'alerts'), 0);
      });

      test('old_claimed_row_that_retries_retains_receipt', () async {
        final snapshot = await actualTombstone();
        final oldReceipt = fence;
        final raw = await seedStreamDb(session, snapshot, [
          streamDbCheck(fence.subtract(const Duration(seconds: 2))),
        ], observed: oldReceipt);
        final claimed = Completer<void>();
        final release = Completer<void>();
        final pipeline = PipelineRepository(
          builder.build(),
          clock: () => boundary,
          retryDelay: (_) => Duration.zero,
          afterClaim: () async {
            claimed.complete();
            await release.future;
            throw StateError('test worker retry');
          },
        );
        expect(await pipeline.pinOne(), isTrue);
        final processing = pipeline.processOne();
        try {
          await Future.any([claimed.future, processing.then<void>((_) {})]);
          expect(claimed.isCompleted, isTrue);
          expect(await sweep(), 0);
        } finally {
          release.complete();
          await processing;
        }
        expect(await sweep(), 0);
        await processIcinga2(builder.build(), boundary);
        expect(await outcomeOf(session, raw), containsPair('stale', 1));
        expect((await theAlert(session))['status'], 'resolved');
      });

      test('retained_event_subject_probe_uses_its_index', () async {
        await session.db.transaction((tx) async {
          await session.db.unsafeSimpleExecute(
            'SET LOCAL enable_seqscan=off',
            transaction: tx,
          );
          final plan = await session.db.unsafeQuery('''EXPLAIN
            SELECT 1 FROM events WHERE correlia_event_subject(payload)='${'a' * 64}' LIMIT 1
          ''', transaction: tx);
          expect(
            plan.map((row) => row[0]).join(' '),
            contains('events_subject_idx'),
          );
        });
      });

      test('admission_and_reclamation_fence_both_orders', () async {
        final writer = builder.build();
        final sweepSession = builder.build();
        final oldReceipt = fence.add(const Duration(seconds: 1));
        await mark(1, fence.subtract(const Duration(seconds: 1)));
        final inserted = Completer<int>();
        final release = Completer<void>();
        final writing = writer.db.transaction((tx) async {
          await rawAt(writer, oldReceipt, tx: tx);
          inserted.complete(
            (await writer.db.unsafeQuery(
                  'SELECT pg_backend_pid()',
                  transaction: tx,
                )).single[0]!
                as int,
          );
          await release.future;
        });
        Future<void> blockedBy(int pid) async {
          final elapsed = Stopwatch()..start();
          while (elapsed.elapsed < const Duration(milliseconds: 750)) {
            final waiting = await session.db.unsafeQuery('''
              SELECT 1 FROM pg_stat_activity
              WHERE $pid = ANY(pg_blocking_pids(pid)) AND datname=current_database()
            ''');
            if (waiting.isNotEmpty) return;
          }
          fail('Expected another transaction to block on backend $pid');
        }

        final writerPid = await inserted.future;
        final scanner = TombstoneSweep(
          sweepSession,
          clock: () => boundary.add(const Duration(hours: 1)),
        );
        final waiting = scanner.runOnce();
        try {
          await blockedBy(writerPid);
        } finally {
          release.complete();
          await writing;
        }
        expect(await waiting, 0);
        expect(await countRows(session, 'alerts'), 1);
        await session.db.unsafeExecute("UPDATE raw_inbox SET status='done'");
        const advisory = 678124;
        await session.db.unsafeSimpleExecute('''
          CREATE FUNCTION wait_after_cutoff_update() RETURNS trigger LANGUAGE plpgsql AS \$\$
          BEGIN PERFORM pg_advisory_xact_lock($advisory); RETURN NEW; END; \$\$;
          CREATE TRIGGER wait_after_cutoff_update AFTER UPDATE ON raw_admission_cutoff
            FOR EACH ROW EXECUTE FUNCTION wait_after_cutoff_update();
        ''');
        final held = Completer<int>();
        final unlock = Completer<void>();
        final gate = session.db.transaction((tx) async {
          await session.db.unsafeQuery(
            'SELECT pg_advisory_xact_lock($advisory)',
            transaction: tx,
          );
          held.complete(
            (await session.db.unsafeQuery(
                  'SELECT pg_backend_pid()',
                  transaction: tx,
                )).single[0]!
                as int,
          );
          await unlock.future;
        });
        final gatePid = await held.future;
        final reclaiming = scanner.runOnce();
        try {
          await blockedBy(gatePid);
          // Identify the sweep backend waiting at the trigger; admission now
          // has to queue behind its cutoff update, not observe the old cutoff.
          final sweepPid =
              (await session.db.unsafeQuery('''
            SELECT pid FROM pg_stat_activity WHERE $gatePid = ANY(pg_blocking_pids(pid))
          ''')).single[0]!
                  as int;
          final rejected = expectLater(
            rawAt(writer, oldReceipt),
            throwsA(
              isA<DatabaseQueryException>().having(
                (e) => e.code,
                'code',
                'CR001',
              ),
            ),
          );
          try {
            await blockedBy(sweepPid);
          } finally {
            unlock.complete();
            await rejected;
          }
          expect(await reclaiming, 1);
        } finally {
          if (!unlock.isCompleted) unlock.complete();
          await gate;
          await reclaiming;
          await session.db.unsafeSimpleExecute(
            'DROP FUNCTION wait_after_cutoff_update() CASCADE',
          );
        }
        await rawAt(writer, boundary);
        expect(await countRows(session, 'raw_inbox'), 2);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
