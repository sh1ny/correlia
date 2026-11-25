@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_webhook_fixture.dart';
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
  bool versionOne = false,
  Future<void> Function(Transaction)? beforeCommit,
}) => session.db.transaction((tx) async {
  await session.db.unsafeQuery(
    'SELECT pg_advisory_xact_lock($_publicationLock)',
    transaction: tx,
  );
  if (versionOne) {
    await session.db.unsafeSimpleExecute(
      "SET LOCAL correlia.publisher_version = '1'",
      transaction: tx,
    );
  }
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

SchemaStep _publisherVersion2() {
  final steps = schemaSteps.where((step) => step.version == 10);
  expect(steps, hasLength(1), reason: 'missing publisher schema step 10');
  return steps.single;
}

final _outdatedPublisher = isA<DatabaseQueryException>()
    .having((e) => e.code, 'SQLSTATE', '55000')
    .having((e) => e.message, 'message', 'outdated configuration publisher');

Future<void> _prepareVersionOne(Session session) => applySchemaSteps(
  session,
  schemaSteps.where((step) => step.version < 10).toList(),
);

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
        final release = ContentionGate();
        final publishSession = builder.build();
        final publisher = release.run(
          () => _oldPublish(
            publishSession,
            1,
            beforeCommit: (tx) async {
              inserted.complete(await pooledLockActor(publishSession, tx));
              await release.future;
            },
          ),
        );
        final blocker = await Future.any([
          inserted.future,
          publisher.then<LockActor>(
            (_) => throw StateError('Publisher did not hold its transaction'),
          ),
        ]);
        final cutoverSession = builder.build();
        final entered = Completer<LockActor>();
        final cutover = release.run(
          () => applySchemaSteps(
            cutoverSession,
            schemaSteps,
            stepTimeoutInSecondsForTest: const Duration(minutes: 5).inSeconds,
            beforeStepForTest: (tx, step) async {
              if (step.version == 5) {
                entered.complete(
                  await pooledLockActor(
                    cutoverSession,
                    tx,
                    waiter: SqlTimeouts.schemaStep,
                  ),
                );
              }
            },
          ),
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
          await release.join();
        }
        await publisher;
        await cutover;
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

      test('current_publisher', () async {
        _publisherVersion2();
        await initializeSchema(session);
        final published = await repository.publishConfig(
          {
            'format_version': 2,
            'revision': 1,
            'sources': [genericSource(_streamId, 'generic-key')],
            'mappings': [checkMapping()],
            'outputs': <Object?>[],
          },
          {
            'generic-key': base64Url
                .encode(List<int>.filled(32, 9))
                .replaceAll('=', ''),
          },
          runMode: 'test',
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          published.snapshotId,
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT kind FROM ingest_source',
          )).single[0],
          'generic',
        );
      });

      test('older_publisher_after_the_upgrade', () async {
        final upgrade = _publisherVersion2();
        await _prepareVersionOne(session);
        await _oldPublish(session, 1, versionOne: true);
        await applySchemaSteps(session, [upgrade]);
        await expectLater(
          _oldPublish(session, 2, versionOne: true),
          throwsA(_outdatedPublisher),
        );
        expect((await repository.activeSnapshot())!['revision'], 1);
        expect(
          (await session.db.unsafeQuery(
            'SELECT revision FROM ingest_config_snapshot',
          )).map((row) => row[0]),
          [1],
        );
      });

      test('older_publication_in_flight_during_the_schema_step', () async {
        final upgrade = _publisherVersion2();
        await _prepareVersionOne(session);
        final witness = await PostgresLockWitness.start(session);
        addTearDown(witness.close);
        final inserted = Completer<LockActor>();
        final entered = Completer<LockActor>();
        final release = ContentionGate();
        final publishSession = builder.build();
        final upgradeSession = builder.build();
        final publisher = release.run(
          () => _oldPublish(
            publishSession,
            1,
            versionOne: true,
            beforeCommit: (tx) async {
              inserted.complete(await pooledLockActor(publishSession, tx));
              await release.future;
            },
          ),
        );
        final blocker = await Future.any([
          inserted.future,
          publisher.then<LockActor>(
            (_) => throw StateError('No held publication'),
          ),
        ]);
        final cutover = release.run(
          () => applySchemaSteps(
            upgradeSession,
            [upgrade],
            stepTimeoutInSecondsForTest: const Duration(minutes: 5).inSeconds,
            beforeStepForTest: (tx, _) async {
              entered.complete(
                await pooledLockActor(
                  upgradeSession,
                  tx,
                  waiter: SqlTimeouts.schemaStep,
                ),
              );
            },
          ),
        );
        try {
          final waiter = await Future.any([
            entered.future,
            cutover.then<LockActor>(
              (_) => throw StateError('No schema lock wait'),
            ),
          ]);
          await witness.blockedBy(
            waiter,
            blocker,
            cutover,
            statement: 'pg_advisory_xact_lock($_publicationLock)',
            advisory: true,
          );
          expect(
            await session.db.unsafeQuery(
              'SELECT version FROM correlia_schema_versions WHERE version = 10',
            ),
            isEmpty,
          );
        } finally {
          await release.join();
        }
        await publisher;
        await cutover;
        expect((await repository.activeSnapshot())!['revision'], 1);
        expect(
          await session.db.unsafeQuery(
            'SELECT version FROM correlia_schema_versions WHERE version = 10',
          ),
          hasLength(1),
        );
        await expectLater(
          _oldPublish(session, 2, versionOne: true),
          throwsA(_outdatedPublisher),
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    ephemeralDatabase: false,
    configOverride: cluster.override,
    testGroupTagsOverride: ['db'],
  );
}
