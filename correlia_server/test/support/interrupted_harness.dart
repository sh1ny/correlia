// A stand-alone e2e harness process for `interrupted_run_e2e_test.dart`.
//
// Usage: dart test/support/interrupted_harness.dart <test-id> hold|complete
//
// Starts a real child server in the stable root of <test-id>, waits until it
// is ready, prints `CHILD <pid>` and then, in `hold` mode, waits forever so
// that the test can kill this process with SIGKILL. In `complete` mode it
// stops the child gracefully, deletes the root and exits 0.
import 'dart:async';
import 'dart:io';

import 'child_server.dart';

Future<void> main(List<String> args) async {
  final [testId, mode] = args;
  final serverDir = Directory.current;
  final root = E2eRoot(serverDir, testId);
  final child = await ChildServer.start(serverDir: serverDir, root: root.dir);
  await child.waitUntilReady();
  stdout.writeln('CHILD ${child.pid}');
  await stdout.flush();
  switch (mode) {
    case 'hold':
      await Completer<void>().future;
    case 'complete':
      final code = await child.closeStdin();
      if (code != 0) {
        stderr.writeln('child exited $code:\n${child.output}');
        exit(1);
      }
      root.deleteAfterExit();
    default:
      stderr.writeln('unknown mode $mode');
      exit(2);
  }
}
