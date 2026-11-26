@Timeout(Duration(minutes: 5))
library;

import 'dart:io' show Platform, Process;

import 'package:correlia_client/correlia_client.dart' as rpc;
import 'package:correlia_server/src/feed/feed_runtime.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../../tool/simulate_cli.dart';
import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as fixture;
import 'pipeline_test.dart' as support;

const _output = '33333333-3333-4333-8333-333333333333';

Future<void> _publish(Session session) async {
  final repository = IngestConfigRepository(
    session,
    secretStore: testSecretStore,
  );
  final active = await repository.activeSnapshot();
  await repository.publishConfig(
    {
      'format_version': 2,
      'revision': ((active?['revision'] as int?) ?? 0) + 1,
      'expected_active_snapshot': active?['snapshotId'],
      'sources': [
        {
          'id': fixture.sourceId,
          'kind': 'alertmanager',
          'enabled': true,
          'credentials': [
            {'type': 'bearer', 'ref': 'token'},
          ],
          'output_ids': [fixture.outputId],
        },
      ],
      'outputs': [
        for (final id in [fixture.outputId, _output])
          {
            'id': id,
            'kind': 'webhook',
            'url': 'http://127.0.0.1:9099/events',
            'signing_key_ref': 'key',
          },
      ],
      'matcher': {
        'language': 'matcher',
        'version': 1,
        'rules': [
          {
            'id': 'label-it',
            'when': {'field': 'summary', 'op': 'exists'},
            'actions': [
              {'type': 'set_label', 'key': 'team', 'value': 'ops'},
            ],
          },
        ],
      },
    },
    {'token': fixture.token(1), 'key': fixture.token(2)},
    runMode: 'test',
  );
}

void main() {
  withServerpod(
    'Simulator command line',
    (builder, _) {
      late Session session;
      late rpc.Client client;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
        await _publish(session);
        client = rpc.Client(
          'http://127.0.0.1:${session.serverpod.server.port}/',
        );
        addTearDown(client.close);
        final previous = FeedRuntime.role;
        FeedRuntime.role = ProcessRole.api;
        addTearDown(() => FeedRuntime.role = previous);
      });

      test('trace_a_stored_event', () async {
        await support.seed(session, [
          payload.alert(
            startsAt: '2026-11-10T12:00:00Z',
            labels: {'alertname': 'Example'},
          ),
        ]);
        final worker = PipelineRepository(
          session,
          clock: () => support.now,
          elapsedForTest: () => Duration.zero,
        );
        expect(await worker.pinOne(), isTrue);
        expect(await worker.processOne(), isTrue);
        final event = (await session.db.unsafeQuery(
          'SELECT event_id::text, observed_at FROM events',
        )).single;

        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runSimulate(
          [
            '--event-id',
            event[0]! as String,
            '--observed-at',
            (event[1]! as DateTime).toUtc().toIso8601String(),
          ],
          client.ruleSimulator.simulate,
          out,
          err,
        );

        expect(err.toString(), isEmpty);
        expect(code, 0);
        final text = out.toString();
        expect(text, contains('rule label-it: matched'));
        expect(text, contains('summary exists: matched'));
        expect(text, contains('action 0 label team = ops: staged (applied)'));
        expect(text, contains('team=ops (matcher)'));
        expect(text, contains('stored snapshot:'));
      });

      test('the_executable_traces_a_stored_event', () async {
        await support.seed(session, [
          payload.alert(
            startsAt: '2026-11-10T12:00:00Z',
            labels: {'alertname': 'Example'},
          ),
        ]);
        final worker = PipelineRepository(
          session,
          clock: () => support.now,
          elapsedForTest: () => Duration.zero,
        );
        expect(await worker.pinOne(), isTrue);
        expect(await worker.processOne(), isTrue);
        final event = (await session.db.unsafeQuery(
          'SELECT event_id::text, observed_at FROM events',
        )).single;

        // The real entry point, its --server option and its own client.
        final run = await Process.run(Platform.resolvedExecutable, [
          'run',
          'tool/simulate.dart',
          '--server',
          'http://127.0.0.1:${session.serverpod.server.port}/',
          '--event-id',
          event[0]! as String,
          '--observed-at',
          (event[1]! as DateTime).toUtc().toIso8601String(),
        ]);

        expect(run.exitCode, 0, reason: '${run.stderr}');
        final text = '${run.stdout}';
        expect(text, contains('rule label-it: matched'));
        expect(text, contains('action 0 label team = ops: staged (applied)'));
        expect(text, contains('stored snapshot:'));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
