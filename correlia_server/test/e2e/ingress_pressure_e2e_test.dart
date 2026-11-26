@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:postgres/postgres.dart' show Sql;
import 'package:serverpod/serverpod.dart' show Uuid;
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/icinga2_pipeline.dart' show icinga2DbSourceId;
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart' show streamDbCheck;
import '../support/output_process.dart';
import '../support/shared_cluster.dart';

const _timeout = Timeout(Duration(minutes: 5));

Future<(int, String?)> _post(ChildServer child, String key) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse(
        'http://127.0.0.1:${child.webPort}/hooks/alertmanager/$outputSource',
      ),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('Authorization', 'Bearer $outputToken');
    request.headers.set('Idempotency-Key', key);
    request.write(
      jsonEncode({
        'version': '4',
        'status': 'firing',
        'alerts': [
          {
            'status': 'firing',
            'labels': {'alertname': key},
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

Future<String> _bootstrap(
  Directory directory,
  int revision,
  Map<String, Object?> policy, {
  int? receiver,
  bool pull = false,
}) async {
  final file = File('${directory.path}/config-$revision.json');
  final icinga = streamSource(icinga2DbSourceId);
  (icinga['api']! as Map<String, Object?>)['url'] = 'https://127.0.0.1:1';
  await file.writeAsString(
    jsonEncode({
      'format_version': 2,
      'revision': revision,
      'pipeline_operations': policy,
      'sources': [
        {
          'id': outputSource,
          'kind': 'alertmanager',
          'enabled': true,
          'credentials': [
            {'ref': 'token', 'type': 'bearer'},
          ],
          'output_ids': [if (receiver != null) outputId],
        },
        if (pull) icinga,
      ],
      'outputs': [
        if (receiver != null)
          {
            'id': outputId,
            'kind': 'webhook',
            'url': 'http://127.0.0.1:$receiver/events',
            'signing_key_ref': 'key',
          },
      ],
    }),
  );
  return file.path;
}

Future<void> _withServers(
  Future<void> Function(
    SharedClusterDatabase,
    Directory,
    Future<ChildServer> Function(String, String),
  )
  use,
) async {
  final database = await SharedClusterDatabase.create(Directory.current);
  final directory = Directory.systemTemp.createTempSync(
    'correlia-ingress-pressure-',
  );
  final children = <ChildServer>[];
  try {
    final secret = File('${directory.path}/secrets.json');
    await secret.writeAsString(
      jsonEncode({
        'token': outputToken,
        'key': outputKey,
        ...streamMaterial(),
      }),
    );
    expect((await Process.run('chmod', ['600', secret.path])).exitCode, 0);
    await use(database, directory, (role, config) async {
      final child = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: database,
        args: ['--mode', 'test', '--apply-migrations', '--process-role', role],
        environment: {
          'CORRELIA_INGEST_CONFIG': config,
          'CORRELIA_INGEST_SECRETS': secret.path,
        },
      );
      children.add(child);
      await child.waitForReadyEvent();
      return child;
    });
  } finally {
    try {
      await tearDownChildren(children);
    } finally {
      await database.drop();
      directory.deleteSync(recursive: true);
    }
  }
}

void main() {
  test('dur_9_webhook_and_pull_pause_and_recover', () async {
    await _withServers((database, directory, start) async {
      final seen = Completer<void>();
      final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      receiver.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 204;
        await request.response.close();
        if (!seen.isCompleted) seen.complete();
      });
      final db = await outputConnection(database);
      try {
        final cfg = await _bootstrap(
          directory,
          1,
          {
            'pending_max_rows': 1,
            'pending_max_age_seconds': 3600,
          },
          receiver: receiver.port,
          pull: true,
        );
        final api = await start('api', cfg);
        final snapshot =
            (await db.execute(
                  'SELECT "snapshotId" FROM ingest_active_config',
                )).single[0]!
                as String;
        final lease = (await StreamLeaseStore(
          db,
        ).acquire(icinga2DbSourceId, const Uuid().v4()))!;
        // This fixture owns the pull lease until invoked; VM startup speed
        // must not let the production supervisor replace that lease.
        await db.execute(
          "UPDATE icinga2_stream_lease SET \"expiresAt\"='infinity'",
        );
        final received = DateTime.now().toUtc();
        final batch = StreamRawBatch(
          id: const Uuid().v4(),
          connectionId: const Uuid().v4(),
          origin: IcingaStreamOrigin.stream,
          rows: [
            [
              StreamAdmissionItem.text(
                received,
                jsonEncode(streamDbCheck(received)),
              ),
            ],
          ],
        );
        Future<StreamAdmissionResult> admit() => ConsumerAdmission(db).admit(
          lease: lease,
          snapshotId: snapshot,
          batch: batch,
        );
        expect((await _post(api, 'accepted-before-outage')).$1, 202);
        final refused = await _post(api, 'absent-during-outage');
        expect(refused.$1, 429);
        expect(int.parse(refused.$2!), greaterThan(0));
        expect(await admit(), StreamAdmissionResult.atCapacity);
        await start('worker', cfg);
        await seen.future;
        expect(await admit(), StreamAdmissionResult.committed);
        expect(
          (await db.execute(
            Sql.named('''
          SELECT count(*) FROM raw_inbox WHERE source_id=@id::uuid AND status='done'
        '''),
            parameters: {'id': outputSource},
          )).single[0],
          1,
        );
      } finally {
        await db.close();
        await receiver.close(force: true);
      }
    });
  }, timeout: _timeout);

  test('oversize_database_pushes_back_and_degrades_readiness', () async {
    await _withServers((database, directory, start) async {
      final db = await outputConnection(database);
      try {
        final small = await _bootstrap(directory, 1, {'disk_budget_bytes': 1});
        final api = await start('api', small);
        final refused = await _post(api, 'disk-too-small');
        expect(refused.$1, 503);
        expect(int.parse(refused.$2!), greaterThan(0));
        expect(await api.statusOf('/readyz'), 503);
        expect(await api.statusOf('/livez'), 200);
        expect(
          (await db.execute('SELECT count(*) FROM transport_keys')).single[0],
          0,
        );
        final larger = await _bootstrap(directory, 2, {
          'disk_budget_bytes': 1073741824,
        });
        final recovered = await start('api', larger);
        expect(await recovered.statusOf('/readyz'), 200);
        expect((await _post(recovered, 'disk-too-small')).$1, 202);
      } finally {
        await db.close();
      }
    });
  }, timeout: _timeout);
}
