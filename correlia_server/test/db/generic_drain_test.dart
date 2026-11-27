@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/ingress.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_pipeline_fixture.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;

final _now = DateTime.utc(2026, 11, 24, 12);

final class _Routes implements RouteHost {
  _Routes(this.web);
  final WebServer web;

  @override
  void addRoute(Route route, String path) => web.addRoute(route, path);
}

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
        // Keep both rows pending across publication. Their synthetic receipt
        // predates the database clock; this test does not advance queue age.
        await session.db.unsafeExecute(
          "UPDATE raw_inbox SET queued_at='infinity'",
        );
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
        final web = WebServer(serverpod: session.serverpod);
        final ingress = IngressSubsystem(
          pod: session.serverpod,
          bootstrap: () => active,
          ready: () => true,
          log: (_) {},
          clock: () => later,
        );
        ingress.mountRoutes(_Routes(web));
        await ingress.start();
        addTearDown(ingress.stop);
        expect(await web.start(), isTrue);
        addTearDown(web.stop);
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
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.post(
          '127.0.0.1',
          web.port!,
          '/hooks/generic/$genericPipelineSource',
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('Authorization', 'Bearer ${genericTestToken(2)}');
        request.write(body);
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 401);
        final raw = await session.db.unsafeQuery(
          'SELECT status FROM raw_inbox',
        );
        expect(raw.map((row) => row[0]), ['done', 'done']);
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
