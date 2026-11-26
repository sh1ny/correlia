import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/event/cloud_event.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/output/overflow_notices.dart';
import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:correlia_server/src/output/output_relay.dart';
import 'package:correlia_server/src/output/webhook_output.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:serverpod/serverpod.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;
import '../support/postgres_lock_witness.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as config;
import 'pipeline_routing_test.dart' show secondOutput;
import 'pipeline_test.dart' as raw;

const _first = config.outputId;
const _second = secondOutput;

Future<IngestBootstrap> _publish(
  Session session,
  int revision, {
  List<String> outputs = const [_first, _second],
  List<String>? routes,
  Map<String, Object?> budgets = const {},
  Map<String, String> urls = const {},
  Map<String, Object?> pressure = const {},
}) =>
    IngestConfigRepository(session, secretStore: testSecretStore).publishConfig(
      {
        ...config.cutoverV2(revision),
        'sources': [
          {
            'id': config.sourceId,
            'kind': 'alertmanager',
            'enabled': true,
            'credentials': [
              {'ref': 'source-token', 'type': 'bearer'},
            ],
            'output_ids': routes ?? outputs,
          },
        ],
        'outputs': [
          for (final id in outputs)
            {
              'id': id,
              'kind': 'webhook',
              'url': urls[id] ?? 'https://example.com/events',
              'signing_key_ref': 'key-v1',
            },
        ],
        'pipeline_operations': {...pressure, 'output_budgets': budgets},
      },
      {'source-token': config.token(1), 'key-v1': config.token(2)},
      runMode: 'test',
    );

Future<void> _send(Session session, List<String> names) => raw.seed(session, [
  for (final name in names)
    payload.alert(
      startsAt: '2026-11-10T12:00:00Z',
      labels: {'alertname': name},
    ),
]);

PipelineRepository _worker(
  Session session, {
  Future<void> Function()? afterClaim,
}) => PipelineRepository(
  session,
  clock: () => raw.now,
  elapsedForTest: () => Duration.zero,
  afterClaim: afterClaim,
);

Future<void> _process(Session session, List<String> names) async {
  await _send(session, names);
  final worker = _worker(session);
  expect(await worker.pinOne(), isTrue);
  expect(await worker.processOne(), isTrue);
}

Future<void> _oldIntents(
  Session session,
  IngestBootstrap snapshot,
  String output,
  int count, {
  int payloadBytes = 1,
}) async {
  final parsed = snapshot.outputs.first as WebhookIngestOutput;
  await session.db.unsafeExecute(
    '''
    INSERT INTO outbox(created_at,delivery_id,event_observed_at,event_id,event_disposition,
      output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload)
    SELECT now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',@output::uuid,
      @snapshot,'https://example.com/events',@reference,@commitment,convert_to(repeat('x',@bytes),'UTF8')
    FROM generate_series(1,@count)
  ''',
    parameters: QueryParameters.named({
      'output': output,
      'snapshot': snapshot.snapshotId,
      'reference': parsed.signingKeyRef,
      'bytes': payloadBytes,
      'commitment': parsed.signingKeyCommitment,
      'count': count,
    }),
  );
}

Future<List<Object?>> _usage(Session session, String output) async =>
    (await session.db.unsafeQuery('''
      SELECT used_rows,used_bytes,discarded_count FROM pipeline_output_capacity
      WHERE output_id=@id::uuid
    ''', parameters: QueryParameters.named({'id': output}))).single.toList();

Future<Map<Object?, Object?>> _intents(Session session) async => {
  for (final row in await session.db.unsafeQuery('''
    SELECT output_id::text,count(*) FROM outbox WHERE status<>'delivered' GROUP BY output_id
  '''))
    row[0]: row[1],
};

