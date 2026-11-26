import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/generated/protocol.dart';
import 'package:correlia_server/src/ingest/admission.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_pipeline_fixture.dart';
import '../support/generic_webhook_fixture.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/postgres_lock_witness.dart' show ContentionGate;
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' as cfg;

void main() {
  withServerpod(
    'raw replay uses the operator-time pin',
    (builder, _) {
      late Session session;
      late DateTime now;
      late QueueOperations ops;
      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        now = streamDbNow;
        await session.db.unsafeExecute(
          "UPDATE pipeline_icinga2_replay_floor SET effective_floor='-infinity'",
        );
        ops = QueueOperations(
          session,
          clock: () => now,
          secretStore: testSecretStore,
        );
      });

      PipelineRepository worker({
        Session? owner,
        Future<void> Function()? afterClaim,
        Future<void> Function()? beforeError,
      }) => PipelineRepository(
        owner ?? session,
        clock: () => now,
        elapsedForTest: () => Duration.zero,
        afterClaim: afterClaim,
        beforeRecordErrorForTest: beforeError,
      );

      Future<QueueFailure> failure() async => (await ops.list(
        QueueFailureFilter(kind: QueueFailureKind.raw),
      )).failures.single;
      Future<QueueReplayResult> replay(int occurrence) =>
          ops.replayOne(QueueFailureKind.raw, occurrence, 'demo');
      Future<void> markFailure(String id, String pin) async {
        await session.db.unsafeSimpleExecute('''
        SELECT correlia_record_raw_failure(observed_at,raw_id,source_id,'$pin','processing_exhausted',NULL,observed_at)
        FROM raw_inbox WHERE raw_id='$id';
        UPDATE raw_inbox SET status='failed',config_snapshot_id='$pin',attempt_count=5 WHERE raw_id='$id';
      ''');
      }

      test('dur_13_mapping_fix_repins_at_replay', () async {
        final first = await publishGenericConfig(
          session,
          now: now,
          mapping: checkMapping()..['identity'] = {'host': '/wrong'},
        );
        final id = await admitGeneric(
          session,
          first,
          jsonEncode(genericAlert(now)),
          now,
        );
        expect(await worker().pinOne(), isTrue);
        expect(await worker().processOne(), isTrue);
        final failed = await failure();
        expect(failed.snapshotId, first.snapshotId);
        final second = await publishGenericConfig(
          session,
          now: now,
          revision: 2,
        );
        expect((await replay(failed.occurrence)).queued, 1);
        final third = await publishGenericConfig(
          session,
          now: now,
          revision: 3,
          mapping: checkMapping()..['identity'] = {'host': '/wrong'},
        );
        expect(third.snapshotId, isNot(second.snapshotId));
        expect(await worker().processOne(), isTrue);
        final event = (await genericEvents(session)).single;
        expect(event.pipeline.version, second.snapshotId);
        expect(event.pipeline.generation, 0);
        expect(event.raw.ref, endsWith('/$id'));
        expect(event.observedAt.toRfc3339(), '2026-11-23T12:00:00Z');
      });

      test('missing_and_disabled_sources_keep_failure_occurrence', () async {
        final active = await publishGenericConfig(session, now: now);
        await admitGeneric(session, active, '{}', now);
        expect(await worker().pinOne(), isTrue);
        expect(await worker().processOne(), isTrue);
        final original = await failure();
        await publishGenericConfig(
          session,
          now: now,
          revision: 2,
          includeSource: false,
        );
        expect(
          (await replay(original.occurrence)).items.single.outcome,
          'source_unavailable',
        );
        await publishGenericConfig(
          session,
          now: now,
          revision: 3,
          enabled: false,
        );
        expect(
          (await replay(original.occurrence)).items.single.outcome,
          'source_unavailable',
        );
        final unchanged = await failure();
        expect(
          (unchanged.occurrence, unchanged.failedAt),
          (original.occurrence, original.failedAt),
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT status FROM raw_inbox',
          )).single[0],
          'failed',
        );
      });

      test('stale_same_pin_error_cannot_cross_replay_epoch', () async {
        final initial = await publishGenericConfig(session, now: now);
        final id = await admitGeneric(session, initial, 'not json', now);
        expect(await worker().pinOne(), isTrue);
        final gate = ContentionGate();
        final paused = Completer<void>();
        final original = gate.run(
          () => worker(
            owner: builder.build(),
            afterClaim: () async => throw StateError('fixture'),
            beforeError: () async {
              paused.complete();
              await gate.future;
            },
          ).processOne(),
        );
        await paused.future;
        expect(await worker().processOne(), isTrue);
        final failed = await failure();
        expect((await replay(failed.occurrence)).queued, 1);
        await gate.join();
        expect(await original, isTrue);
        final row = (await session.db.unsafeQuery('''
        SELECT raw_id::text,config_snapshot_id,status,attempt_count,next_attempt_at,processing_epoch
        FROM raw_inbox
      ''')).single;
        expect(row.toList(), [id, initial.snapshotId, 'pending', 0, null, 1]);
      });

      test('replay_and_ingress_share_last_slot', () async {
        final publish = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final active = await publish.publishConfig(
          cfg.cutoverV2(1)..['pipeline_operations'] = {'pending_max_rows': 1},
          {'source-token': cfg.token(1), 'key-v1': cfg.token(2)},
          runMode: 'test',
        );
        final observed = DateTime.now().toUtc();
        now = observed;
        Future<AdmissionOutcome> admit(Session s, String key) =>
            IngestAdmission(s).admit(
              sourceId: cfg.sourceId,
              kind: 'alertmanager',
              credential: active.sources.single.credentials.single,
              pathToken: false,
              body: Uint8List.fromList(utf8.encode('{')),
              contentType: 'application/json',
              observedAt: observed,
              idempotencyKey: key,
            );
        expect(await admit(session, 'fails-first'), AdmissionOutcome.accepted);
        expect(await worker().pinOne(), isTrue);
        expect(await worker().processOne(), isTrue);
        final old = await failure();
        final recording = replay(old.occurrence);
        final sender = await admit(builder.build(), 'racer');
        final result = await recording;
        expect(
          result.queued + (sender == AdmissionOutcome.accepted ? 1 : 0),
          1,
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT pending_rows FROM pipeline_pending',
          )).single[0],
          1,
        );
        if (result.refused == 1) {
          expect(result.items.single.outcome, 'inbox_capacity');
          expect((await failure()).occurrence, old.occurrence);
        }
      });

      test('reconcile_replay_preserves_finished_and_pruned_runs', () async {
        final pin = await publishStreamDb(session);
        final check = now.subtract(const Duration(minutes: 1));
        await seedStreamDb(session, pin, [streamDbCheck(check)]);
        expect(await worker().pinOne(), isTrue);
        expect(await worker().processOne(), isTrue);
        for (final present in [true, false]) {
          await session.db.unsafeExecute('DELETE FROM icinga2_sync_progress');
          if (present) {
            await session.db.unsafeExecute('''
          INSERT INTO icinga2_sync_progress (sync_id,source_id,phase,rows_admitted,rows_failed,started_at,ended_at)
          VALUES ('$streamDbSyncId','$icinga2DbSourceId','failed',1,1,now(),now())
        ''');
          }
          final row = await seedStreamDb(session, pin, [
            streamDbCheck(check.add(const Duration(seconds: 30)), sync: true),
          ], sync: true);
          await markFailure(row, pin);
          expect((await replay((await failure()).occurrence)).queued, 1);
          expect(await worker().processOne(), isTrue);
          expect(
            await queryRows(
              session,
              "SELECT status FROM raw_inbox WHERE raw_id='$row'",
            ),
            isEmpty,
          );
          final runs = await queryRows(
            session,
            'SELECT rows_admitted,rows_done,rows_failed FROM icinga2_sync_progress',
          );
          expect(
            runs,
            present
                ? [
                    {'rows_admitted': 1, 'rows_done': 0, 'rows_failed': 1},
                  ]
                : isEmpty,
          );
        }
        expect(
          (await session.db.unsafeQuery(
            "SELECT count(*) FROM activity WHERE change_kind='replayed_reconcile_no_event'",
          )).single[0],
          2,
        );
      });

      test('restored_source_replays_with_admission_origin_policy', () async {
        final pin = await publishStreamDb(session, policy: 'hard_only');
        final id = await seedStreamDb(session, pin, [
          streamDbCheck(now, stateType: 0),
        ]);
        await markFailure(id, pin);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publishConfig(
          streamBootstrap(2, [streamSource(icinga2DbSourceId, enabled: false)]),
          streamMaterial(),
          runMode: 'test',
          clock: () => now,
        );
        final failed = await failure();
        expect(
          (await replay(failed.occurrence)).items.single.outcome,
          'source_unavailable',
        );
        final restored = await publishStreamDb(
          session,
          revision: 3,
          policy: 'soft_and_hard',
        );
        expect((await replay(failed.occurrence)).queued, 1);
        expect(await worker().processOne(), isTrue);
        expect(await outcomeOf(session, id), containsPair('soft_info', 1));
        expect(await countRows(session, 'alerts'), 0);
        final saved = (await session.db.unsafeQuery(
          'SELECT config_snapshot_id FROM raw_inbox',
        )).single;
        expect(saved[0], restored);
      });

      test('preupgrade_icinga2_floor_keeps_older_evidence_late', () async {
        final pin = await publishStreamDb(session);
        final id = await seedStreamDb(
          session,
          pin,
          [
            streamDbCheck(now, host: 'before-floor'),
            streamDbCheck(
              now.add(const Duration(seconds: 2)),
              host: 'after-floor',
            ),
            streamDbCheck(now, host: 'old-evidence-received-later'),
          ],
          itemReceipt: (index) => now.add(Duration(seconds: 2 * index)),
        );
        await markFailure(id, pin);
        await session.db.unsafeExecute(
          'UPDATE pipeline_icinga2_replay_floor SET effective_floor=@floor',
          parameters: QueryParameters.named({
            'floor': now.add(const Duration(seconds: 1)),
          }),
        );
        final old = await failure();
        expect((await replay(old.occurrence)).queued, 1);
        expect(await worker().processOne(), isTrue);
        final outcome = await outcomeOf(session, id);
        expect(outcome['late'], 2);
        expect(outcome['committed'], 1);
        expect(await countRows(session, 'outbox'), 1);
        expect((await theAlert(session))['summary'], contains('after-floor'));
        expect(
          (await session.db.unsafeQuery(
            'SELECT observed_at FROM raw_inbox',
          )).single[0],
          old.workAt,
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
