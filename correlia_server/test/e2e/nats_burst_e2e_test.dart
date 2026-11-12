@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/plugin/plugin_status_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../plugin/support/plugin_process_identity.dart';
import '../support/jetstream_inspector.dart';
import '../support/nats_marker_observer.dart';
import '../support/nats_process.dart';
import '../support/output_process.dart';

const _api = ['--mode', 'test', '--apply-migrations', '--process-role', 'api'];
const _worker = [
  '--mode',
  'test',
  '--apply-migrations',
  '--process-role',
  'worker',
];

Future<void> _waitFile(File file) async {
  final found = Completer<void>();
  final subscription = file.parent.watch().listen((_) {
    if (file.existsSync() && !found.isCompleted) found.complete();
  });
  try {
    if (!file.existsSync()) {
      await found.future.timeout(const Duration(seconds: 90));
    }
  } finally {
    await subscription.cancel();
  }
}

Future<Result> _until(
  Connection db,
  String sql,
  bool Function(Result) condition, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    final rows = await db.execute(sql);
    if (condition(rows)) return rows;
  }
  throw StateError('Timed out waiting for SQL condition: $sql');
}

Future<void> _post(int port, int start, int count) async {
  final http = HttpClient();
  try {
    final request = await http.postUrl(
      Uri.parse('http://127.0.0.1:$port/hooks/alertmanager/$outputSource'),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('Authorization', 'Bearer $outputToken');
    final time = DateTime.now().toUtc().toIso8601String();
    request.write(
      jsonEncode({
        'version': '4',
        'status': 'firing',
        'alerts': [
          for (var i = start; i < start + count; i++)
            {
              'status': 'firing',
              'labels': {'alertname': 'Burst$i', 'severity': 'warning'},
              'annotations': <String, String>{},
              'startsAt': time,
            },
        ],
      }),
    );
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 202);
  } finally {
    http.close(force: true);
  }
}