void main() {
  final cluster = LockWitnessCluster();
  tearDownAll(cluster.close);
  withServerpod(
    'output pressure and durable routing',
    (builder, _) {
      late Session session;
      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute('''
        TRUNCATE delivery_attempts,pipeline_overflow_notice;
        UPDATE pipeline_output_capacity SET discarded_count=0,overflow_activity_id=NULL,
          demand_rows=0,demand_bytes=0
      ''');
      });

      test('dur_11_discard_preserves_other_fanout', () async {
        await _publish(
          session,
          1,
          budgets: {
            _first: {'max_rows': 1},
          },
        );
        await _process(session, ['discard-a', 'discard-b']);
        expect(await _intents(session), {_first: 1, _second: 2});
        expect((await _usage(session, _first))[2], 1);
        expect((await _usage(session, _second))[2], 0);
        expect(
          (await session.db.unsafeQuery(
            'SELECT status FROM raw_inbox',
          )).single[0],
          'done',
        );
        await _process(session, ['discard-c', 'discard-d']);
        expect((await _usage(session, _first))[2], 3);
        final audit = await session.db.unsafeQuery('''
          SELECT actor_ref,entity_version FROM activity WHERE change_kind='output_discarded' ORDER BY id
        ''');
        expect(audit.map((row) => row.toList()), [
          [_first, 1],
          [_first, 2],
        ]);
        expect(
          (await session.db.unsafeQuery(
            "SELECT count(*) FROM activity WHERE change_kind='output_overflow' AND actor_ref='$_first'",
          )).single[0],
          1,
        );
      });

      test(
        'oversized_discard_does_not_keep_episode_open_after_recovery',
        () async {
          await _publish(session, 1, outputs: [_first]);
          await _process(session, ['calibration']);
          final used = (await _usage(session, _first))[1]! as int;
          await session.db.unsafeExecute(
            "UPDATE outbox SET status='delivered'",
          );
          final budgets = {
            _first: {'max_payload_bytes': used + 100},
          };
          await _publish(
            session,
            2,
            outputs: [_first],
            budgets: budgets,
          );
          final ops = QueueOperations(session);
          Future<int?> episode() async =>
              (await ops.status()).outputs.single.overflowActivityId;
          await _process(session, ['large-a-${'a' * 500}']);
          final initial = await episode();
          expect(initial, isNotNull);
          await _publish(session, 3, outputs: [_first], budgets: budgets);
          await _process(session, ['large-same-budget-${'c' * 500}']);
          expect(await episode(), initial);
          await _process(session, ['small-again']);
          expect(await episode(), initial, reason: 'An insert uses capacity');
          expect(await _intents(session), {_first: 1});
          await session.db.unsafeExecute(
            "UPDATE outbox SET status='delivered' WHERE status='queued'",
          );
          expect(await episode(), isNull);
          await _process(session, ['large-b-${'b' * 500}']);
          final next = await episode();
          expect(next, isNotNull);
          expect(next, isNot(initial));
          expect(await _usage(session, _first), [0, 0, 3]);
        },
      );

      test(
        'partially_fitting_batches_keep_the_first_overflow_episode',
        () async {
          await _publish(session, 1, outputs: [_first]);
          await _process(session, ['calibrate']);
          final smallBytes = (await _usage(session, _first))[1]! as int;
          await session.db.unsafeExecute(
            "UPDATE outbox SET status='delivered'",
          );
          await _publish(
            session,
            2,
            outputs: [_first],
            budgets: {
              _first: {'max_payload_bytes': 3 * smallBytes},
            },
          );
          Future<void> sendPair(String suffix) async {
            await raw.seed(session, [
              payload.alert(
                startsAt: '2026-11-10T12:00:00Z',
                labels: {'alertname': 'fits-$suffix'},
                annotations: const {},
              ),
              payload.alert(
                startsAt: '2026-11-10T12:00:00Z',
                labels: {'alertname': 'too-big-$suffix'},
                annotations: {
                  for (var n = 0; n < 12; n++) 'detail$n': 'a' * 500,
                },
              ),
            ]);
            final worker = _worker(session);
            expect(await worker.pinOne(), isTrue);
            expect(await worker.processOne(), isTrue);
          }

          await sendPair('one');
          expect((await _usage(session, _first))[2], 1);
          expect(await _intents(session), {_first: 1});
          final initial = (await QueueOperations(
            session,
          ).status()).outputs.single.overflowActivityId;
          expect(initial, isNotNull);
          await sendPair('two');
          expect(await _intents(session), {_first: 2});
          expect((await _usage(session, _first))[2], 2);
          expect(
            (await QueueOperations(
              session,
            ).status()).outputs.single.overflowActivityId,
            initial,
          );
        },
      );

      test('switch_to_blocking_ignores_discard_only_demand', () async {
        const budget = 16 * 1024 * 1024;
        final old = await _publish(
          session,
          1,
          routes: [_first],
          budgets: {
            _first: {'max_payload_bytes': budget},
          },
        );
        await _oldIntents(session, old, _first, 1, payloadBytes: budget - 1);
        await _process(session, ['old-policy-discard']);
        expect(await _usage(session, _first), [1, budget - 1, 1]);
        final before = (await QueueOperations(session).status()).outputs
            .singleWhere(
              (output) => output.outputId == _first,
            );
        expect(before.overflowActivityId, isNotNull);
        await _publish(
          session,
          2,
          routes: [_first],
          budgets: {
            _first: {
              'max_payload_bytes': budget,
              'max_rows': 1000,
              'overflow_policy': 'block_ingest',
            },
          },
        );
        final state = await QueueOperations(session).status();
        final lane = state.outputs.singleWhere(
          (output) => output.outputId == _first,
        );
        expect(state.pressure, isNull);
        expect(lane.blocksIngress, isFalse);
        expect(lane.overflowActivityId, isNull);
        expect(await _usage(session, _first), [1, budget - 1, 1]);
      });

      test('status_prioritizes_a_blocked_lane_over_retired_work', () async {
        const budget = 16 * 1024 * 1024;
        final snapshot = await _publish(
          session,
          1,
          outputs: [_first],
          budgets: {
            _first: {
              'max_payload_bytes': budget,
              'max_rows': 1000,
              'overflow_policy': 'block_ingest',
            },
          },
        );
        await _oldIntents(session, snapshot, _first, 1, payloadBytes: budget);
        await session.db.unsafeExecute(
          '''
          INSERT INTO outbox(created_at,delivery_id,event_observed_at,event_id,event_disposition,
            output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status)
          SELECT now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',
            ('00000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
            @snapshot,'https://example.com/events',signing_key_ref,signing_key_commitment,
            decode('01','hex'),'dead'
          FROM outbox CROSS JOIN generate_series(1,64) n WHERE output_id=@id::uuid
        ''',
          parameters: QueryParameters.named({
            'snapshot': snapshot.snapshotId,
            'id': _first,
          }),
        );
        final state = await QueueOperations(session).status();
        expect(state.pressure, 'output');
        expect(state.outputsTruncated, isTrue);
        final lane = state.outputs.singleWhere(
          (output) => output.outputId == _first,
        );
        expect((lane.blocksIngress, lane.usedBytes), (true, budget));
      });

      test(
        'drained_retired_blocking_lanes_do_not_hide_active_outputs',
        () async {
          final retired = [
            for (var i = 0; i < 64; i++)
              '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
          ];
          await _publish(
            session,
            1,
            outputs: retired,
            routes: [],
            budgets: {
              for (final id in retired) id: {'overflow_policy': 'block_ingest'},
            },
          );
          await _publish(session, 2);
          final status = await QueueOperations(session).status();
          expect(status.outputs.map((lane) => lane.outputId), [
            _first,
            _second,
          ]);
          expect(status.outputsTruncated, isFalse);
          expect(status.pressure, isNull);
        },
      );

      test('lower_blocking_cap_opens_an_episode_with_empty_inbox', () async {
        const budget = 16 * 1024 * 1024;
        Future<IngestBootstrap> publish(int revision, int bytes) => _publish(
          session,
          revision,
          outputs: [_first],
          budgets: {
            _first: {
              'max_payload_bytes': bytes,
              'max_rows': 1000,
              'overflow_policy': 'block_ingest',
            },
          },
        );
        final initial = await publish(1, budget * 2);
        await _oldIntents(session, initial, _first, 1, payloadBytes: budget);
        final ops = QueueOperations(session);
        expect((await ops.status()).pressure, isNull);
        await publish(2, budget);
        final pressure = await ops.status();
        expect((pressure.pendingRows, pressure.pressure), (0, 'output'));
        final episode = pressure.outputs.single.overflowActivityId;
        expect(episode, isNotNull);
        await publish(3, budget);
        final notice = (await session.db.unsafeQuery('''
          SELECT n.activity_id,a.change_kind,n.output_id::text,n.reason,n.handled
          FROM pipeline_overflow_notice n JOIN activity a ON a.id=n.activity_id
        ''')).single;
        expect(notice.toList(), [
          episode,
          'output_overflow',
          _first,
          'saturated',
          false,
        ]);
        expect(await _usage(session, _first), [1, budget, 0]);
        await publish(4, budget * 2);
        expect((await ops.status()).outputs.single.overflowActivityId, isNull);
      });

      for (final byBytes in [false, true]) {
        test(
          'parallel_workers_respect_both_caps ${byBytes ? 'bytes' : 'rows'}',
          () async {
            if (byBytes) {
              await _publish(session, 1, routes: [_first]);
              await _process(session, ['sample-0']);
            }
            final budget = byBytes
                ? {
                    'max_payload_bytes': (await session.db.unsafeQuery(
                      'SELECT octet_length(payload) FROM outbox',
                    )).single[0],
                  }
                : {'max_rows': 1};
            if (byBytes) {
              await session.db.unsafeExecute(
                "UPDATE outbox SET status='delivered'",
              );
            }
            await _publish(
              session,
              2,
              routes: [_first],
              budgets: {_first: budget},
            );
            await _send(session, ['sample-a']);
            await _send(session, ['sample-b']);
            final pins = _worker(session);
            expect(await pins.pinOne(), isTrue);
            expect(await pins.pinOne(), isTrue);
            final gate = ContentionGate();
            final both = Completer<void>();
            var arriving = 0;
            Future<void> claim() async {
              if (++arriving == 2) both.complete();
              await gate.future;
            }

            final first = gate.run(
              () => _worker(builder.build(), afterClaim: claim).processOne(),
            );
            final next = gate.run(
              () => _worker(builder.build(), afterClaim: claim).processOne(),
            );
            await both.future;
            await gate.join();
            expect(await Future.wait([first, next]), [true, true]);
            expect(await _intents(session), {_first: 1});
            expect((await _usage(session, _first))[2], 1);
            if (byBytes) {
              expect(
                (await _usage(session, _first))[1],
                budget['max_payload_bytes'],
              );
            }
          },
        );
      }

      test('lower_budget_leaves_old_work_intact', () async {
        final old = await _publish(session, 1);
        await _oldIntents(session, old, _first, 3);
        final previous = await session.db.unsafeQuery(
          'SELECT delivery_id::text,payload FROM outbox ORDER BY delivery_id',
        );
        await _publish(
          session,
          2,
          budgets: {
            _first: {'max_rows': 1},
          },
        );
        await _process(session, ['after-lowering']);
        final kept = await session.db.unsafeQuery(
          "SELECT delivery_id::text,payload FROM outbox WHERE output_id='$_first' ORDER BY delivery_id",
        );
        expect(
          kept.map((row) => row.toList()),
          previous.map((row) => row.toList()),
        );
        expect(await _usage(session, _first), [3, 3, 1]);
        expect(await _intents(session), {_first: 3, _second: 1});
      });

      test(
        'admission_uses_one_policy_when_publication_crosses_disk_sample',
        () async {
          final initial = await _publish(
            session,
            1,
            budgets: {
              _first: {'max_rows': 1000, 'overflow_policy': 'block_ingest'},
            },
            pressure: {'disk_budget_bytes': 1024 * 1024 * 1024 * 1024},
          );
          await _oldIntents(session, initial, _first, 1000);
          await session.db.unsafeExecute(
            "UPDATE pipeline_disk_sample SET sampled_at='-infinity'",
          );
          final witness = await PostgresLockWitness.start(session);
          addTearDown(witness.close);
          final gate = ContentionGate();
          final sampler = builder.build();
          final admitting = builder.build();
          final sampleReady = Completer<LockActor>();
          final admitReady = Completer<LockActor>();
          final holding = gate.run(
            () => sampler.db.transaction((tx) async {
              final actor = await pooledLockActor(sampler, tx);
              await sampler.db.unsafeQuery(
                'SELECT 1 FROM pipeline_disk_sample FOR UPDATE',
                transaction: tx,
              );
              sampleReady.complete(actor);
              await gate.future;
            }),
          );
          try {
            final holder = await Future.any([
              sampleReady.future,
              holding.then<LockActor>((_) => fail('Sample was not held')),
            ]);
            const reserve = 'SELECT correlia_reserve_raw(1)';
            final checking = gate.run(
              () => admitting.db.transaction((tx) async {
                admitReady.complete(
                  await pooledLockActor(
                    admitting,
                    tx,
                    waiter: SqlTimeouts.poolDefault,
                  ),
                );
                return (await admitting.db.unsafeQuery(
                  reserve,
                  transaction: tx,
                )).single[0];
              }),
            );
            final waiter = await Future.any([
              admitReady.future,
              checking.then<LockActor>(
                (_) => fail('Admission did not wait for a sample'),
              ),
            ]);
            await witness.blockedBy(
              waiter,
              holder,
              checking,
              statement: reserve,
            );
            await _publish(
              session,
              2,
              budgets: {
                _first: {'max_rows': 2000, 'overflow_policy': 'block_ingest'},
              },
              pressure: {'disk_budget_bytes': 1},
            );
            await gate.join();
            await holding;
            expect(await checking, 'output');
            expect(
              (await session.db.unsafeQuery(reserve)).single[0],
              'storage',
            );
          } finally {
            await gate.join();
          }
        },
      );

      test(
        'dur_11_block_defers_atomic_batch_without_spending_attempts',
        () async {
          final current = await _publish(
            session,
            1,
            budgets: {
              _first: {'max_rows': 1000, 'overflow_policy': 'block_ingest'},
            },
          );
          await _oldIntents(session, current, _first, 999);
          await _process(session, ['blocked-first', 'blocked-second']);
          final rows = await session.db.unsafeQuery(
            'SELECT status,config_snapshot_id,attempt_count,next_attempt_at FROM raw_inbox',
          );
          expect(rows.single.take(3), ['pending', current.snapshotId, 0]);
          expect(rows.single[3], isNotNull);
          expect(await _intents(session), {_first: 999});
          expect(await raw.count(session, 'alerts'), 0);
          expect(await raw.count(session, 'events'), 0);
          expect(await raw.count(session, 'observation_keys'), 0);
          expect(
            (await session.db.unsafeQuery(
              'SELECT correlia_reserve_raw(1)',
            )).single[0],
            'output',
          );
          await session.db.unsafeExecute('''
        UPDATE outbox SET status='delivered' WHERE (created_at,delivery_id) IN (
          SELECT created_at,delivery_id FROM outbox ORDER BY created_at,delivery_id LIMIT 2)
      ''');
          await session.db.unsafeExecute(
            'UPDATE raw_inbox SET next_attempt_at=NULL',
          );
          expect(await _worker(session).processOne(), isTrue);
          expect(await _intents(session), {_first: 999, _second: 2});
          expect(
            (await session.db.unsafeQuery(
              'SELECT correlia_reserve_raw(1)',
            )).single[0],
            isNull,
          );
        },
      );

      for (final duplicate in [false, true]) {
        test(
          'capacity_lock_statement_timeout_keeps_processing_allowance duplicate=$duplicate',
          () async {
            await _publish(session, 1, outputs: [_first]);
            const alert = ['valid-during-capacity-contention'];
            if (duplicate) await _process(session, alert);
            await _send(session, alert);
            final pinner = _worker(session);
            expect(await pinner.pinOne(), isTrue);
            await session.db.unsafeExecute(
              "UPDATE raw_inbox SET attempt_count=4 WHERE status='pending'",
            );
            final locker = builder.build();
            final locked = Completer<void>();
            final gate = ContentionGate();
            final holding = gate.run(
              () => locker.db.transaction((tx) async {
                await locker.db.unsafeQuery('''
                SELECT 1 FROM pipeline_output_capacity WHERE output_id='$_first' FOR UPDATE
              ''', transaction: tx);
                locked.complete();
                await gate.future;
              }),
            );
            try {
              await Future.any([
                locked.future,
                holding.then<void>((_) => fail('Capacity lock was not held')),
              ]);
              final contender = PipelineRepository(
                session,
                clock: () => raw.now,
                elapsedForTest: () => Duration.zero,
                beforeCapacityLockForTest: (tx) => session.db.unsafeSimpleExecute(
                  "SET LOCAL statement_timeout='50ms'; SET LOCAL lock_timeout=0",
                  transaction: tx,
                ),
              );
              expect(await contender.processOne(), isTrue);
              final row = (await session.db.unsafeQuery(
                "SELECT status,attempt_count,next_attempt_at FROM raw_inbox WHERE status='pending'",
              )).single;
              expect(row.toList(), [
                'pending',
                4,
                raw.now.add(const Duration(seconds: 1)),
              ]);
              expect(await raw.count(session, 'events'), duplicate ? 1 : 0);
              expect(await raw.count(session, 'pipeline_failures'), 0);
              await gate.join();
              await holding;
              await session.db.unsafeExecute(
                'UPDATE raw_inbox SET next_attempt_at=NULL',
              );
              expect(await pinner.processOne(), isTrue);
              expect(await _intents(session), {_first: 1});
              expect(await raw.count(session, 'events'), 1);
            } finally {
              await gate.join();
            }
          },
        );
      }

      test('output_write_refreshes_remaining_deadline', () async {
        await _publish(session, 1, outputs: [_first]);
        await _send(session, ['bounded-output-insert']);
        await session.db.unsafeSimpleExecute(r'''
          CREATE FUNCTION test_output_write_deadline() RETURNS trigger
          LANGUAGE plpgsql AS $$
          BEGIN
            IF current_setting('statement_timeout')::interval > interval '4 seconds'
            THEN
              RAISE EXCEPTION 'output insert exceeds the remaining row deadline';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER test_output_write_deadline BEFORE INSERT ON outbox
            FOR EACH ROW EXECUTE FUNCTION test_output_write_deadline()
        ''');
        addTearDown(
          () => session.db.unsafeSimpleExecute('''
            DROP TRIGGER test_output_write_deadline ON outbox;
            DROP FUNCTION test_output_write_deadline()
          '''),
        );
        var elapsed = Duration.zero;
        final worker = PipelineRepository(
          session,
          clock: () => raw.now,
          elapsedForTest: () => elapsed,
          beforeCapacityLockForTest: (_) async {
            elapsed = const Duration(seconds: 6);
          },
        );
        expect(await worker.pinOne(), isTrue);
        expect(await worker.processOne(), isTrue);
        expect(await _intents(session), {_first: 1});
        expect(
          (await session.db.unsafeQuery(
            'SELECT status FROM raw_inbox',
          )).single[0],
          'done',
        );
      });

      test('event_partition_lock_timeout_keeps_processing_allowance', () async {
        await _publish(session, 1, outputs: [_first]);
        await _send(session, ['valid-during-event-partition-ddl']);
        final pinner = _worker(session);
        expect(await pinner.pinOne(), isTrue);
        await session.db.unsafeExecute(
          'UPDATE raw_inbox SET attempt_count=4',
        );
        final locker = builder.build();
        final locked = Completer<void>();
        final gate = ContentionGate();
        final holding = gate.run(
          () => locker.db.transaction((tx) async {
            await locker.db.unsafeExecute(
              'LOCK TABLE ONLY events IN ACCESS EXCLUSIVE MODE',
              transaction: tx,
            );
            locked.complete();
            await gate.future;
          }),
        );
        try {
          await Future.any([
            locked.future,
            holding.then<void>((_) => fail('Partition lock was not held')),
          ]);
          final contender = PipelineRepository(
            session,
            clock: () => raw.now,
            elapsedForTest: () => Duration.zero,
            beforeEventWriteForTest: (tx) => session.db.unsafeSimpleExecute(
              "SET LOCAL statement_timeout='50ms'; SET LOCAL lock_timeout=0",
              transaction: tx,
            ),
          );
          expect(await contender.processOne(), isTrue);
          final row = (await session.db.unsafeQuery(
            'SELECT status,attempt_count,next_attempt_at FROM raw_inbox',
          )).single;
          expect(row.toList(), [
            'pending',
            4,
            raw.now.add(const Duration(seconds: 1)),
          ]);
          expect(await raw.count(session, 'pipeline_failures'), 0);
          expect(await raw.count(session, 'observation_keys'), 0);
          expect(await raw.count(session, 'alerts'), 0);
          await gate.join();
          await holding;
          await session.db.unsafeExecute(
            'UPDATE raw_inbox SET next_attempt_at=NULL',
          );
          expect(await pinner.processOne(), isTrue);
          expect(await _intents(session), {_first: 1});
          expect(await raw.count(session, 'events'), 1);
        } finally {
          await gate.join();
        }
      });

      test(
        'deferral_deadline_leaves_the_processing_allowance_intact',
        () async {
          final snapshot = await _publish(
            session,
            1,
            budgets: {
              _first: {'max_rows': 1000, 'overflow_policy': 'block_ingest'},
            },
          );
          await _oldIntents(session, snapshot, _first, 999);
          await _send(session, [
            'defer-after-capacity-check-a',
            'defer-after-capacity-check-b',
          ]);
          await session.db.unsafeExecute(
            'UPDATE raw_inbox SET queued_at=clock_timestamp()',
          );
          var forceExpiry = false;
          var refusals = 0;
          var now = raw.now;
          final worker = PipelineRepository(
            session,
            clock: () => now,
            elapsedForTest: () {
              if (!forceExpiry) return Duration.zero;
              forceExpiry = false;
              return pipelineRowDeadline;
            },
            afterOutputRefusalForTest: () {
              refusals++;
              forceExpiry = true;
            },
          );
          expect(await worker.pinOne(), isTrue);
          for (var attempt = 0; attempt < 6; attempt++) {
            expect(await worker.processOne(), isTrue);
            expect(
              (await session.db.unsafeQuery(
                'SELECT correlia_reserve_raw(1)',
              )).single[0],
              'output',
            );
            final row = (await session.db.unsafeQuery('''
            SELECT status,attempt_count,next_attempt_at FROM raw_inbox
          ''')).single;
            expect(row.toList(), [
              'pending',
              0,
              now.add(const Duration(seconds: 1)),
            ]);
            expect(await worker.processOne(), isFalse);
            now = row[2]! as DateTime;
          }
          expect(refusals, 6);
          expect(await raw.count(session, 'pipeline_failures'), 0);
          expect(await raw.count(session, 'events'), 0);
          expect(await _intents(session), {_first: 999});
          await session.db.unsafeExecute('''
            UPDATE outbox SET status='delivered' WHERE (created_at,delivery_id) IN (
              SELECT created_at,delivery_id FROM outbox ORDER BY created_at,delivery_id LIMIT 2)
          ''');
          expect(await worker.processOne(), isTrue);
          expect(await raw.count(session, 'events'), 2);
        },
      );

      test('eligible_old_deferrals_cannot_starve_healthy_work', () async {
        final previous = await _publish(
          session,
          1,
          routes: [_first],
          budgets: {
            _first: {'max_rows': 1000, 'overflow_policy': 'block_ingest'},
          },
        );
        await _oldIntents(session, previous, _first, 1000);
        Future<void> seed(String name, DateTime at) => raw.seed(session, [
          payload.alert(
            startsAt: at.toIso8601String(),
            labels: {'alertname': name},
          ),
        ], observed: at);
        var now = raw.now;
        final worker = PipelineRepository(
          session,
          clock: () => now,
          elapsedForTest: () => Duration.zero,
        );
        await seed('deferred-first', now);
        await seed('deferred-second', now.add(const Duration(milliseconds: 1)));
        expect(await worker.pinOne(), isTrue);
        expect(await worker.pinOne(), isTrue);
        await _publish(
          session,
          2,
          routes: [_second],
          budgets: {
            _first: {'max_rows': 1000, 'overflow_policy': 'block_ingest'},
          },
        );
        await seed('healthy', now.add(const Duration(milliseconds: 2)));
        expect(await worker.pinOne(), isTrue);
        for (var claim = 0; claim < 3; claim++) {
          now = now.add(const Duration(seconds: 2));
          expect(await worker.processOne(), isTrue);
        }
        expect(await _intents(session), {_first: 1000, _second: 1});
        final deferred = await session.db.unsafeQuery('''
          SELECT attempt_count FROM raw_inbox WHERE status='pending' AND next_attempt_at IS NOT NULL
        ''');
        expect(deferred.map((row) => row[0]), [0, 0]);
      });

      test(
        'completed_deferrals_release_only_their_own_output_demand',
        () async {
          const budgets = {
            _first: {'max_rows': 1000, 'overflow_policy': 'block_ingest'},
          };
          final previous = await _publish(
            session,
            1,
            routes: [_first],
            budgets: budgets,
          );
          await _oldIntents(session, previous, _first, 999);
          var now = raw.now;
          final worker = PipelineRepository(
            session,
            clock: () => now,
            elapsedForTest: () => Duration.zero,
          );
          Future<void> pin(List<String> names, int offset) async {
            await raw.seed(session, [
              for (final name in names)
                payload.alert(
                  startsAt: raw.now.toIso8601String(),
                  labels: {'alertname': name},
                ),
            ], observed: raw.now.add(Duration(milliseconds: offset)));
            expect(await worker.pinOne(), isTrue);
          }

          Future<Object?> pressure() async => (await session.db.unsafeQuery(
            'SELECT correlia_reserve_raw(1)',
          )).single[0];
          final first = ['a', 'b'];
          final second = ['c', 'd', 'e'];
          await pin(first, 0);
          await pin(second, 1);
          await _publish(session, 2, routes: [_second], budgets: budgets);
          await pin(first, 2);
          await pin(second, 3);
          for (var claim = 0; claim < 4; claim++) {
            now = now.add(const Duration(seconds: 2));
            expect(await worker.processOne(), isTrue);
          }
          expect(await _intents(session), {_first: 999, _second: 5});
          expect(await pressure(), 'output');
          expect(await worker.processOne(), isTrue);
          expect(
            await pressure(),
            'output',
            reason: 'the second deferred row is still pending',
          );
          expect(await worker.processOne(), isTrue);
          expect(await pressure(), isNull);
          expect(await _intents(session), {_first: 999, _second: 5});
        },
      );

      Future<int> notices() async =>
          (await session.db.unsafeQuery(
                "SELECT count(*) FROM activity WHERE change_kind='output_overflow'",
              )).single[0]!
              as int;

      Future<List<List<Object?>>> noticePayload(String output) async => [
        for (final row in await session.db.unsafeQuery('''
        SELECT e.system_activity_id,e.raw_id,e.raw_observed_at,e.payload,
          n.evidence, o.output_id::text, e.tableoid::regclass::text
        FROM events e JOIN pipeline_overflow_notice n ON n.activity_id=e.system_activity_id
        JOIN outbox o ON (o.event_observed_at,o.event_id,o.event_disposition)=
          (e.observed_at,e.event_id,e.disposition)
        WHERE o.output_id=@id::uuid
      ''', parameters: QueryParameters.named({'id': output})))
          row.toList(),
      ];

      void verifyEvidence(List<Object?> row) {
        expect(row.sublist(1, 3), [null, null]);
        final evidence = utf8.encode(row[4]! as String);
        final envelope = CloudEvent.decode(row[3]! as Uint8List).event;
        expect(envelope.source.sourceKind, 'correlia');
        expect(envelope.raw.ref, 'activity:${row[0]}');
        expect(envelope.raw.sha256, sha256.convert(evidence).toString());
        expect(envelope.raw.size, evidence.length);
        expect(row[4], isNot(contains('https://')));
      }

      test('notice_reaches_healthy_output_with_ledger_evidence', () async {
        await _publish(
          session,
          1,
          routes: [_first],
          budgets: {
            _first: {'max_rows': 1},
          },
        );
        await _process(session, ['overflow-notice-a', 'overflow-notice-b']);
        expect(await notices(), 1);
        final router = OverflowNotices(session);
        expect(await router.routeOne(), isTrue);
        expect(await router.routeOne(), isFalse);
        expect(await _intents(session), {_first: 1, _second: 1});
        verifyEvidence((await noticePayload(_second)).single);
        expect(await raw.count(session, 'raw_inbox'), 1);
        expect(await raw.count(session, 'alerts'), 2);
      });

      test('full_notice_destinations_do_not_enqueue_or_recurse', () async {
        final snapshot = await _publish(
          session,
          1,
          routes: [_first],
          budgets: {
            _first: {'max_rows': 1},
            _second: {'max_rows': 1},
          },
        );
        await _oldIntents(session, snapshot, _second, 1);
        await _process(session, ['full-notice']);
        expect(await notices(), 1);
        final router = OverflowNotices(session);
        expect(await router.routeOne(), isTrue);
        expect(await notices(), 1);
        expect(await router.routeOne(), isFalse);
        expect(await _intents(session), {_first: 1, _second: 1});
      });

      test('notice_at_exact_cap_blocks_ingress_without_recurse', () async {
        const budgets = {
          _first: {'max_rows': 1},
          _second: {
            'max_rows': 1001,
            'max_payload_bytes': 16 * 1024 * 1024,
            'overflow_policy': 'block_ingest',
          },
        };
        final snapshot = await _publish(
          session,
          1,
          routes: [_first],
          budgets: budgets,
        );
        await _oldIntents(session, snapshot, _second, 1000);
        await _process(session, ['fills-other']);
        expect(await notices(), 1);
        final router = OverflowNotices(session);
        expect(await router.routeOne(), isTrue);
        expect(await router.routeOne(), isFalse);
        expect(await _intents(session), {_first: 1, _second: 1001});
        expect(
          (await session.db.unsafeQuery(
            'SELECT correlia_reserve_raw(1)',
          )).single[0],
          'output',
        );
        expect(await notices(), 1);
        await _publish(session, 2, routes: [_first], budgets: budgets);
        expect(await notices(), 1);
        expect(await router.routeOne(), isFalse);
        await _publish(
          session,
          3,
          routes: [_first],
          budgets: {
            ...budgets,
            _second: {
              'max_rows': 1000,
              'max_payload_bytes': 16 * 1024 * 1024,
              'overflow_policy': 'block_ingest',
            },
          },
        );
        expect(await notices(), 2);
        expect(await _intents(session), {_first: 1, _second: 1001});
      });

      for (final parent in ['events', 'outbox']) {
        test('notice_leaves_capacity_free_while_${parent}_ddl_waits', () async {
          await _publish(
            session,
            1,
            routes: [_first],
            budgets: {
              _first: {'max_rows': 1},
            },
          );
          await _process(session, ['ddl-overflow-a', 'ddl-overflow-b']);
          expect(await notices(), 1);
          final witness = await PostgresLockWitness.start(session);
          addTearDown(witness.close);
          final waiters = ContentionGate();
          final releaseWriter = ContentionGate();
          final writer = builder.build();
          final ddl = builder.build();
          final router = builder.build();
          final writerReady = Completer<LockActor>();
          final ddlReady = Completer<LockActor>();
          final routerReady = Completer<LockActor>();
          final writing = releaseWriter.run(
            () => writer.db.transaction((tx) async {
              final actor = await pooledLockActor(writer, tx);
              await writer.db.unsafeExecute(
                'LOCK TABLE ONLY $parent IN ROW EXCLUSIVE MODE',
                transaction: tx,
              );
              writerReady.complete(actor);
              await releaseWriter.future;
              await writer.db.unsafeQuery('''
              SELECT 1 FROM pipeline_output_capacity
              WHERE output_id='$_second' FOR UPDATE NOWAIT
            ''', transaction: tx);
              if (parent == 'outbox') {
                // Replay already holds outbox when it asks for the registry.
                await writer.db.unsafeQuery(
                  'SELECT singleton FROM ingest_active_config FOR UPDATE NOWAIT',
                  transaction: tx,
                );
              }
            }),
          );
          try {
            final holder = await Future.any([
              writerReady.future,
              writing.then<LockActor>(
                (_) => fail('Writer did not hold $parent'),
              ),
            ]);
            final ddlLock = 'LOCK TABLE ONLY $parent IN ACCESS EXCLUSIVE MODE';
            final altering = waiters.run(
              () => ddl.db.transaction((tx) async {
                ddlReady.complete(
                  await pooledLockActor(
                    ddl,
                    tx,
                    waiter: SqlTimeouts.poolDefault,
                  ),
                );
                await ddl.db.unsafeExecute(ddlLock, transaction: tx);
              }),
            );
            final ahead = await Future.any([
              ddlReady.future,
              altering.then<LockActor>((_) => fail('DDL did not wait')),
            ]);
            await witness.blockedBy(
              ahead,
              holder,
              altering,
              statement: ddlLock,
            );
            final routing = waiters.run(
              () => OverflowNotices(
                router,
                beforeRelationLocksForTest: (tx) async => routerReady.complete(
                  await pooledLockActor(
                    router,
                    tx,
                    waiter: SqlTimeouts.overflowNotice,
                  ),
                ),
              ).routeOne(),
            );
            final behind = await Future.any([
              routerReady.future,
              routing.then<LockActor>((_) => fail('Notice did not wait')),
            ]);
            await witness.blockedBy(behind, ahead, routing, statement: parent);
            await releaseWriter.join();
            await writing;
            await altering;
            expect(await routing, isTrue);
            verifyEvidence((await noticePayload(_second)).single);
          } finally {
            await releaseWriter.join();
            await waiters.join();
          }
        });
      }

      test('notice_registry_race_keeps_live_lane_limit', () async {
        await _publish(
          session,
          1,
          routes: [_first],
          budgets: {
            _first: {'max_rows': 1},
          },
        );
        await _process(session, ['changing-notice']);
        expect(await notices(), 1);
        await session.db.unsafeExecute("UPDATE outbox SET status='delivered'");
        final replacement = [
          for (var i = 0; i < 64; i++)
            'aaaaaaaa-aaaa-4aaa-8aaa-${i.toString().padLeft(12, '0')}',
        ];
        final claimed = Completer<void>();
        final gate = ContentionGate();
        final routing = gate.run(
          () => OverflowNotices(
            builder.build(),
            afterRegistryLockForTest: (_) async {
              claimed.complete();
              await gate.future;
            },
          ).routeOne(),
        );
        await claimed.future;
        await expectLater(
          session.db.unsafeQuery(
            'SELECT singleton FROM ingest_active_config FOR UPDATE NOWAIT',
          ),
          throwsA(
            isA<DatabaseQueryException>().having(
              (e) => e.code,
              'code',
              '55P03',
            ),
          ),
        );
        await gate.join();
        expect(await routing, isTrue);
        await expectLater(
          _publish(session, 2, outputs: replacement, routes: []),
          throwsA(
            isA<BootstrapError>().having(
              (e) => e.code,
              'code',
              'retained_output_bound',
            ),
          ),
        );
        expect(await _intents(session), {_second: 1});
        await session.db.unsafeExecute("UPDATE outbox SET status='delivered'");
        await _publish(session, 2, outputs: replacement, routes: []);
        expect(await _intents(session), isEmpty);
      });

      for (final completionFirst in [true, false]) {
        test(
          'completion_and_recovery_order_one_capacity_delta ${completionFirst ? 'completion first' : 'recovery first'}',
          () async {
            final snapshot = await _publish(session, 1);
            await _oldIntents(session, snapshot, _first, 1);
            final witness = await PostgresLockWitness.start(session);
            addTearDown(witness.close);
            final gate = ContentionGate();
            final completing = builder.build();
            final recovering = builder.build();
            final held = Completer<void>();
            final recoveryActor = Completer<LockActor>();
            final completionActor = Completer<LockActor>();
            final completion = OutputRelayRepository(
              completing,
              testSecretResolver(completing).resolve,
              afterCompletionOutbox: completionFirst
                  ? () async {
                      held.complete();
                      await gate.future;
                    }
                  : null,
              beforeCompletionLockForTest: completionFirst
                  ? null
                  : (tx) async {
                      final actor = await pooledLockActor(completing, tx);
                      await completing.db.unsafeSimpleExecute(
                        "SET LOCAL log_lock_waits=on; SET LOCAL deadlock_timeout='1ms'",
                        transaction: tx,
                      );
                      completionActor.complete(actor);
                    },
            );
            final recovery = OutputRelayRepository(
              recovering,
              testSecretResolver(recovering).resolve,
            );
            final claim = (await completion.claim(_first))!.claims.single;
            // Give recovery a later eligibility sample while completion uses
            // the valid lease it saw before the cutoff.
            final leaseEnd = DateTime.utc(2099);
            await session.db.unsafeExecute(
              'UPDATE outbox SET lease_until=@at',
              parameters: QueryParameters.named({'at': leaseEnd}),
            );
            final recoveryTime = leaseEnd.add(const Duration(microseconds: 1));
            if (completionFirst) {
              final result = gate.run(
                () => completion.complete(claim, const DeliveryAcknowledged()),
              );
              await Future.any([
                held.future,
                result.then(
                  (_) => fail('Completion did not acquire the intent'),
                ),
              ]);
              expect(
                await recovery.recoverExpired(nowForTest: recoveryTime),
                isFalse,
              );
              await gate.join();
              expect(await result, isTrue);
            } else {
              final recovered = gate.run(
                () => recovery.recoverExpired(
                  nowForTest: recoveryTime,
                  afterLockForTest: (tx) async {
                    recoveryActor.complete(
                      await pooledLockActor(recovering, tx),
                    );
                    await gate.future;
                  },
                ),
              );
              final blocker = await Future.any([
                recoveryActor.future,
                recovered.then<LockActor>(
                  (_) => fail('Recovery did not acquire the intent'),
                ),
              ]);
              final stale = gate.run(
                () => completion.complete(claim, const DeliveryAcknowledged()),
              );
              final waiter = await Future.any([
                completionActor.future,
                stale.then<LockActor>(
                  (_) => fail('Completion did not try to lock the intent'),
                ),
              ]);
              await witness.blockedBy(
                waiter,
                blocker,
                stale,
                statement: 'WITH held AS MATERIALIZED',
              );
              await gate.join();
              expect(await recovered, isTrue);
              expect(await stale, isFalse);
            }
            expect(
              await _usage(session, _first),
              completionFirst ? [0, 0, 0] : [1, 1, 0],
            );
            final outcome = (await session.db.unsafeQuery(
              'SELECT outcome FROM delivery_attempts',
            )).single[0];
            expect(outcome, completionFirst ? 'acknowledged' : 'interrupted');
          },
        );
      }
    },
    rollbackDatabase: RollbackDatabase.disabled,
    ephemeralDatabase: false,
    configOverride: cluster.override,
    testGroupTagsOverride: ['db'],
  );

  final historicalCluster = LockWitnessCluster();
  tearDownAll(historicalCluster.close);
  withServerpod(
    'overflow routes into a pre-existing heap',
    (builder, _) {
      test(
        'upgraded_historical_event_child_accepts_and_routes_notice',
        () async {
          final session = builder.build();
          await applySchemaSteps(
            session,
            schemaSteps.where((step) => step.version < 15).toList(),
          );
          const priorOutput = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
          await session.db.unsafeSimpleExecute('''
        INSERT INTO events (observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,
          config_snapshot_id,source_time,payload)
        VALUES ('2026-11-10 23:00 UTC',gen_random_uuid(),'ready','2026-11-10 23:00 UTC',
          gen_random_uuid(),'${config.sourceId}','prior-pin','2026-11-10 23:00 UTC',
          convert_to('{"subject":"historical-fixture","data":{}}','UTF8'));
        INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,
          output_id,config_snapshot_id,output_kind,definition_digest,payload,status,dead_reason)
        VALUES ('2026-11-10 23:00 UTC',gen_random_uuid(),'2026-11-10 23:00 UTC',gen_random_uuid(),
          'ready','$priorOutput','prior-pin','plugin',
          repeat('a',64),convert_to('{}','UTF8'),'dead','old_plugin_private_label')
      ''');
          const legacy = '''
            SELECT raw_observed_at,raw_id::text,payload FROM events WHERE config_snapshot_id='prior-pin'
          ''';
          final senderBefore = (await session.db.unsafeQuery(
            legacy,
          )).single.toList();
          final receiver = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          addTearDown(() => receiver.close(force: true));
          final received = Completer<(Uint8List, String?)>();
          receiver.listen((request) async {
            final bytes = await request.fold(
              BytesBuilder(copy: false),
              (value, chunk) => value..add(chunk),
            );
            received.complete((
              bytes.takeBytes(),
              request.headers.value('idempotency-key'),
            ));
            request.response.statusCode = 204;
            await request.response.close();
          });
          await applySchemaSteps(session, schemaSteps);
          expect(
            (await session.db.unsafeQuery('''
              SELECT error_class FROM pipeline_dead_letter WHERE kind='delivery'
            ''')).single[0],
            'plugin_failure',
          );
          await _publish(
            session,
            1,
            routes: [_first],
            urls: {_second: 'http://127.0.0.1:${receiver.port}/events'},
            budgets: {
              _first: {'max_rows': 1},
            },
          );
          await _process(session, ['legacy-child-overflow']);
          final before =
              (await session.db.unsafeQuery(
                    'SELECT clock_timestamp()',
                  )).single[0]!
                  as DateTime;
          expect(await OverflowNotices(session).routeOne(), isTrue);
          final after =
              (await session.db.unsafeQuery(
                    'SELECT clock_timestamp()',
                  )).single[0]!
                  as DateTime;
          final intent = (await session.db.unsafeQuery('''
            SELECT o.created_at,o.tableoid::regclass::text,r.child_name
            FROM outbox o JOIN pipeline_partition_range r ON r.parent_name='outbox'
              AND r.first_day <= (o.created_at AT TIME ZONE 'UTC')::date
              AND r.end_day > (o.created_at AT TIME ZONE 'UTC')::date
            WHERE o.output_id='$_second'
          ''')).single;
          final created = intent[0]! as DateTime;
          expect(created.isBefore(before) || created.isAfter(after), isFalse);
          expect(intent[1], intent[2]);
          final result = (await session.db.unsafeQuery('''
        SELECT e.tableoid::regclass::text,e.raw_observed_at,e.raw_id,e.system_activity_id,
          n.evidence,payload
        FROM events e JOIN pipeline_overflow_notice n ON n.activity_id=e.system_activity_id
      ''')).single;
          expect(result[0], 'legacy_events');
          expect(result.toList().sublist(1, 3), [null, null]);
          final envelope = CloudEvent.decode(result[5]! as Uint8List).event;
          expect(envelope.raw.ref, 'activity:${result[3]}');
          final evidence = utf8.encode(result[4]! as String);
          expect(envelope.raw.sha256, sha256.convert(evidence).toString());
          expect(envelope.raw.size, evidence.length);
          expect(await _intents(session), {
            _first: 1,
            _second: 1,
            priorOutput: 1,
          });
          final relay = OutputRelayRepository(
            session,
            testSecretResolver(session).resolve,
          );
          final claim = (await relay.claim(_second))!.claims.single;
          final transport = WebhookOutput(
            runMode: 'test',
            deadline: const Duration(minutes: 2),
          );
          addTearDown(transport.close);
          final outcome = await transport.send(claim.intent!, claim.key!);
          expect(outcome, isA<DeliveryAcknowledged>());
          expect(await relay.complete(claim, outcome), isTrue);
          final (body, key) = await received.future;
          expect(body, result[5]);
          expect(key, envelope.eventId);
          expect(
            (await session.db.unsafeQuery(legacy)).single.toList(),
            senderBefore,
          );
        },
      );
    },
    rollbackDatabase: RollbackDatabase.disabled,
    ephemeralDatabase: false,
    configOverride: historicalCluster.override,
    testGroupTagsOverride: ['db'],
  );
}
