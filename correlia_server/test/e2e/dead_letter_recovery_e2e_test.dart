@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_client/correlia_client.dart';
import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/output_process.dart';
import '../support/shared_cluster.dart';
import '../support/queue_operator.dart';

const _guard = Duration(seconds: 90);
const _timeout = Timeout(Duration(minutes: 6));
const _discardOutput = '33333333-3333-4333-8333-333333333333';

Future<ChildServer> _start(
  SharedClusterDatabase db,
  Map<String, String> env,
  List<ChildServer> children, {
  required String role,
}) async {
  final child = await ChildServer.startOnSharedCluster(
    serverDir: Directory.current,
    database: db,
    args: ['--mode', 'test', '--apply-migrations', '--process-role', role],
    environment: env,
  );
  children.add(child);
  await child.waitForReadyEvent();
  return child;
}

Future<void> _watchOutbox(Connection pg) async {
  await pg.execute('''
    CREATE FUNCTION test_queue_delivery_notify() RETURNS trigger LANGUAGE plpgsql AS \$\$
      BEGIN PERFORM pg_notify('test_queue_delivery',NEW.status); RETURN NEW; END \$\$
  ''');
  await pg.execute('''
    CREATE TRIGGER test_queue_delivery_notify AFTER INSERT OR UPDATE OF status ON outbox
    FOR EACH ROW EXECUTE FUNCTION test_queue_delivery_notify()
  ''');
  await pg.execute('LISTEN test_queue_delivery');
}

Future<File> _config(
  Map<String, String> env,
  int port,
  int rev, {
  int? pendingCap,
  String signingKeyRef = 'key',
  bool discardOverflow = false,
}) =>
    File(
      '${File(env['CORRELIA_INGEST_CONFIG']!).parent.path}/config-$rev.json',
    ).writeAsString(
      jsonEncode({
        'format_version': 2,
        'revision': rev,
        if (pendingCap != null || discardOverflow)
          'pipeline_operations': {
            'pending_max_rows': ?pendingCap,
            if (discardOverflow)
              'output_budgets': {
                _discardOutput: {'max_rows': 1},
              },
          },
        'sources': [
          {
            'id': outputSource,
            'kind': 'alertmanager',
            'enabled': true,
            'credentials': [
              {'ref': 'token', 'type': 'bearer'},
            ],
            'output_ids': [outputId, if (discardOverflow) _discardOutput],
          },
        ],
        'outputs': [
          {
            'id': outputId,
            'kind': 'webhook',
            'url':
                'http://127.0.0.1:$port/${rev == 1 ? 'healthy' : 'replacement'}',
            'signing_key_ref': signingKeyRef,
          },
          if (discardOverflow)
            {
              'id': _discardOutput,
              'kind': 'webhook',
              'url': 'http://127.0.0.1:$port/failing',
              'signing_key_ref': signingKeyRef,
            },
        ],
      }),
    );

Future<(int, String?)> _probe(ChildServer child, String id) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse(
        'http://127.0.0.1:${child.webPort}/hooks/alertmanager/$outputSource',
      ),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('Authorization', 'Bearer $outputToken');
    request.headers.set('Idempotency-Key', id);
    request.write(
      jsonEncode({
        'version': '4',
        'status': 'firing',
        'alerts': [
          {
            'status': 'firing',
            'labels': {'alertname': id},
            'annotations': <String, String>{},
            'startsAt': DateTime.now().toUtc().toIso8601String(),
          },
        ],
      }),
    );
    final response = await request.close();
    await response.drain<void>();
    return (response.statusCode, response.headers.value('retry-after'));
  } finally {
    client.close(force: true);
  }
}

typedef _Delivery = ({
  List<int> bytes,
  String path,
  String? eventId,
  String? signature,
});

