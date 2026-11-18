import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' as fixture;

Future<void> addIntent(
  Session session,
  String snapshot,
  String kind,
  String status, {
  String? commitment,
}) async {
  await session.db.unsafeExecute(
    '''INSERT INTO outbox
    (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
     config_snapshot_id,output_kind,definition_digest,target_url,signing_key_ref,
     signing_key_commitment,payload,status)
    VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',CAST(@output AS uuid),
      @snapshot,@kind,@digest,@url,@ref,@commitment,decode('7b7d','hex'),@status)''',
    parameters: QueryParameters.named({
      'output': fixture.outputId,
      'snapshot': snapshot,
      'kind': kind,
      'digest': kind == 'plugin' ? 'a' * 64 : null,
      'url': kind == 'webhook' ? 'http://127.0.0.1:9099/events' : null,
      'ref': kind == 'webhook' ? 'key-v1' : null,
      'commitment': commitment,
      'status': status,
    }),
  );
}

void main() {
  IngestBootstrap unauthenticatedPlugin() => IngestBootstrap.parse(
    {
      'format_version': 1,
      'revision': 1,
      'sources': [
        {
          'id': fixture.sourceId,
          'enabled': true,
          'token_ref': 'source-token',
          'output_ids': [fixture.outputId],
        },
      ],
      'outputs': [
        {
          'id': fixture.outputId,
          'kind': 'plugin',
          'plugin': 'output-nats',
          'sha256': 'a' * 64,
          'config': <String, Object?>{},
          'secret_refs': <String, Object?>{},
        },
      ],
    },
    {'source-token': fixture.token(1)},
    runMode: 'test',
  );
  withServerpod(
    'plugin startup secrets',
    (builder, _) {
      setUp(() async {
        final session = builder.build();
        await initializeIngestSchema(session);
        for (final table in [
          'outbox',
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
      test('restart_with_pending_unauthenticated_plugin_work', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final current = unauthenticatedPlugin();
        await repository.publish(current);
        await addIntent(session, current.snapshotId, 'plugin', 'queued');
        await addIntent(session, current.snapshotId, 'plugin', 'delivering');
        await repository.validateLiveSecrets();
      });
      test('mixed_live_work_missing_plugin_secret', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final historical = fixture.pluginInput(1);
        await repository.publish(historical);
        await session.db.unsafeSimpleExecute(
          "DELETE FROM secret_record WHERE reference='plugin-token'",
        );
        await addIntent(session, historical.snapshotId, 'plugin', 'queued');
        final current = fixture.input(2);
        final webhook = current.outputs.single as WebhookIngestOutput;
        await addIntent(
          session,
          current.snapshotId,
          'webhook',
          'queued',
          commitment: webhook.signingKeyCommitment,
        );
        await repository.publish(current);
        await repository.validateLiveSecrets();
      });
      test('missing_webhook_key_fails_startup', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final current = fixture.input(1);
        await repository.publish(current);
        final webhook = current.outputs.single as WebhookIngestOutput;
        await addIntent(
          session,
          current.snapshotId,
          'webhook',
          'queued',
          commitment: webhook.signingKeyCommitment,
        );
        await session.db.unsafeSimpleExecute(
          "DELETE FROM secret_record WHERE reference='key-v1'",
        );
        await expectLater(
          repository.validateLiveSecrets(),
          throwsA(
            isA<BootstrapError>().having(
              (e) => e.code,
              'code',
              'historical_key_unavailable',
            ),
          ),
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
