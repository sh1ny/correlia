import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingress.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' show token;

const _teamA = '11111111-1111-4111-8111-111111111111';
const _teamB = '22222222-2222-4222-8222-222222222222';
const _tenants = [(_teamA, 'team-a', 1), (_teamB, 'team-b', 2)];

final class _Routes implements RouteHost {
  _Routes(this.web);
  final WebServer web;

  @override
  void addRoute(Route route, String path) => web.addRoute(route, path);
}

void main() {
  withServerpod(
    'Thanos tenants via Alertmanager',
    (builder, _) {
      late Session session;
      late WebServer web;
      late HttpClient client;
      late PipelineRepository pipeline;
      late DateTime now;
      late Uint8List body;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute(
          '''TRUNCATE activity,alerts,pipeline_failures,observation_keys,
        outbox,events,raw_inbox,transport_keys,ingest_active_config,ingest_source_credential,
        ingest_source,ingest_config_snapshot,ingest_secret_commitment,secret_record CASCADE''',
        );
        now = DateTime.utc(2026, 11, 24, 21);
        body = await File(
          'test/unit/ingest/fixtures/thanos/v0.42.5-dropped-0001.json',
        ).readAsBytes();
        final bootstrap =
            await IngestConfigRepository(
              session,
              secretStore: testSecretStore,
            ).publishConfig(
              {
                'format_version': 2,
                'revision': 1,
                'namespaces': [for (final (_, name, _) in _tenants) name],
                'sources': [
                  for (final (id, name, _) in _tenants)
                    {
                      'id': id,
                      'kind': 'alertmanager',
                      'enabled': true,
                      'namespace': name,
                      'credentials': [
                        {'ref': '$name-key', 'type': 'bearer'},
                      ],
                      'output_ids': <Object?>[],
                    },
                ],
                'outputs': <Object?>[],
              },
              {for (final (_, name, key) in _tenants) '$name-key': token(key)},
              runMode: 'test',
              clock: () => now,
            );
        client = HttpClient();
        web = WebServer(serverpod: session.serverpod);
        final ingress = IngressSubsystem(
          pod: session.serverpod,
          bootstrap: () => bootstrap,
          ready: () => true,
          log: (_) {},
          clock: () => now,
        );
        addTearDown(() async {
          client.close(force: true);
          await ingress.stop();
          await web.stop();
        });
        ingress.mountRoutes(_Routes(web));
        await ingress.start();
        expect(await web.start(), isTrue);
        pipeline = PipelineRepository(session, clock: () => now);
      });

      Future<void> deliver(
        String id,
        int key,
        String delivery, {
        String? tenant,
      }) async {
        final request = await client.post(
          '127.0.0.1',
          web.port!,
          '/hooks/alertmanager/$id',
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('authorization', 'Bearer ${token(key)}');
        request.headers.set('idempotency-key', delivery);
        if (tenant != null) request.headers.set('THANOS-TENANT', tenant);
        request.add(body);
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 202);
        expect(await pipeline.pinOne(), isTrue);
        expect(await pipeline.processOne(), isTrue);
        now = now.add(const Duration(seconds: 1));
      }

      Future<List<CanonicalEvent>> committed() async => [
        for (final row in await session.db.unsafeQuery(
          'SELECT payload FROM events ORDER BY observed_at',
        ))
          CloudEvent.decode(row[0]! as Uint8List).event,
      ];

      test('two_tenants_with_equal_labels', () async {
        await deliver(_teamA, 1, 'first');
        await deliver(_teamB, 2, 'second');
        final events = await committed();
        expect(events.map((e) => e.source.namespace), ['team-a', 'team-b']);
        expect(events.map((e) => e.source.tenant), everyElement('default'));
        expect(events.first.labels, events.last.labels);
        expect(events.first.fingerprint, isNot(events.last.fingerprint));
        expect(events.first.eventId, isNot(events.last.eventId));
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('tenant_header_on_a_delivery', () async {
        await deliver(_teamA, 1, 'without-header');
        await deliver(_teamA, 1, 'with-header', tenant: 'team-a');
        final raw = await session.db.unsafeQuery(
          'SELECT status, outcome_json, source_id::text FROM raw_inbox ORDER BY observed_at',
        );
        expect(raw.map((row) => row[0]), ['done', 'done']);
        expect(raw.map((row) => row[2]), everyElement(_teamA));
        final outcomes = raw.map((row) => jsonDecode(row[1]! as String));
        expect(outcomes.first, containsPair('committed', 1));
        expect(outcomes.last, containsPair('duplicate_observation', 1));
        final event = (await committed()).single;
        expect(event.source.tenant, 'default');
        expect(event.source.namespace, 'team-a');
        final alerts = await session.db.unsafeQuery(
          'SELECT fingerprint FROM alerts',
        );
        expect(alerts.single[0], event.fingerprint);
      }, timeout: const Timeout(Duration(minutes: 5)));
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
