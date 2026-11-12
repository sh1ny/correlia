@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_client/correlia_client.dart';
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/output_process.dart';

Future<void> _post(ChildServer child, String name) async {
  final http = HttpClient();
  try {
    final request = await http.postUrl(
      Uri.parse(
        'http://127.0.0.1:${child.webPort}/hooks/alertmanager/$outputSource',
      ),
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

void main() {
  test(
    'local_development_access',
    () => withOutputProcess((db, env, receiver, children) async {
      receiver.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 204;
        await request.response.close();
      });
      final child = await startOutputChild(db, env, children);
      final client = Client('http://127.0.0.1:${child.apiPort}/');
      try {
        final snapshot = await client.alertConsole.snapshot();
        final wake = client.alertConsole.wakeUps().first;
        await _post(child, 'live');
        await wake.timeout(const Duration(seconds: 30));
        final page = await client.alertConsole.feed(snapshot.cursor, 100);
        expect(page.alerts.single.summary, 'live');
        expect(page.alerts.single.status, 'firing');
        expect(page.entries.single.entityId, page.alerts.single.id);
        expect(page.entries.single.changeKind, 'created');
      } finally {
        client.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'stream_dropped_and_resumed',
    () => withOutputProcess((db, env, receiver, children) async {
      final delivered = Completer<void>();
      var count = 0;
      receiver.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 204;
        await request.response.close();
        if (++count == 3) delivered.complete();
      });
      final child = await startOutputChild(db, env, children);
      final client = Client('http://127.0.0.1:${child.apiPort}/');
      final initialCursor = (await client.alertConsole.snapshot()).cursor;
      final firstWake = Completer<void>();
      final subscription = client.alertConsole.wakeUps().listen((_) {
        if (!firstWake.isCompleted) firstWake.complete();
      });
      await _post(child, 'initial');
      await firstWake.future.timeout(const Duration(seconds: 30));
      final initialPage = await client.alertConsole.feed(initialCursor, 100);
      expect(initialPage.entries, hasLength(1));
      final cursor = initialPage.nextCursor;
      await subscription.cancel();
      await _post(child, 'one');
      await _post(child, 'two');
      await delivered.future.timeout(const Duration(seconds: 30));
      final resumed = client.alertConsole.wakeUps().listen((_) {});
      try {
        final page = await client.alertConsole.feed(cursor, 100);
        expect(page.entries, hasLength(2));
        expect(
          page.alerts.map((alert) => alert.summary),
          unorderedEquals(['one', 'two']),
        );
        expect(
          (await client.alertConsole.feed(page.nextCursor, 100)).entries,
          isEmpty,
        );
      } finally {
        await resumed.cancel();
        client.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'worker_role_refuses',
    () => withOutputProcess((db, env, receiver, children) async {
      final child = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: db,
        args: [
          '--mode',
          'test',
          '--apply-migrations',
          '--process-role',
          'worker',
        ],
        environment: {
          'CORRELIA_INGEST_CONFIG': env['CORRELIA_INGEST_CONFIG']!,
          'CORRELIA_INGEST_SECRETS': env['CORRELIA_INGEST_SECRETS']!,
        },
      );
      children.add(child);
      await child.waitUntilReady();
      final client = Client('http://127.0.0.1:${child.apiPort}/');
      try {
        await expectLater(
          client.alertConsole.snapshot(),
          throwsA(isA<ConsoleAccessDeniedException>()),
        );
      } finally {
        client.close();
      }
    }),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
