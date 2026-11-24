@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_pipeline_fixture.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;

final _now = DateTime.utc(2026, 11, 24, 12);

void main() {
  withServerpod(
    'Removing a generic source',
    (builder, _) {
      late Session session;
      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
      });

      test('drained_source_removed', () async {
        final original = await publishGenericConfig(session, now: _now);
        final body = jsonEncode(genericAlert(_now));
        await admitGeneric(session, original, body, _now);
        final later = _now.add(const Duration(seconds: 1));
        await admitGeneric(
          session,
          original,
          jsonEncode(genericAlert(later, host: 'database')),
          later,
        );
        final active = await publishGenericConfig(
          session,
          now: later,
          revision: 2,
          bearer: 2,
        );
        expect(active.sources.single.enabled, isTrue);
        final pipeline = PipelineRepository(session, clock: () => later);
        for (final _ in [1, 2]) {
          expect(await pipeline.pinOne(), isTrue);
          expect(await pipeline.processOne(), isTrue);
        }
        expect(await pipeline.pinOne(), isFalse);
        await publishGenericConfig(
          session,
          now: later,
          revision: 3,
          includeSource: false,
          bearer: 2,
        );
        expect(await pipeline.processOne(), isFalse);
        expect(
          await session.db.unsafeQuery('SELECT 1 FROM pipeline_failures'),
          isEmpty,
        );
        expect(
          (await genericEvents(
            session,
          )).map((event) => event.identityFields['host']!.raw),
          ['api', 'database'],
        );
      });

      test('source_removed_before_draining', () async {
        final original = await publishGenericConfig(session, now: _now);
        final raw = await admitGeneric(
          session,
          original,
          jsonEncode(genericAlert(_now)),
          _now,
        );
        await publishGenericConfig(
          session,
          now: _now,
          revision: 2,
          includeSource: false,
        );
        final pipeline = PipelineRepository(session, clock: () => _now);
        expect(await pipeline.pinOne(), isTrue);
        expect(await pipeline.processOne(), isTrue);
        expect(
          (await session.db.unsafeQuery(
            'SELECT "rawId"::text,"errorClass" FROM pipeline_failures',
          )).single.toList(),
          [raw, 'source_not_configured'],
        );
        expect(await genericEvents(session), isEmpty);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
