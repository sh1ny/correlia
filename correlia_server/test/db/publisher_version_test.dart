@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/postgres_lock_witness.dart';
import '../support/secret_fixture.dart';
import '../support/secret_reuse_fixture.dart';

const _publicationLock = 1129271884;
const _streamId = '11111111-1111-4111-8111-111111111111';
const _legacyDigest =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Future<void> _oldPublish(
  Session session,
  int revision, {
  Future<void> Function(Transaction)? beforeCommit,
}) => session.db.transaction((tx) async {
  await session.db.unsafeQuery(
    'SELECT pg_advisory_xact_lock($_publicationLock)',
    transaction: tx,
  );
  await session.db.unsafeExecute(
    '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
        VALUES (@id,@revision,@json)''',
    parameters: QueryParameters.named({
      'id': 'previous-release-$revision',
      'revision': revision,
      'json': jsonEncode({
        'format_version': 1,
        'sources': [
          {'id': _streamId, 'token_digest': _legacyDigest},
        ],
        'outputs': <Object?>[],
      }),
    }),
    transaction: tx,
  );
  await session.db.unsafeExecute(
    '''INSERT INTO ingest_secret_commitment (reference,digest)
        VALUES (@id,@digest)''',
    parameters: QueryParameters.named({
      'id': 'old-$revision',
      'digest':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    }),
    transaction: tx,
  );
  await session.db.unsafeExecute(
    '''INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,@id)
        ON CONFLICT (singleton) DO UPDATE SET "snapshotId"=EXCLUDED."snapshotId"''',
    parameters: QueryParameters.named({'id': 'previous-release-$revision'}),
    transaction: tx,
  );
  await beforeCommit?.call(tx);
});

void main() {
  final cluster = LockWitnessCluster();
  tearDownAll(cluster.close);
  withServerpod(
    'secret inventory publisher cutover',
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

      test('publication_in_flight_at_the_cutover', () async {
        final witness = await PostgresLockWitness.start(session);
        addTearDown(witness.close);
        final inserted = Completer<LockActor>();
        final release = Completer<void>();
        final publishSession = builder.build();
        final publisher = _oldPublish(
          publishSession,
          1,
          beforeCommit: (tx) async {
            inserted.complete(await pooledLockActor(publishSession, tx));
            await release.future;
          },
        );
        final blocker = await Future.any([
          inserted.future,
          publisher.then<LockActor>(
            (_) => throw StateError('Publisher did not hold its transaction'),
          ),
        ]);
        final cutoverSession = builder.build();
        final entered = Completer<LockActor>();
        final cutover = applySchemaSteps(
          cutoverSession,
          schemaSteps,
          stepTimeoutInSecondsForTest: const Duration(minutes: 5).inSeconds,
          beforeStepForTest: (tx, step) async {
            if (step.version == 5) {
              entered.complete(
                await pooledLockActor(cutoverSession, tx, waiter: true),
              );
            }
          },
        );
        try {
          final waiter = await Future.any([
            entered.future,
            cutover.then<LockActor>(
              (_) => throw StateError(
                'Cutover did not reach the publication lock',
              ),
            ),
          ]);
          await witness.blockedBy(
            waiter,
            blocker,
            cutover,
            statement: 'pg_advisory_xact_lock($_publicationLock)',
            advisory: true,
          );
        } finally {
          release.complete();
          await publisher;
          await cutover;
        }
        final boundary = (await session.db.unsafeQuery(
          'SELECT snapshot_boundary FROM secret_reuse_backfill',
        )).single[0];
        expect(boundary, 1);
        await initializeSchema(session);
        expect(
          (await session.db.unsafeQuery(
            "SELECT digest FROM secret_reuse_digest WHERE kind='bare' AND digest='$_legacyDigest'",
          )).single[0],
          _legacyDigest,
        );
        await expectLater(
          _oldPublish(session, 2),
          throwsA(isA<DatabaseQueryException>()),
        );
        expect((await repository.activeSnapshot())!['revision'], 1);
      });

      test('older_process_publishes_after_the_upgrade', () async {
        await _oldPublish(session, 1);
        await applySchemaSteps(session, schemaSteps);
        await expectLater(
          _oldPublish(session, 2),
          throwsA(isA<DatabaseQueryException>()),
        );
        await expectLater(
          session.db.unsafeExecute('''INSERT INTO ingest_secret_commitment
          (reference,digest) VALUES ('old-direct','$_legacyDigest')'''),
          throwsA(isA<DatabaseQueryException>()),
        );
        expect((await repository.activeSnapshot())!['revision'], 1);
        expect(
          (await session.db.unsafeQuery(
            'SELECT reference FROM ingest_secret_commitment',
          )).single[0],
          'old-1',
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT revision FROM ingest_config_snapshot',
          )).single[0],
          1,
        );
      });

      test('rollback_after_a_password_was_published', () async {
        await initializeSchema(session);
        await repository.publishConfig(
          streamBootstrap(1, [streamSource(_streamId)]),
          streamMaterial(),
          runMode: 'test',
        );
        await expectLater(
          _oldPublish(session, 2),
          throwsA(isA<DatabaseQueryException>()),
        );
        expect((await repository.activeSnapshot())!['revision'], 1);
        expect(
          await session.db.unsafeQuery(
            'SELECT digest FROM ingest_secret_commitment WHERE reference=\'old-2\'',
          ),
          isEmpty,
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    ephemeralDatabase: false,
    configOverride: cluster.override,
    testGroupTagsOverride: ['db'],
  );
}
