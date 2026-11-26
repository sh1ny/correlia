import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/event/cloud_event.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/output/overflow_notices.dart';
import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:correlia_server/src/output/output_relay.dart';
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
              'url': 'https://example.com/events',
              'signing_key_ref': 'key-v1',
            },
        ],
        'pipeline_operations': {'output_budgets': budgets},
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
          await _publish(
            session,
            2,
            outputs: [_first],
            budgets: {
              _first: {'max_payload_bytes': used + 100},
            },
          );
          final ops = QueueOperations(session);
          Future<int?> episode() async =>
              (await ops.status()).outputs.single.overflowActivityId;
          await _process(session, ['large-a-${'a' * 500}']);
          final initial = await episode();
          expect(initial, isNotNull);
          await _process(session, ['small-again']);
          expect(await _intents(session), {_first: 1});
          await session.db.unsafeExecute(
            "UPDATE outbox SET status='delivered' WHERE status='queued'",
          );
          expect(await episode(), isNull);
          await _process(session, ['large-b-${'b' * 500}']);
          final next = await episode();
          expect(next, isNotNull);
          expect(next, isNot(initial));
          expect(await _usage(session, _first), [0, 0, 2]);
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
        expect(await OverflowNotices(session).routeOne(), isTrue);
        expect(await _intents(session), {_first: 1, _second: 1});
      });

      test('notice_at_exact_cap_blocks_ingress_without_recurse', () async {
        final snapshot = await _publish(
          session,
          1,
          routes: [_first],
          budgets: {
            _first: {'max_rows': 1},
            _second: {'max_rows': 1000, 'overflow_policy': 'block_ingest'},
          },
        );
        await _oldIntents(session, snapshot, _second, 999);
        await _process(session, ['fills-other']);
        expect(await notices(), 1);
        final router = OverflowNotices(session);
        expect(await router.routeOne(), isTrue);
        expect(await router.routeOne(), isFalse);
        expect(await _intents(session), {_first: 1, _second: 1000});
        expect(
          (await session.db.unsafeQuery(
            'SELECT correlia_reserve_raw(1)',
          )).single[0],
          'output',
        );
        expect(await notices(), 1);
      });

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
            afterRegistryLockForTest: () async {
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
          await session.db.unsafeSimpleExecute('''
        INSERT INTO events (observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,
          config_snapshot_id,source_time,payload)
        VALUES ('2026-11-10 23:00 UTC',gen_random_uuid(),'ready','2026-11-10 23:00 UTC',
          gen_random_uuid(),'${config.sourceId}','prior-pin','2026-11-10 23:00 UTC',
          convert_to('{"subject":"historical-fixture","data":{}}','UTF8'))
      ''');
          await applySchemaSteps(session, schemaSteps);
          await _publish(
            session,
            1,
            routes: [_first],
            budgets: {
              _first: {'max_rows': 1},
            },
          );
          await _process(session, ['legacy-child-overflow']);
          expect(await OverflowNotices(session).routeOne(), isTrue);
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
          expect(await _intents(session), {_first: 1, _second: 1});
        },
      );
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
