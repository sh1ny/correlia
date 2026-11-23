import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/admission.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/event/identity.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingress.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart';
import '../support/icinga2_pipeline.dart' show timeText;
import '../support/ingest_schema.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' show token;

const _alertmanagerId = '11111111-1111-4111-8111-111111111111';
const _icinga2Id = '33333333-3333-4333-8333-333333333333';
final _now = DateTime.utc(2026, 11, 18);
const _streamId = '44444444-4444-4444-8444-444444444444';

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

      Future<IngestBootstrap> publish({
        required bool both,
        bool stream = false,
      }) =>
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
                if (stream) streamSource(_streamId),
              ],
            },
            <String, Object?>{
              for (var i = 1; i <= 2; i++) 'test-key-$i': token(i),
              if (stream) ...streamMaterial(),
            },
            runMode: 'test',
            clock: () => _now,
          );

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute(
          '''TRUNCATE activity,alerts,pipeline_failures,observation_keys,outbox,
        events,raw_inbox,transport_keys,
        ingest_active_config,ingest_source_credential,ingest_source,
        ingest_config_snapshot,ingest_secret_commitment,secret_record,icinga2_raw_origin CASCADE;
        UPDATE raw_admission_cutoff SET cutoff='-infinity', cursor_seconds=0, cursor_nanos=0, cursor_id=0''',
        );
        client = HttpClient();
      });

      Future<void> start(
        IngestBootstrap input, {
        Future<void> Function()? beforeBody,
        DateTime Function()? clock,
      }) async {
        web = WebServer(serverpod: session.serverpod);
        ingress = IngressSubsystem(
          pod: session.serverpod,
          bootstrap: () => input,
          ready: () => true,
          log: (_) {},
          clock: clock ?? () => _now,
          beforeBody: beforeBody,
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

      Future<int> post(
        String path, {
        int? bearer,
        String text = '{}',
        String? key,
      }) async {
        final request = await client.post('127.0.0.1', web.port!, path);
        request.headers.contentType = ContentType.json;
        if (key != null) request.headers.set('idempotency-key', key);
        if (bearer != null) {
          request.headers.set('authorization', 'Bearer ${token(bearer)}');
        }
        request.write(text);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      Future<int> rawCount() async =>
          (await session.db.unsafeQuery(
                'SELECT count(*) FROM raw_inbox',
              )).single[0]!
              as int;

      Future<void> setCutoff(DateTime value) => session.db.unsafeExecute(
        'UPDATE raw_admission_cutoff SET cutoff=@time WHERE singleton=1',
        parameters: QueryParameters.named({'time': value}),
      );

      test('webhook_behind_cutoff_can_retry', () async {
        final input = await publish(both: false);
        final reading = Completer<void>();
        final release = Completer<void>();
        var clock = _now;
        await start(
          input,
          clock: () => clock,
          beforeBody: () {
            if (!reading.isCompleted) reading.complete();
            return release.future;
          },
        );
        final request = post(
          '/hooks/icinga2/$_icinga2Id',
          bearer: 2,
          key: 'cutoff-retry',
        );
        try {
          await reading.future;
          clock = _now.add(const Duration(seconds: 1));
          await setCutoff(clock);
        } finally {
          release.complete();
        }
        expect(await request, 503);
        expect(await rawCount(), 0);
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM transport_keys',
          )).single[0],
          0,
        );
        // A receipt exactly at the cutoff is a valid new admission.
        expect(
          await post(
            '/hooks/icinga2/$_icinga2Id',
            bearer: 2,
            key: 'cutoff-retry',
          ),
          202,
        );
        expect(await rawCount(), 1);
      });

      test('cutoff_keeps_webhook_dedup_window', () async {
        final input = await publish(both: false);
        await start(input);
        const path = '/hooks/icinga2/$_icinga2Id';
        const key = 'cutoff-window';
        expect(await post(path, bearer: 2, key: key), 202);
        await setCutoff(_now.add(const Duration(seconds: 1)));
        expect(await post(path, bearer: 2, key: key), 202);
        expect(
          await post(path, bearer: 2, key: key, text: '{"different":true}'),
          409,
        );
        await session.db.unsafeExecute(
          'UPDATE transport_keys SET "expiresAt"=@now',
          parameters: QueryParameters.named({'now': _now}),
        );
        expect(await post(path, bearer: 2, key: key), 503);
        expect(await rawCount(), 1);
      });

      test('delivery_to_a_stream_source', () async {
        final input = await publish(both: false);
        // Exercise both mode fences even if stale credential state exists.
        await session.db.unsafeSimpleExecute(
          "UPDATE ingest_source SET mode='event_streams' WHERE kind='icinga2'",
        );
        var bodyReads = 0;
        await start(
          input,
          beforeBody: () async {
            bodyReads++;
          },
        );
        Future<(int, String)> rejected(String id) async {
          final request = await client.post(
            '127.0.0.1',
            web.port!,
            '/hooks/icinga2/$id',
          );
          request.headers.contentType = ContentType.json;
          request.headers.set('authorization', 'Bearer ${token(2)}');
          request.write('{}');
          final response = await request.close();
          return (response.statusCode, await utf8.decodeStream(response));
        }

        final absent = await rejected(_alertmanagerId);
        expect(absent.$1, 401);
        expect(await rejected(_icinga2Id), absent);
        expect(bodyReads, 0);
        final direct = await IngestAdmission(session).admit(
          sourceId: _icinga2Id,
          kind: 'icinga2',
          credential: input.sources.single.credentials.single,
          pathToken: false,
          body: utf8.encode('{}'),
          contentType: 'application/json',
          observedAt: _now,
        );
        expect(direct, AdmissionOutcome.unauthorized);
        expect(await rawCount(), 0);
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM transport_keys',
          )).single[0],
          0,
        );
      });

      test('webhook_source_unaffected', () async {
        final input = await publish(both: false, stream: true);
        await start(input);
        expect(await post('/hooks/icinga2/$_icinga2Id', bearer: 2), 202);
        expect(await rawCount(), 1);
      });

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

      test('id_3_maximum_length_host_and_long_check_output', () async {
        await start(await publish(both: false));
        final host = 'h' * 256;
        final output = 'o' * 4097;
        final changed = _now.subtract(const Duration(minutes: 1));
        final status = await post(
          '/hooks/icinga2/$_icinga2Id',
          bearer: 2,
          text: jsonEncode(
            delivery(
              set: {
                'host': host,
                'output': output,
                'last_state_change': timeText(changed),
                'notification_time': timeText(_now),
              },
            ),
          ),
        );
        expect(status, 202);
        final repo = PipelineRepository(session, clock: () => _now);
        expect(await repo.pinOne(), isTrue);
        expect(await repo.processOne(), isTrue);
        expect(
          (await session.db.unsafeQuery(
            'SELECT status FROM raw_inbox',
          )).single[0],
          'done',
        );
        final event =
            jsonDecode(
                  utf8.decode(
                    (await session.db.unsafeQuery(
                          'SELECT payload FROM events',
                        )).single[0]!
                        as List<int>,
                  ),
                )
                as Map<String, Object?>;
        final data = event['data']! as Map<String, Object?>;
        final summary = data['summary']! as String;
        final description = data['description']! as String;
        expect(summary.runes, hasLength(256));
        expect(summary, endsWith('…'));
        expect(description.runes, hasLength(4096));
        expect(description, '${'o' * 4095}…');
        // Identity uses the complete host name.
        final source = SourceContext(
          sourceInstance: _icinga2Id,
          sourceKind: 'icinga2',
        );
        expect(
          event['subject'],
          alertFingerprint(
            source,
            identityComponents({'host': host, 'service': 'disk'}),
          ),
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
