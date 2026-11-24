@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:correlia_server/src/secrets/commitments.dart';
import 'package:correlia_server/src/secrets/reuse_backfill.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/postgres_lock_witness.dart';
import '../support/secret_fixture.dart';
import '../support/secret_reuse_fixture.dart';

const _streamId = '11111111-1111-4111-8111-111111111111';
const _webhookId = '22222222-2222-4222-8222-222222222222';
const _outputId = '33333333-3333-4333-8333-333333333333';

Uint8List _bytes(int seed) => Uint8List(32)..fillRange(0, 32, seed);
String _encoded(int seed) => base64Url.encode(_bytes(seed)).split('=').first;
String _digest(int seed) => legacySecretCommitment(_bytes(seed));

Matcher _code(String code) =>
    throwsA(isA<BootstrapError>().having((e) => e.code, 'code', code));

void main() {
  final cluster = LockWitnessCluster();
  tearDownAll(cluster.close);
  withServerpod(
    'secret inventory history and restart',
    (builder, _) {
      late Session session;
      late IngestConfigRepository repository;

      setUp(() async {
        session = builder.build();
        await prepareHistoricalReuse(session);
        repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
      });

      Future<void> cutover() => applySchemaSteps(session, schemaSteps);
      Future<void> backfill() => initializeSchema(session);

      Future<IngestBootstrap> stream(int revision, int seed) =>
          repository.publishConfig(
            streamBootstrap(revision, [streamSource(_streamId)]),
            {
              ...streamMaterial(),
              'icinga-password': {'bytes': _encoded(seed)},
            },
            runMode: 'test',
          );

      Future<IngestBootstrap> webhook(
        int revision, [
        int seed = 1,
        IngestConfigRepository? publisher,
      ]) => (publisher ?? repository).publishConfig(
        streamBootstrap(revision, [
          {
            'id': _webhookId,
            'kind': 'icinga2',
            'enabled': true,
            'credentials': [
              {'ref': 'current-webhook', 'type': 'bearer'},
            ],
            'output_ids': <String>[],
          },
        ]),
        {'current-webhook': _encoded(seed)},
        runMode: 'test',
      );

      Future<void> history(
        List<Map<String, Object?>> sources, {
        List<Map<String, Object?>> outputs = const [],
      }) async {
        await session.db.unsafeExecute(
          '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
          VALUES ('historic',1,@json)''',
          parameters: QueryParameters.named({
            'json': jsonEncode({
              'format_version': 1,
              'sources': sources,
              'outputs': outputs,
            }),
          }),
        );
        await session.db.unsafeExecute(
          '''INSERT INTO ingest_active_config (singleton,"snapshotId")
          VALUES (1,'historic')''',
        );
      }

      Future<void> credentialOnly(int seed) async {
        await session.db.unsafeExecute(
          '''INSERT INTO ingest_source_credential
          ("sourceId",reference,type,digest) VALUES ('$_webhookId','pre-cutover-only','bearer',@digest)''',
          parameters: QueryParameters.named({'digest': _digest(seed)}),
        );
      }

      Future<Map<String, Object?>> marks() async =>
          (await session.db.unsafeQuery(
            'SELECT * FROM secret_reuse_backfill',
          )).single.toColumnMap();

      Future<void> historyMany(int count) async {
        await session.db.unsafeSimpleExecute('''
          INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
          SELECT 'snapshot-' || n,n,jsonb_build_object(
            'format_version',1,'outputs','[]'::jsonb,'sources',jsonb_build_array(
              jsonb_build_object('id','$_webhookId','token_digest',md5('s' || n) || md5('s' || n))
            ))::text FROM generate_series(1,$count) n;
          INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,'snapshot-$count');
        ''');
      }

      Future<void> failOnDigest(String digest) =>
          session.db.unsafeSimpleExecute('''
        CREATE FUNCTION test_interrupt_inventory() RETURNS trigger LANGUAGE plpgsql AS \$\$
        BEGIN
          IF NEW.digest = '$digest' THEN RAISE EXCEPTION 'test interruption'; END IF;
          RETURN NEW;
        END; \$\$;
      ''');

      test('password_published_during_the_backfill', () async {
        await history([]);
        await cutover();
        expect((await marks())['complete'], false);
        await expectLater(stream(2, 20), _code('reuse_inventory_pending'));
        expect((await repository.activeSnapshot())!['revision'], 1);
      });

      test('format_version_1_token_digest', () async {
        await history([
          {'id': _webhookId, 'token_digest': _digest(20)},
        ]);
        await cutover();
        await backfill();
        expect((await marks())['complete'], true);
        await expectLater(stream(2, 20), _code('password_reuse'));
        expect((await repository.activeSnapshot())!['revision'], 1);
      });

      test('credential_removed_before_its_backfill_batch', () async {
        await history([]);
        await credentialOnly(20);
        await cutover();
        await webhook(2);
        expect(
          await session.db.unsafeQuery(
            "SELECT 1 FROM ingest_source_credential WHERE reference = 'pre-cutover-only'",
          ),
          isEmpty,
        );
        await backfill();
        expect((await marks())['complete'], true);
        expect(
          (await session.db.unsafeQuery(
            'SELECT digest FROM secret_reuse_retired_credential',
          )).single[0],
          _digest(20),
        );
        await expectLater(stream(3, 20), _code('password_reuse'));
      });

      test('backfill_interrupted', () async {
        await historyMany(501);
        await cutover();
        await marks();
        final lastDigest =
            (await session.db.unsafeQuery(
                  "SELECT md5('s501') || md5('s501')",
                )).single[0]!
                as String;
        await failOnDigest(lastDigest);
        await session.db.unsafeSimpleExecute(
          '''CREATE TRIGGER test_interrupt BEFORE INSERT ON secret_reuse_digest
          FOR EACH ROW EXECUTE FUNCTION test_interrupt_inventory()''',
        );
        try {
          await expectLater(backfill(), throwsA(anything));
          expect((await marks())['snapshot_mark'], 500);
          expect((await marks())['complete'], false);
        } finally {
          await session.db.unsafeSimpleExecute(
            'DROP TRIGGER test_interrupt ON secret_reuse_digest',
          );
        }
        await backfill();
        expect((await marks())['snapshot_mark'], 501);
        expect((await marks())['complete'], true);
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM secret_reuse_digest',
          )).single[0],
          501,
        );
        await stream(502, 20);
      });

      test('interrupted_between_passes', () async {
        await historyMany(1);
        await credentialOnly(20);
        await cutover();
        await marks();
        await failOnDigest(_digest(20));
        await session.db.unsafeSimpleExecute(
          '''CREATE TRIGGER test_interrupt BEFORE INSERT ON secret_reuse_digest
          FOR EACH ROW EXECUTE FUNCTION test_interrupt_inventory()''',
        );
        try {
          await expectLater(backfill(), throwsA(anything));
          expect((await marks())['snapshot_mark'], 1);
          expect((await marks())['credential_mark'], 0);
          await expectLater(stream(2, 21), _code('reuse_inventory_pending'));
        } finally {
          await session.db.unsafeSimpleExecute(
            'DROP TRIGGER test_interrupt ON secret_reuse_digest',
          );
        }
        await backfill();
        expect((await marks())['complete'], true);
        await expectLater(stream(2, 20), _code('password_reuse'));
      });

      Future<void> pin({required bool plugin, required int seed}) =>
          session.db.unsafeExecute(
            '''
            INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,
              event_disposition,output_id,config_snapshot_id,target_url,
              signing_key_ref,signing_key_commitment,payload,output_kind,definition_digest)
            VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',
              '$_outputId','historic',@url,@reference,@digest,decode('00','hex'),@kind,@definition)
          ''',
            parameters: QueryParameters.named({
              'url': plugin ? null : 'http://127.0.0.1:8123/',
              'reference': plugin ? null : 'historic-key',
              'digest': plugin ? null : _digest(seed),
              'kind': plugin ? 'plugin' : 'webhook',
              'definition': plugin ? _digest(99) : null,
            }),
          );

      test('bare_plugin_commitment_only_in_a_pinned_snapshot', () async {
        await history(
          [],
          outputs: [
            {
              'id': _outputId,
              'kind': 'plugin',
              'secret_refs': {
                'auth': {
                  'reference': 'retired-plugin',
                  'commitment': _digest(20),
                },
              },
            },
          ],
        );
        await pin(plugin: true, seed: 20);
        await cutover();
        await backfill();
        expect((await marks())['complete'], true);
        await expectLater(stream(2, 20), _code('password_reuse'));
      });

      test('outbox_pins_are_covered_by_snapshots', () async {
        await history(
          [],
          outputs: [
            {
              'id': _outputId,
              'kind': 'webhook',
              'signing_key_ref': 'historic-key',
              'signing_key_commitment': _digest(20),
            },
          ],
        );
        await pin(plugin: false, seed: 20);
        await pin(plugin: true, seed: 20);
        await cutover();
        await backfill();
        final rows = await session.db.unsafeQuery('''
          SELECT DISTINCT o.signing_key_commitment,
            output->>'signing_key_commitment', d.digest
          FROM outbox o JOIN ingest_config_snapshot s ON s."snapshotId"=o.config_snapshot_id
          CROSS JOIN LATERAL jsonb_array_elements(s."publicJson"::jsonb->'outputs') output
          LEFT JOIN secret_reuse_digest d ON d.digest=o.signing_key_commitment
          WHERE o.signing_key_commitment IS NOT NULL AND output->>'id'=o.output_id::text
        ''');
        expect(rows.single.toList(), List.filled(3, _digest(20)));
      });

      test('publication_overlaps_a_backfill_write', () async {
        final low = _digest(20).compareTo(_digest(21)) < 0 ? 20 : 21;
        final high = low == 20 ? 21 : 20;
        await history([
          {'id': _webhookId, 'token_digest': _digest(high)},
          {'id': _streamId, 'token_digest': _digest(low)},
        ]);
        await credentialOnly(high);
        await cutover();
        await marks();
        const lock = 1129271979;
        await session.db.unsafeSimpleExecute('''
          CREATE FUNCTION test_gate_inventory() RETURNS trigger LANGUAGE plpgsql AS \$\$
          BEGIN
            IF NEW.digest = '${_digest(low)}' THEN
              PERFORM pg_advisory_xact_lock($lock);
            END IF;
            RETURN NEW;
          END; \$\$;
          CREATE TRIGGER test_gate AFTER INSERT ON secret_reuse_digest
            FOR EACH ROW EXECUTE FUNCTION test_gate_inventory();
        ''');
        final witness = await PostgresLockWitness.start(session);
        addTearDown(witness.close);
        final held = Completer<LockActor>();
        final release = Completer<void>();
        final gateSession = builder.build();
        final gate = gateSession.db.transaction((tx) async {
          final actor = await pooledLockActor(gateSession, tx);
          await gateSession.db.unsafeQuery(
            'SELECT pg_advisory_xact_lock($lock)',
            transaction: tx,
          );
          held.complete(actor);
          await release.future;
        });
        final blocker = await held.future;
        final scanSession = builder.build();
        final scanActor = Completer<LockActor>();
        final scanning = backfillSecretReuse(
          scanSession,
          writeTimeoutInSecondsForTest: const Duration(minutes: 5).inSeconds,
          beforeWriteForTest: (tx, completing) async {
            if (!completing) {
              scanActor.complete(
                await pooledLockActor(scanSession, tx, waiter: true),
              );
            }
          },
        );
        Future<IngestBootstrap>? publishing;
        try {
          final scanner = await Future.any([
            scanActor.future,
            scanning.then<LockActor>(
              (_) => throw StateError('Backfill did not write the snapshot'),
            ),
          ]);
          await witness.blockedBy(
            scanner,
            blocker,
            scanning,
            statement: 'INSERT INTO secret_reuse_digest',
            advisory: true,
          );
          final publisher = builder.build();
          final publishActor = Completer<LockActor>();
          publishing = webhook(
            2,
            low,
            IngestConfigRepository(
              publisher,
              secretStore: testSecretStore,
              writeTimeoutInSecondsForTest: const Duration(
                minutes: 5,
              ).inSeconds,
              beforeInventoryForTest: (tx) async => publishActor.complete(
                await pooledLockActor(publisher, tx, waiter: true),
              ),
            ),
          );
          final writer = await Future.any([
            publishActor.future,
            publishing.then<LockActor>(
              (_) => throw StateError('Publisher did not overlap backfill'),
            ),
          ]);
          await witness.blockedBy(
            writer,
            scanner,
            publishing,
            statement: 'INSERT INTO secret_reuse_digest',
          );
        } finally {
          release.complete();
          await gate;
          await scanning;
          await publishing;
        }
        expect((await marks())['snapshot_mark'], 1);
        expect((await repository.activeSnapshot())!['revision'], 2);
      });

      test('large_history', () async {
        await historyMany(10000);
        await session.db.unsafeSimpleExecute('''
          INSERT INTO ingest_secret_commitment (reference,digest)
          SELECT 'historic-' || n,md5('m' || n) || md5('m' || n) FROM generate_series(1,50000) n;
          INSERT INTO ingest_source_credential ("sourceId",reference,type,digest)
          SELECT '$_webhookId','historic-' || n,'bearer',md5('c' || n) || md5('c' || n)
            FROM generate_series(1,50000) n;
        ''');
        await cutover();
        await marks();
        const lock = 1129271980;
        await session.db.unsafeSimpleExecute('''
          CREATE FUNCTION test_check_inventory_batch() RETURNS trigger LANGUAGE plpgsql AS \$\$
          BEGIN
            IF greatest(NEW.snapshot_mark-OLD.snapshot_mark, NEW.commitment_mark-OLD.commitment_mark,
                        NEW.credential_mark-OLD.credential_mark) > 500 THEN
              RAISE EXCEPTION 'inventory batch exceeded 500 rows';
            END IF;
            IF NEW.complete THEN PERFORM pg_advisory_xact_lock($lock); END IF;
            RETURN NEW;
          END; \$\$;
          CREATE TRIGGER test_batch_size BEFORE UPDATE ON secret_reuse_backfill
            FOR EACH ROW EXECUTE FUNCTION test_check_inventory_batch();
        ''');
        final witness = await PostgresLockWitness.start(session);
        addTearDown(witness.close);
        final held = Completer<LockActor>();
        final release = Completer<void>();
        final gateSession = builder.build();
        final gate = gateSession.db.transaction((tx) async {
          final actor = await pooledLockActor(gateSession, tx);
          await gateSession.db.unsafeQuery(
            'SELECT pg_advisory_xact_lock($lock)',
            transaction: tx,
          );
          held.complete(actor);
          await release.future;
        });
        final blocker = await held.future;
        final scanSession = builder.build();
        final scanActor = Completer<LockActor>();
        final scanning = backfillSecretReuse(
          scanSession,
          writeTimeoutInSecondsForTest: const Duration(minutes: 5).inSeconds,
          beforeWriteForTest: (tx, completing) async {
            if (completing) {
              scanActor.complete(
                await pooledLockActor(scanSession, tx, waiter: true),
              );
            }
          },
        );
        try {
          final scanner = await Future.any([
            scanActor.future,
            scanning.then<LockActor>(
              (_) => throw StateError('Backfill did not reach the last batch'),
            ),
          ]);
          await witness.blockedBy(
            scanner,
            blocker,
            scanning,
            statement: 'UPDATE secret_reuse_backfill',
            advisory: true,
          );
          // This transaction must commit with the scanner still held.
          await webhook(10001, 22);
        } finally {
          release.complete();
          await gate;
          await scanning;
        }
        expect((await marks())['complete'], true);
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM secret_reuse_digest',
          )).single[0],
          110001,
        );
      }, timeout: const Timeout(Duration(minutes: 2)));
    },
    rollbackDatabase: RollbackDatabase.disabled,
    ephemeralDatabase: false,
    configOverride: cluster.override,
    testGroupTagsOverride: ['db'],
  );
}
