import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/event/cloud_event.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingress.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' show sourceId, token;

const _other = '22222222-2222-4222-8222-222222222222';
const _namespace = 'same-alerts';
final _now = DateTime.utc(2026, 11, 18, 12);

final class _Routes implements RouteHost {
  _Routes(this.web);
  final WebServer web;
  @override
  void addRoute(Route route, String path) => web.addRoute(route, path);
}

void main() {
  withServerpod(
    'ingress identity and display scenarios',
    (builder, _) {
      Future<void> scenario({
        required bool shared,
        required Future<void> Function(
          Session,
          Future<void> Function(String, String),
        )
        verify,
      }) async {
        final session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute(
          '''TRUNCATE activity,alerts,pipeline_failures,observation_keys,
        outbox,events,raw_inbox,transport_keys,ingest_active_config,ingest_source_credential,
        ingest_source,ingest_config_snapshot,ingest_secret_commitment,secret_record CASCADE''',
        );
        final bootstrap =
            await IngestConfigRepository(
              session,
              secretStore: testSecretStore,
            ).publishConfig(
              {
                'format_version': 2,
                'revision': 1,
                if (shared) 'namespaces': [_namespace],
                'sources': [
                  for (final (id, ref) in [(sourceId, 'one'), (_other, 'two')])
                    {
                      'id': id,
                      'kind': 'alertmanager',
                      'enabled': true,
                      if (shared) 'namespace': _namespace,
                      'credentials': [
                        {'ref': ref, 'type': 'bearer'},
                      ],
                      'output_ids': <Object?>[],
                    },
                ],
                'outputs': <Object?>[],
              },
              {'one': token(1), 'two': token(2)},
              runMode: 'test',
            );
        final web = WebServer(serverpod: session.serverpod);
        final client = HttpClient();
        final ingress = IngressSubsystem(
          pod: session.serverpod,
          bootstrap: () => bootstrap,
          ready: () => true,
          log: (_) {},
          clock: () => _now,
        );
        ingress.mountRoutes(_Routes(web));
        await ingress.start();
        try {
          expect(await web.start(), isTrue);
          final pipeline = PipelineRepository(session, clock: () => _now);
          await verify(session, (id, body) async {
            final request = await client.post(
              '127.0.0.1',
              web.port!,
              '/hooks/alertmanager/$id',
            );
            request.headers.contentType = ContentType.json;
            request.headers.set(
              'authorization',
              'Bearer ${token(id == sourceId ? 1 : 2)}',
            );
            request.write(body);
            final response = await request.close();
            await response.drain<void>();
            expect(response.statusCode, 202);
            expect(await pipeline.pinOne(), isTrue);
            expect(await pipeline.processOne(), isTrue);
          });
        } finally {
          client.close(force: true);
          await ingress.stop();
          await web.stop();
        }
      }

      String wire({required String instance, required String description}) =>
          jsonEncode(
            payload.groupOf([
              payload.alert(
                startsAt: _now.toIso8601String(),
                labels: {'alertname': 'SameName', 'instance': instance},
                annotations: {'description': description},
              ),
            ]),
          );

      test('id_2_same_names_from_two_sources', () async {
        final body = wire(instance: 'same-host', description: 'same-check');
        for (final shared in [false, true]) {
          await scenario(
            shared: shared,
            verify: (session, post) async {
              await post(sourceId, body);
              await post(_other, body);
              final events =
                  (await session.db.unsafeQuery('SELECT payload FROM events'))
                      .map(
                        (row) => CloudEvent.decode(row[0]! as Uint8List).event,
                      )
                      .toList();
              expect(
                events.map((event) => event.source.sourceInstance),
                unorderedEquals([sourceId, _other]),
              );
              expect(
                events.map((event) => event.eventId).toSet(),
                hasLength(2),
              );
              final fingerprints = events
                  .map((event) => event.fingerprint)
                  .toSet();
              expect(fingerprints, hasLength(shared ? 1 : 2));
              expect(
                (await session.db.unsafeQuery(
                  'SELECT fingerprint FROM alerts',
                )).map((row) => row[0]),
                unorderedEquals(fingerprints),
              );
            },
          );
        }
      });

      test('id_3_maximum_length_values_through_http_ingress', () async {
        final instance = 'é' * 128;
        final prefix = '🚨' * 4096;
        final a = wire(instance: instance, description: '${prefix}a');
        final b = wire(instance: instance, description: '${prefix}b');
        await scenario(
          shared: false,
          verify: (session, post) async {
            await post(sourceId, a);
            await post(sourceId, b);
            final rows = await session.db.unsafeQuery(
              'SELECT body,status,outcome_json FROM raw_inbox',
            );
            final bodies = {
              for (final row in rows) utf8.decode(row[0]! as List<int>): row,
            };
            expect(bodies.keys, unorderedEquals([a, b]));
            expect(rows.map((row) => row[1]), everyElement('done'));
            final first =
                jsonDecode(bodies[a]![2]! as String) as Map<String, Object?>;
            final second =
                jsonDecode(bodies[b]![2]! as String) as Map<String, Object?>;
            expect(first['committed'], 1);
            expect(second['committed'], 0);
            expect(second['duplicate_observation'], 1);
            final persisted = await session.db.unsafeQuery(
              'SELECT payload FROM events',
            );
            final event = CloudEvent.decode(
              persisted.single[0]! as Uint8List,
            ).event;
            expect(event.labels['instance'], instance);
            expect(event.description, '${'🚨' * 4095}…');
            expect(event.annotations['description'], '${'🚨' * 1023}…');
            expect(
              (await session.db.unsafeQuery(
                'SELECT fingerprint FROM alerts',
              )).single[0],
              event.fingerprint,
            );
            expect(
              await session.db.unsafeQuery('SELECT 1 FROM pipeline_failures'),
              isEmpty,
            );
          },
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
