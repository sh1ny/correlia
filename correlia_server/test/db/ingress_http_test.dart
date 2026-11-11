import 'dart:async';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingress.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import 'ingest_config_test.dart' as fixture;

final class _Host implements RouteHost {
  _Host(this.web);
  final WebServer web;
  @override
  void addRoute(Route route, String path) => web.addRoute(route, path);
}

final class _Events implements DiagnosticEventHandler {
  final lines = <String>[];
  final sentinel = Completer<void>();
  @override
  void handleEvent(
    DiagnosticEvent event, {
    required OriginSpace space,
    required DiagnosticEventContext context,
  }) {
    lines.add('$event ${event.custom} ${context.toJson()}');
    if (event is ExceptionEvent &&
        event.message == 'test sentinel' &&
        !sentinel.isCompleted) {
      sentinel.complete();
    }
  }
}

IngestBootstrap _input() => IngestBootstrap.parse(
  {
    'format_version': 1,
    'revision': 1,
    'sources': [
      {
        'id': fixture.sourceId,
        'enabled': true,
        'token_ref': 'source-token',
        'path_token_enabled': true,
        'output_ids': [fixture.outputId],
      },
    ],
    'outputs': [
      {
        'id': fixture.outputId,
        'kind': 'webhook',
        'url': 'http://127.0.0.1:9099/events',
        'signing_key_ref': 'key-v1',
      },
    ],
  },
  {'source-token': fixture.token(1), 'key-v1': fixture.token(2)},
  runMode: 'test',
);

Future<int> _send(
  HttpClient client,
  int port,
  String target, {
  String? token,
  List<int> body = const [123, 125],
}) async {
  final request = await client.postUrl(
    Uri.parse('http://127.0.0.1:$port$target'),
  );
  request.headers.contentType = ContentType.json;
  if (token != null) request.headers.set('Authorization', 'Bearer $token');
  request.add(body);
  final response = await request.close();
  await response.drain<void>();
  return response.statusCode;
}

void main() {
  final events = _Events();
  withServerpod(
    'secure HTTP ingress and operational counters',
    (builder, _) {
      test('diagnostics_counters_rekey_and_preauth_saturation', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final bootstrap = _input();
        final repository = IngestConfigRepository(session);
        await repository.publish(bootstrap);
        final pod = session.serverpod;
        final logs = <String>[];
        final ingress = IngressSubsystem(
          pod: pod,
          bootstrap: () => bootstrap,
          ready: () => true,
          log: logs.add,
        );
        ingress.mountRoutes(_Host(pod.webServer));
        await ingress.start();
        final startedHere = !pod.webServer.running;
        if (startedHere) expect(await pod.webServer.start(), isTrue);
        final port = pod.webServer.port!;
        final client = HttpClient();
        final held = <HttpClientRequest>[];
        final path = '/hooks/alertmanager/${fixture.sourceId}';
        final token = fixture.token(1);
        final invalid = fixture.token(3);
        final unlock = Completer<void>();
        Future<void>? lockTransaction;
        try {
          expect(await _send(client, port, '$path/$token'), 202);
          expect(await _send(client, port, '$path/$token'), 202);
          expect(await _send(client, port, '$path/$invalid'), 401);
          expect(
            await _send(
              client,
              port,
              '$path/$token?probe=SYNTHETIC_QUERY_SECRET',
            ),
            400,
          );
          await session.db.unsafeSimpleExecute(
            "ALTER TABLE raw_inbox ADD CONSTRAINT ingress_privacy_failure CHECK (content_type <> 'application/json') NOT VALID",
          );
          try {
            expect(await _send(client, port, '$path/$token', body: [1]), 503);
          } finally {
            await session.db.unsafeSimpleExecute(
              'ALTER TABLE raw_inbox DROP CONSTRAINT ingress_privacy_failure',
            );
          }
          final count = ingress.counters.snapshot()[fixture.sourceId]!;
          expect(count.received, 1);
          expect(count.duplicate, 1);
          expect(count.rejected, 3);
          pod.experimental.submitDiagnosticEvent(
            ExceptionEvent(
              StateError('sentinel'),
              StackTrace.empty,
              message: 'test sentinel',
            ),
            session: session,
          );
          await events.sentinel.future.timeout(const Duration(seconds: 5));
          final metadata = await session.db.unsafeQuery(
            'SELECT row_to_json(s)::text FROM serverpod_session_log s',
          );
          final diagnosticText = events.lines.join();
          final all =
              '${logs.join()} ${metadata.map((r) => r[0]).join()} $diagnosticText';
          for (final secret in [token, invalid, 'SYNTHETIC_QUERY_SECRET']) {
            expect(all, isNot(contains(secret)));
          }
          expect(logs.join(), contains(fixture.sourceId));
          expect(logs.join(), contains('outcome='));

          final locked = Completer<void>();
          final lockSession = builder.build();
          lockTransaction = lockSession.db.transaction((tx) async {
            await lockSession.db.unsafeSimpleExecute(
              'LOCK TABLE ingest_source IN ACCESS EXCLUSIVE MODE',
              transaction: tx,
            );
            locked.complete();
            await unlock.future;
          });
          await locked.future.timeout(const Duration(seconds: 5));
          for (var i = 0; i < 16; i++) {
            final request = await client.postUrl(
              Uri.parse('http://127.0.0.1:$port$path'),
            );
            request.headers.contentType = ContentType.json;
            request.headers.set('Authorization', 'Bearer $token');
            request.bufferOutput = false;
            request.add([123]);
            await request.flush();
            held.add(request);
          }
          final saturated = await client.postUrl(
            Uri.parse('http://127.0.0.1:$port$path'),
          );
          saturated.headers.set('Authorization', 'Bearer $token');
          final rejection = await saturated.close();
          expect(rejection.statusCode, 503);
          expect(ingress.inFlight, 16);
          expect(rejection.headers.value('retry-after'), '1');
          await rejection.drain<void>();
          expect((await session.db.unsafeQuery('SELECT 1')).single[0], 1);
          unlock.complete();
          await lockTransaction;
          for (final request in held) {
            request.add([125]);
          }
          final responses = await Future.wait(
            held.map((request) => request.close()),
          );
          for (final response in responses) {
            await response.drain<void>();
          }
          held.clear();
          expect(
            responses.map((response) => response.statusCode),
            everyElement(202),
          );

          await repository.publish(fixture.input(2, includeSource: false));
          expect(await _send(client, port, path, token: token), 401);
          expect(
            ingress.counters.snapshot().keys,
            isNot(contains(fixture.sourceId)),
          );
          expect(ingress.counters.snapshot()[null]!.rejected, greaterThan(0));
          expect(ingress.counters.snapshot().length, lessThanOrEqualTo(65));
        } finally {
          if (!unlock.isCompleted) unlock.complete();
          if (lockTransaction != null) await lockTransaction;
          client.close(force: true);
          await ingress.stop();
          if (startedHere) await pod.webServer.stop();
        }
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
    enableSessionLogging: true,
    experimentalFeatures: ExperimentalFeatures(
      diagnosticEventHandlers: [events],
    ),
  );
}
