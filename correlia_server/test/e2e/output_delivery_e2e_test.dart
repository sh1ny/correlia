@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/output/webhook_output.dart';
import 'package:correlia_server/src/output/output_relay.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../support/output_process.dart';

void main() {
  test(
    'receiver_verifies_signed_event',
    () => withOutputProcess((database, env, receiver, children) async {
      final received = Completer<(List<int>, String?, String?, String?)>();
      receiver.listen((request) async {
        final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        received.complete((
          bytes,
          request.headers.value('content-type'),
          request.headers.value('idempotency-key'),
          request.headers.value('x-correlia-signature'),
        ));
        request.response.statusCode = 204;
        await request.response.close();
      });
      final child = await startOutputChild(database, env, children);
      final observer = await outputConnection(database);
      try {
        await observer.execute(
          '''CREATE FUNCTION test_signed_notify() RETURNS trigger LANGUAGE plpgsql AS \$\$
        BEGIN PERFORM pg_notify('test_signed', NEW.status); RETURN NEW; END \$\$''',
        );
        await observer.execute(
          'CREATE TRIGGER test_signed_notify AFTER INSERT OR UPDATE ON outbox FOR EACH ROW EXECUTE FUNCTION test_signed_notify()',
        );
        await observer.execute('LISTEN test_signed');
        final events = StreamIterator(
          observer.channels.all.where(
            (event) => event.channel == 'test_signed',
          ),
        );
        try {
          var next = events.moveNext();
          await postOutputAlert(child);
          final (body, contentType, id, signature) = await received.future
              .timeout(const Duration(seconds: 30));
          final envelope = CloudEvent.decode(Uint8List.fromList(body));
          expect(envelope.event.eventId, id);
          expect(contentType, 'application/cloudevents+json');
          expect(
            signature,
            'sha256=${Hmac(sha256, List<int>.filled(32, 2)).convert(body)}',
          );
          var done = false;
          while (!done && await next.timeout(const Duration(seconds: 30))) {
            next = events.moveNext();
            final rows = await observer.execute(
              'SELECT status,payload,event_id::text FROM outbox',
            );
            if (rows.isNotEmpty && rows.single[0] == 'delivered') {
              expect(rows.single[1], body);
              expect(rows.single[2], id);
              done = true;
            }
          }
          expect(done, isTrue);
        } finally {
          await events.cancel();
        }
      } finally {
        await observer.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test('redirect_timeout_and_rejection', () async {
    final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var called = 0;
    receiver.listen((request) async {
      called++;
      request.response.statusCode = switch (request.uri.path) {
        '/redirect' => 302,
        '/retry' => 429,
        '/timeout-status' => 408,
        '/server-error' => 503,
        _ => 400,
      };
      request.response.headers.set('location', '/target');
      request.response.write('secret response body');
      await request.response.close();
    });
    final webhook = WebhookOutput(runMode: 'test');
    final key = Uint8List.fromList(List.filled(32, 3));
    Future<DeliveryOutcome> send(String path) => webhook.send(
      DeliveryIntent(
        eventId: 'event',
        targetUrl: 'http://127.0.0.1:${receiver.port}/$path',
        payload: Uint8List.fromList([123, 125]),
      ),
      key,
    );
    try {
      expect(await send('redirect'), isA<DeliveryPermanent>());
      expect(await send('retry'), isA<DeliveryRetryable>());
      expect(await send('timeout-status'), isA<DeliveryRetryable>());
      expect(await send('server-error'), isA<DeliveryRetryable>());
      expect(await send('reject'), isA<DeliveryPermanent>());
      expect(called, 5);
    } finally {
      webhook.close();
      await receiver.close(force: true);
    }
    await withOutputProcess((database, env, receiver, children) async {
      var requests = 0;
      receiver.listen((request) async {
        requests++;
        await request.drain<void>();
        request.response.statusCode = 302;
        request.response.headers.set('location', '/redirect-target');
        request.response.write('SYNTHETIC_RESPONSE_SECRET');
        await request.response.close();
      });
      final child = await startOutputChild(database, env, children);
      final observer = await outputConnection(database);
      try {
        await observer.execute(
          '''CREATE FUNCTION test_rejection_notify() RETURNS trigger LANGUAGE plpgsql AS \$\$
          BEGIN IF NEW.status='dead' THEN PERFORM pg_notify('test_rejection', 'dead'); END IF; RETURN NEW; END \$\$''',
        );
        await observer.execute(
          'CREATE TRIGGER test_rejection_notify AFTER UPDATE ON outbox FOR EACH ROW EXECUTE FUNCTION test_rejection_notify()',
        );
        await observer.execute('LISTEN test_rejection');
        final dead = observer.channels.all.firstWhere(
          (event) => event.channel == 'test_rejection',
        );
        await postOutputAlert(child);
        await dead.timeout(const Duration(seconds: 30));
        final row = (await observer.execute(
          'SELECT status,dead_reason FROM outbox',
        )).single;
        expect(row[0], 'dead');
        expect(row[1], 'http_permanent');
        final attempts = await observer.execute(
          'SELECT outcome,"errorClass" FROM delivery_attempts',
        );
        expect(attempts.single[0], 'permanent');
        expect(attempts.single[1], 'http_permanent');
        expect(requests, 1);
        expect(child.output, isNot(contains('SYNTHETIC_RESPONSE_SECRET')));
        expect(child.output, isNot(contains(outputKey)));
      } finally {
        await observer.close();
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
  test('bounded_response_and_total_deadline', () async {
    final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final entered = Completer<void>();
    final release = Completer<void>();
    receiver.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == '/slow') {
        entered.complete();
        await release.future;
      } else {
        request.response.add(List<int>.filled(65537, 120));
      }
      try {
        await request.response.close();
      } on SocketException {
        // The client deliberately closes oversized and timed-out responses.
      }
    });
    final webhook = WebhookOutput(
      runMode: 'test',
      deadline: const Duration(milliseconds: 100),
    );
    final key = Uint8List.fromList(List.filled(32, 3));
    Future<DeliveryOutcome> send(String path) => webhook.send(
      DeliveryIntent(
        eventId: 'event',
        targetUrl: 'http://127.0.0.1:${receiver.port}/$path',
        payload: Uint8List.fromList([123, 125]),
      ),
      key,
    );
    try {
      expect(await send('large'), isA<DeliveryAcknowledged>());
      final timed = send('slow');
      await entered.future;
      expect(await timed, isA<DeliveryRetryable>());
    } finally {
      release.complete();
      webhook.close();
      await receiver.close(force: true);
    }
  });
  test(
    'one_output_fails_while_another_succeeds',
    () => withOutputProcess((database, env, receiver, children) async {
      final healthy = Completer<(List<int>, String?, String?)>();
      receiver.listen((request) async {
        final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        if (request.uri.path == '/healthy') {
          healthy.complete((
            bytes,
            request.headers.value('idempotency-key'),
            request.headers.value('x-correlia-signature'),
          ));
          request.response.statusCode = 204;
        } else {
          request.response.statusCode = 503;
        }
        await request.response.close();
      });
      final child = await startOutputChild(
        database,
        env,
        children,
        gated: true,
      );
      final observer = await outputConnection(database);
      try {
        await observer.execute(
          '''CREATE FUNCTION test_delivery_notify() RETURNS trigger LANGUAGE plpgsql AS \$\$
        BEGIN PERFORM pg_notify('test_delivery', NEW.status); RETURN NEW; END \$\$''',
        );
        await observer.execute(
          'CREATE TRIGGER test_delivery_notify AFTER INSERT OR UPDATE ON outbox FOR EACH ROW EXECUTE FUNCTION test_delivery_notify()',
        );
        await observer.execute('LISTEN test_delivery');
        final events = StreamIterator(
          observer.channels.all.where(
            (event) => event.channel == 'test_delivery',
          ),
        );
        try {
          var next = events.moveNext();
          await postOutputAlert(child);
          File(env['TEST_GATE_PATH']!).writeAsStringSync('release');
          final (bytes, id, signature) = await healthy.future.timeout(
            const Duration(seconds: 30),
          );
          expect(
            signature,
            'sha256=${Hmac(sha256, List<int>.filled(32, 2)).convert(bytes)}',
          );
          expect(
            (jsonDecode(utf8.decode(bytes)) as Map<String, Object?>)['id'],
            id,
          );
          var done = false;
          while (!done && await next.timeout(const Duration(seconds: 60))) {
            next = events.moveNext();
            final rows = await observer.execute(
              'SELECT output_id::text,status,attempt_count,dead_reason FROM outbox',
            );
            if (rows.length != 2) continue;
            final good = rows.singleWhere((row) => row[0] == outputId);
            final bad = rows.singleWhere((row) => row[0] == secondOutputId);
            done = good[1] == 'delivered' && bad[1] == 'dead';
            if (done) {
              expect(bad[2], 20);
              expect(bad[3], 'http_retryable');
              break;
            }
            await observer.execute(
              "UPDATE outbox SET next_attempt_at=clock_timestamp() WHERE output_id='$secondOutputId' AND status='queued' AND next_attempt_at>clock_timestamp()",
            );
          }
          expect(done, isTrue);
        } finally {
          await events.cancel();
        }
      } finally {
        await observer.close();
      }
    }, twoOutputs: true),
    timeout: const Timeout(Duration(minutes: 4)),
  );
  test(
    'loaded_historical_signing_reference',
    () => withOutputProcess((database, env, receiver, children) async {
      final delivered = Completer<(List<int>, String?, String)>();
      receiver.listen((request) async {
        final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        delivered.complete((
          bytes,
          request.headers.value('x-correlia-signature'),
          request.uri.path,
        ));
        request.response.statusCode = 204;
        await request.response.close();
      });
      final first = await startOutputChild(
        database,
        env,
        children,
        gated: true,
      );
      final observer = await outputConnection(database);
      try {
        await observer.execute(
          '''CREATE FUNCTION test_historical_notify() RETURNS trigger LANGUAGE plpgsql AS \$\$
        BEGIN PERFORM pg_notify('test_historical', 'committed'); RETURN NEW; END \$\$''',
        );
        await observer.execute(
          'CREATE TRIGGER test_historical_notify AFTER INSERT ON outbox FOR EACH ROW EXECUTE FUNCTION test_historical_notify()',
        );
        await observer.execute('LISTEN test_historical');
        final committed = observer.channels.all.firstWhere(
          (event) => event.channel == 'test_historical',
        );
        await postOutputAlert(first);
        await committed.timeout(const Duration(seconds: 30));
        final old = (await observer.execute(
          'SELECT status, payload FROM outbox',
        )).single;
        expect(old[0], 'queued');
        first.kill();
        expect(await first.exitCode, -9);
        final newKey = base64Url
            .encode(List<int>.filled(32, 3))
            .replaceAll('=', '');
        File(env['CORRELIA_INGEST_SECRETS']!).writeAsStringSync(
          jsonEncode({
            'token': outputToken,
            'key': outputKey,
            'new-key': newKey,
          }),
        );
        File(env['CORRELIA_INGEST_CONFIG']!).writeAsStringSync(
          jsonEncode({
            'format_version': 1,
            'revision': 2,
            'sources': [
              {
                'id': outputSource,
                'enabled': true,
                'token_ref': 'token',
                'output_ids': [outputId],
              },
            ],
            'outputs': [
              {
                'id': outputId,
                'kind': 'webhook',
                'url': 'http://127.0.0.1:${receiver.port}/new',
                'signing_key_ref': 'new-key',
              },
            ],
          }),
        );
        await startOutputChild(database, env, children);
        final (bytes, signature, path) = await delivered.future.timeout(
          const Duration(seconds: 30),
        );
        expect(path, '/healthy');
        expect(bytes, old[1]);
        expect(
          signature,
          'sha256=${Hmac(sha256, List<int>.filled(32, 2)).convert(bytes)}',
        );
      } finally {
        await observer.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