void main() {
  test('dur_4_dead_delivery_is_visible_and_replays', () async {
    await withOutputProcess((db, env, receiver, children) async {
      final credentials = await operatorCredentials(
        '${env['TEST_GATE_PATH']!}-operators',
      );
      final opts = {
        ...env,
        'CORRELIA_DEAD_LETTER_CREDENTIALS_FILE': credentials.path,
      };
      var recovering = false;
      final accepted = Completer<_Delivery>();
      final failed = <_Delivery>[];
      final receiverSubscription = receiver.listen((request) async {
        final delivery = (
          bytes: await request.fold(
            <int>[],
            (bytes, chunk) => bytes..addAll(chunk),
          ),
          path: request.uri.path,
          eventId: request.headers.value('idempotency-key'),
          signature: request.headers.value('x-correlia-signature'),
        );
        if (!recovering) failed.add(delivery);
        request.response.statusCode = recovering ? 204 : 503;
        await request.response.close();
        if (recovering && !accepted.isCompleted) accepted.complete(delivery);
      });
      final child = await _start(db, opts, children, role: 'all');
      final pg = await outputConnection(db);
      final client = operatorClient(child);
      final notifications = StreamIterator(
        pg.channels.all.where((e) => e.channel == 'test_queue_delivery'),
      );
      try {
        await _watchOutbox(pg);
        var next = notifications.moveNext();
        await postOutputAlert(child);
        // Let PostgreSQL observe each real failed attempt, then make its next
        // retry eligible without sleeping through the production backoff.
        while (await next.timeout(_guard)) {
          final status = notifications.current.payload;
          if (status == 'dead') break;
          next = notifications.moveNext();
          if (status == 'queued') {
            await pg.execute('''
            UPDATE outbox SET next_attempt_at=now() WHERE status='queued' AND next_attempt_at>now()
          ''');
          }
        }
        expect(failed, hasLength(20));
        final listed = await client.deadLetter.list(
          QueueFailureFilter(
            kind: QueueFailureKind.delivery,
            scopeId: outputId,
          ),
          limit: 10,
        );
        final dead = listed.failures.single;
        expect(dead.errorClass, 'http_retryable');
        expect(
          listed.toJson()['failures'].toString(),
          isNot(contains('Recovery')),
        );
        const replacementRef = 'key-2';
        final replacementKey = List<int>.filled(32, 3);
        final rotation = await _config(
          env,
          receiver.port,
          2,
          signingKeyRef: replacementRef,
        );
        await File(env['CORRELIA_INGEST_SECRETS']!).writeAsString(
          jsonEncode({
            'token': outputToken,
            'key': outputKey,
            replacementRef: base64Url
                .encode(replacementKey)
                .replaceAll('=', ''),
          }),
        );
        await _start(
          db,
          {...opts, 'CORRELIA_INGEST_CONFIG': rotation.path},
          children,
          role: 'api',
        );
        expect(
          (await pg.execute('''
            SELECT s."publicJson"::jsonb->'outputs'->0->>'signing_key_ref'
            FROM ingest_active_config a JOIN ingest_config_snapshot s USING ("snapshotId")
            WHERE a.singleton=1
          ''')).single[0],
          replacementRef,
        );
        recovering = true;
        next = notifications.moveNext();
        expect(
          (await client.deadLetter.replay(
            QueueFailureKind.delivery,
            dead.occurrence,
          )).queued,
          1,
        );
        final replayed = await accepted.future.timeout(_guard);
        expect(replayed.path, '/healthy');
        expect(replayed.bytes, failed.first.bytes);
        expect(replayed.eventId, failed.first.eventId);
        final originalKey = base64Url.decode(base64Url.normalize(outputKey));
        String sign(List<int> key) =>
            'sha256=${Hmac(sha256, key).convert(replayed.bytes)}';
        expect(replayed.signature, sign(originalKey));
        expect(replayed.signature, isNot(sign(replacementKey)));
        var delivered = false;
        while (await next.timeout(_guard)) {
          if ((delivered = notifications.current.payload == 'delivered')) break;
          next = notifications.moveNext();
        }
        expect(delivered, isTrue);
        expect(
          (await pg.execute('''
          SELECT delivery_id::text,event_id::text,status,attempt_count,retry_base FROM outbox
        ''')).single.toList(),
          [dead.workId, replayed.eventId, 'delivered', 21, 20],
        );
        expect(
          (await pg.execute(
            'SELECT count(*) FROM delivery_attempts',
          )).single[0],
          21,
        );
        expect(
          (await client.deadLetter.list(
            QueueFailureFilter(kind: QueueFailureKind.delivery),
            limit: 10,
          )).failures,
          isEmpty,
        );
      } finally {
        client.close();
        await notifications.cancel();
        await pg.close();
        await receiverSubscription.cancel();
      }
    });
  }, timeout: _timeout);

  test('operator_status_tracks_pressure_and_recovery', () async {
    await withOutputProcess((db, env, receiver, children) async {
      final deliveries = <String?>[];
      final subscription = receiver.listen((request) async {
        await request.drain<void>();
        deliveries.add(request.headers.value('idempotency-key'));
        request.response.statusCode = 204;
        await request.response.close();
      });
      final credentials = await operatorCredentials(env['TEST_GATE_PATH']!);
      final config = await _config(env, receiver.port, 1, pendingCap: 1);
      final opts = {
        ...env,
        'CORRELIA_DEAD_LETTER_CREDENTIALS_FILE': credentials.path,
        'CORRELIA_INGEST_CONFIG': config.path,
      };
      final api = await _start(db, opts, children, role: 'api');
      final client = operatorClient(api);
      final pg = await outputConnection(db);
      final notifications = StreamIterator(
        pg.channels.all.where((e) => e.channel == 'test_queue_delivery'),
      );
      try {
        await _watchOutbox(pg);
        var next = notifications.moveNext();
        expect((await _probe(api, 'first')).$1, 202);
        final pressure = await client.deadLetter.status();
        expect(
          (pressure.pendingRows, pressure.pendingMaxRows, pressure.pressure),
          (1, 1, 'inbox'),
        );
        expect(pressure.oldestPendingAgeSeconds, isNotNull);
        expect(pressure.outputs.single.usedRows, 0);
        final denied = await _probe(api, 'after-recovery');
        expect(denied.$1, 429);
        expect(int.parse(denied.$2!), greaterThan(0));
        await _start(db, opts, children, role: 'worker');
        var delivered = false;
        while (await next.timeout(_guard)) {
          if ((delivered = notifications.current.payload == 'delivered')) break;
          next = notifications.moveNext();
        }
        expect(delivered, isTrue);
        final recovered = await client.deadLetter.status();
        expect(
          (
            recovered.pendingRows,
            recovered.pressure,
            recovered.oldestPendingAgeSeconds,
          ),
          (0, null, null),
        );
        expect(recovered.outputs.single.usedRows, 0);
        expect(deliveries, hasLength(1));
        expect((await _probe(api, 'after-recovery')).$1, 202);
      } finally {
        client.close();
        await notifications.cancel();
        await pg.close();
        await subscription.cancel();
      }
    });
  }, timeout: _timeout);

  test('dur_11_discard_keeps_http_ingress_and_delivery_running', () async {
    await withOutputProcess((db, env, receiver, children) async {
      final subscription = receiver.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = request.uri.path == '/failing'
            ? 422
            : 204;
        await request.response.close();
      });
      final config = await _config(
        env,
        receiver.port,
        1,
        discardOverflow: true,
      );
      final app = await _start(
        db,
        {...env, 'CORRELIA_INGEST_CONFIG': config.path},
        children,
        role: 'all',
      );
      final pg = await outputConnection(db);
      final notifications = StreamIterator(
        pg.channels.all.where((e) => e.channel == 'test_queue_delivery'),
      );
      try {
        await _watchOutbox(pg);
        var next = notifications.moveNext();
        Future<void> until(Future<bool> Function() seen) async {
          while (!await seen()) {
            expect(await next.timeout(_guard), isTrue);
            next = notifications.moveNext();
          }
        }

        Future<int> acknowledgements() async =>
            (await pg.execute('''
              SELECT count(*) FROM outbox o
              JOIN events e ON (e.observed_at,e.event_id,e.disposition)=
                (o.event_observed_at,o.event_id,o.event_disposition)
              JOIN delivery_attempts a ON a."outboxCreatedAt"=(o.created_at AT TIME ZONE 'UTC')
                AND a."deliveryId"=o.delivery_id
              WHERE o.output_id='$outputId' AND e.system_activity_id IS NULL
                AND o.status='delivered' AND a.outcome='acknowledged'
            ''')).single[0]!
                as int;

        Future<Result> failingIntents() => pg.execute('''
          SELECT delivery_id::text,event_id::text,status,encode(payload,'hex'),attempt_count
          FROM outbox WHERE output_id='$_discardOutput' ORDER BY created_at,delivery_id
        ''');

        expect((await _probe(app, 'fills-failing-output')).$1, 202);
        await until(() async {
          final failing = await failingIntents();
          return failing.singleOrNull?[2] == 'dead' &&
              (await acknowledgements()) == 1;
        });
        final retained = (await failingIntents())
            .map((row) => row.toList())
            .toList();
        expect(retained.single[4], 1);

        expect((await _probe(app, 'accepted-while-output-is-full')).$1, 202);
        await until(() async => await acknowledgements() == 2);
        expect((await failingIntents()).map((row) => row.toList()), retained);
        expect(
          (await pg.execute('''
            SELECT used_rows,discarded_count FROM pipeline_output_capacity
            WHERE output_id='$_discardOutput'
          ''')).single.toList(),
          [1, 1],
        );
      } finally {
        await notifications.cancel();
        await pg.close();
        await subscription.cancel();
      }
    });
  }, timeout: _timeout);
}
