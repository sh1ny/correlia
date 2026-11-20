import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingress.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' show token;

const _alertmanagerId = '11111111-1111-4111-8111-111111111111';
const _icinga2Id = '33333333-3333-4333-8333-333333333333';
final _now = DateTime.utc(2026, 11, 18);

final class _Routes implements RouteHost {
  _Routes(this.web);
  final WebServer web;
  @override
  void addRoute(Route route, String path) => web.addRoute(route, path);
}

Map<String, Object?> _source(String id, String kind, int key) => {
  'id': id,
  'kind': kind,
  'enabled': true,
  'credentials': [
    {'ref': 'test-key-$key', 'type': 'bearer'},
  ],
  'output_ids': <Object?>[],
};

void main() {
  withServerpod(
    'Icinga2 ingress route',
    (builder, _) {
      late Session session;
      late IngressSubsystem ingress;
      late HttpClient client;
      late WebServer web;

      Future<IngestBootstrap> publish({required bool both}) =>
          IngestConfigRepository(
            session,
            secretStore: testSecretStore,
          ).publishConfig(
            {
              'format_version': 2,
              'revision': 1,
              'outputs': <Object?>[],
              'sources': [
                if (both) _source(_alertmanagerId, 'alertmanager', 1),
                _source(_icinga2Id, 'icinga2', 2),
              ],
            },
            <String, Object?>{
              for (var i = 1; i <= 2; i++) 'test-key-$i': token(i),
            },
            runMode: 'test',
            clock: () => _now,
          );

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute(
          '''TRUNCATE raw_inbox,transport_keys,
        ingest_active_config,ingest_source_credential,ingest_source,
        ingest_config_snapshot,ingest_secret_commitment,secret_record CASCADE''',
        );
        client = HttpClient();
      });

      Future<void> start(IngestBootstrap input) async {
        web = WebServer(serverpod: session.serverpod);
        ingress = IngressSubsystem(
          pod: session.serverpod,
          bootstrap: () => input,
          ready: () => true,
          log: (_) {},
          clock: () => _now,
        );
        ingress.mountRoutes(_Routes(web));
        await ingress.start();
        expect(await web.start(), isTrue);
        addTearDown(() async {
          client.close(force: true);
          await ingress.stop();
          await web.stop();
        });
      }

      Future<int> post(String path, {int? bearer}) async {
        final request = await client.post('127.0.0.1', web.port!, path);
        request.headers.contentType = ContentType.json;
        if (bearer != null) {
          request.headers.set('authorization', 'Bearer ${token(bearer)}');
        }
        request.write('{}');
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      Future<int> rawCount() async =>
          (await session.db.unsafeQuery(
                'SELECT count(*) FROM raw_inbox',
              )).single[0]!
              as int;

      test('supported_kinds', () async {
        await start(await publish(both: true));
        expect(
          await post('/hooks/alertmanager/$_alertmanagerId', bearer: 1),
          202,
        );
        expect(await post('/hooks/icinga2/$_icinga2Id', bearer: 2), 202);
        expect(await rawCount(), 2);
        // Each source answers only under its own kind's route.
        expect(await post('/hooks/icinga2/$_alertmanagerId', bearer: 1), 401);
        expect(await post('/hooks/alertmanager/$_icinga2Id', bearer: 2), 401);
        expect(await rawCount(), 2);
      });

      test('path_token_request_on_the_icinga2_route', () async {
        await start(await publish(both: false));
        expect(await post('/hooks/icinga2/$_icinga2Id/${token(2)}'), 401);
        expect(await rawCount(), 0);
        // The header form of the same credential is admitted.
        expect(await post('/hooks/icinga2/$_icinga2Id', bearer: 2), 202);
        expect(await rawCount(), 1);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
