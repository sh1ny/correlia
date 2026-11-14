@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:test/test.dart';

import '../plugin/support/plugin_process_identity.dart';
import '../support/jetstream_inspector.dart';
import '../support/nats_marker_observer.dart';
import '../support/nats_process.dart';
import '../support/output_process.dart';

Future<void> _entered(File marker) async {
  final done = Completer<void>();
  final subscription = marker.parent.watch().listen((_) {
    if (marker.existsSync() && !done.isCompleted) done.complete();
  });
  try {
    if (!marker.existsSync()) {
      await done.future.timeout(const Duration(seconds: 30));
    }
  } finally {
    await subscription.cancel();
  }
}

void main() {
  test('DUR-3 redelivery after the acknowledgement was lost', () async {
    final setup = await NatsProcessFixture.start();
    final database = await outputConnection(setup.database);
    final stream = await JetStreamInspector.connect(setup.nats.url);
    NatsMarkerObserver? marker;
    try {
      final gate = '${setup.files.path}/complete';
      final worker = await setup.startChild(
        vmArgs: ['-Dcorrelia.testHooks=true'],
        environment: {'CORRELIA_TEST_RELAY_COMPLETION_GATE': gate},
      );
      await postOutputAlert(worker);
      await _entered(File('$gate.entered'));
      final original = (await database.execute(
        '''SELECT event_id::text,encode(payload,'base64'),
        lease_until > clock_timestamp() FROM outbox WHERE status='delivering' ''',
      )).single;
      expect(original[2], isTrue);
      final before = await stream.messages();
      expect(before, hasLength(1));
      expect(before.single.headers['nats-msg-id'], original[0]);
      expect(
        before.single.body,
        base64.decode((original[1] as String).replaceAll('\n', '')),
      );
      final status = await database.execute(
        "SELECT pid FROM plugin_instance_status WHERE state='ready' AND pid IS NOT NULL",
      );
      final identity = PluginProcessIdentity.read(status.single[0] as int);
      expect(identity, isNotNull);
      marker = NatsMarkerObserver.open(identity!);
      worker.kill();
      expect(await worker.exitCode, -9);
      await marker.waitForExitMarker();
      await database.execute(
        "UPDATE outbox SET lease_until=clock_timestamp()-interval '1 second' WHERE status='delivering'",
      );
      await setup.startChild();
      final watch = Stopwatch()..start();
      var delivered = false;
      while (watch.elapsed < const Duration(seconds: 60)) {
        final rows = await database.execute("SELECT status FROM outbox");
        if (rows.length == 1 && rows.single[0] == 'delivered') {
          delivered = true;
          break;
        }
      }
      expect(delivered, isTrue);
      final after = await stream.messages();
      expect(after, hasLength(1));
      expect(after.single.headers['nats-msg-id'], original[0]);
      expect(
        after.single.body,
        base64.decode((original[1] as String).replaceAll('\n', '')),
      );
      final attempts = await database.execute(
        'SELECT outcome FROM delivery_attempts ORDER BY "attemptNumber"',
      );
      expect(attempts.first[0], 'interrupted');
      expect(attempts.length, greaterThanOrEqualTo(2));
    } finally {
      await marker?.close();
      await stream.close();
      await database.close();
      await setup.close();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
