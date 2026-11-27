import 'dart:async';

import 'package:correlia_server/src/generated/protocol.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;
import '../support/postgres_lock_witness.dart' show ContentionGate;
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' show outputId, pluginInput, sourceId, token;
import 'pipeline_test.dart' as raw;

Map<String, Object?> _config(int revision, [Map<String, Object?>? policy]) => {
  'format_version': 2,
  'revision': revision,
  'sources': [
    {
      'id': sourceId,
      'kind': 'alertmanager',
      'enabled': true,
      'credentials': [
        {'ref': 'source-token', 'type': 'bearer'},
      ],
      'output_ids': [outputId],
    },
  ],
  'outputs': [
    {
      'id': outputId,
      'kind': 'webhook',
      'url': 'https://example.com/events',
      'signing_key_ref': 'key-v1',
    },
  ],
  'pipeline_operations': ?policy,
};

Map<String, String> _secrets() => {
  'source-token': token(1),
  'key-v1': token(2),
};

Matcher _error(String code) =>
    isA<BootstrapError>().having((e) => e.code, 'code', code);

Future<void> _outbox(
  Session session,
  IngestBootstrap snapshot,
  int count, {
  String? reference,
  String? commitment,
}) async {
  final output = snapshot.outputs.single as WebhookIngestOutput;
  await session.db.unsafeExecute(
    '''INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,
      event_disposition,output_id,config_snapshot_id,target_url,signing_key_ref,
      signing_key_commitment,payload)
    SELECT transaction_timestamp(),gen_random_uuid(),transaction_timestamp(),gen_random_uuid(),
      'ready',@output::uuid,@pin,'https://example.com/events',@reference,@commitment,decode('ffddee','hex')
    FROM generate_series(1,@count)''',
    parameters: QueryParameters.named({
      'output': output.id,
      'pin': snapshot.snapshotId,
      'reference': reference ?? output.signingKeyRef,
      'commitment': commitment ?? output.signingKeyCommitment,
      'count': count,
    }),
  );
}

Future<void> _pluginIntents(
  Session session,
  IngestBootstrap snapshot,
  int count,
) async {
  final output = snapshot.outputs.single as PluginIngestOutput;
  await session.db.unsafeExecute(
    '''INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,
      output_id,config_snapshot_id,output_kind,definition_digest,payload)
    SELECT transaction_timestamp(),gen_random_uuid(),transaction_timestamp(),gen_random_uuid(),
      'ready',@output::uuid,@pin,'plugin',@digest,decode('ffddee','hex')
    FROM generate_series(1,@count)''',
    parameters: QueryParameters.named({
      'output': output.id,
      'pin': snapshot.snapshotId,
      'digest': output.definitionDigest,
      'count': count,
    }),
  );
}

Future<(int, int)> _reads(
  Session session,
  Future<void> Function(Transaction) operation,
) => session.db.transaction((tx) async {
  Future<DatabaseResult> counters() => session.db.unsafeQuery(r'''
    SELECT coalesce(sum(seq_tup_read+idx_tup_fetch) FILTER
      (WHERE relname ~ '^(outbox|raw_inbox)(_|$)'),0)::int,
      coalesce(sum(seq_tup_read+idx_tup_fetch) FILTER
      (WHERE relname IN ('pipeline_output_capacity','pipeline_output_commitment')),0)::int
    FROM pg_stat_xact_user_tables WHERE schemaname=current_schema()
  ''', transaction: tx);
  final before = (await counters()).single;
  await operation(tx);
  final after = (await counters()).single;
  return (
    (after[0]! as int) - (before[0]! as int),
    (after[1]! as int) - (before[1]! as int),
  );
});

