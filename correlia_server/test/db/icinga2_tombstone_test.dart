@Timeout(Duration(minutes: 5))
library;

import 'dart:async';

import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/state/tombstone_sweep.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart' as webhook;
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/ingest_schema.dart';
import '../support/postgres_lock_witness.dart';

void main() {
  final cluster = LockWitnessCluster();
  tearDownAll(cluster.close);
  withServerpod(
    'stream tombstone reclamation',
    (builder, _) {
      late Session session;
      late pg.Connection sweepConnection;
      final boundary = streamDbNow;
      final fence = boundary.subtract(const Duration(days: 7));

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        sweepConnection = await endpoint.open(
          queryTimeout: const Duration(minutes: 5),
        );
      });

      tearDown(() async {
        if (sweepConnection.isOpen) {
          await sweepConnection.close(force: true);
        }
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
        sweepConnection,
        clock: () => boundary.add(const Duration(hours: 1)),
        beforeCutoffLockForTest: (tx) async {
          await lockActor(tx);
        },
      ).runOnce();

      Future<void> rawAt(Session writer, DateTime receipt, {Transaction? tx}) =>
          writer.db.unsafeExecute(
            '''INSERT INTO raw_inbox
          (observed_at,raw_id,source_id,body,body_sha256,content_type)
          VALUES (@receipt,gen_random_uuid(),'$icinga2OtherDbSourceId',decode('00','hex'),'test','application/json')''',
            parameters: QueryParameters.named({'receipt': receipt}),
            transaction: tx,
            timeoutInSeconds: const Duration(minutes: 5).inSeconds,
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

      test('replayable_failure_keeps_tombstone_until_expiry', () async {
        await mark(1, fence.subtract(const Duration(seconds: 1)));
        await rawAt(session, fence.add(const Duration(seconds: 1)));
        await session.db.unsafeExecute(
          '''UPDATE raw_admission_cutoff SET cutoff=@cutoff''',
          parameters: QueryParameters.named({'cutoff': boundary}),
        );
        await session.db.unsafeQuery('''
          WITH failed AS (
            UPDATE raw_inbox SET status='failed' RETURNING observed_at,raw_id,source_id
          )
          SELECT correlia_record_raw_failure(observed_at,raw_id,source_id,NULL,'processing_exhausted',NULL,@now)
          FROM failed
        ''', parameters: QueryParameters.named({'now': boundary}));
        expect(await sweep(), 0);
        expect(await countRows(session, 'alerts'), 1);
        expect(
          (await session.db.unsafeQuery(
            "SELECT correlia_maintain('expiry',@now,10)",
            parameters: QueryParameters.named({
              'now': boundary.add(const Duration(days: 15)),
            }),
          )).single[0],
          1,
        );
        expect(await sweep(), 1);
        expect(await countRows(session, 'alerts'), 0);
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
        final reserved = Completer<void>();
        final release = ContentionGate();
        final worker = PipelineRepository(
          builder.build(),
          clock: () => boundary,
          elapsedForTest: () => Duration.zero,
          afterKeyReservationForTest: () {
            reserved.complete();
            return release.future;
          },
        );
        expect(await worker.pinOne(), isTrue);
        // The real observation key exists in the open transaction.
        final writing = release.run(worker.processOne);
        try {
          await Future.any([
            reserved.future,
            writing.then<void>(
              (_) => throw StateError('Worker did not reserve a key'),
            ),
          ]);
          expect(await release.run(sweep), 1);
        } finally {
          await release.join();
        }
        expect(await writing, isTrue);
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
          final indexes = await session.db.unsafeQuery('''
            SELECT inhrelid::regclass::text FROM pg_inherits
            WHERE inhparent='events_subject_idx'::regclass
          ''', transaction: tx);
          final explanation = plan.map((row) => row[0]).join(' ');
          expect(
            indexes.any((row) => explanation.contains(row[0]! as String)),
            isTrue,
          );
        });
      });

      for (final (lane, parent) in [
        for (final lane in ['observation', 'tombstone'])
          for (final parent in ['raw_inbox', 'events']) (lane, parent),
      ]) {
        test('${lane}_reclaim_waits_on_${parent}_before_cutoff', () async {
          final hasTombstone = lane == 'tombstone' && parent == 'events';
          if (hasTombstone) {
            await mark(1, fence.subtract(const Duration(seconds: 1)));
          }
          final witness = await PostgresLockWitness.start(session);
          addTearDown(witness.close);
          final gate = ContentionGate();
          final ddl = builder.build();
          final sweepSession = builder.build();
          final ddlReady = Completer<LockActor>();
          final sweepReady = Completer<LockActor>();
          final holding = gate.run(
            () => ddl.db.transaction((tx) async {
              final actor = await pooledLockActor(ddl, tx);
              await ddl.db.unsafeExecute(
                'LOCK TABLE ONLY $parent IN ACCESS EXCLUSIVE MODE',
                transaction: tx,
              );
              ddlReady.complete(actor);
              await gate.future;
              await ddl.db.unsafeQuery(
                'SELECT 1 FROM raw_admission_cutoff FOR UPDATE NOWAIT',
                transaction: tx,
              );
            }),
          );
          try {
            final holder = await Future.any([
              ddlReady.future,
              holding.then<LockActor>((_) => fail('DDL did not hold $parent')),
            ]);
            const observation = "SELECT correlia_maintain('observation',now())";
            final sweeping = gate.run(
              lane == 'observation'
                  ? () => sweepSession.db.transaction((tx) async {
                      sweepReady.complete(
                        await pooledLockActor(
                          sweepSession,
                          tx,
                          waiter: SqlTimeouts.poolDefault,
                        ),
                      );
                      return (await sweepSession.db.unsafeQuery(
                            observation,
                            transaction: tx,
                          )).single[0]
                          as int;
                    })
                  : TombstoneSweep(
                      sweepConnection,
                      clock: () => boundary.add(const Duration(hours: 1)),
                      beforeCutoffLockForTest: (tx) async =>
                          sweepReady.complete(
                            await lockActor(tx, waiter: SqlTimeouts.sweep),
                          ),
                    ).runOnce,
            );
            final waiter = await Future.any([
              sweepReady.future,
              sweeping.then<LockActor>((_) => fail('Sweep did not wait')),
            ]);
            await witness.blockedBy(
              waiter,
              holder,
              sweeping,
              statement: lane == 'observation' ? observation : parent,
            );
            await gate.join();
            await holding;
            expect(await sweeping, hasTombstone ? 1 : 0);
          } finally {
            await gate.join();
          }
        });
      }

      test('admission_and_reclamation_fence_both_orders', () async {
        final writer = builder.build();
        final witness = await PostgresLockWitness.start(session);
        addTearDown(witness.close);
        final oldReceipt = fence.add(const Duration(seconds: 1));
        await mark(1, fence.subtract(const Duration(seconds: 1)));
        final inserted = Completer<LockActor>();
        final release = ContentionGate();
        final writing = release.run(
          () => writer.db.transaction((tx) async {
            final actor = await pooledLockActor(writer, tx);
            await rawAt(writer, oldReceipt, tx: tx);
            inserted.complete(actor);
            await release.future;
          }),
        );
        final writerActor = await Future.any([
          inserted.future,
          writing.then<LockActor>(
            (_) => throw StateError('Admission did not hold the cutoff'),
          ),
        ]);
        var sweepEntered = Completer<LockActor>();
        final scanner = TombstoneSweep(
          sweepConnection,
          clock: () => boundary.add(const Duration(hours: 1)),
          beforeCutoffLockForTest: (tx) async => sweepEntered.complete(
            await lockActor(tx, waiter: SqlTimeouts.sweep),
          ),
        );
        final waiting = release.run(scanner.runOnce);
        try {
          final sweepActor = await Future.any([
            sweepEntered.future,
            waiting.then<LockActor>(
              (_) => throw StateError('Sweep did not wait for admission'),
            ),
          ]);
          await witness.blockedBy(
            sweepActor,
            writerActor,
            waiting,
            statement: 'correlia_advance_raw_cutoff',
          );
        } finally {
          await release.join();
        }
        await writing;
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
        addTearDown(
          () => session.db.unsafeSimpleExecute(
            'DROP FUNCTION wait_after_cutoff_update() CASCADE',
          ),
        );
        final held = Completer<LockActor>();
        final unlock = ContentionGate();
        final gate = unlock.run(
          () => session.db.transaction((tx) async {
            final actor = await pooledLockActor(session, tx);
            await session.db.unsafeQuery(
              'SELECT pg_advisory_xact_lock($advisory)',
              transaction: tx,
            );
            held.complete(actor);
            await unlock.future;
          }),
        );
        final cutoffGate = await Future.any([
          held.future,
          gate.then<LockActor>(
            (_) => throw StateError('Cutoff trigger gate was not held'),
          ),
        ]);
        sweepEntered = Completer<LockActor>();
        final reclaiming = unlock.run(scanner.runOnce);
        late Future<void> rejected;
        try {
          final sweepActor = await Future.any([
            sweepEntered.future,
            reclaiming.then<LockActor>(
              (_) =>
                  throw StateError('Sweep did not wait in the cutoff trigger'),
            ),
          ]);
          await witness.blockedBy(
            sweepActor,
            cutoffGate,
            reclaiming,
            statement: 'correlia_advance_raw_cutoff',
            advisory: true,
          );
          final admissionEntered = Completer<LockActor>();
          final admission = unlock.run(
            () => writer.db.transaction((tx) async {
              admissionEntered.complete(
                await pooledLockActor(
                  writer,
                  tx,
                  waiter: SqlTimeouts.poolDefault,
                ),
              );
              await rawAt(writer, oldReceipt, tx: tx);
            }),
          );
          rejected = expectLater(
            admission,
            throwsA(
              isA<DatabaseQueryException>().having(
                (e) => e.code,
                'code',
                'CR001',
              ),
            ),
          );
          rejected.ignore();
          final admissionActor = await Future.any([
            admissionEntered.future,
            admission.then<LockActor>(
              (_) => throw StateError(
                'Admission was not queued behind the cutoff',
              ),
            ),
          ]);
          await witness.blockedBy(
            admissionActor,
            sweepActor,
            admission,
            statement: 'INSERT INTO raw_inbox',
          );
        } finally {
          await unlock.join();
        }
        await gate;
        await rejected;
        expect(await reclaiming, 1);
        await rawAt(writer, boundary);
        expect(await countRows(session, 'raw_inbox'), 2);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    ephemeralDatabase: false,
    configOverride: cluster.override,
    testGroupTagsOverride: ['db'],
  );
}
