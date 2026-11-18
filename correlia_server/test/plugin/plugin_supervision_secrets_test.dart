@Tags(['plugin'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingest_startup.dart';
import 'package:correlia_server/src/ingest/ingest_test_gates.dart';
import 'package:correlia_server/src/ingest/ingest_workers.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import 'support/plugin_fixture_support.dart';

void main() {
  withServerpod(
    'historical plugin secrets',
    (builder, _) {
      test(
        'missing_historical_secret_keeps_work_queued_without_blocking_worker',
        () async {
          final suite = PluginFixtureSuite.create();
          IngestWorkers? workers;
          try {
            final built = await suite.build();
            final executable =
                built.binaries[PluginFixtureBinary.outputProduction]!;
            await Process.run('chmod', ['700', executable.path]);
            final digest = sha256
                .convert(await executable.readAsBytes())
                .toString();
            const output = '22222222-2222-4222-8222-222222222222';
            final old = IngestBootstrap.parse(
              {
                'format_version': 1,
                'revision': 1,
                'sources': <Object>[],
                'outputs': [
                  {
                    'id': output,
                    'kind': 'plugin',
                    'plugin': 'output-production',
                    'sha256': digest,
                    'config': {'subject': 'alerts'},
                    'secret_refs': {'token': 'token'},
                  },
                ],
              },
              {
                'token': {
                  'bytes': base64Url
                      .encode(utf8.encode('fixture-secret'))
                      .replaceAll('=', ''),
                },
              },
              runMode: 'test',
            );
            final current = IngestBootstrap.parse(
              {
                'format_version': 1,
                'revision': 2,
                'sources': <Object>[],
                'outputs': <Object>[],
              },
              <String, Object?>{},
              runMode: 'test',
            );
            final session = builder.build();
            await initializeIngestSchema(session);
            final repository = IngestConfigRepository(
              session,
              secretStore: testSecretStore,
            );
            await repository.publish(old);
            await session.db.unsafeExecute(
              '''INSERT INTO outbox
          (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
           config_snapshot_id,payload,output_kind,definition_digest)
          VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',CAST(@output AS uuid),
           @snapshot,decode('7b7d','hex'),'plugin',@digest)''',
              parameters: QueryParameters.named({
                'output': output,
                'snapshot': old.snapshotId,
                'digest':
                    (old.outputs.single as PluginIngestOutput).definitionDigest,
              }),
            );
            await session.db.unsafeSimpleExecute(
              "DELETE FROM secret_record WHERE reference='token'",
            );
            await repository.publish(current);
            final startup =
                IngestStartup(
                    pod: session.serverpod,
                    role: ProcessRole.worker,
                    runMode: 'test',
                    environment: {
                      'CORRELIA_PLUGIN_DIR': executable.parent.path,
                    },
                  )
                  ..bootstrap = current
                  ..resolver = testSecretResolver(session)
                  ..ready = true;
            final messages = <String>[];
            workers = IngestWorkers(
              pod: session.serverpod,
              startup: startup,
              runMode: 'test',
              gates: IngestTestGates.fromEnvironment('test', {}),
              log: messages.add,
            );
            await workers.start();
            expect(startup.ready, isTrue);
            final watch = Stopwatch()..start();
            var unavailable = false;
            var observed = 'no status';
            while (watch.elapsed < const Duration(seconds: 15) &&
                !unavailable) {
              final rows = await session.db.unsafeQuery(
                '''SELECT "lastErrorClass" FROM plugin_instance_status
            WHERE "outputId"=@output''',
                parameters: QueryParameters.named({'output': output}),
              );
              unavailable = rows.any(
                (row) => row[0] == 'plugin_secret_unavailable',
              );
              observed = rows.map((row) => row[0]).join(', ');
            }
            expect(unavailable, isTrue, reason: '$observed; $messages');
            final row = (await session.db.unsafeQuery(
              'SELECT status,attempt_count FROM outbox',
            )).single;
            expect(row[0], 'queued');
            expect(row[1], 0);
          } finally {
            await workers?.stop();
            await suite.dispose();
          }
        },
      );
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['plugin'],
  );
}
