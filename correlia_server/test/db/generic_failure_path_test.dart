@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_pipeline_fixture.dart';
import '../support/generic_webhook_fixture.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;

final _now = DateTime.utc(2026, 11, 24, 12);

Map<String, Object?> _expandedMapping({bool batch = false}) => {
  ...checkMapping(),
  if (batch) 'items': '',
  'labels': {
    for (var i = 0; i < 128; i++) 'k$i': {'copy': '/copy'},
  },
};

void main() {
  withServerpod(
    'Persisted generic validation failures',
    (builder, _) {
      late Session session;
      late List<String> logs;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        logs = [];
      });

      Future<void> expectFailure(
        IngestBootstrap input,
        String body,
        String code,
        String? path,
      ) async {
        final raw = await admitGeneric(session, input, body, _now);
        final pipeline = PipelineRepository(
          session,
          clock: () => _now,
          log: logs.add,
        );
        expect(await pipeline.pinOne(), isTrue);
        expect(await pipeline.processOne(), isTrue);
        final failures = await session.db.unsafeQuery(
          'SELECT "rawId"::text,"errorClass","fieldPath" FROM pipeline_failures',
        );
        expect(failures.map((row) => row.toList()), [
          [raw, code, path],
        ]);
        expect(
          (await session.db.unsafeQuery(
            'SELECT status FROM raw_inbox',
          )).single[0],
          'failed',
        );
        for (final table in [
          'events',
          'observation_keys',
          'alerts',
          'outbox',
        ]) {
          expect(
            await session.db.unsafeQuery('SELECT 1 FROM $table LIMIT 1'),
            isEmpty,
          );
        }
        expect(logs, isEmpty);
      }

      test('invalid_json_body', () async {
        final input = await publishGenericConfig(session, now: _now);
        await expectFailure(input, '{"sender-secret":', 'invalid_json', '');
      });

      test('nul_in_copied_summary_fails_at_its_pointer', () async {
        final input = await publishGenericConfig(session, now: _now);
        await expectFailure(
          input,
          jsonEncode({...genericAlert(_now), 'summary': 'bad\u0000summary'}),
          'invalid_text',
          '/summary',
        );
      });

      test('nul_summary_path_is_bounded', () async {
        final key = 'x' * 256;
        final revised = await publishGenericConfig(
          session,
          now: _now,
          mapping: {
            ...checkMapping(),
            'summary': {'copy': '/$key'},
          },
        );
        await expectFailure(
          revised,
          jsonEncode({...genericAlert(_now)..remove('summary'), key: '\u0000'}),
          'invalid_text',
          '/*',
        );
      });

      test('canonical_failure_while_decoding', () async {
        final input = await publishGenericConfig(
          session,
          now: _now,
          mapping: _expandedMapping(),
        );
        final body = jsonEncode({
          ...genericAlert(_now),
          'copy': '\u0000' * 512,
        });
        await expectFailure(input, body, 'event_too_large', 'event');
      });

      test('budget_failure_while_committing', () async {
        final input = await publishGenericConfig(
          session,
          now: _now,
          mapping: _expandedMapping(batch: true),
          outputs: [
            for (var i = 0; i < 8; i++)
              {
                'id':
                    '40000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
                'kind': 'webhook',
                'url': 'http://127.0.0.1:9099/events',
                'signing_key_ref': 'output-key',
              },
          ],
          outputSecrets: {'output-key': genericTestToken(2)},
        );
        final copied = '🦋' * 200;
        final body = jsonEncode([
          for (var i = 0; i < 20; i++)
            {...genericAlert(_now, host: 'check-$i'), 'copy': copied},
        ]);
        await expectFailure(input, body, 'batch_bound', null);
      });

      test('failure_in_the_second_of_three_alerts', () async {
        final input = await publishGenericConfig(
          session,
          now: _now,
          mapping: {
            ...checkMapping(),
            'items': '/items',
            'severity': {
              'pointer': '/severity',
              'values': {'CRITICAL': 'critical'},
            },
          },
        );
        final body = jsonEncode({
          'items': [
            {...genericAlert(_now), 'severity': 'CRITICAL'},
            {...genericAlert(_now, host: 'cache'), 'severity': 'secret-value'},
            {...genericAlert(_now, host: 'database'), 'severity': 'CRITICAL'},
          ],
        });
        await expectFailure(input, body, 'unlisted_value', '/items/1/severity');
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
