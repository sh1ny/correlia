import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/secret_fixture.dart';
import '../support/secret_reuse_fixture.dart';

const _publicationLock = 1129271884;
const _streamId = '11111111-1111-4111-8111-111111111111';
const _legacyDigest =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Future<void> _oldPublish(
  Session session,
  int revision, {
  Future<void> Function()? beforeCommit,
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
  await beforeCommit?.call();
});

void main() {
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
        final inserted = Completer<void>();
        final release = Completer<void>();
        final publisher = _oldPublish(
          builder.build(),
          1,
          beforeCommit: () {
            inserted.complete();
            return release.future;
          },
        );
        await inserted.future;
        var finished = false;
        final cutover = applySchemaSteps(
          builder.build(),
          schemaSteps,
        ).whenComplete(() => finished = true);
        try {
          final deadline = Stopwatch()..start();
          var waiting = false;
          while (!finished && deadline.elapsed < const Duration(seconds: 3)) {
            final rows = await session.db.unsafeQuery(
              '''SELECT 1 FROM pg_locks
              WHERE locktype='advisory' AND objid=$_publicationLock AND NOT granted''',
            );
            if (rows.isNotEmpty) {
              waiting = true;
              break;
            }
          }
          expect(
            waiting,
            isTrue,
            reason: 'cutover must wait on the publication advisory lock',
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
    testGroupTagsOverride: ['db'],
  );
}
