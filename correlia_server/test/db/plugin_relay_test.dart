import 'dart:async';
import 'dart:typed_data';

import 'package:correlia_server/src/output/delivery_permit.dart';
import 'package:correlia_server/src/output/output_relay.dart';
import 'package:correlia_server/src/output/plugin_output_router.dart';
import 'package:correlia_server/src/output/relay_deadline.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

const output = '11111111-1111-4111-8111-111111111111';
const webhook = '11111111-1111-4111-8111-111111111112';
const digestA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const digestB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final key = Uint8List.fromList(List.filled(32, 4));

final class TestRouter implements PluginOutputRouter {
  TestRouter(this.source);
  final DeliveryPermitSource source;
  @override
  Map<String, Set<String>> get readyDefinitions => {
    output: {digestA},
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
  ) async => List.filled(batch.claims.length, const DeliveryAcknowledged());
}

Future<void> seedPlugin(
  Session session, {
  int count = 1,
  int first = 1,
  String digest = digestA,
}) async {
  await session.db.unsafeExecute(
    '''INSERT INTO outbox
      (created_at, delivery_id, event_observed_at, event_id, event_disposition,
       output_id, config_snapshot_id, output_kind, definition_digest, payload)
      SELECT clock_timestamp() + n * interval '1 millisecond',
       CAST('22222222-2222-4222-8222-' || lpad(to_hex(n), 12, '0') AS uuid),
       clock_timestamp(),
       CAST('33333333-3333-4333-8333-' || lpad(to_hex(n), 12, '0') AS uuid),
       'accepted', CAST(@output AS uuid), 'snapshot', 'plugin', @digest, @payload
      FROM generate_series(CAST(@first AS integer), CAST(@last AS integer)) AS n''',
    parameters: QueryParameters.named({
      'output': output,
      'digest': digest,
      'payload': Uint8List.fromList([123, 125]),
      'first': first,
      'last': first + count - 1,
    }),
  );
}

Future<void> seedWebhook(Session session) async {
  await session.db.unsafeExecute(
    '''INSERT INTO outbox
      (created_at, delivery_id, event_observed_at, event_id, event_disposition,
       output_id, config_snapshot_id, target_url, signing_key_ref,
       signing_key_commitment, payload)
      VALUES (clock_timestamp(), '44444444-4444-4444-8444-444444444444',
       clock_timestamp(), '55555555-5555-4555-8555-555555555555', 'accepted',
       CAST(@output AS uuid), 'snapshot', 'http://127.0.0.1:9000/', 'key',
       @commitment, @payload)''',
    parameters: QueryParameters.named({
      'output': webhook,
      'commitment': sha256.convert(key).toString(),
      'payload': Uint8List.fromList([123, 125]),
    }),
  );
}

OutputRelayRepository repository(
  Session session, {
  Future<void> Function()? beforeClaimCommit,
}) => OutputRelayRepository(
  session,
  (ref) => ref == 'key' ? key : null,
  loadedReferences: {'key'},
  beforeClaimCommit: beforeClaimCommit,
);

Future<List<Map<String, Object?>>> rows(Session session) async =>
    (await session.db.unsafeQuery(
      '''SELECT output_kind,definition_digest,status,
      attempt_count,dead_reason,payload,claim_id::text AS claim_id
      FROM outbox ORDER BY created_at,delivery_id''',
    )).map((row) => row.toColumnMap()).toList();

