@Tags(['e2e'])
library;

import 'package:test/test.dart';

import '../plugin/support/plugin_process_identity.dart';
import '../support/nats_process.dart';
import '../support/output_process.dart';

void main() {
  test('graceful_worker_stop', () async {
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
      final gate = '${setup.files.path}/acquire';
      final worker = await setup.startChild(
        args: const [
          '--mode',
          'test',
          '--apply-migrations',
          '--process-role',
          'worker',
        ],
        environment: {'CORRELIA_TEST_RELAY_ACQUIRE_GATE': gate},
      );
      int? statusId;
      int? pluginPid;
      final clock = Stopwatch()..start();
      while (clock.elapsed < const Duration(seconds: 60)) {
        final rows = await db.execute(
          "SELECT id,pid FROM plugin_instance_status WHERE state='ready' AND pid IS NOT NULL",
        );
        if (rows.isNotEmpty) {
          statusId = rows.single[0] as int;
          pluginPid = rows.single[1] as int;
          break;
        }
      }
      expect(pluginPid, isNotNull);
      final identity = PluginProcessIdentity.read(pluginPid!);
      expect(identity, isNotNull);
      final before = await db.execute('SELECT count(*) FROM delivery_attempts');
      expect(before.single[0], 0);
      expect(await worker.stop(), 0);
      expect(identity!.matchesCurrentProcess(), isFalse);
      final status = await db.execute(
        'SELECT state FROM plugin_instance_status WHERE id=$statusId',
      );
      expect(status.single[0], 'stopped');
      final after = await db.execute('SELECT count(*) FROM delivery_attempts');
      expect(after.single[0], before.single[0]);
    } finally {
      await db.close();
      await setup.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
