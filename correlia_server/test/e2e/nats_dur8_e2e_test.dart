@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../plugin/support/plugin_process_identity.dart';
import '../support/jetstream_inspector.dart';
import '../support/nats_ack_proxy.dart';
import '../support/nats_process.dart';
import '../support/output_process.dart';

Future<Result> _until(
  Connection db,
  String sql,
  bool Function(Result) accept, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    final rows = await db.execute(sql);
    if (accept(rows)) return rows;
  }
  throw StateError('Timed out waiting for $sql');
}

Future<void> _configureProxy(NatsProcessFixture setup, Uri url) async {
  final config = File(setup.environment['CORRELIA_INGEST_CONFIG']!);
  final data = jsonDecode(await config.readAsString()) as Map<String, Object?>;
  final outputs = data['outputs'] as List<Object?>;
  final output = outputs.single as Map<String, Object?>;
  output['config'] = {'server': url.toString(), 'stream': 'CORRELIA_EVENTS'};
  await config.writeAsString(jsonEncode(data));
}

void main() {
  test('DUR-8 plugin crashes mid-stream', () async {
    final setup = await NatsProcessFixture.start();
    final proxy = await NatsAckProxy.start(setup.nats.url);
    final db = await outputConnection(setup.database);
    final stream = await JetStreamInspector.connect(setup.nats.url);
    try {
      await _configureProxy(setup, proxy.url);
      final child = await setup.startChild();
      await postOutputAlert(child);
      await proxy.published.timeout(const Duration(seconds: 45));
      final inFlight = await db.execute(
        "SELECT event_id::text,encode(payload,'base64') FROM outbox WHERE status='delivering'",
      );
      expect(inFlight, hasLength(1));
      final before = await stream.messages();
      expect(before, hasLength(1));
      expect(before.single.headers['nats-msg-id'], inFlight.single[0]);
      expect(
        before.single.body,
        base64.decode((inFlight.single[1] as String).replaceAll('\n', '')),
      );
      final ready = await db.execute(
        "SELECT pid FROM plugin_instance_status WHERE state='ready' AND pid IS NOT NULL",
      );
      final identity = PluginProcessIdentity.read(ready.single[0] as int);
      expect(identity, isNotNull);
      expect(identity!.signalIfExact(ProcessSignal.sigkill), isTrue);
      proxy.resume();
      await _until(
        db,
        'SELECT status,attempt_count FROM outbox',
        (rows) => rows.length == 1 && rows.single[0] == 'delivered',
        timeout: const Duration(seconds: 120),
      );
      final after = await db.execute(
        "SELECT event_id::text,encode(payload,'base64'),attempt_count FROM outbox",
      );
      expect(after.single[0], inFlight.single[0]);
      expect(after.single[1], inFlight.single[1]);
      expect(after.single[2] as int, greaterThanOrEqualTo(2));
      final messages = await stream.messages();
      expect(messages, hasLength(1));
      expect(messages.single.headers['nats-msg-id'], inFlight.single[0]);
      expect(
        messages.single.body,
        base64.decode((inFlight.single[1] as String).replaceAll('\n', '')),
      );
      final attempts = await db.execute(
        'SELECT "errorClass" FROM delivery_attempts ORDER BY "attemptNumber"',
      );
      expect(attempts.first[0], 'plugin_connection_lost');
    } finally {
      await stream.close();
      await db.close();
      await setup.close();
      await proxy.close();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('DUR-8 crash budget exceeded', () async {
    final setup = await NatsProcessFixture.start();
    final db = await outputConnection(setup.database);
    try {
      final api = await setup.startChild(
        args: const [
          '--mode',
          'test',
          '--apply-migrations',
          '--process-role',
          'api',
        ],
      );
      await postOutputAlert(api);
      await setup.startChild(
        args: const [
          '--mode',
          'test',
          '--apply-migrations',
          '--process-role',
          'worker',
        ],
        environment: {
          'CORRELIA_TEST_RELAY_ACQUIRE_GATE': '${setup.files.path}/acquire',
        },
      );
      int? previous;
      for (var crash = 0; crash < 6; crash++) {
        final rows = await _until(
          db,
          "SELECT pid FROM plugin_instance_status WHERE state='ready' AND pid IS NOT NULL",
          (rows) => rows.isNotEmpty && rows.single[0] != previous,
          timeout: const Duration(seconds: 90),
        );
        previous = rows.single[0] as int;
        final identity = PluginProcessIdentity.read(previous);
        expect(identity, isNotNull);
        expect(identity!.signalIfExact(ProcessSignal.sigkill), isTrue);
      }
      await _until(
        db,
        "SELECT state FROM plugin_instance_status WHERE state='degraded'",
        (rows) => rows.isNotEmpty,
      );
      await File('${setup.files.path}/acquire').writeAsString('release');
      final activity = await db.execute(
        "SELECT count(*) FROM activity WHERE entity_kind='plugin' AND change_kind='plugin_degraded'",
      );
      expect(activity.single[0], 1);
      final outbox = await db.execute(
        'SELECT status,attempt_count FROM outbox',
      );
      expect(outbox, isNotEmpty);
      for (final row in outbox) {
        expect(row[0], 'queued');
        expect(row[1], 0);
      }
      expect(
        (await db.execute('SELECT count(*) FROM delivery_attempts')).single[0],
        0,
      );
    } finally {
      await db.close();
      await setup.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
