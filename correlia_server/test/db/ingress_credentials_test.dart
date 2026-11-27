import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingress.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' show sourceId, token;

const _observed = 1794960000;
final _now = DateTime.fromMillisecondsSinceEpoch(_observed * 1000, isUtc: true);
const _path = '/hooks/alertmanager/$sourceId';

final class _Routes implements RouteHost {
  _Routes(this.web);
  final WebServer web;
  @override
  void addRoute(Route route, String path) => web.addRoute(route, path);
}

Map<String, Object?> _credential(
  int number, {
  String type = 'bearer',
  DateTime? from,
  DateTime? to,
}) => {
  'ref': 'test-key-$number',
  'type': type,
  'not_before': ?from?.toIso8601String(),
  'not_after': ?to?.toIso8601String(),
};

String _sign(String body, {int timestamp = _observed, String? idempotency}) {
  final part = idempotency == null
      ? '-'
      : sha256.convert(utf8.encode(idempotency)).toString();
  final key = List<int>.filled(32, 3);
  return 'sha256=${Hmac(sha256, key).convert(utf8.encode('$timestamp.$part.$body'))}';
}

void main() {
  withServerpod(
    'HTTP source credentials',
    (builder, _) {
      late Session session;
      late IngestConfigRepository config;
      late IngressSubsystem ingress;
      late HttpClient client;
      late List<String> logs;
      var beforeBody = Completer<void>();
      var resume = Completer<void>();

      Future<IngestBootstrap> publish(
        int revision,
        List<Map<String, Object?>> credentials, {
        int burst = 40,
        bool enabled = true,
        bool pathTokens = false,
        bool secondHmacSource = false,
      }) => config.publishConfig(
        {
          'format_version': 2,
          'revision': revision,
          'outputs': <Object?>[],
          'sources': [
            {
              'id': sourceId,
              'kind': 'alertmanager',
              'enabled': enabled,
              'credentials': credentials,
              'output_ids': <Object?>[],
              'path_token_enabled': pathTokens,
              'rate_limit': {'per_second': 1, 'burst': burst},
            },
            if (secondHmacSource)
              {
                'id': '33333333-3333-4333-8333-333333333333',
                'kind': 'alertmanager',
                'enabled': true,
                'credentials': [_credential(3, type: 'hmac')],
                'output_ids': <Object?>[],
              },
          ],
        },
        <String, Object?>{for (var i = 1; i <= 4; i++) 'test-key-$i': token(i)},
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
        config = IngestConfigRepository(session, secretStore: testSecretStore);
        client = HttpClient();
        logs = [];
        beforeBody = Completer<void>();
        resume = Completer<void>();
      });

      late WebServer web;

      Future<void> start(
        IngestBootstrap input, {
        bool slow = false,
        Future<void> Function()? bodyGate,
      }) async {
        web = WebServer(serverpod: session.serverpod);
        ingress = IngressSubsystem(
          pod: session.serverpod,
          bootstrap: () => input,
          ready: () => true,
          log: logs.add,
          clock: () => _now,
          secretResolver: testSecretResolver(session).resolve,
          beforeBody:
              bodyGate ??
              (slow
                  ? () async {
                      beforeBody.complete();
                      await resume.future;
                    }
                  : null),
        );
        ingress.mountRoutes(_Routes(web));
        await ingress.start();
        expect(await web.start(), isTrue);
        addTearDown(() async {
          if (!resume.isCompleted) resume.complete();
          client.close(force: true);
          await ingress.stop();
          await web.stop();
        });
      }

      Future<(int, String?)> send({
        String path = _path,
        int? bearer,
        String body = '{}',
        String? signature,
        int timestamp = _observed,
        String? idempotency,
        bool duplicate = false,
      }) async {
        final request = await client.post('127.0.0.1', web.port!, path);
        request.headers.contentType = ContentType.json;
        if (bearer != null) {
          request.headers.set('authorization', 'Bearer ${token(bearer)}');
        }
        if (idempotency != null) {
          request.headers.set('idempotency-key', idempotency);
        }
        if (signature != null) {
          request.headers.set('x-correlia-timestamp', '$timestamp');
          request.headers.set('x-correlia-signature', signature);
          if (duplicate) request.headers.add('x-correlia-signature', signature);
        }
        request.write(body);
        final response = await request.close();
        await response.drain<void>();
        return (response.statusCode, response.headers.value('retry-after'));
      }

      Future<int> rawCount() async =>
          (await session.db.unsafeQuery(
                'SELECT count(*) FROM raw_inbox',
              )).single[0]!
              as int;

      Future<void> drainFixtureInbox() => session.db.unsafeExecute(
        "UPDATE raw_inbox SET status='done' WHERE status='pending'",
      );

      test('stream_source_holds_no_credentials', () async {
        final input = await config.publishConfig(
          streamBootstrap(1, [streamSource(sourceId)]),
          streamMaterial(),
          runMode: 'test',
        );
        expect(input.sources.single.credentials, isEmpty);
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM ingest_source_credential',
          )).single[0],
          0,
        );
        await start(input);
        expect(
          (await send(path: '/hooks/icinga2/$sourceId', bearer: 1)).$1,
          401,
        );
        expect(await rawCount(), 0);
      });

      test('route_kind_mismatch', () async {
        await start(await publish(1, [_credential(1)]));
        expect(
          (await send(path: '/hooks/icinga2/$sourceId', bearer: 1)).$1,
          401,
        );
        expect(
          (await send(
            path: '/hooks/icinga2/22222222-2222-4222-8222-222222222222',
            bearer: 1,
          )).$1,
          401,
        );
        expect(await rawCount(), 0);
      });

      test('overlapping_rotation', () async {
        await start(await publish(1, [_credential(1)]));
        await publish(2, [_credential(1), _credential(2)]);
        expect((await send(bearer: 1, body: '{"rev":1}')).$1, 202);
        // Keep previous fixtures without letting their synthetic age throttle
        // this test of the credential overlap.
        await drainFixtureInbox();
        expect((await send(bearer: 2, body: '{"rev":2}')).$1, 202);
        await drainFixtureInbox();
        await publish(3, [_credential(2)]);
        expect((await send(bearer: 1)).$1, 401);
        expect((await send(bearer: 2)).$1, 202);
        expect(await rawCount(), 3);
      });

      test('expired_and_not_yet_valid_credentials', () async {
        await start(
          await publish(1, [
            _credential(1, to: _now),
            _credential(2, from: _now.add(const Duration(seconds: 1))),
            _credential(4, from: _now),
          ]),
        );
        expect((await send(bearer: 1)).$1, 401);
        expect((await send(bearer: 2)).$1, 401);
        expect((await send(bearer: 4)).$1, 202);
        expect(await rawCount(), 1);
        expect(ingress.counters.snapshot()[sourceId]?.rejected, 2);
      });

      test('rotation_during_a_body_read', () async {
        await start(
          await publish(1, [_credential(1), _credential(2)]),
          slow: true,
        );
        final request = await client.post('127.0.0.1', web.port!, _path);
        request.bufferOutput = false;
        request.headers.contentType = ContentType.json;
        request.headers.set('authorization', 'Bearer ${token(1)}');
        request.write('{');
        await request.flush();
        await beforeBody.future.timeout(const Duration(seconds: 5));
        await publish(2, [_credential(2)]);
        request.write('}');
        resume.complete();
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 401);
        expect(await rawCount(), 0);
        expect(
          await session.db.unsafeQuery('SELECT 1 FROM transport_keys'),
          isEmpty,
        );
      });

      test('valid_signature_admitted', () async {
        const body = '{"hello":true}';
        final signature = _sign(body);
        await start(await publish(1, [_credential(3, type: 'hmac')]));
        expect((await send(body: body, signature: signature)).$1, 202);
        final raw =
            (await session.db.unsafeQuery(
                  'SELECT row_to_json(r)::text FROM raw_inbox r',
                )).single[0]!
                as String;
        expect(raw, isNot(contains(signature)));
        expect(raw, isNot(contains('x-correlia-timestamp')));
        expect(raw, isNot(contains('x-correlia-signature')));
      });

      test('bad_stale_or_misplaced_signature', () async {
        final signature = _sign('{}');
        await start(await publish(1, [_credential(3, type: 'hmac')]));
        expect((await send(signature: 'sha256=${'0' * 64}')).$1, 401);
        expect((await send(signature: signature, body: '[]')).$1, 401);
        expect(
          (await send(
            signature: _sign('{}', timestamp: _observed - 301),
            timestamp: _observed - 301,
          )).$1,
          401,
        );
        expect((await send(signature: signature, duplicate: true)).$1, 401);
        expect((await send(bearer: 3)).$1, 401);
        expect(await rawCount(), 0);
        expect(logs, isNot(isEmpty));
        expect(
          logs.join(),
          allOf(isNot(contains(signature)), isNot(contains(token(3)))),
        );
      });

      test('signed_replay_with_a_new_idempotency_key', () async {
        final signature = _sign('1.23', idempotency: 'k');
        await start(await publish(1, [_credential(3, type: 'hmac')]));
        expect(
          (await send(body: '1.23', signature: signature, idempotency: 'k')).$1,
          202,
        );
        expect(
          (await send(body: '1.23', signature: signature, idempotency: 'k')).$1,
          202,
        );
        expect(
          (await send(
            body: '1.23',
            signature: signature,
            idempotency: 'other',
          )).$1,
          401,
        );
        expect(
          (await send(body: '23', signature: signature, idempotency: 'k.1')).$1,
          401,
        );
        expect(await rawCount(), 1);
      });

      test('budget_exceeded', () async {
        await start(await publish(1, [_credential(1)], burst: 1));
        expect((await send(bearer: 1)).$1, 202);
        expect(await send(bearer: 1, body: '[]'), (429, '1'));
        expect(await rawCount(), 1);
        expect(ingress.counters.snapshot()[sourceId]?.rejected, 1);
      });

      test(
        'hmac_slots_isolate_sources_and_preserve_bearer_admission',
        () async {
          final full = Completer<void>();
          var readers = 0;
          await start(
            await publish(1, [
              _credential(1),
              _credential(3, type: 'hmac'),
            ], secondHmacSource: true),
            bodyGate: () async {
              if (++readers == 2) full.complete();
              if (readers <= 2) await resume.future;
            },
          );
          final invalid = 'sha256=${'0' * 64}';
          final held = Future.wait(
            List.generate(2, (_) => send(signature: invalid)),
          );
          try {
            await full.future.timeout(const Duration(seconds: 5));
            final locked = Completer<void>();
            final unlock = Completer<void>();
            final lockSession = builder.build();
            final lock = lockSession.db.transaction((tx) async {
              await lockSession.db.unsafeSimpleExecute(
                'LOCK TABLE ingest_source IN ACCESS EXCLUSIVE MODE',
                transaction: tx,
              );
              locked.complete();
              await unlock.future;
            });
            try {
              await locked.future.timeout(const Duration(seconds: 5));
              final overflowWhileLocked = send(signature: invalid);
              expect(
                await overflowWhileLocked.timeout(const Duration(seconds: 2)),
                (503, '1'),
              );
            } finally {
              unlock.complete();
              await lock;
            }
            expect(
              (await send(
                path:
                    '/hooks/alertmanager/33333333-3333-4333-8333-333333333333',
                signature: _sign('{}'),
              )).$1,
              202,
            );
            await drainFixtureInbox();
            expect((await send(bearer: 1)).$1, 202);
            await drainFixtureInbox();
          } finally {
            resume.complete();
            expect((await held).map((result) => result.$1), everyElement(401));
          }
          expect((await send(signature: _sign('[]'), body: '[]')).$1, 202);
          expect(await rawCount(), 3);
        },
      );

      test('unauthenticated_traffic_spends_no_budget', () async {
        await start(await publish(1, [_credential(1)], burst: 1));
        for (var i = 0; i < 3; i++) {
          expect((await send(bearer: 2)).$1, 401);
        }
        expect((await send(bearer: 1)).$1, 202);
        expect(await rawCount(), 1);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