void main() {
  withServerpod(
    'plugin relay',
    (builder, _) {
      setUp(() async {
        final session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute(
          'DELETE FROM delivery_attempts; DELETE FROM outbox',
        );
      });

      test('plugin_degraded_while_work_queued', () async {
        final session = builder.build();
        await seedPlugin(session, count: 50);
        await seedWebhook(session);
        final repo = repository(session);
        expect(await repo.discover({}, readyDefinitions: {}), {webhook});
        final claim = (await repo.claim(webhook))!.claims.single;
        expect(
          await repo.complete(claim, const DeliveryAcknowledged()),
          isTrue,
        );
        final result = await rows(session);
        expect(
          result.where((r) => r['output_kind'] == 'plugin'),
          hasLength(50),
        );
        expect(
          result
              .where((r) => r['output_kind'] == 'plugin')
              .every((r) => r['status'] == 'queued' && r['attempt_count'] == 0),
          isTrue,
        );
        expect(
          result.singleWhere((r) => r['output_kind'] == 'webhook')['status'],
          'delivered',
        );
      });

      test('plugin_becomes_ready_again', () async {
        final session = builder.build();
        await seedPlugin(session);
        final repo = repository(session);
        final source = DeliveryPermitSource();
        expect(await repo.discover({}, readyDefinitions: {}), isEmpty);
        expect(
          await repo.discover(
            {},
            readyDefinitions: {
              output: {digestA},
            },
          ),
          {output},
        );
        final permit = source.acquire()!;
        final batch = (await repo.claim(
          output,
          limit: 64,
          readyDigests: {digestA},
          permit: permit,
        ))!;
        expect(
          await repo.completeBatch(batch, [const DeliveryAcknowledged()]),
          isTrue,
        );
        permit.release();
        expect((await rows(session)).single['status'], 'delivered');
      });

      test('older_unavailable_beside_ready', () async {
        final session = builder.build();
        await seedPlugin(session, digest: digestA);
        await seedPlugin(session, first: 2, digest: digestB);
        final source = DeliveryPermitSource();
        final permit = source.acquire()!;
        final repo = repository(session);
        final batch = (await repo.claim(
          output,
          limit: 64,
          readyDigests: {digestB},
          permit: permit,
        ))!;
        expect(batch.claims, hasLength(1));
        expect(
          await repo.completeBatch(batch, [const DeliveryAcknowledged()]),
          isTrue,
        );
        permit.release();
        final result = await rows(session);
        expect(
          result.singleWhere(
            (r) => r['definition_digest'] == digestA,
          )['attempt_count'],
          0,
        );
        expect(
          result.singleWhere(
            (r) => r['definition_digest'] == digestB,
          )['status'],
          'delivered',
        );
      });

      test('instance_leaves_ready_before_permit', () async {
        final session = builder.build();
        await seedPlugin(session);
        final source = DeliveryPermitSource();
        final repo = repository(session);
        expect(
          await repo.discover(
            {},
            readyDefinitions: {
              output: {digestA},
            },
          ),
          {output},
        );
        source.invalidate();
        expect(source.acquire(), isNull);
        final result = (await rows(session)).single;
        expect(result['status'], 'queued');
        expect(result['attempt_count'], 0);
        expect(
          await session.db.unsafeQuery('SELECT 1 FROM delivery_attempts'),
          isEmpty,
        );
      });

      test('plugin_exit_observed_during_open_claim', () async {
        final session = builder.build();
        await seedPlugin(session, count: 3);
        final entered = Completer<void>();
        final resume = Completer<void>();
        final repo = repository(
          session,
          beforeClaimCommit: () async {
            entered.complete();
            await resume.future;
          },
        );
        final source = DeliveryPermitSource();
        final permit = source.acquire()!;
        final pending = repo.claim(
          output,
          limit: 64,
          readyDigests: {digestA},
          permit: permit,
        );
        await entered.future;
        source.invalidate();
        resume.complete();
        expect(await pending, isNull);
        permit.release();
        expect(
          (await rows(
            session,
          )).every((r) => r['status'] == 'queued' && r['attempt_count'] == 0),
          isTrue,
        );
        expect(
          await session.db.unsafeQuery('SELECT 1 FROM delivery_attempts'),
          isEmpty,
        );
        final nextSource = DeliveryPermitSource();
        final nextPermit = nextSource.acquire()!;
        final nextRepo = repository(session);
        final committed = (await nextRepo.claim(
          output,
          limit: 64,
          readyDigests: {digestA},
          permit: nextPermit,
        ))!;
        nextSource.invalidate();
        final outcomes = await deliverPluginBatch(
          TestRouter(nextSource),
          nextPermit,
          committed,
        );
        expect(
          outcomes,
          everyElement(
            isA<DeliveryRetryable>().having(
              (o) => o.errorClass,
              'error class',
              'plugin_connection_lost',
            ),
          ),
        );
        expect(await nextRepo.completeBatch(committed, outcomes), isTrue);
        nextPermit.release();
        expect(
          (await rows(
            session,
          )).every((r) => r['status'] == 'queued' && r['attempt_count'] == 1),
          isTrue,
        );
        final attempts = await session.db.unsafeQuery(
          '''SELECT "errorClass" FROM delivery_attempts''',
        );
        expect(attempts, hasLength(3));
        expect(attempts.every((r) => r[0] == 'plugin_connection_lost'), isTrue);
      });

      test('batch_with_one_bad_event', () async {
        final session = builder.build();
        await seedPlugin(session, count: 10);
        final source = DeliveryPermitSource();
        final permit = source.acquire()!;
        final repo = repository(session);
        final batch = (await repo.claim(
          output,
          limit: 64,
          readyDigests: {digestA},
          permit: permit,
        ))!;
        expect(batch.claims, hasLength(10));
        expect(
          await repo.completeBatch(batch, [
            for (var i = 0; i < 9; i++) const DeliveryAcknowledged(),
            const DeliveryPermanent('payload_too_large'),
          ]),
          isTrue,
        );
        permit.release();
        final result = await rows(session);
        expect(result.where((r) => r['status'] == 'delivered'), hasLength(9));
        final dead = result.singleWhere((r) => r['status'] == 'dead');
        expect(dead['dead_reason'], 'payload_too_large');
        expect(dead['payload'], isNotNull);
        expect(
          await session.db.unsafeQuery('SELECT 1 FROM delivery_attempts'),
          hasLength(10),
        );
      });

      test('full_batch_within_budget', () async {
        final session = builder.build();
        await seedPlugin(session, count: 64);
        final source = DeliveryPermitSource();
        final permit = source.acquire()!;
        final repo = repository(session);
        var elapsed = Duration.zero;
        var completing = false;
        final deadline = RelayDeadline(
          elapsed: () {
            if (completing) elapsed += const Duration(milliseconds: 500);
            return elapsed;
          },
        );
        final batch = (await repo.claim(
          output,
          limit: 64,
          readyDigests: {digestA},
          permit: permit,
          deadline: deadline,
        ))!;
        elapsed = const Duration(milliseconds: 19900);
        completing = true;
        expect(batch.claims, hasLength(64));
        expect(
          await repo.completeBatch(
            batch,
            List.filled(64, const DeliveryAcknowledged()),
          ),
          isTrue,
        );
        expect(elapsed, greaterThan(const Duration(seconds: 24)));
        expect(elapsed, lessThan(const Duration(seconds: 27)));
        permit.release();
        expect(
          (await rows(session)).every((r) => r['status'] == 'delivered'),
          isTrue,
        );
        expect(await repo.recoverExpired(), isFalse);
      });
      test('stale_batch_completion', () async {
        final session = builder.build();
        await seedPlugin(session, count: 3);
        final source = DeliveryPermitSource();
        final permit = source.acquire()!;
        final repo = repository(session);
        final old = (await repo.claim(
          output,
          limit: 64,
          readyDigests: {digestA},
          permit: permit,
        ))!;
        await session.db.unsafeSimpleExecute(
          "UPDATE outbox SET lease_until=clock_timestamp()-interval '1 second'",
        );
        for (var i = 0; i < 3; i++) {
          expect(await repo.recoverExpired(), isTrue);
        }
        await session.db.unsafeSimpleExecute(
          'UPDATE outbox SET next_attempt_at=clock_timestamp()',
        );
        final current = (await repo.claim(
          output,
          limit: 64,
          readyDigests: {digestA},
          permit: permit,
        ))!;
        expect(
          await repo.completeBatch(
            old,
            List.filled(3, const DeliveryAcknowledged()),
          ),
          isFalse,
        );
        expect(
          (await rows(session)).every(
            (r) =>
                r['status'] == 'delivering' && r['claim_id'] == current.claimId,
          ),
          isTrue,
        );
        final attempts = await session.db.unsafeQuery(
          "SELECT outcome FROM delivery_attempts WHERE outcome='started'",
        );
        expect(attempts, hasLength(3));
        permit.release();
      });
      test('plugin_intents_need_no_signing_reference', () async {
        final session = builder.build();
        await seedPlugin(session);
        final diagnostics = <String>[];
        final repo = OutputRelayRepository(
          session,
          (_) => null,
          onUnavailable: (id, ref) => diagnostics.add('$id/$ref'),
        );
        expect(await repo.discover({}, readyDefinitions: {}), isEmpty);
        expect(diagnostics, isEmpty);
        expect(
          await repo.discover(
            {},
            readyDefinitions: {
              output: {digestA},
            },
          ),
          {output},
        );
        final result = (await rows(session)).single;
        expect(result['status'], 'queued');
        expect(result['attempt_count'], 0);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
