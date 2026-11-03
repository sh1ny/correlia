@Tags(['db'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/child_server.dart';

void main() {
  final serverDir = Directory.current;
  final root = Directory(p.join(serverDir.path, '.serverpod', 'test-kill'));
  final pgdata = p.join(root.path, 'pgdata');
  final children = <ChildServer>[];

  tearDownAll(() async {
    // A live child (a failed test) is stopped gracefully so that Serverpod
    // stops its Postgres; only a child that ignores SIGTERM is killed.
    for (final child in children.where((c) => !c.hasExited)) {
      try {
        await child.stop();
      } on StateError {
        await child.exitCode;
      }
    }
    final postmasterPid = File(p.join(pgdata, 'postmaster.pid'));
    if (postmasterPid.existsSync()) {
      fail(
        'left ${root.path} for the next run to recover: '
        '${postmasterPid.path} still exists',
      );
    }
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<ChildServer> startChild() async {
    final child = await ChildServer.start(serverDir: serverDir, root: root);
    children.add(child);
    return child;
  }

  test(
    'after SIGKILL the next run in the same root passes and leaves no postmaster',
    () async {
      final first = await startChild();
      await first.waitUntilReady();
      expect(processesNaming(pgdata), isNotEmpty, reason: 'its own postmaster');

      first.kill();
      expect(await first.exitCode, -9);
      expect(
        await first.statusOf('/startupz'),
        isNull,
        reason: 'it was the server',
      );
      expect(
        processesNaming(pgdata),
        isNotEmpty,
        reason: 'orphaned postmaster',
      );

      final second = await startChild();
      await second.waitUntilReady();
      expect(await second.statusOf('/readyz'), 200, reason: 'database healthy');
      expect(await second.closeStdin(), 0, reason: second.output);

      expect(processesNaming(pgdata), isEmpty);
    },
    // Two cold server starts, one of them recovering a cluster.
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
