import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as fixture;
import 'pipeline_test.dart' as support;

const secondOutput = '33333333-3333-4333-8333-333333333333';

IngestBootstrap config(int revision, {bool routed = true}) =>
    IngestBootstrap.parse(
      {
        'format_version': 1,
        'revision': revision,
        'sources': [
          {
            'id': fixture.sourceId,
            'enabled': true,
            'token_ref': 'source-token',
            'output_ids': [
              if (routed) ...[fixture.outputId, secondOutput],
            ],
          },
        ],
        'outputs': [
          {
            'id': fixture.outputId,
            'kind': 'webhook',
            'url': 'http://127.0.0.1:${revision == 1 ? 9099 : 9100}/events',
            'signing_key_ref': 'key',
          },
          {
            'id': secondOutput,
            'kind': 'webhook',
            'url': 'http://127.0.0.1:9101/events',
            'signing_key_ref': 'key',
          },
        ],
      },
      {'source-token': fixture.token(1), 'key': fixture.token(2)},
      runMode: 'test',
    );

void main() {
  withServerpod(
    'pinned routing',
    (builder, _) {
      setUp(() async {
        final session = builder.build();
        await initializeIngestSchema(session);
        for (final table in [
          'pipeline_failures',
          'observation_keys',
          'outbox',
          'events',
          'raw_inbox',
          'ingest_active_config',
          'ingest_source',
          'ingest_config_snapshot',
          'ingest_secret_commitment',
        ]) {
          await session.db.unsafeSimpleExecute('DELETE FROM "$table"');
        }
      });
      test('fanout_with_configuration_change', () async {
        final session = builder.build();
        final repository = IngestConfigRepository(session);
        final first = config(1);
        await repository.publish(first);
        await support.seed(session, [
          payload.alert(startsAt: '2026-11-10T12:00:00Z'),
        ]);
        final pipeline = PipelineRepository(session, clock: () => support.now);
        await pipeline.pinOne();
        await repository.publish(config(2));
        await pipeline.processOne();
        final rows = await session.db.unsafeQuery(
          'SELECT config_snapshot_id,target_url,payload FROM outbox ORDER BY target_url',
        );
        expect(rows, hasLength(2));
        expect(rows.map((row) => row[0]), everyElement(first.snapshotId));
        expect(rows.map((row) => row[1]), [
          'http://127.0.0.1:9099/events',
          'http://127.0.0.1:9101/events',
        ]);
        expect(rows[0][2], rows[1][2]);
      });
      test('fanout_bound_rolls_back_all_siblings', () async {
        final session = builder.build();
        final ids = List.generate(
          8,
          (index) =>
              '40000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
        );
        final input = IngestBootstrap.parse(
          {
            'format_version': 1,
            'revision': 1,
            'sources': [
              {
                'id': fixture.sourceId,
                'enabled': true,
                'token_ref': 'source-token',
                'output_ids': ids,
              },
            ],
            'outputs': [
              for (final id in ids)
                {
                  'id': id,
                  'kind': 'webhook',
                  'url': 'http://127.0.0.1:9099/events',
                  'signing_key_ref': 'key',
                },
            ],
          },
          {'source-token': fixture.token(1), 'key': fixture.token(2)},
          runMode: 'test',
        );
        await IngestConfigRepository(session).publish(input);
        final labels = {for (var i = 0; i < 60; i++) 'key$i': 'x' * 900};
        await support.seed(session, [
          for (var i = 0; i < 18; i++)
            payload.alert(
              startsAt: '2026-11-10T12:00:00Z',
              labels: {...labels, 'alertname': 'alert$i'},
            ),
        ]);
        expect(
          (await session.db.unsafeQuery(
            'SELECT octet_length(body) FROM raw_inbox',
          )).single[0],
          lessThanOrEqualTo(1048576),
        );
        final pipeline = PipelineRepository(session, clock: () => support.now);
        await pipeline.pinOne();
        await pipeline.processOne();
        expect(await support.count(session, 'events'), 0);
        expect(await support.count(session, 'observation_keys'), 0);
        expect(await support.count(session, 'outbox'), 0);
        expect(
          (await session.db.unsafeQuery(
            'SELECT "errorClass" FROM pipeline_failures',
          )).single[0],
          'batch_bound',
        );
      });
      test('explicitly_unrouted_event', () async {
        final session = builder.build();
        await IngestConfigRepository(session).publish(config(1, routed: false));
        await support.seed(session, [
          payload.alert(startsAt: '2026-11-10T12:00:00Z'),
        ]);
        final pipeline = PipelineRepository(session, clock: () => support.now);
        await pipeline.pinOne();
        await pipeline.processOne();
        expect(await support.count(session, 'events'), 1);
        expect(await support.count(session, 'outbox'), 0);
        expect(
          (await session.db.unsafeQuery(
            "SELECT (outcome_json::jsonb->>'unrouted')::int FROM raw_inbox WHERE status='done'",
          )).single[0],
          1,
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
