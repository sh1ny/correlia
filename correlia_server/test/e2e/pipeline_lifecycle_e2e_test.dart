@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/output_process.dart';
import '../support/shared_cluster.dart';

Future<ChildServer> _role(
  SharedClusterDatabase db,
  Map<String, String> env,
  List<ChildServer> children,
  String role, {
  bool configured = true,
}) async {
  final child = await ChildServer.startOnSharedCluster(
    serverDir: Directory.current,
    database: db,
    args: ['--mode', 'test', '--apply-migrations', '--process-role', role],
    environment: configured
        ? {
            'CORRELIA_INGEST_CONFIG': env['CORRELIA_INGEST_CONFIG']!,
            'CORRELIA_INGEST_SECRETS': env['CORRELIA_INGEST_SECRETS']!,
          }
        : {},
  );
  children.add(child);
  return child;
}

Future<void> _mustFailStartup(ChildServer child) async {
  final outcome = await Future.any<int>([
    child.exitCode,
    child.waitUntilReady().then((_) => -999, onError: (_) => child.exitCode),
  ]);
  expect(outcome, 1);
  expect(child.output, contains('bootstrap_required'));
}

void main() {
  test(
    'split_roles_and_restart',
    () => withOutputProcess((db, env, receiver, children) async {
      final delivered = Completer<List<int>>();
      receiver.listen((request) async {
        final bytes = await request.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        if (!delivered.isCompleted) delivered.complete(bytes);
        request.response.statusCode = 204;
        await request.response.close();
      });
      final api = await _role(db, env, children, 'api');
      await api.waitUntilReady();
      await postOutputAlert(api);
      final observer = await outputConnection(db);
      try {
        expect(
          (await observer.execute("SELECT status FROM raw_inbox")).single[0],
          'pending',
        );
        expect(await observer.execute('SELECT 1 FROM events'), isEmpty);
        expect(await api.closeStdin(), 0);
        final worker = await _role(db, env, children, 'worker');
        await worker.waitUntilReady();
        expect(
          await worker.statusOf('/hooks/alertmanager/$outputSource', web: true),
          404,
        );
        final body = await delivered.future.timeout(
          const Duration(seconds: 30),
        );
        expect(
          (await observer.execute('SELECT payload FROM outbox')).single[0],
          body,
        );
        expect(
          (await observer.execute('SELECT status FROM raw_inbox')).single[0],
          'done',
        );
        worker.kill();
        expect(await worker.exitCode, -9);
        final replacement = await _role(db, env, children, 'worker');
        await replacement.waitUntilReady();
        expect(
          (await observer.execute('SELECT count(*) FROM events')).single[0],
          1,
        );
        expect(
          (await observer.execute(
            'SELECT count(*) FROM observation_keys',
          )).single[0],
          1,
        );
      } finally {
        await observer.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'missing_config_with_durable_work',
    () => withOutputProcess((db, env, receiver, children) async {
      final api = await _role(db, env, children, 'api');
      await api.waitUntilReady();
      await postOutputAlert(api);
      expect(await api.closeStdin(), 0);
      final worker = await _role(
        db,
        env,
        children,
        'worker',
        configured: false,
      );
      await _mustFailStartup(worker);
      expect(worker.output, contains('raw=1'));
      final observer = await outputConnection(db);
      try {
        expect(
          (await observer.execute('SELECT status FROM raw_inbox')).single[0],
          'pending',
        );
      } finally {
        await observer.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'missing_worker_config_after_drained_queue',
    () => withOutputProcess((db, env, receiver, children) async {
      final api = await _role(db, env, children, 'api');
      await api.waitUntilReady();
      expect(await api.closeStdin(), 0);
      final worker = await _role(
        db,
        env,
        children,
        'worker',
        configured: false,
      );
      await _mustFailStartup(worker);
      expect(worker.output, contains('active=1,raw=0,output=0'));
    }),
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'shutdown_during_processing',
    () => withOutputProcess((db, env, receiver, children) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      receiver.listen((request) async {
        await request.drain<void>();
        if (!entered.isCompleted) entered.complete();
        await release.future;
        try {
          request.response.statusCode = 204;
          await request.response.close();
        } on HttpException {
          /* Cancellation closes the client connection. */
        } on SocketException {
          /* Cancellation closes the client connection. */
        }
      });
      final child = await startOutputChild(db, env, children);
      final observer = await outputConnection(db);
      try {
        await postOutputAlert(child);
        await entered.future.timeout(const Duration(seconds: 30));
        expect(
          (await observer.execute(
            'SELECT outcome FROM delivery_attempts',
          )).single[0],
          'started',
        );
        expect(await child.closeStdin(), 0);
        expect(
          (await observer.execute('SELECT status FROM raw_inbox')).single[0],
          'done',
        );
        expect(
          (await observer.execute('SELECT count(*) FROM events')).single[0],
          1,
        );
        expect(
          (await observer.execute('SELECT status FROM outbox')).single[0],
          'delivering',
        );
        expect(
          (await observer.execute(
            'SELECT outcome FROM delivery_attempts',
          )).single[0],
          'started',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await observer.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
