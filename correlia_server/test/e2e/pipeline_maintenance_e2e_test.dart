@Tags(['e2e'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/output_process.dart';

void main() {
  test('role_and_shutdown_wait_for_open_maintenance_batch', () async {
    await withOutputProcess((db, environment, _, children) async {
      final connection = await outputConnection(db);
      final gate = File(environment['TEST_GATE_PATH']!);
      Future<void> failBatch() async {
        final staged = await File('${gate.path}.staged').writeAsString('fail');
        await staged.rename(gate.path);
      }

      Future<ChildServer> start(String role) async {
        final child = await ChildServer.startOnSharedCluster(
          serverDir: Directory.current,
          database: db,
          args: [
            '--mode',
            'test',
            '--apply-migrations',
            '--process-role',
            role,
          ],
          vmArgs: ['--define=correlia.testHooks=true'],
          environment: {
            ...environment,
            'CORRELIA_TEST_MAINTENANCE_GATE': gate.path,
          },
        );
        children.add(child);
        await child.waitForReadyEvent();
        return child;
      }

      try {
        final api = await start('api');
        expect(api.output, isNot(contains('Started pipeline-maintenance')));
        // The API is ready and can write, but never claims a maintenance batch.
        await connection.execute('''
          INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,
            output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,
            payload,status,terminal_at)
          VALUES (clock_timestamp()-interval '15 days',gen_random_uuid(),now(),gen_random_uuid(),
            'ready','$outputId','test-pin','https://test.invalid','key','commitment',
            decode('ff','hex'),'dead',clock_timestamp()-interval '15 days')
        ''');
        expect(await api.closeStdin(), 0);
        for (final role in ['worker', 'all']) {
          final child = await start(role);
          await child.waitForOutput(RegExp('test maintenance: expiry gate'));
          final stopping = child.closeStdin();
          try {
            await child.waitForOutput(RegExp('test maintenance: stopping'));
            expect(child.hasExited, isFalse);
            expect(
              (await connection.execute('SELECT status FROM outbox')).single[0],
              'dead',
            );
          } finally {
            await failBatch();
          }
          expect(await stopping, 0, reason: child.output);
          final outcome = (await connection.execute(
            'SELECT lane,outcome,affected FROM pipeline_maintenance_outcome',
          )).single;
          expect(outcome.toList(), ['expiry', 'failed', 0]);
          expect(
            (await connection.execute('SELECT status FROM outbox')).single[0],
            'dead',
          );
          expect(
            (await connection.execute(
              "SELECT count(*) FROM activity WHERE change_kind='dead_letter_expired'",
            )).single[0],
            0,
          );
          final resumed = child.output.split('test maintenance: expiry gate');
          expect(resumed, hasLength(2));
          await gate.delete();
        }
      } finally {
        if (!gate.existsSync()) await failBatch();
        await connection.close();
      }
    });
  }, timeout: const Timeout(Duration(minutes: 6)));
}
