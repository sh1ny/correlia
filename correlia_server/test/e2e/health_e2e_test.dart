@Tags(['e2e'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/shared_cluster.dart';

const _timeout = Timeout(Duration(minutes: 4));

void main() {
  final serverDir = Directory.current;

  test('livez readyz startupz answer 200 in each role', () async {
    final roles = ['api', 'worker', 'all'];
    final roots = {for (final r in roles) r: E2eRoot(serverDir, 'health-$r')};
    final children = <ChildServer>[];
    try {
      // The three roles run side by side, each in its own root.
      children.addAll(
        await Future.wait([
          for (final role in roles)
            ChildServer.start(
              serverDir: serverDir,
              root: roots[role]!.dir,
              args: [
                '--mode',
                'test',
                '--apply-migrations',
                '--process-role',
                role,
              ],
            ),
        ]),
      );
      await Future.wait([for (final c in children) c.waitUntilReady()]);

      for (final (index, role) in roles.indexed) {
        final child = children[index];
        for (final path in ['/livez', '/readyz', '/startupz']) {
          expect(
            await child.statusOf(path),
            200,
            reason: '$path in role $role. Output:\n${child.output}',
          );
        }
      }
    } finally {
      for (final child in children) {
        await tearDownChildren([child]);
      }
      for (final root in roots.values) {
        root.deleteAfterExit();
      }
    }
  }, timeout: _timeout);

  test('readyz 503 and livez 200 when the database stops', () async {
    // The child uses an ephemeral database on the shared test cluster, so
    // that dropping it (WITH (FORCE), which also ends the child's
    // connections) is the database going away; no PostgreSQL process is
    // signalled or stopped.
    final database = await SharedClusterDatabase.create(serverDir);
    ChildServer? child;
    try {
      child = await ChildServer.startOnSharedCluster(
        serverDir: serverDir,
        database: database,
      );
      await child.waitUntilReady();
      expect(await child.statusOf('/readyz'), 200, reason: child.output);

      await database.drop();

      final deadline = DateTime.now().add(const Duration(seconds: 30));
      int? readyz;
      while (DateTime.now().isBefore(deadline)) {
        readyz = await child.statusOf('/readyz');
        if (readyz == 503) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(readyz, 503, reason: 'readyz after the drop. ${child.output}');
      expect(await child.statusOf('/livez'), 200);
    } finally {
      if (child != null && !child.hasExited) {
        await child.closeStdin();
      }
      await database.drop();
    }
  }, timeout: _timeout);
}
