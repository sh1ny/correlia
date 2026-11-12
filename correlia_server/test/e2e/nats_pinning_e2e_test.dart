@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../plugin/support/natsdev.dart';
import '../support/jetstream_inspector.dart';
import '../support/nats_process.dart';
import '../support/output_process.dart';

Future<void> _post(int port, String name) async {
  final http = HttpClient();
  try {
    final request = await http.postUrl(
      Uri.parse('http://127.0.0.1:$port/hooks/alertmanager/$outputSource'),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('Authorization', 'Bearer $outputToken');
    request.write(
      jsonEncode({
        'version': '4',
        'status': 'firing',
        'alerts': [
          {
            'status': 'firing',
            'labels': {'alertname': name},
            'annotations': <String, String>{},
            'startsAt': DateTime.now().toUtc().toIso8601String(),
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

Future<void> _waitFile(File file) async {
  final found = Completer<void>();
  final subscription = file.parent.watch().listen((_) {
    if (file.existsSync() && !found.isCompleted) found.complete();
  });
  try {
    if (!file.existsSync()) {
      await found.future.timeout(const Duration(seconds: 45));
    }
  } finally {
    await subscription.cancel();
  }
}

void main() {
  test('nats_server_changed_with_work_pending', () async {
    final setup = await NatsProcessFixture.start();
    final second = await NatsTestServer.start();
    final db = await outputConnection(setup.database);
    final firstStream = await JetStreamInspector.connect(setup.nats.url);
    final secondStream = await JetStreamInspector.connect(second.url);
    try {
      final result = await Process.run(
        '${Directory.current.parent.path}/build/plugins/natsdev',
        ['stream', '--url', second.url.toString()],
      );
      if (result.exitCode != 0) {
        throw StateError('second stream failed: ${result.stderr}');
      }
      final api = await setup.startChild(
        args: const [
          '--mode',
          'test',
          '--apply-migrations',
          '--process-role',
          'api',
        ],
      );
      await _post(api.webPort, 'OldNats');
      final gate = '${setup.files.path}/launch';
      await setup.startChild(
        args: const [
          '--mode',
          'test',
          '--apply-migrations',
          '--process-role',
          'worker',
        ],
        vmArgs: const ['-Dcorrelia.testHooks=true'],
        environment: {'CORRELIA_TEST_PLUGIN_LAUNCH_GATE': gate},
      );
      await _waitFile(File('$gate.entered'));
      final clock = Stopwatch()..start();
      while (true) {
        final rows = await db.execute(
          'SELECT event_id::text,status FROM outbox',
        );
        if (rows.length == 1 && rows.single[1] == 'queued') break;
        if (clock.elapsed > const Duration(seconds: 45)) {
          throw StateError('Old event not pinned');
        }
      }
      final pinned = (await db.execute(
        'SELECT event_id::text,definition_digest FROM outbox',
      )).single;
      final old = pinned[0] as String;
      final oldDigest = pinned[1] as String;
      final config = File(setup.environment['CORRELIA_INGEST_CONFIG']!);
      final data =
          jsonDecode(await config.readAsString()) as Map<String, Object?>;
      data['revision'] = 2;
      final outputs = data['outputs'] as List<Object?>;
      final definition = outputs.single as Map<String, Object?>;
      definition['config'] = {
        'server': second.url.toString(),
        'stream': 'CORRELIA_EVENTS',
      };
      await config.writeAsString(jsonEncode(data));
      await api.closeStdin();
      final newApi = await setup.startChild(
        args: const [
          '--mode',
          'test',
          '--apply-migrations',
          '--process-role',
          'api',
        ],
      );
      await _post(newApi.webPort, 'NewNats');
      while (true) {
        final rows = await db.execute('SELECT event_id::text FROM outbox');
        if (rows.length == 2) break;
        if (clock.elapsed > const Duration(seconds: 90)) {
          throw StateError('New event not pinned');
        }
      }
      await File(gate).writeAsString('release');
      while (true) {
        final rows = await db.execute(
          "SELECT event_id::text FROM outbox WHERE status='delivered'",
        );
        if (rows.length == 2) break;
        if (clock.elapsed > const Duration(seconds: 150)) {
          throw StateError('Pinned events not delivered');
        }
      }
      final first = await firstStream.messages();
      final next = await secondStream.messages();
      expect(first, hasLength(1));
      expect(next, hasLength(1));
      expect(first.single.headers['nats-msg-id'], old);
      expect(next.single.headers['nats-msg-id'], isNot(old));
      final rows = await db.execute(
        "SELECT event_id::text,encode(payload,'base64') FROM outbox",
      );
      final bodies = {for (final row in rows) row[0] as String: row[1]};
      expect(
        first.single.body,
        base64.decode(
          (bodies[first.single.headers['nats-msg-id']] as String).replaceAll(
            '\n',
            '',
          ),
        ),
      );
      expect(
        next.single.body,
        base64.decode(
          (bodies[next.single.headers['nats-msg-id']] as String).replaceAll(
            '\n',
            '',
          ),
        ),
      );
      final stopClock = Stopwatch()..start();
      while (true) {
        final status = await db.execute(
          "SELECT state FROM plugin_instance_status WHERE \"definitionDigest\"='$oldDigest'",
        );
        if (status.isNotEmpty && status.every((row) => row[0] == 'stopped')) {
          break;
        }
        if (stopClock.elapsed > const Duration(seconds: 90)) {
          throw StateError(
            'Old definition did not stop after its work became terminal',
          );
        }
      }
    } finally {
      await firstStream.close();
      await secondStream.close();
      await db.close();
      await setup.close();
      await second.close();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
