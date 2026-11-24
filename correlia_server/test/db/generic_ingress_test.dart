@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/hmac_signing.dart';
import 'package:correlia_server/src/ingest/ingress.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_webhook_fixture.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' show token;

const _source = '11111111-1111-4111-8111-111111111111';
const _path = '/hooks/generic/$_source';
const _rejectedBody = '{ "host": 42 }\n';
final _now = DateTime.utc(2026, 11, 24);

final class _Routes implements RouteHost {
  _Routes(this.web);
  final WebServer web;

  @override
  void addRoute(Route route, String path) => web.addRoute(route, path);
}

void main() {
  withServerpod(
    'Generic webhook admission',
    (builder, _) {
      late Session session;
      late WebServer web;
      late HttpClient client;
      late Uint8List signingKey;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute('''
          TRUNCATE pipeline_failures,raw_inbox,transport_keys,ingest_active_config,
          ingest_source_credential,ingest_source,ingest_config_snapshot,
          ingest_secret_commitment,secret_record CASCADE''');
        signingKey = Uint8List.fromList(List<int>.filled(32, 2));
        final input =
            await IngestConfigRepository(
              session,
              secretStore: testSecretStore,
            ).publishConfig(
              {
                'format_version': 2,
                'revision': 1,
                'mappings': [checkMapping()],
                'sources': [
                  {
                    ...genericSource(_source, 'webhook-bearer'),
                    'body_limit_bytes': 128,
                    'rate_limit': {'per_second': 1, 'burst': 4},
                    'credentials': [
                      {'type': 'bearer', 'ref': 'webhook-bearer'},
                      {'type': 'hmac', 'ref': 'webhook-hmac'},
                    ],
                  },
                ],
                'outputs': <Object?>[],
              },
              {'webhook-bearer': token(1), 'webhook-hmac': token(2)},
              runMode: 'test',
              clock: () => _now,
            );
        web = WebServer(serverpod: session.serverpod);
        client = HttpClient();
        final ingress = IngressSubsystem(
          pod: session.serverpod,
          bootstrap: () => input,
          ready: () => true,
          log: (_) {},
          clock: () => _now,
          secretResolver: testSecretResolver(session).resolve,
        );
        addTearDown(() async {
          client.close(force: true);
          await ingress.stop();
          await web.stop();
        });
        ingress.mountRoutes(_Routes(web));
        await ingress.start();
        expect(await web.start(), isTrue);
      });

      Future<int> post({
        String path = _path,
        String body = _rejectedBody,
        int? bearer = 1,
        bool hmac = false,
        String? delivery,
        ContentType? contentType,
      }) async {
        final request = await client.post('127.0.0.1', web.port!, path);
        final bytes = utf8.encode(body);
        request.headers.contentType = contentType ?? ContentType.json;
        if (delivery != null) request.headers.set('idempotency-key', delivery);
        if (hmac) {
          final timestamp = '${_now.millisecondsSinceEpoch ~/ 1000}';
          final signature = signIngress(
            signingKey,
            ingressSigningPrefix(timestamp, delivery),
            bytes,
          );
          request.headers.set('x-correlia-timestamp', timestamp);
          request.headers.set('x-correlia-signature', 'sha256=$signature');
        } else if (bearer != null) {
          request.headers.set('authorization', 'Bearer ${token(bearer)}');
        }
        request.add(bytes);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      Future<List<List<Object?>>> rawRows() async => [
        for (final row in await session.db.unsafeQuery(
          'SELECT source_id::text,status,config_snapshot_id,body FROM raw_inbox',
        ))
          row.toList(),
      ];

      test('generic_source_with_a_known_mapping', () async {
        expect(await post(hmac: true, delivery: 'signed'), 202);
        expect((await rawRows()).single.take(3), [_source, 'pending', null]);
        final pipeline = PipelineRepository(session, clock: () => _now);
        expect(await pipeline.pinOne(), isTrue);
        expect((await rawRows()).single[2], isA<String>());
      });

      test('wrong_credential_on_the_generic_route', () async {
        expect(await post(bearer: 3), 401);
        expect(await rawRows(), isEmpty);
      });

      test('path_token_request_on_the_generic_route', () async {
        expect(await post(path: '$_path/${token(1)}', bearer: null), 401);
        expect(await rawRows(), isEmpty);
      });

      test('wrong_content_type_on_the_generic_route', () async {
        expect(
          await post(
            contentType: ContentType('application', 'x-www-form-urlencoded'),
          ),
          415,
        );
        expect(await rawRows(), isEmpty);
      });

      test('mapping_rejected_bytes_are_admitted_unparsed', () async {
        expect(await post(), 202);
        final row = (await rawRows()).single;
        expect(row.take(3), [_source, 'pending', null]);
        expect(row[3], utf8.encode(_rejectedBody));
      });

      test('generic_admission_keeps_body_rate_and_transport_limits', () async {
        expect(await post(body: ' ' * 129), 413);
        expect(await rawRows(), isEmpty);
        expect(await post(delivery: 'same-delivery'), 202);
        expect(await post(delivery: 'same-delivery'), 202);
        expect(await post(delivery: 'same-delivery', body: '{}'), 409);
        expect(await post(delivery: 'new-delivery'), 429);
        expect(await rawRows(), hasLength(1));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
