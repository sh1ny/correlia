import 'dart:async';

import 'package:correlia_server/src/output/delivery_permit.dart';
import 'package:correlia_server/src/output/output_relay.dart';
import 'package:correlia_server/src/output/plugin_output_router.dart';
import 'package:correlia_server/src/output/relay_subsystem.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import 'plugin_relay_test.dart' as fixture;

final class _RecordingRouter implements PluginOutputRouter {
  final source = DeliveryPermitSource();
  final batches = <DeliveryBatch>[];

  @override
  Map<String, Set<String>> get readyDefinitions => {
    fixture.output: {fixture.digestA},
  };

  @override
  DeliveryPermit? tryAcquire(String outputId, String digest) =>
      source.acquire();

  @override
  int eventLimit(String outputId, String digest) => 64;

  @override
  int byteLimit(String outputId, String digest) => 1024 * 1024;

  @override
  Future<List<DeliveryOutcome>> deliver(
    DeliveryPermit permit,
    DeliveryBatch batch,
  ) async {
    batches.add(batch);
    return List.filled(batch.claims.length, const DeliveryAcknowledged());
  }
}

void main() {
  withServerpod(
    'plugin relay shutdown during claim',
    (builder, _) {
      test('does not send a committed claim and recovers it', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        await fixture.seedPlugin(session);
        final entered = Completer<void>();
        final resume = Completer<void>();
        final router = _RecordingRouter();
        final relay = RelaySubsystem(
          pod: session.serverpod,
          resolveKey: noSigningKey,
          runMode: 'test',
          pluginRouter: router,
          beforeClaimCommit: () async {
            entered.complete();
            await resume.future;
          },
        );
        addTearDown(() async {
          if (!resume.isCompleted) {
            resume.complete();
          }
          await relay.stop();
        });

        await relay.start();
        await entered.future;
        final stopping = relay.stop();
        resume.complete();
        await stopping;

        expect(router.batches, isEmpty);
        final claimed = (await fixture.rows(session)).single;
        expect(claimed['status'], 'delivering');
        expect(claimed['attempt_count'], 1);
        expect(claimed['claim_id'], isNotNull);
        var attempts = await session.db.unsafeQuery(
          'SELECT outcome FROM delivery_attempts ORDER BY "attemptNumber"',
        );
        expect(attempts.map((row) => row[0]), ['started']);

        await session.db.unsafeSimpleExecute(
          "UPDATE outbox SET lease_until=clock_timestamp()-interval '1 second'",
        );
        final repo = fixture.repository(session);
        expect(await repo.recoverExpired(), isTrue);
        expect((await fixture.rows(session)).single['status'], 'queued');
        attempts = await session.db.unsafeQuery(
          'SELECT outcome FROM delivery_attempts ORDER BY "attemptNumber"',
        );
        expect(attempts.map((row) => row[0]), ['interrupted']);

        await session.db.unsafeSimpleExecute(
          'UPDATE outbox SET next_attempt_at=clock_timestamp()',
        );
        final permit = router.source.acquire()!;
        try {
          final batch = (await repo.claim(
            fixture.output,
            limit: 64,
            readyDigests: {fixture.digestA},
            permit: permit,
          ))!;
          final outcomes = await deliverPluginBatch(router, permit, batch);
          expect(await repo.completeBatch(batch, outcomes), isTrue);
        } finally {
          permit.release();
        }
        expect(router.batches, hasLength(1));
        final delivered = (await fixture.rows(session)).single;
        expect(delivered['status'], 'delivered');
        expect(delivered['attempt_count'], 2);
        attempts = await session.db.unsafeQuery(
          'SELECT outcome FROM delivery_attempts ORDER BY "attemptNumber"',
        );
        expect(attempts.map((row) => row[0]), ['interrupted', 'acknowledged']);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
