@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_pipeline_fixture.dart';
import '../support/generic_webhook_fixture.dart';
import '../support/icinga2_pipeline.dart'
    show clearPipelineTables, outcomeOf, theAlert;

final _now = DateTime.utc(2026, 11, 24, 12);

void main() {
  withServerpod(
    'Generic deliveries through the pipeline',
    (builder, _) {
      late Session session;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
      });

      Future<String> deliver(
        IngestBootstrap input,
        Object? alert,
        DateTime receipt,
      ) async {
        final raw = await admitGeneric(
          session,
          input,
          jsonEncode(alert),
          receipt,
        );
        final pipeline = PipelineRepository(session, clock: () => receipt);
        expect(await pipeline.pinOne(), isTrue);
        expect(await pipeline.processOne(), isTrue);
        final failed = await session.db.unsafeQuery(
          'SELECT "errorClass" FROM pipeline_failures',
        );
        expect(failed.map((row) => row[0]), isEmpty, reason: 'delivery failed');
        return raw;
      }

      test(
        'generator_link_keeps_canonical_text_and_stores_a_safe_url',
        () async {
          const href = 'https://example.org/a\u0000b';
          const display = 'a\u0000\u0000b\\u0000\\\u0000c';
          final config = await publishGenericConfig(
            session,
            now: _now,
            mapping: {
              ...checkMapping(),
              'links': {
                'generator': {'copy': '/url'},
              },
              'description': {'copy': '/display'},
              'labels': {
                'message': {'copy': '/display'},
              },
            },
          );
          await deliver(config, {
            ...genericAlert(_now),
            'url': href,
            'display': display,
          }, _now);
          final event = (await genericEvents(session)).single;
          expect(event.links.single.href, href);
          expect(event.description, display);
          expect(event.labels['message'], display);
          final subject = await session.db.unsafeQuery(
            'SELECT correlia_event_subject(payload) FROM events',
          );
          expect(subject.single[0], event.fingerprint);
          expect(
            (await theAlert(session))['generatorUrl'],
            'https://example.org/a%00b',
          );
        },
      );

      test('mapping_published_with_its_source', () async {
        final config = await publishGenericConfig(
          session,
          now: _now,
          mapping: {
            ...checkMapping(),
            'summary': {'constant': 'checks mapping'},
            'unmapped_fields': 'count',
          },
        );
        final raw = await deliver(config, genericAlert(_now), _now);
        final event = (await genericEvents(session)).single;
        expect(event.summary, 'checks mapping');
        expect(event.source.sourceInstance, genericPipelineSource);
        expect(event.source.sourceKind, 'generic');
        expect((await outcomeOf(session, raw))['unmapped_fields'], 1);
      });

      test(
        'invalid_mapping_cannot_replace_a_snapshot_pinned_by_pending_work',
        () async {
          final active = await publishGenericConfig(session, now: _now);
          await admitGeneric(
            session,
            active,
            jsonEncode(genericAlert(_now)),
            _now,
          );
          final pipeline = PipelineRepository(session, clock: () => _now);
          expect(await pipeline.pinOne(), isTrue);
          await expectLater(
            publishGenericConfig(
              session,
              now: _now,
              revision: 2,
              mapping: {
                ...checkMapping(),
                'summary': {'constant': 'bad\u0000text'},
              },
            ),
            throwsA(
              isA<BootstrapError>()
                  .having(
                    (error) => error.field,
                    'field',
                    'mappings[0].summary',
                  )
                  .having((error) => error.code, 'code', 'invalid_text'),
            ),
          );
          final snapshot = await IngestConfigRepository(
            session,
          ).activeSnapshot();
          expect(snapshot?['snapshotId'], active.snapshotId);
          expect(await pipeline.processOne(), isTrue);
          expect((await genericEvents(session)).single.summary, 'Check status');
        },
      );

      test('ord_4_future_source_time', () async {
        final config = await publishGenericConfig(session, now: _now);
        final reported = _now.add(const Duration(hours: 3));
        final raw = await deliver(config, genericAlert(reported), _now);
        final event = (await genericEvents(session)).single;
        expect(
          event.sourceTime,
          EventTimestamp.parse(reported.toIso8601String()),
        );
        final effective = await session.db.unsafeQuery(
          'SELECT events_effective_source_time(e) FROM events e',
        );
        expect(effective.single[0], _now.add(const Duration(minutes: 5)));
        expect((await outcomeOf(session, raw))['clamped'], 1);
      });

      test('observation_id_reused_for_the_resolve', () async {
        final config = await publishGenericConfig(
          session,
          now: _now,
          mapping: {
            ...checkMapping(),
            'observation_id': '/changeId',
          },
        );
        await deliver(config, genericAlert(_now, changeId: 'same-id'), _now);
        final later = _now.add(const Duration(seconds: 1));
        final raw = await deliver(
          config,
          genericAlert(later, changeId: 'same-id', state: 'OK'),
          later,
        );
        expect((await outcomeOf(session, raw))['duplicate_observation'], 1);
        expect(
          (await genericEvents(session)).single.status,
          EventStatus.firing,
        );
        expect((await theAlert(session))['status'], 'firing');
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
