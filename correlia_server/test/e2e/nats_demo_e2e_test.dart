@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_client/correlia_client.dart';
import 'package:test/test.dart';

import '../plugin/support/plugin_process_identity.dart';
import '../support/nats_process.dart';
import '../support/output_process.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as fixture;

void main() {
  test('Alertmanager fixture reaches the feed and natsdev subscriber', () async {
    final setup = await NatsProcessFixture.start();
    Process? subscriber;
    PluginProcessIdentity? identity;
    StreamIterator<String>? lines;
    Future<void>? stderrDone;
    Client? client;
    try {
      subscriber = await Process.start(
        '${Directory.current.parent.path}/build/plugins/natsdev',
        ['sub', '--url', setup.nats.url.toString()],
      );
      identity = PluginProcessIdentity.read(subscriber.pid);
      if (identity == null) {
        throw StateError('Subscriber exited before identification');
      }
      stderrDone = subscriber.stderr.drain<void>();
      lines = StreamIterator(
        subscriber.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      if (!await lines.moveNext().timeout(const Duration(seconds: 15)) ||
          lines.current != 'ready') {
        throw StateError('NATS subscriber did not become ready');
      }
      final child = await setup.startChild();
      client = Client('http://127.0.0.1:${child.apiPort}/');
      final snapshot = await client.alertConsole.snapshot();
      final wake = client.alertConsole.wakeUps().first;
      final body = fixture.groupOf([
        fixture.alert(
          labels: {'alertname': 'DemoNatsAlert', 'severity': 'warning'},
          annotations: {'summary': 'Demo NATS alert'},
          startsAt: DateTime.now().toUtc().toIso8601String(),
        ),
      ]);
      final http = HttpClient();
      try {
        final request = await http.postUrl(
          Uri.parse(
            'http://127.0.0.1:${child.webPort}/hooks/alertmanager/$outputSource',
          ),
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('Authorization', 'Bearer $outputToken');
        request.write(jsonEncode(body));
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 202);
      } finally {
        http.close(force: true);
      }
      await wake.timeout(const Duration(seconds: 30));
      final page = await client.alertConsole.feed(snapshot.cursor, 100);
      expect(page.alerts, hasLength(1));
      expect(page.alerts.single.summary, 'Demo NATS alert');
      expect(page.alerts.single.status, 'firing');
      if (!await lines.moveNext().timeout(const Duration(seconds: 30))) {
        throw StateError('Subscriber exited before the alert was delivered');
      }
      final line = lines.current;
      final space = line.indexOf(' ');
      expect(space, greaterThan(0));
      expect(line.substring(0, space), startsWith('correlia.v1.ev.'));
      final event =
          jsonDecode(line.substring(space + 1)) as Map<String, Object?>;
      expect(event['id'], isA<String>());
      expect(jsonEncode(event), contains('DemoNatsAlert'));
      stdout.writeln(
        'Demo CLI: mise run nats:dev; mise run nats:stream -- --url ${setup.nats.url}; mise run run; mise run nats:sub -- --url ${setup.nats.url}',
      );
    } finally {
      client?.close();
      if (identity != null) {
        identity.signalIfExact(ProcessSignal.sigterm);
      } else {
        subscriber?.kill(ProcessSignal.sigkill);
      }
      if (subscriber != null) await subscriber.exitCode;
      await lines?.cancel();
      await stderrDone;
      await setup.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
