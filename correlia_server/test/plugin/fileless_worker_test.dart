@Tags(['plugin'])
library;

import '../support/secret_fixture.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingest_startup.dart';
import 'package:correlia_server/src/ingest/ingest_test_gates.dart';
import 'package:correlia_server/src/output/output_relay.dart';
import 'package:correlia_server/src/ingest/ingest_workers.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import 'support/plugin_fixture_support.dart';

const _webhookId = '11111111-1111-4111-8111-111111111111';
const _pluginId = '22222222-2222-4222-8222-222222222222';
String _base64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void main() {
  withServerpod(
    'store-backed output consumers',
    (builder, _) {
      for (final (name, rotate) in [
        ('fileless_worker_delivers_both_outputs', false),
        ('historical_outputs_drain_after_a_revision_change', true),
      ]) {
        test(name, () => runSecretOutputTest(builder.build(), rotate: rotate));
      }
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['plugin'],
  );
}

Future<void> runSecretOutputTest(
  Session session, {
  bool rotate = false,
  bool upgrade = false,
  bool shared = false,
}) async {
  final suite = PluginFixtureSuite.create();
  addTearDown(suite.dispose);
  final temp = await Directory.systemTemp.createTemp(
    'correlia-fileless-',
  );
  addTearDown(() => temp.delete(recursive: true));
  expect(
    (await Process.run('chmod', ['0700', temp.path])).exitCode,
    0,
  );
  final webhook = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  addTearDown(() => webhook.close(force: true));
  final signature = Completer<String?>();
  webhook.listen((request) async {
    await request.drain<void>();
    request.response.statusCode = 204;
    await request.response.close();
    if (!signature.isCompleted) {
      signature.complete(request.headers.value('x-correlia-signature'));
    }
  });
  final built = await suite.build();
  final executable = await built.binaries[PluginFixtureBinary.outputProduction]!
      .copy('${temp.path}/output-production');
  expect(
    (await Process.run('chmod', ['0700', executable.path])).exitCode,
    0,
  );
  final webhookKey = shared
      ? utf8.encode('k' * 32)
      : (Uint8List(32)..fillRange(0, 32, 2));
  final config = <String, Object?>{
    'format_version': 1,
    'revision': 1,
    'sources': <Object?>[],
    'outputs': [
      {
        'kind': 'webhook',
        'id': _webhookId,
        'url': 'http://127.0.0.1:${webhook.port}/events',
        'signing_key_ref': 'fileless-signing',
      },
      {
        'kind': 'plugin',
        'id': _pluginId,
        'plugin': 'output-production',
        'sha256': sha256.convert(await executable.readAsBytes()).toString(),
        'config': {'subject': shared ? 'shared' : 'alerts'},
        'secret_refs': {
          'token': shared ? 'fileless-signing' : 'fileless-plugin',
        },
      },
    ],
  };
  final imported = <String, Object?>{
    'fileless-signing': _base64(webhookKey),
    if (!shared)
      'fileless-plugin': {
        'bytes': _base64(utf8.encode('fixture-secret')),
      },
  };
  final m1 = upgrade
      ? IngestBootstrap.parse(config, imported, runMode: 'test')
      : null;
  final current = upgrade
      ? <String, Object?>{
          'format_version': 1,
          'revision': 2,
          'sources': <Object?>[],
          'outputs': [
            {
              ...(config['outputs']! as List<Map<String, Object?>>)[1],
              'secret_refs': {'token': 'fileless-plugin-new'},
            },
          ],
        }
      : config;
  if (upgrade) imported['fileless-plugin-new'] = imported['fileless-plugin'];
  Future<String> fixtureFile(String name, String content) async {
    final file = await File(
      '${temp.path}/$name',
    ).writeAsString(content);
    expect(
      (await Process.run('chmod', ['0600', file.path])).exitCode,
      0,
    );
    return file.path;
  }

  final env = {
    'CORRELIA_INGEST_CONFIG': await fixtureFile(
      'config.json',
      jsonEncode(current),
    ),
    'CORRELIA_SECRET_KEY_FILE': await fixtureFile(
      'key',
      _base64(Uint8List(32)),
    ),
    'CORRELIA_PLUGIN_DIR': executable.parent.path,
  };
  final secretFile = await fixtureFile(
    'secrets.json',
    jsonEncode(imported),
  );
  await initializeIngestSchema(session);
  await session.db.unsafeSimpleExecute(
    'DELETE FROM delivery_attempts; DELETE FROM outbox; '
    'DELETE FROM ingest_active_config; DELETE FROM ingest_config_snapshot; '
    'DELETE FROM ingest_secret_commitment; DELETE FROM secret_record;',
  );
  IngestStartup workerStartup(Map<String, String> environment) => IngestStartup(
    pod: session.serverpod,
    role: ProcessRole.worker,
    runMode: 'test',
    environment: environment,
  );
  final payload = utf8.encode('{}');
  Future<void> seed(IngestBootstrap pinned) async {
    for (final output in pinned.outputs) {
      final webhook = output is WebhookIngestOutput ? output : null;
      final plugin = output is PluginIngestOutput ? output : null;
      final eventId = const Uuid().v4();
      await session.db.unsafeExecute(
        '''INSERT INTO outbox (
                created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
                config_snapshot_id,payload,output_kind,definition_digest,target_url,signing_key_ref,signing_key_commitment)
                VALUES(now(),gen_random_uuid(),now(),CAST(@event AS uuid),'ready',CAST(@id AS uuid),
                @snapshot,@payload,@kind,@digest,@url,@ref,@commitment)''',
        parameters: QueryParameters.named({
          'id': output.id,
          'event': eventId,
          'snapshot': pinned.snapshotId,
          'payload': plugin == null ? payload : utf8.encode('bytes-$eventId'),
          'kind': webhook == null ? 'plugin' : 'webhook',
          'digest': plugin?.definitionDigest,
          'url': webhook?.url.toString(),
          'ref': webhook?.signingKeyRef,
          'commitment': webhook?.signingKeyCommitment,
        }),
      );
    }
  }

  if (m1 != null) {
    await session.db.transaction((tx) async {
      await session.db.unsafeSimpleExecute(
        "SET LOCAL correlia.publisher_version = '2'",
        transaction: tx,
      );
      await session.db.unsafeExecute(
        '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
                VALUES (@snapshot,1,@json)''',
        parameters: QueryParameters.named({
          'snapshot': m1.snapshotId,
          'json': m1.publicJson,
        }),
        transaction: tx,
      );
    });
    await session.db.unsafeExecute(
      'INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,@snapshot)',
      parameters: QueryParameters.named({'snapshot': m1.snapshotId}),
    );
    await seed(m1);
  }
  final publisher = workerStartup({
    ...env,
    'CORRELIA_INGEST_SECRETS': secretFile,
  });
  await publisher.start();
  final pinned = publisher.bootstrap!;
  if (m1 != null || shared) {
    final plugin = pinned.outputs.whereType<PluginIngestOutput>().single;
    final commitment = plugin.secretRefs.values.single.commitment;
    expect(commitment, startsWith('hmac-sha256:'));
    final records = await session.db.unsafeQuery(
      'SELECT reference,commitment FROM secret_record ORDER BY reference',
    );
    if (m1 != null) {
      expect(records.map((r) => r[0]), [
        'fileless-plugin',
        'fileless-plugin-new',
        'fileless-signing',
      ]);
      expect(pinned.outputs.whereType<WebhookIngestOutput>(), isEmpty);
    } else {
      final webhook = pinned.outputs.whereType<WebhookIngestOutput>().single;
      expect(
        webhook.signingKeyCommitment,
        sha256.convert(webhookKey).toString(),
      );
      expect(records.single[0], webhook.signingKeyRef);
      expect(records.single[1], commitment);
      final repository = IngestConfigRepository(
        session,
        secretStore: testSecretStore,
      );
      final legacyRow = (await session.db.unsafeQuery(
        'SELECT digest FROM ingest_secret_commitment',
      )).single;
      expect(legacyRow[0], commitment);
      expect(
        (await repository.activeSnapshot())!['snapshotId'],
        pinned.snapshotId,
      );
    }
  }
  await publisher.stop();
  await File(secretFile).delete();
  if (m1 != null) {
    final file = File(env['CORRELIA_INGEST_CONFIG']!);
    await file.writeAsString(jsonEncode({...current, 'revision': 3}));
  }
  final fileless = workerStartup(env);
  await fileless.start();
  final gate = File('${temp.path}/allow-acquire');
  final workers = IngestWorkers(
    pod: session.serverpod,
    startup: fileless,
    runMode: 'test',
    gates: IngestTestGates.fromEnvironment('test', {
      'CORRELIA_TEST_RELAY_ACQUIRE_GATE': gate.path,
    }),
    log: (_) {},
  );
  addTearDown(workers.stop);
  await workers.start();
  if (m1 == null) await seed(pinned);
  if (shared) {
    const wrongOutput = '33333333-3333-4333-8333-333333333333';
    await session.db.unsafeExecute('''
              INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,
                output_id,config_snapshot_id,payload,output_kind,target_url,signing_key_ref,signing_key_commitment)
              SELECT now(),gen_random_uuid(),event_observed_at,event_id,event_disposition,
                '$wrongOutput',config_snapshot_id,payload,output_kind,target_url,signing_key_ref,repeat('0',64)
              FROM outbox WHERE output_kind='webhook' ''');
    final repository = OutputRelayRepository(
      session,
      fileless.resolver!.resolve,
    );
    expect(await repository.claim(wrongOutput), isNull);
    expect(
      (await session.db.unsafeQuery(
        "SELECT status,attempt_count FROM outbox WHERE output_id='$wrongOutput'",
      )).single.toList(),
      ['queued', 0],
    );
  }
  if (rotate) {
    final next = IngestBootstrap.parse(
      {...config, 'revision': 2, 'outputs': <Object?>[]},
      <String, Object?>{},
      runMode: 'test',
    );
    final repository = IngestConfigRepository(
      session,
      secretStore: testSecretStore,
    );
    await repository.publish(next);
    expect((await repository.activeSnapshot())?['revision'], 2);
  }
  await gate.create();
  expect(
    await signature.future.timeout(const Duration(seconds: 20)),
    'sha256=${Hmac(sha256, webhookKey).convert(payload)}',
  );
  final deadline = Stopwatch()..start();
  List<Object?> statuses = [];
  do {
    statuses = (await session.db.unsafeQuery(
      'SELECT status FROM outbox ORDER BY output_id',
    )).map<Object?>((row) => row[0]).toList();
  } while ((statuses.length < 2 ||
          statuses.take(2).any((status) => status != 'delivered')) &&
      deadline.elapsed < const Duration(seconds: 20));
  expect(
    statuses,
    shared ? ['delivered', 'delivered', 'queued'] : ['delivered', 'delivered'],
  );
  if (m1 != null) {
    final row = (await session.db.unsafeQuery(
      "SELECT definition_digest,config_snapshot_id FROM outbox WHERE output_kind='plugin'",
    )).single;
    expect(
      row[0],
      m1.outputs.whereType<PluginIngestOutput>().single.definitionDigest,
    );
    expect(row[1], m1.snapshotId);
  }
}
