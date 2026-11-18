import 'dart:typed_data';

import 'package:correlia_server/src/output/output_relay.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';

const output = '11111111-1111-4111-8111-111111111111';
const delivery = '22222222-2222-4222-8222-222222222222';
const event = '33333333-3333-4333-8333-333333333333';
final key = Uint8List.fromList(List.filled(32, 4));

Future<void> seed(
  Session session, {
  String ref = 'key',
  String? commitment,
  bool storeKey = true,
}) async {
  if (storeKey) await seedSigningSecret(session, ref, key);
  await session.db.unsafeExecute(
    '''INSERT INTO outbox
    (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
     config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload)
    VALUES (now(),CAST(@delivery AS uuid),now(),CAST(@event AS uuid),'accepted',
      CAST(@output AS uuid),'snapshot','http://127.0.0.1:9000/',@ref,@commitment,@payload)''',
    parameters: QueryParameters.named({
      'delivery': delivery,
      'event': event,
      'output': output,
      'ref': ref,
      'commitment': commitment ?? sha256.convert(key).toString(),
      'payload': Uint8List.fromList([123, 125]),
    }),
  );
}

void main() {
  withServerpod(
    'durable relay',
    (builder, _) {
      setUp(() async {
        final session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute(
          'DELETE FROM delivery_attempts; DELETE FROM outbox; DELETE FROM secret_record',
        );
      });
      test('expired_owner_completion', () async {
        final session = builder.build();
        await seed(session);
        final repository = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
        );
        final old = (await repository.claim(output))!.claims.single;
        await session.db.unsafeSimpleExecute(
          "UPDATE outbox SET lease_until=now()-interval '1 second'",
        );
        await repository.recoverExpired();
        await session.db.unsafeSimpleExecute(
          'UPDATE outbox SET next_attempt_at=now()',
        );
        final current = (await repository.claim(output))!.claims.single;
        expect(
          await repository.complete(old, const DeliveryAcknowledged()),
          isFalse,
        );
        expect(
          await repository.complete(old, const DeliveryRetryable('network')),
          isFalse,
        );
        expect(
          await repository.complete(
            old,
            const DeliveryPermanent('http_permanent'),
          ),
          isFalse,
        );
        final row = (await session.db.unsafeQuery(
          'SELECT status,claim_id::text AS claim FROM outbox',
        )).single.toColumnMap();
        expect(row['status'], 'delivering');
        expect(row['claim'], current.claimId);
        final attempts = await session.db.unsafeQuery(
          'SELECT outcome FROM delivery_attempts ORDER BY "attemptNumber"',
        );
        expect(attempts.map((r) => r.toColumnMap()['outcome']), [
          'interrupted',
          'started',
        ]);
      });
      test('interrupted_attempt_exhausts_budget', () async {
        final session = builder.build();
        await seed(session);
        final repository = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
        );
        for (var i = 0; i < 20; i++) {
          expect(await repository.claim(output), isNotNull);
          await session.db.unsafeSimpleExecute(
            "UPDATE outbox SET lease_until=now()-interval '1 second'",
          );
          await repository.recoverExpired();
          await session.db.unsafeSimpleExecute(
            'UPDATE outbox SET next_attempt_at=now()',
          );
        }
        final row = (await session.db.unsafeQuery(
          'SELECT status,attempt_count,dead_reason FROM outbox',
        )).single.toColumnMap();
        expect(row['status'], 'dead');
        expect(row['attempt_count'], 20);
        expect(row['dead_reason'], isNotNull);
        expect(
          (await session.db.unsafeQuery(
            "SELECT count(*) AS n FROM delivery_attempts WHERE outcome='interrupted'",
          )).single.toColumnMap()['n'],
          20,
        );
      });
      test('concurrent_claims_for_one_output_are_isolated', () async {
        final session = builder.build();
        await seed(session);
        await session.db.unsafeSimpleExecute("""
        INSERT INTO outbox (created_at, delivery_id, event_observed_at, event_id,
          event_disposition, output_id, config_snapshot_id, target_url,
          signing_key_ref, signing_key_commitment, payload)
        SELECT now(), '44444444-4444-4444-8444-444444444444', event_observed_at,
          event_id, event_disposition, output_id, config_snapshot_id, target_url,
          signing_key_ref, signing_key_commitment, payload FROM outbox
      """);
        final first = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
        );
        final second = OutputRelayRepository(
          builder.build(),
          testSecretResolver(session).resolve,
        );
        final claims = await Future.wait([
          first.claim(output),
          second.claim(output),
        ]);
        expect(claims.whereType<DeliveryBatch>(), hasLength(1));
      });
      test('discovery_skips_busy_and_unavailable_lanes', () async {
        final session = builder.build();
        await seed(session, ref: 'missing', storeKey: false);
        await seedSigningSecret(session, 'key', key);
        const healthy = '55555555-5555-4555-8555-555555555555';
        await session.db.unsafeExecute(
          '''
        INSERT INTO outbox (created_at, delivery_id, event_observed_at, event_id,
          event_disposition, output_id, config_snapshot_id, target_url,
          signing_key_ref, signing_key_commitment, payload)
        SELECT now(), '66666666-6666-4666-8666-666666666666', event_observed_at,
          event_id, event_disposition, CAST(@output AS uuid), config_snapshot_id,
          target_url, 'key', @commitment, payload FROM outbox
      ''',
          parameters: QueryParameters.named({
            'output': healthy,
            'commitment': sha256.convert(key).toString(),
          }),
        );
        final diagnostics = <String>[];
        final repository = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
          onUnavailable: (id, ref) => diagnostics.add('$id/$ref'),
        );
        expect(await repository.discover({}), {healthy});
        expect(await repository.discover({healthy}), isEmpty);
        expect(diagnostics, ['$output/missing']);
      });
      test('unverifiable_pinned_signing_commitment', () async {
        final session = builder.build();
        await seed(
          session,
          commitment: sha256.convert(List<int>.filled(32, 9)).toString(),
        );
        const healthy = '55555555-5555-4555-8555-555555555555';
        await session.db.unsafeExecute(
          '''INSERT INTO outbox (created_at, delivery_id, event_observed_at, event_id,
            event_disposition, output_id, config_snapshot_id, target_url,
            signing_key_ref, signing_key_commitment, payload)
          SELECT now(), '66666666-6666-4666-8666-666666666666', event_observed_at,
            event_id, event_disposition, CAST(@output AS uuid), config_snapshot_id,
            target_url, signing_key_ref, @commitment, payload FROM outbox''',
          parameters: QueryParameters.named({
            'output': healthy,
            'commitment': sha256.convert(key).toString(),
          }),
        );
        final diagnostics = <String>[];
        final repository = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
          onUnavailable: (id, ref) => diagnostics.add('$id/$ref'),
        );
        expect(await repository.discover({}), {output, healthy});
        expect(await repository.claim(output), isNull);
        expect(await repository.claim(output), isNull);
        expect(diagnostics, ['$output/key']);
        final claim = (await repository.claim(healthy))!.claims.single;
        expect(
          await repository.complete(claim, const DeliveryAcknowledged()),
          isTrue,
        );
        final rows = await session.db.unsafeQuery(
          'SELECT output_id::text,status,attempt_count FROM outbox ORDER BY output_id',
        );
        expect(rows.first[1], 'queued');
        expect(rows.first[2], 0);
        expect(rows.last[1], 'delivered');
        expect(rows.last[2], 1);
        expect(
          await session.db.unsafeQuery(
            'SELECT 1 FROM delivery_attempts WHERE "deliveryId"=CAST(@delivery AS uuid)',
            parameters: QueryParameters.named({'delivery': delivery}),
          ),
          isEmpty,
        );
      });
      test('bad_signing_pin_does_not_block_its_output', () async {
        final session = builder.build();
        await seed(session, commitment: '0' * 64);
        const healthy = '66666666-6666-4666-8666-666666666666';
        await session.db.unsafeExecute(
          '''INSERT INTO outbox (created_at, delivery_id, event_observed_at, event_id,
            event_disposition, output_id, config_snapshot_id, target_url,
            signing_key_ref, signing_key_commitment, payload)
          SELECT created_at + interval '1 second', CAST(@id AS uuid), event_observed_at,
            event_id, event_disposition, output_id, config_snapshot_id,
            target_url, signing_key_ref, @commitment, payload FROM outbox''',
          parameters: QueryParameters.named({
            'id': healthy,
            'commitment': sha256.convert(key).toString(),
          }),
        );
        final repository = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
        );
        final batch = await repository.claim(output);
        expect(batch?.claims.single.deliveryId, healthy);
        final rows = await session.db.unsafeQuery(
          'SELECT status,attempt_count FROM outbox ORDER BY created_at',
        );
        expect(rows.first.toList(), ['queued', 0]);
        expect(rows.last.toList(), ['delivering', 1]);
      });
      test('loaded_historical_signing_reference', () async {
        final session = builder.build();
        await seed(session, ref: 'historical');
        await seedSigningSecret(
          session,
          'current',
          Uint8List.fromList(List.filled(32, 8)),
        );
        final repository = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
        );
        final claim = (await repository.claim(output))!.claims.single;
        expect(claim.key, orderedEquals(key));
        expect(
          await repository.complete(claim, const DeliveryAcknowledged()),
          isTrue,
        );
        final row = (await session.db.unsafeQuery(
          'SELECT status,signing_key_ref,signing_key_commitment FROM outbox',
        )).single.toColumnMap();
        expect(row['status'], 'delivered');
        expect(row['signing_key_ref'], 'historical');
        expect(row['signing_key_commitment'], sha256.convert(key).toString());
      });
      test('unloaded_live_signing_reference', () async {
        final session = builder.build();
        await seed(session, ref: 'unloaded', storeKey: false);
        final diagnostics = <String>[];
        final repository = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
          onUnavailable: (id, ref) => diagnostics.add('$id/$ref'),
        );
        expect(await repository.discover({}), isEmpty);
        expect(await repository.discover({}), isEmpty);
        expect(diagnostics, ['$output/unloaded']);
        expect(await repository.claim(output), isNull);
        expect(
          (await session.db.unsafeQuery(
            'SELECT status,attempt_count FROM outbox',
          )).single.toColumnMap(),
          containsPair('attempt_count', 0),
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) AS n FROM delivery_attempts',
          )).single.toColumnMap()['n'],
          0,
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