void main() {
  withServerpod(
    'versioned pipeline configuration and queue inventory',
    (builder, _) {
      late Session session;
      late IngestConfigRepository repository;
      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
      });

      test(
        'explicit_pipeline_defaults_keep_snapshot_and_definition_bytes',
        () async {
          final old = await repository.publishConfig(
            _config(1),
            _secrets(),
            runMode: 'test',
          );
          final equivalent = await repository.publishConfig(
            _config(1, {
              'pending_max_rows': 50000,
              'pending_max_age_seconds': 30,
              'disk_watermark_percent': 85,
              'raw_retention_days': 30,
              'event_retention_days': 90,
              'outbox_retention_days': 7,
              'dead_letter_retention_days': 14,
              'output_budgets': {
                outputId: {
                  'max_rows': 500000,
                  'max_payload_bytes': 1073741824,
                  'overflow_policy': 'discard_new',
                },
              },
            }),
            _secrets(),
            runMode: 'test',
          );
          expect(equivalent.snapshotId, old.snapshotId);
          expect(equivalent.publicJson, old.publicJson);
          final stricter = await repository.publishConfig(
            _config(2, {
              'pending_max_rows': 2,
              'output_budgets': {
                outputId: {'max_rows': 7},
              },
            }),
            _secrets(),
            runMode: 'test',
          );
          expect(stricter.publicJson, contains('"pending_max_rows":2'));
          expect(stricter.outputs.single.toJson(), old.outputs.single.toJson());
        },
      );

      test('undersized_blocking_budget_cannot_publish', () async {
        final old = await repository.publishConfig(
          _config(1),
          _secrets(),
          runMode: 'test',
        );
        for (final (rows, bytes) in [(999, 16777216), (1000, 16777215)]) {
          await expectLater(
            repository.publishConfig(
              _config(2, {
                'output_budgets': {
                  outputId: {
                    'max_rows': rows,
                    'max_payload_bytes': bytes,
                    'overflow_policy': 'block_ingest',
                  },
                },
              }),
              _secrets(),
              runMode: 'test',
            ),
            throwsA(_error('blocking_output_bound')),
          );
          expect(
            (await repository.activeSnapshot())?['snapshotId'],
            old.snapshotId,
          );
        }
        final sufficient = await repository.publishConfig(
          _config(2, {
            'output_budgets': {
              outputId: {
                'max_rows': 1000,
                'max_payload_bytes': 16777216,
                'overflow_policy': 'block_ingest',
              },
            },
          }),
          _secrets(),
          runMode: 'test',
        );
        expect(sufficient.publicJson, contains('"block_ingest"'));
      });

      test('historical_import_and_startup_use_distinct_metadata', () async {
        final snapshot = await repository.publishConfig(
          _config(1),
          _secrets(),
          runMode: 'test',
        );
        final plugin = pluginInput(2);
        await repository.publish(plugin);
        await session.db.unsafeSimpleExecute(r'''
          CREATE TABLE test_publication_reads (id bigserial, payload int, metadata int);
          CREATE FUNCTION test_capture_publication_reads() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            INSERT INTO test_publication_reads (payload,metadata)
            SELECT coalesce(sum(seq_tup_read+idx_tup_fetch) FILTER
              (WHERE relname ~ '^(outbox|raw_inbox)(_|$)'),0)::int,
              coalesce(sum(seq_tup_read+idx_tup_fetch) FILTER
              (WHERE relname IN ('pipeline_output_capacity','pipeline_output_commitment')),0)::int
            FROM pg_stat_xact_user_tables WHERE schemaname=current_schema();
            RETURN NULL;
          END;
          $$;
          CREATE TRIGGER test_capture_publication_reads AFTER UPDATE ON pipeline_queue_policy
          FOR EACH STATEMENT EXECUTE FUNCTION test_capture_publication_reads()
        ''');
        Future<IngestBootstrap> restoreHistorical(
          int revision,
          int key,
          int pluginKey,
        ) => repository.publishConfig(
          _config(revision)
            ..['sources'] = <Object?>[]
            ..['outputs'] = <Object?>[],
          {'key-v1': token(key), 'plugin-token': token(pluginKey)},
          runMode: 'test',
        );
        Future<List<Object?>> publish(int revision) async {
          // Only the live plugin intents still vouch for this reference.
          await session.db.unsafeSimpleExecute('''
            DELETE FROM secret_record WHERE reference='plugin-token';
            DELETE FROM ingest_secret_commitment WHERE reference='plugin-token';
          ''');
          await expectLater(
            restoreHistorical(revision, 3, 7),
            throwsA(_error('reference_rebound')),
          );
          await expectLater(
            restoreHistorical(revision, 2, 8),
            throwsA(_error('reference_rebound')),
          );
          expect((await restoreHistorical(revision, 2, 7)).outputs, isEmpty);
          return (await session.db.unsafeQuery(
            'SELECT payload,metadata FROM test_publication_reads ORDER BY id DESC LIMIT 1',
          )).single.toList();
        }

        Future<(int, int)> read() => _reads(
          session,
          (tx) => repository.validateLiveSecrets(transaction: tx),
        );
        await _outbox(session, snapshot, 10);
        await _pluginIntents(session, plugin, 10);
        final shallow = await read();
        final shallowImport = await publish(3);
        await _outbox(session, snapshot, 90);
        await _pluginIntents(session, plugin, 90);
        final deep = await read();
        final deepImport = await publish(4);
        expect(
          shallowImport[0],
          0,
          reason: 'publication must not scan payload rows',
        );
        expect(shallowImport[1], greaterThan(0));
        expect(
          deepImport,
          shallowImport,
          reason: 'historical lookup work follows distinct tuples',
        );
        expect(shallow.$1, 0, reason: 'startup must not read payload rows');
        expect(
          deep,
          shallow,
          reason:
              'more intents for the same commitment are not more lookup work',
        );
        expect(shallow.$2, greaterThan(0));
      });

      test(
        'layered_live_webhook_commitment_remains_visible_at_startup',
        () async {
          final snapshot = await repository.publishConfig(
            _config(1),
            _secrets(),
            runMode: 'test',
          );
          await _outbox(session, snapshot, 2);
          await _outbox(
            session,
            snapshot,
            1,
            reference: 'historical-lost-key',
            commitment: 'a' * 64,
          );
          await expectLater(
            repository.validateLiveSecrets(),
            throwsA(_error('historical_key_unavailable')),
          );
          await session.db.unsafeExecute(
            "UPDATE outbox SET status='dead' WHERE signing_key_ref='historical-lost-key'",
          );
          await repository.validateLiveSecrets();
        },
      );

      test(
        'publication_and_replay_preserve_a_lane_across_pin_to_intent',
        () async {
          final original = await repository.publishConfig(
            _config(1),
            _secrets(),
            runMode: 'test',
          );
          await raw.seed(session, [
            payload.alert(startsAt: raw.now.toIso8601String()),
          ]);
          final worker = PipelineRepository(
            session,
            clock: () => raw.now,
            elapsedForTest: () => Duration.zero,
          );
          expect(await worker.pinOne(), isTrue);
          const newLane = 'a0000000-0000-4000-8000-000000000999';
          final registry = [
            for (var n = 0; n < 63; n++)
              'a0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
          ];
          Map<String, Object?> replacement(int revision, List<String> ids) =>
              _config(revision)
                ..['sources'] = <Object?>[]
                ..['outputs'] = [
                  for (final id in ids)
                    {
                      'id': id,
                      'kind': 'webhook',
                      'url': 'https://example.com/events',
                      'signing_key_ref': 'key-v1',
                    },
                ];
          final active = await repository.publishConfig(
            replacement(2, registry),
            _secrets(),
            runMode: 'test',
          );
          final pinnedOutput = original.outputs.single as WebhookIngestOutput;
          await session.db.unsafeExecute(
            '''
          INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,
            output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,dead_reason)
          VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready','$newLane',@pin,
            'https://example.com/events','key-v1',@commitment,decode('ff','hex'),'dead','network')
        ''',
            parameters: QueryParameters.named({
              'pin': original.snapshotId,
              'commitment': pinnedOutput.signingKeyCommitment,
            }),
          );
          final ops = QueueOperations(session, secretStore: testSecretStore);
          final filter = QueueFailureFilter(kind: QueueFailureKind.delivery);
          final dead = (await ops.list(filter)).failures.single;
          Future<void> refusePublication() => expectLater(
            repository.publishConfig(
              replacement(3, [...registry, newLane]),
              _secrets(),
              runMode: 'test',
            ),
            throwsA(_error('retained_output_bound')),
          );
          Future<QueueReplayResult> replay(QueueOperations repository) =>
              repository.replayOne(
                QueueFailureKind.delivery,
                dead.occurrence,
                'operator',
              );
          await refusePublication();
          expect((await replay(ops)).items.single.outcome, 'live_output_bound');
          final gate = ContentionGate();
          final workLocked = Completer<void>();
          final concurrent = QueueOperations(
            builder.build(),
            secretStore: testSecretStore,
            startDeadlineForTest: () =>
                () => Duration.zero,
            beforeConfigLockForTest: () async {
              workLocked.complete();
              await gate.future;
            },
          );
          final trying = gate.run(() => replay(concurrent));
          try {
            await Future.any([
              workLocked.future,
              trying.then<void>((_) => fail('Replay did not lock its intent')),
            ]);
            expect(await worker.processOne(), isTrue);
          } finally {
            await gate.join();
          }
          expect((await trying).items.single.outcome, 'live_output_bound');
          await refusePublication();
          expect(
            (await repository.activeSnapshot())!['snapshotId'],
            active.snapshotId,
          );
          expect(
            (await ops.list(filter)).failures.single.occurrence,
            dead.occurrence,
          );
        },
      );

      test('lane_inventory_cost_does_not_follow_queue_depth', () async {
        final snapshot = await repository.publishConfig(
          _config(1),
          _secrets(),
          runMode: 'test',
        );
        Future<(int, int)> read() => _reads(session, (tx) async {
          final ids = await session.db.unsafeQuery(
            'SELECT output_id FROM correlia_retained_output_ids()',
            transaction: tx,
          );
          expect(ids.map((row) => row[0]), [outputId]);
        });
        await _outbox(session, snapshot, 10);
        final shallow = await read();
        await _outbox(session, snapshot, 90);
        final deep = await read();
        expect(
          shallow.$1,
          0,
          reason: 'lane inventory must not read payload rows',
        );
        expect(deep, shallow);
        expect(shallow.$2, greaterThan(0));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
