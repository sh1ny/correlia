import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingress.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';
import 'package:crypto/crypto.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';

import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'pipeline_test.dart' as pipeline_fixture;

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';

const sourceId = '11111111-1111-4111-8111-111111111111';
const outputId = '22222222-2222-4222-8222-222222222222';

final class _Routes implements RouteHost {
  _Routes(this.web);
  final WebServer web;
  @override
  void addRoute(Route route, String path) => web.addRoute(route, path);
}

String token(int byte) =>
    base64Url.encode(List<int>.filled(32, byte)).replaceAll('=', '');
IngestBootstrap input(
  int revision, {
  int credential = 1,
  String? tokenRef,
  String keyRef = 'key-v1',
  int key = 2,
  bool includeSource = true,
}) {
  final reference =
      tokenRef ??
      (credential == 1 ? 'source-token' : 'source-token-$credential');
  return IngestBootstrap.parse(
    {
      'format_version': 1,
      'revision': revision,
      'sources': [
        if (includeSource)
          {
            'id': sourceId,
            'enabled': true,
            'token_ref': reference,
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
    {reference: token(credential), keyRef: token(key)},
    runMode: 'test',
  );
}

Map<String, Object?> pluginConfig(int revision) => {
  'format_version': 1,
  'revision': revision,
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
      'kind': 'plugin',
      'plugin': 'output-nats',
      'sha256': 'a' * 64,
      'config': {'subject': 'events'},
      'secret_refs': {'token': 'plugin-token'},
    },
  ],
};

Map<String, Object?> pluginSecrets(int value) => {
  'source-token': token(1),
  'plugin-token': token(value),
};

IngestBootstrap pluginInput(int revision) => IngestBootstrap.parse(
  pluginConfig(revision),
  pluginSecrets(7),
  runMode: 'test',
  pluginCommitment: testSecretStore.commitments.plugin,
);

Map<String, Object?> cutoverV2(int revision) => {
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
      'url': 'http://127.0.0.1:9099/events',
      'signing_key_ref': 'key-v1',
    },
  ],
};

Map<String, Object?> kindConfig(
  int revision,
  String? kind, {
  String id = sourceId,
}) => {
  'format_version': 2,
  'revision': revision,
  'outputs': <Object?>[],
  'sources': [
    if (kind != null)
      {
        'id': id,
        'kind': kind,
        'enabled': true,
        'credentials': [
          {'ref': 'source-token', 'type': 'bearer'},
        ],
        'output_ids': <Object?>[],
      },
  ],
};

Matcher kindChanged(String field) => throwsA(
  isA<BootstrapError>()
      .having((e) => e.field, 'field', field)
      .having((e) => e.code, 'code', 'kind_changed'),
);

