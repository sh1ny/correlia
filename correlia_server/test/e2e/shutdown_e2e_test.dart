@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/shared_cluster.dart';

void main() {
  test(
    'SIGTERM stops subsystems before the pool closes and exits 0',
    () async {
      final serverDir = Directory.current;
      final database = await SharedClusterDatabase.create(serverDir);
      ChildServer? child;
      try {
        child = await ChildServer.startOnSharedCluster(
          serverDir: serverDir,
          database: database,
          environment: {'CORRELIA_TEST_STOP_PROBE': '1'},
        );
        await child.waitUntilReady();

        expect(await child.stop(), 0, reason: child.output);
        final lines = child.output.split('\n');
        int indexOf(Pattern pattern) =>
            lines.indexWhere((line) => line.contains(pattern));

        final probeStopped = indexOf('Stopped test-stop-hooks');
        final consoleStopped = indexOf('Stopped console');
        final probed = indexOf('test probe: ${database.name} ');
        final completed = indexOf('SERVERPOD shutdown completed');
        expect(
          [probed, probeStopped, consoleStopped, completed],
          everyElement(isNonNegative),
          reason: child.output,
        );
        expect(
          probed,
          lessThan(probeStopped),
          reason: 'the query ran while the subsystem was stopping',
        );
        expect(
          probeStopped,
          lessThan(consoleStopped),
          reason: 'subsystems stop in reverse start order',
        );
        expect(
          consoleStopped,
          lessThan(completed),
          reason: 'subsystems stopped before shutdown completed',
        );
        expect(
          lines[probed],
          contains(p.join(serverDir.path, '.serverpod', 'test', 'pgdata')),
          reason: 'the child used the shared cluster, not its own',
        );
        expect(child.output, isNot(contains('test probe failed')));
      } finally {
        if (child != null && !child.hasExited) await child.closeStdin();
        await database.drop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
