import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

const sourceId = '11111111-1111-4111-8111-111111111111';
const outputId = '22222222-2222-4222-8222-222222222222';
String token(int byte) =>
    base64Url.encode(List<int>.filled(32, byte)).replaceAll('=', '');
IngestBootstrap input(
  int revision, {
  int credential = 1,
  String keyRef = 'key-v1',
  int key = 2,
  bool includeSource = true,
}) => IngestBootstrap.parse(
  {
    'format_version': 1,
    'revision': revision,
    'sources': [
      if (includeSource)
        {
          'id': sourceId,
          'enabled': true,
          'token_ref': 'source-token',
          'output_ids': [outputId],
        },
    ],
    'outputs': [
      {
        'id': outputId,
        'kind': 'webhook',
        'url': 'http://127.0.0.1:9099/events',
        'signing_key_ref': keyRef,
      },
    ],
  },
  {'source-token': token(credential), keyRef: token(key)},
  runMode: 'test',
);

void main() {
  withServerpod(
    'immutable ingest configuration',
    (builder, _) {
      setUp(() async {
        final session = builder.build();
        await initializeIngestSchema(session);
        for (final table in [
          'outbox',
          'raw_inbox',
          'ingest_active_config',
          'ingest_source',
          'ingest_config_snapshot',
          'ingest_secret_commitment',
        ]) {
          await session.db.unsafeSimpleExecute('DELETE FROM "$table"');
        }
      });
      test('bootstrap_publication_and_rotation', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(session);
        final first = input(1);
        await repository.publish(first);
        await repository.publish(first);
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          first.snapshotId,
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) AS count FROM ingest_config_snapshot',
          )).single.toColumnMap()['count'],
          1,
        );
        final second = input(2, credential: 3);
        await repository.publish(second);
        final row = (await session.db.unsafeQuery(
          'SELECT "tokenDigest" FROM ingest_source',
        )).single.toColumnMap();
        expect(row['tokenDigest'], second.sources.single.tokenDigest);
        expect(row['tokenDigest'], isNot(first.sources.single.tokenDigest));
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) AS count FROM ingest_config_snapshot',
          )).single.toColumnMap()['count'],
          2,
        );
      });
      test('empty_registry_and_missing_secret', () async {
        final repository = IngestConfigRepository(builder.build());
        final first = input(1);
        await repository.publish(first);
        expect(
          () => IngestBootstrap.parse(
            {
              'format_version': 1,
              'revision': 2,
              'sources': [
                {
                  'id': sourceId,
                  'enabled': true,
                  'token_ref': 'source-token',
                  'output_ids': [outputId],
                },
              ],
              'outputs': <Object?>[],
            },
            {'source-token': token(1)},
            runMode: 'test',
          ),
          throwsA(isA<BootstrapError>()),
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          first.snapshotId,
        );
        await expectLater(
          repository.publish(input(2, key: 3)),
          throwsA(isA<BootstrapError>()),
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          first.snapshotId,
        );
      });
      test('stale_bootstrap_cannot_revoke_the_rotation', () async {
        final repository = IngestConfigRepository(builder.build());
        final first = input(1);
        final second = input(2, credential: 3);
        await repository.publish(first);
        await repository.publish(second);
        await expectLater(
          repository.publish(first),
          throwsA(isA<SnapshotActivationError>()),
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          second.snapshotId,
        );
      });
      test('revert_by_higher_revision', () async {
        final repository = IngestConfigRepository(builder.build());
        await repository.publish(input(1));
        await repository.publish(input(2, credential: 3));
        final reverted = input(3);
        await repository.publish(reverted);
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          reverted.snapshotId,
        );
      });
      test('conflicting_equal_revision', () async {
        final repository = IngestConfigRepository(builder.build());
        final first = input(1);
        await repository.publish(first);
        await expectLater(
          repository.publish(input(1, credential: 3)),
          throwsA(isA<SnapshotActivationError>()),
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          first.snapshotId,
        );
      });
      test(
        'omitted source is disabled and active config requires worker bootstrap',
        () async {
          final session = builder.build();
          final repository = IngestConfigRepository(session);
          await repository.validateWithoutBootstrap();
          await repository.publish(input(1));
          await expectLater(
            repository.validateWithoutBootstrap(),
            throwsA(isA<BootstrapError>()),
          );
          await repository.publish(input(2, includeSource: false));
          expect(
            (await session.db.unsafeQuery(
              'SELECT enabled FROM ingest_source',
            )).single.toColumnMap()['enabled'],
            false,
          );
        },
      );
      test('dead_intent_does_not_require_signing_material', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(session);
        final first = input(1);
        await repository.publish(first);
        await session.db.unsafeExecute(
          '''INSERT INTO outbox
        (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,attempt_count)
        VALUES (now(),'33333333-3333-4333-8333-333333333333',now(),'44444444-4444-4444-8444-444444444444','ready',
        '$outputId',@config,'http://127.0.0.1:9099/events','key-v1',@commitment,decode('7b7d','hex'),'dead',20)''',
          parameters: QueryParameters.named({
            'config': first.snapshotId,
            'commitment': first.outputs.single.signingKeyCommitment,
          }),
        );
        final rotated = input(2, keyRef: 'key-v2', key: 3);
        await repository.publish(rotated);
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          rotated.snapshotId,
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT signing_key_ref,status FROM outbox',
          )).single[0],
          'key-v1',
        );
        await session.db.unsafeExecute("UPDATE outbox SET status='queued'");
        await expectLater(
          repository.validateLiveSecrets(rotated),
          throwsA(isA<BootstrapError>()),
        );
        final operatorInput = <String, Object?>{
          'format_version': 1,
          'revision': 3,
          'sources': [
            {
              'id': sourceId,
              'enabled': true,
              'token_ref': 'source-token',
              'output_ids': [outputId],
            },
          ],
          'outputs': [
            {
              'id': outputId,
              'kind': 'webhook',
              'url': 'http://127.0.0.1:9099/events',
              'signing_key_ref': 'key-v2',
            },
          ],
        };
        final withHistorical = IngestBootstrap.parse(operatorInput, {
          'source-token': token(1),
          'key-v1': token(2),
          'key-v2': token(3),
        }, runMode: 'test');
        await repository.publish(withHistorical);
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          withHistorical.snapshotId,
        );
      });
      test('retained live output lanes cannot exceed capacity', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(session);
        final first = input(1);
        await repository.publish(first);
        await session.db.unsafeExecute(
          '''INSERT INTO outbox
        (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,attempt_count)
        SELECT now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',gen_random_uuid(),@config,
        'http://127.0.0.1:9099/events','key-v1',@commitment,decode('7b7d','hex'),'queued',0
        FROM generate_series(1,64)''',
          parameters: QueryParameters.named({
            'config': first.snapshotId,
            'commitment': first.outputs.single.signingKeyCommitment,
          }),
        );
        await expectLater(
          repository.publish(input(2)),
          throwsA(
            isA<BootstrapError>().having(
              (error) => error.code,
              'code',
              'retained_output_bound',
            ),
          ),
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          first.snapshotId,
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
