@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../support/output_process.dart';

Future<void> _waitForGate(String path) async {
  final file = File('$path.entered');
  final events = file.parent.watch().where((event) => event.path == file.path);
  final iterator = StreamIterator(events);
  try {
    var next = iterator.moveNext();
    while (!file.existsSync() && await next) {
      next = iterator.moveNext();
    }
  } finally {
    await iterator.cancel();
  }
}

void main() {
  test(
    'dur_2_restart_after_processing_commit',
    () => withOutputProcess((db, env, receiver, children) async {
      final received = Completer<List<int>>();
      receiver.listen((request) async {
        final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        received.complete(body);
        request.response.statusCode = 204;
        await request.response.close();
      });
      final child = await startOutputChild(db, env, children, gated: true);
      await _waitForGate(
        env['TEST_GATE_PATH']!,
      ).timeout(const Duration(seconds: 30));
      final observer = await outputConnection(db);
      try {
        await observer.execute(
          '''CREATE FUNCTION test_outbox_notify() RETURNS trigger LANGUAGE plpgsql AS \$\$
        BEGIN PERFORM pg_notify('test_outbox', 'committed'); RETURN NEW; END \$\$''',
        );
        await observer.execute(
          'CREATE TRIGGER test_outbox_notify AFTER INSERT ON outbox FOR EACH ROW EXECUTE FUNCTION test_outbox_notify()',
        );
        await observer.execute('LISTEN test_outbox');
        final notification = observer.channels.all.firstWhere(
          (event) => event.channel == 'test_outbox',
        );
        await postOutputAlert(child);
        await notification.timeout(const Duration(seconds: 30));
        final rows = await observer.execute(
          "SELECT status, payload FROM outbox",
        );
        expect(rows, hasLength(1));
        expect(rows.single[0], 'queued');
        child.kill();
        expect(await child.exitCode, -9);
        await startOutputChild(db, env, children);
        expect(
          await received.future.timeout(const Duration(seconds: 30)),
          rows.single[1],
        );
      } finally {
        await observer.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'dur_3_acknowledgement_lost_before_local_commit',
    () => withOutputProcess((db, env, receiver, children) async {
      final lockConnection = await outputConnection(db);
      final observer = await outputConnection(db);
      final locked = Completer<void>();
      final release = Completer<void>();
      final first = Completer<(List<int>, String?)>();
      final second = Completer<(List<int>, String?)>();
      Future<void>? lockTask;
      var count = 0;
      receiver.listen((request) async {
        final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        final message = (bytes, request.headers.value('idempotency-key'));
        if (count++ == 0) {
          lockTask = lockConnection.runTx((tx) async {
            await tx.execute('SELECT 1 FROM outbox FOR UPDATE');
            locked.complete();
            await release.future;
          });
          await locked.future;
          request.response.statusCode = 204;
          await request.response.close();
          first.complete(message);
        } else {
          second.complete(message);
          request.response.statusCode = 204;
          await request.response.close();
        }
      });
      try {
        final child = await startOutputChild(db, env, children);
        await postOutputAlert(child);
        final original = await first.future.timeout(
          const Duration(seconds: 30),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 4));
        var waiting = false;
        while (!waiting && DateTime.now().isBefore(deadline)) {
          final rows = await observer.execute(
            "SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%UPDATE outbox%' LIMIT 1",
          );
          waiting = rows.isNotEmpty;
        }
        expect(
          waiting,
          isTrue,
          reason: 'finalization must be blocked by the receiver-held row lock',
        );
        child.kill();
        expect(await child.exitCode, -9);
        release.complete();
        await lockTask;
        await observer.execute(
          "UPDATE outbox SET lease_until=clock_timestamp()-interval '1 second' WHERE status='delivering'",
        );
        await startOutputChild(db, env, children);
        final duplicate = await second.future.timeout(
          const Duration(seconds: 30),
        );
        expect(duplicate.$1, original.$1);
        expect(duplicate.$2, original.$2);
        final attempts = await observer.execute(
          'SELECT outcome FROM delivery_attempts ORDER BY "attemptNumber"',
        );
        expect(attempts.first[0], 'interrupted');
      } finally {
        if (!release.isCompleted) release.complete();
        if (lockTask != null) await lockTask;
        await lockConnection.close();
        await observer.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