Future<int> _sendBearer(Session session, IngestBootstrap config) async {
  final pod = session.serverpod;
  final ingress = IngressSubsystem(
    pod: pod,
    bootstrap: () => config,
    ready: () => true,
    log: (_) {},
  );
  ingress.mountRoutes(_Routes(pod.webServer));
  await ingress.start();
  final startedHere = !pod.webServer.running;
  if (startedHere) expect(await pod.webServer.start(), isTrue);
  final client = HttpClient();
  try {
    final request = await client.post(
      '127.0.0.1',
      pod.webServer.port!,
      '/hooks/alertmanager/$sourceId',
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('authorization', 'Bearer ${token(1)}');
    request.write('{}');
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
    await ingress.stop();
    if (startedHere) await pod.webServer.stop();
  }
}

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
          'secret_record',
          'ingest_source_credential',
        ]) {
          await session.db.unsafeSimpleExecute('DELETE FROM "$table"');
        }
      });
      test('v2_publication_cutover', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final first = input(1);
        await repository.publish(first);
        final next = await repository.publishConfig(
          cutoverV2(2),
          <String, Object?>{},
          runMode: 'test',
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          next.snapshotId,
        );
        final counts = (await session.db.unsafeQuery('''
          SELECT (SELECT count(*) FROM ingest_config_snapshot),
                 (SELECT count(*) FROM secret_record),
                 (SELECT count(*) FROM ingest_source_credential)
        ''')).single.toList();
        expect(counts, [2, 2, 1]);
        expect(await _sendBearer(session, next), 202);
      });
      test('kind_change_refused', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final secrets = <String, Object?>{'source-token': token(1)};
        final first = await repository.publishConfig(
          kindConfig(1, 'alertmanager'),
          secrets,
          runMode: 'test',
        );
        await expectLater(
          repository.publishConfig(
            kindConfig(2, 'icinga2'),
            secrets,
            runMode: 'test',
          ),
          kindChanged('sources[0].kind'),
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          first.snapshotId,
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT kind FROM ingest_source',
          )).single[0],
          'alertmanager',
        );
      });
      test('disabled_source_keeps_its_kind', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final secrets = <String, Object?>{'source-token': token(1)};
        await repository.publishConfig(
          kindConfig(1, 'alertmanager'),
          secrets,
          runMode: 'test',
        );
        final removed = await repository.publishConfig(
          kindConfig(2, null),
          secrets,
          runMode: 'test',
        );
        await expectLater(
          repository.publishConfig(
            kindConfig(3, 'icinga2'),
            secrets,
            runMode: 'test',
          ),
          kindChanged('sources[0].kind'),
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          removed.snapshotId,
        );
      });
      test('bootstrap_publication_and_rotation', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
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
          'SELECT reference,digest FROM ingest_source_credential',
        )).single.toColumnMap();
        expect(
          row['reference'],
          second.sources.single.credentials.single.reference,
        );
        expect(row['digest'], second.sources.single.credentials.single.digest);
        expect(
          row['digest'],
          isNot(first.sources.single.credentials.single.digest),
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) AS count FROM ingest_config_snapshot',
          )).single.toColumnMap()['count'],
          2,
        );
      });
      test('empty_registry_and_missing_secret', () async {
        final repository = IngestConfigRepository(
          builder.build(),
          secretStore: testSecretStore,
        );
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
        final repository = IngestConfigRepository(
          builder.build(),
          secretStore: testSecretStore,
        );
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
        final repository = IngestConfigRepository(
          builder.build(),
          secretStore: testSecretStore,
        );
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
        final repository = IngestConfigRepository(
          builder.build(),
          secretStore: testSecretStore,
        );
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
          final repository = IngestConfigRepository(
            session,
            secretStore: testSecretStore,
          );
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
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final first = input(1);
        await repository.publish(first);
        await session.db.unsafeExecute(
          '''INSERT INTO outbox
        (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,attempt_count)
        VALUES (now(),'33333333-3333-4333-8333-333333333333',now(),'44444444-4444-4444-8444-444444444444','ready',
        '$outputId',@config,'http://127.0.0.1:9099/events','key-v1',@commitment,decode('7b7d','hex'),'dead',20)''',
          parameters: QueryParameters.named({
            'config': first.snapshotId,
            'commitment': (first.outputs.single as WebhookIngestOutput)
                .signingKeyCommitment,
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
        await repository.validateLiveSecrets();
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
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
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
            'commitment': (first.outputs.single as WebhookIngestOutput)
                .signingKeyCommitment,
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
      test('plugin_output_activates', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final definition = await repository.publishConfig(
          pluginConfig(1),
          pluginSecrets(7),
          runMode: 'test',
        );
        final stored = await repository.snapshot(definition.snapshotId);
        final text = jsonEncode(stored);
        final expected = testSecretStore.commitments.plugin(
          'plugin-token',
          base64Url.decode('${token(7)}='),
        );
        expect(text, contains(expected));
        expect(
          text,
          isNot(
            contains(
              sha256.convert(base64Url.decode('${token(7)}=')).toString(),
            ),
          ),
        );
        expect(
          (await session.db.unsafeSimpleQuery(
            "SELECT digest FROM ingest_secret_commitment WHERE reference='plugin-token'",
          )).single[0],
          expected,
        );
        final same = await repository.publishConfig(
          pluginConfig(1),
          pluginSecrets(7),
          runMode: 'test',
        );
        expect(same.snapshotId, definition.snapshotId);
        expect(text, isNot(contains(token(7))));
        await pipeline_fixture.seed(session, [
          payload.alert(startsAt: '2026-11-10T12:00:00Z'),
        ]);
        final pipeline = PipelineRepository(
          session,
          clock: () => pipeline_fixture.now,
        );
        await pipeline.pinOne();
        await pipeline.processOne();
        final row = (await session.db.unsafeQuery(
          'SELECT output_kind,definition_digest,config_snapshot_id,target_url FROM outbox',
        )).single;
        expect(row[0], 'plugin');
        expect(
          row[1],
          (definition.outputs.single as PluginIngestOutput).definitionDigest,
        );
        expect(row[2], definition.snapshotId);
        expect(row[3], isNull);
      });
      test('plugin_secret_reference_rebound', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final first = await repository.publishConfig(
          pluginConfig(1),
          pluginSecrets(7),
          runMode: 'test',
        );
        final record = (await session.db.unsafeSimpleQuery(
          "SELECT encode(ciphertext,'hex'),commitment FROM secret_record WHERE reference='plugin-token'",
        )).single;
        expect(record[1], startsWith('hmac-sha256:'));
        await expectLater(
          repository.publishConfig(
            pluginConfig(2),
            pluginSecrets(8),
            runMode: 'test',
          ),
          throwsA(
            isA<BootstrapError>().having(
              (e) => e.code,
              'code',
              'reference_rebound',
            ),
          ),
        );
        await expectLater(
          repository.publish(input(2, keyRef: 'plugin-token', key: 8)),
          throwsA(
            isA<BootstrapError>().having(
              (e) => e.code,
              'code',
              'reference_rebound',
            ),
          ),
        );
        expect(
          (await repository.activeSnapshot())!['snapshotId'],
          first.snapshotId,
        );
        final after = (await session.db.unsafeSimpleQuery(
          "SELECT encode(ciphertext,'hex'),commitment FROM secret_record WHERE reference='plugin-token'",
        )).single;
        expect(after.toList(), record.toList());
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