void main() {
  test('Kill -9 during a 1,000-alert burst', () async {
    final setup = await NatsProcessFixture.start();
    final db = await outputConnection(setup.database);
    final stream = await JetStreamInspector.connect(setup.nats.url);
    NatsMarkerObserver? marker;
    try {
      final api = await setup.startChild(args: _api);
      for (var i = 0; i < 1000; i += 50) {
        await _post(api.webPort, i, 50);
      }
      final gate = '${setup.files.path}/complete';
      final worker = await setup.startChild(
        args: _worker,
        vmArgs: ['-Dcorrelia.testHooks=true'],
        environment: {
          'CORRELIA_TEST_RELAY_COMPLETION_GATE': gate,
          'CORRELIA_TEST_RELAY_COMPLETION_ACKS': '100',
        },
      );
      await _waitFile(File('$gate.entered'));
      final live = await db.execute(
        "SELECT event_id::text FROM outbox WHERE status='delivering' AND lease_until>clock_timestamp()",
      );
      expect(live, isNotEmpty);
      final held = live.map((row) => row[0] as String).toSet();
      final storedBefore = await stream.messages();
      expect(storedBefore.length, greaterThanOrEqualTo(100));
      expect(
        storedBefore.map((m) => m.headers['nats-msg-id']).toSet(),
        containsAll(held),
      );
      final statuses = await db.execute(
        "SELECT pid FROM plugin_instance_status WHERE state='ready' AND pid IS NOT NULL ORDER BY id DESC LIMIT 1",
      );
      expect(statuses, hasLength(1));
      final identity = PluginProcessIdentity.read(statuses.single[0] as int);
      expect(identity, isNotNull);
      marker = NatsMarkerObserver.open(identity!);
      worker.kill();
      expect(await worker.exitCode, -9);
      await marker.waitForExitMarker();
      await db.execute(
        "UPDATE outbox SET lease_until=clock_timestamp()-interval '1 second' WHERE status='delivering'",
      );
      await setup.startChild(args: _worker);
      final rows = await _until(
        db,
        "SELECT event_id::text,status,dead_reason,encode(payload,'base64'),attempt_count FROM outbox",
        (r) =>
            r.length == 1000 &&
            r.every((row) => row[1] == 'delivered' || row[1] == 'dead'),
      );
      final events = await db.execute('SELECT event_id::text FROM events');
      final accepted = events.map((row) => row[0] as String).toSet();
      expect(accepted, hasLength(1000));
      final messages = await stream.messages();
      final byId = {
        for (final message in messages)
          message.headers['nats-msg-id']!: message,
      };
      expect(byId.length, messages.length);
      final dead = <String>{};
      for (final row in rows) {
        final id = row[0] as String;
        if (row[1] == 'dead') {
          expect(row[2], isNotNull);
          dead.add(id);
        } else {
          expect(row[1], 'delivered');
          expect(byId[id], isNotNull);
          expect(
            byId[id]!.body,
            base64.decode((row[3] as String).replaceAll('\n', '')),
          );
        }
        if (held.contains(id)) {
          expect(row[1], 'delivered');
          expect(row[4] as int, greaterThanOrEqualTo(2));
        }
      }
      expect(dead.intersection(byId.keys.toSet()), isEmpty);
      expect({...byId.keys, ...dead}, accepted);
      final attempts = await db.execute(
        "SELECT count(*) FROM delivery_attempts WHERE outcome='interrupted'",
      );
      expect(attempts.single[0] as int, greaterThanOrEqualTo(held.length));
      stdout.writeln(
        'burst accepted=${accepted.length} stream=${messages.length} dead=${dead.length} held=${held.length} interrupted=${attempts.single[0]} stored_before_kill=${storedBefore.length} plugin_pid=${statuses.single[0]} independent_stderr_marker=stdin_eof exactchild_exited=true',
      );
    } finally {
      await marker?.close();
      await stream.close();
      await db.close();
      await setup.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('worker_killed_before_any_delivery', () async {
    final setup = await NatsProcessFixture.start();
    final db = await outputConnection(setup.database);
    final stream = await JetStreamInspector.connect(setup.nats.url);
    try {
      final api = await setup.startChild(args: _api);
      await _post(api.webPort, 0, 1);
      final gate = '${setup.files.path}/launch';
      final worker = await setup.startChild(
        args: _worker,
        vmArgs: ['-Dcorrelia.testHooks=true'],
        environment: {'CORRELIA_TEST_PLUGIN_LAUNCH_GATE': gate},
      );
      await _waitFile(File('$gate.entered'));
      final pending = await _until(
        db,
        'SELECT event_id::text,status,attempt_count FROM outbox',
        (r) => r.length == 1,
      );
      expect(pending.single[1], 'queued');
      expect(pending.single[2], 0);
      expect(await stream.messages(), isEmpty);
      final ready = await db.execute(
        "SELECT count(*) FROM plugin_instance_status WHERE state='ready'",
      );
      expect(ready.single[0], 0);
      worker.kill();
      expect(await worker.exitCode, -9);
      await setup.startChild(args: _worker);
      await _until(
        db,
        'SELECT status FROM outbox',
        (r) => r.length == 1 && r.single[0] == 'delivered',
      );
      final messages = await stream.messages();
      expect(messages, hasLength(1));
      expect(messages.single.headers['nats-msg-id'], pending.single[0]);
    } finally {
      await stream.close();
      await db.close();
      await setup.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('worker_killed_status_goes_stale', () async {
    final setup = await NatsProcessFixture.start();
    final db = await outputConnection(setup.database);
    NatsMarkerObserver? marker;
    try {
      final api = await setup.startChild(args: _api);
      await _post(api.webPort, 0, 1);
      final worker = await setup.startChild(
        args: _worker,
        environment: {
          'CORRELIA_TEST_RELAY_ACQUIRE_GATE': '${setup.files.path}/acquire',
        },
      );
      final ready = await _until(
        db,
        "SELECT id,\"heartbeatAt\",pid,\"hostInstanceId\" FROM plugin_instance_status WHERE state='ready' AND pid IS NOT NULL",
        (r) => r.isNotEmpty,
      );
      final id = ready.single[0] as int;
      final host = ready.single[3] as String;
      final identity = PluginProcessIdentity.read(ready.single[2] as int);
      expect(identity, isNotNull);
      marker = NatsMarkerObserver.open(identity!);
      worker.kill();
      expect(await worker.exitCode, -9);
      await marker.waitForExitMarker();
      final query = Sql.named(
        'SELECT "heartbeatAt" FROM plugin_instance_status WHERE id=@id:int8 AND "hostInstanceId"=@host:text',
      );
      final parameters = {'id': id, 'host': host};
      final stopped = await db.execute(query, parameters: parameters);
      final heartbeat = stopped.single[0] as DateTime;
      final observation = Stopwatch()..start();
      // Sampling for 16 seconds spans the worker's 15-second refresh interval,
      // so a still-running heartbeat writer would have an opportunity to update.
      await for (final _ in Stream<void>.periodic(
        const Duration(seconds: 1),
      ).take(16)) {
        final sample = await db.execute(query, parameters: parameters);
        expect(sample.single[0], heartbeat);
      }
      expect(observation.elapsed, greaterThan(const Duration(seconds: 15)));
      expect(
        isPluginHeartbeatStale(
          heartbeat,
          heartbeat.add(const Duration(seconds: 60)),
        ),
        isFalse,
      );
      expect(
        isPluginHeartbeatStale(
          heartbeat,
          heartbeat.add(const Duration(seconds: 61)),
        ),
        isTrue,
      );
    } finally {
      await marker?.close();
      await db.close();
      await setup.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('nats_plugin_exits_after_host_sigkill', () async {
    final setup = await NatsProcessFixture.start();
    final db = await outputConnection(setup.database);
    NatsMarkerObserver? marker;
    try {
      final api = await setup.startChild(args: _api);
      await _post(api.webPort, 0, 1);
      final worker = await setup.startChild(
        args: _worker,
        environment: {
          'CORRELIA_TEST_RELAY_ACQUIRE_GATE': '${setup.files.path}/acquire',
        },
      );
      final ready = await _until(
        db,
        "SELECT pid FROM plugin_instance_status WHERE state='ready' AND pid IS NOT NULL",
        (r) => r.isNotEmpty,
      );
      final identity = PluginProcessIdentity.read(ready.single[0] as int);
      expect(identity, isNotNull);
      marker = NatsMarkerObserver.open(identity!);
      worker.kill();
      expect(await worker.exitCode, -9);
      await marker.waitForExitMarker();
      stdout.writeln(
        'plugin_pid=${ready.single[0]} independent_stderr_marker=stdin_eof exactchild_exited=true',
      );
    } finally {
      await marker?.close();
      await db.close();
      await setup.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
