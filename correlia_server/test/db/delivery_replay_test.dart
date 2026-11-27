import 'package:correlia_server/src/generated/protocol.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/output/output_relay.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' as config;
import 'output_relay_test.dart' as fixture;

void main() {
  withServerpod(
    'immutable delivery replay',
    (builder, _) {
      late Session session;
      late QueueOperations operations;
      late OutputRelayRepository relay;
      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeExecute('DELETE FROM delivery_attempts');
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(config.input(1));
        operations = QueueOperations(session, secretStore: testSecretStore);
        relay = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
        );
      });
      Future<int> dead() async => (await operations.list(
        QueueFailureFilter(kind: QueueFailureKind.delivery),
      )).failures.single.occurrence;
      Future<QueueReplayResult> replay(int id) =>
          operations.replayOne(QueueFailureKind.delivery, id, 'demo');

      test('delivery_replay_refuses_missing_key_or_new_lane', () async {
        await fixture.seed(session);
        await session.db.unsafeExecute(
          "UPDATE outbox SET status='dead',dead_reason='network'",
        );
        final id = await dead();
        await session.db.unsafeExecute(
          "DELETE FROM secret_record WHERE reference='key'",
        );
        expect(
          (await replay(id)).items.single.outcome,
          'signing_key_unavailable',
        );
        expect(await dead(), id);
        await seedSigningSecret(session, 'key', fixture.key);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publishConfig(
          {
            'format_version': 2,
            'revision': 2,
            'sources': <Object?>[],
            'outputs': [
              for (var i = 0; i < 64; i++)
                {
                  'id':
                      'aaaaaaaa-aaaa-4aaa-8aaa-${i.toString().padLeft(12, '0')}',
                  'kind': 'webhook',
                  'url': 'https://example.com',
                  'signing_key_ref': 'key-v1',
                },
            ],
          },
          const <String, Object?>{},
          runMode: 'test',
        );
        expect((await replay(id)).items.single.outcome, 'live_output_bound');
        expect(await dead(), id);
        expect(
          (await session.db.unsafeQuery(
            'SELECT attempt_count,retry_base FROM outbox',
          )).single.toList(),
          [0, 0],
        );
      });

      test('delivery_replay_expires_at_the_final_key_fence', () async {
        await fixture.seed(session);
        await session.db.unsafeExecute(
          "UPDATE outbox SET status='dead',dead_reason='network'",
        );
        final filter = QueueFailureFilter(kind: QueueFailureKind.delivery);
        final failure = (await operations.list(filter)).failures.single;
        final expiry = failure.failedAt.add(const Duration(days: 14));
        var now = expiry.subtract(const Duration(microseconds: 1));
        final racing = QueueOperations(
          session,
          secretStore: testSecretStore,
          clock: () => now,
          beforeDeliveryKeysLockForTest: (_) async {
            now = expiry;
          },
        );
        expect(
          (await racing.replayOne(
            QueueFailureKind.delivery,
            failure.occurrence,
            'operator',
          )).items.single.outcome,
          'expired',
        );
        expect(
          (await session.db.unsafeQuery('SELECT status FROM outbox')).single[0],
          'dead',
        );
        expect(await dead(), failure.occurrence);
        expect(
          (await session.db.unsafeQuery('''
          SELECT count(*) FROM pipeline_output_commitment WHERE reference='key'
        ''')).single[0],
          0,
        );
        expect(
          (await session.db.unsafeQuery('''
          SELECT count(*) FROM activity WHERE change_kind='dead_letter_replayed'
        ''')).single[0],
          0,
        );
      });

      test('fresh_attempt_allowance_fences_completion_and_recovery', () async {
        await fixture.seed(session);
        await session.db.unsafeSimpleExecute('''
        UPDATE outbox SET status='dead',attempt_count=20,dead_reason='interrupted';
        INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
        SELECT created_at,delivery_id,n,gen_random_uuid(),created_at,'interrupted'
        FROM outbox CROSS JOIN generate_series(1,20) n
      ''');
        final old = await dead();
        expect((await replay(old)).queued, 1);
        expect((await replay(old)).items.single.outcome, 'not_active');
        final first = (await relay.claim(fixture.output))!.claims.single;
        expect(first.attemptNumber, 21);
        expect(
          await relay.complete(first, const DeliveryRetryable('network')),
          isTrue,
        );
        Future<void> expectBackoff(int number, int seconds) async {
          final result = (await session.db.unsafeQuery('''
            SELECT o.status,extract(epoch FROM (o.next_attempt_at -
              (a."finishedAt" AT TIME ZONE 'UTC'))) AS seconds
            FROM outbox o JOIN delivery_attempts a
              ON (a."outboxCreatedAt",a."deliveryId",a."attemptNumber")=
                 (o.created_at AT TIME ZONE 'UTC',o.delivery_id,o.attempt_count)
            WHERE a."attemptNumber"=@number
          ''', parameters: QueryParameters.named({'number': number}))).single;
          expect(result[0], 'queued');
          expect(double.parse(result[1].toString()), seconds.toDouble());
        }

        await expectBackoff(21, 1);
        Future<void> eligible() => session.db.unsafeExecute(
          "UPDATE outbox SET next_attempt_at='-infinity'",
        );
        await eligible();
        final second = (await relay.claim(fixture.output))!.claims.single;
        expect(second.attemptNumber, 22);
        await session.db.unsafeExecute(
          "UPDATE outbox SET lease_until='-infinity'",
        );
        expect(await relay.recoverExpired(), isTrue);
        await expectBackoff(22, 2);
        expect(
          await relay.complete(second, const DeliveryAcknowledged()),
          isFalse,
        );
        // Drive the same production claim/completion path to the new boundary.
        for (var n = 23; n <= 40; n++) {
          await eligible();
          final claim = (await relay.claim(fixture.output))!.claims.single;
          expect(claim.attemptNumber, n);
          expect(
            await relay.complete(claim, const DeliveryRetryable('network')),
            isTrue,
          );
        }
        final rows = await session.db.unsafeQuery(
          'SELECT status,attempt_count,retry_base FROM outbox',
        );
        expect(rows.single.toList(), ['dead', 40, 20]);
        expect(await dead(), greaterThan(old));
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM delivery_attempts',
          )).single[0],
          40,
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
