@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/child_server.dart';

void main() {
  test(
    'each cluster has its own stable root, deleted after its server stopped',
    () async {
      final serverDir = Directory.current;
      final roots = [
        E2eRoot(serverDir, 'cluster-roots-a'),
        E2eRoot(serverDir, 'cluster-roots-b'),
      ];
      final children = <ChildServer>[];
      try {
        children.addAll(
          await Future.wait([
            for (final root in roots)
              ChildServer.start(serverDir: serverDir, root: root.dir),
          ]),
        );
        await Future.wait([for (final c in children) c.waitUntilReady()]);

        final sharedCluster = p.join(
          serverDir.path,
          '.serverpod',
          'test',
          'pgdata',
        );
        for (final (index, root) in roots.indexed) {
          final other = roots[1 - index];
          expect(
            p.dirname(root.dir.path),
            p.join(serverDir.path, '.serverpod', 'test-e2e'),
            reason: 'stable root of a test id, never of a run',
          );
          expect(
            Directory(p.join(root.dir.path, 'run')).existsSync(),
            isTrue,
            reason: 'socket directory is a sibling of pgdata, in the root',
          );
          expect(
            _dataDirectoryOf(root),
            root.pgdata,
            reason: "the postmaster's data directory is inside its own root",
          );
          expect(processesNaming(root.pgdata), isNotEmpty);
          expect(
            processesNaming(root.pgdata).where(
              (c) => c.contains(other.pgdata) || c.contains(sharedCluster),
            ),
            isEmpty,
            reason: 'no process names two clusters',
          );
        }

        // Stop the first server; only its root goes away.
        expect(await children[0].closeStdin(), 0, reason: children[0].output);
        roots[0].deleteAfterExit();
        expect(roots[0].dir.existsSync(), isFalse);
        expect(processesNaming(roots[0].pgdata), isEmpty);
        expect(roots[1].dir.existsSync(), isTrue);
        expect(await children[1].statusOf('/readyz'), 200);
        expect(processesNaming(roots[1].pgdata), isNotEmpty);

        expect(await children[1].closeStdin(), 0, reason: children[1].output);
        roots[1].deleteAfterExit();
        expect(roots[1].dir.existsSync(), isFalse);
        expect(processesNaming(roots[1].pgdata), isEmpty);
      } finally {
        await tearDownChildren(children);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

/// The data directory a running postmaster recorded in its `postmaster.pid`
/// (the second line). Reads the file only.
String _dataDirectoryOf(E2eRoot root) =>
    root.postmasterPid.readAsLinesSync()[1];
