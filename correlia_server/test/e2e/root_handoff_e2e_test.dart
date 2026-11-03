@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/child_server.dart';

void main() {
  test(
    'a replacement waits for the root lock, then starts; at its deadline '
    'fails naming the root',
    () async {
      final serverDir = Directory.current;
      final root = E2eRoot(serverDir, 'root-handoff');
      final children = <ChildServer>[];
      final gatePath = p.join(root.dir.path, 'stop.gate');
      RandomAccessFile? gate;
      try {
        // The previous child is held in shutdown by a gate that the test
        // holds: the child's stop waits for the test's lock to be released.
        root.dir.createSync(recursive: true);
        gate = await File(gatePath).open(mode: FileMode.write);
        await gate.lock(FileLock.exclusive);

        final previous = await ChildServer.start(
          serverDir: serverDir,
          root: root.dir,
          environment: {'CORRELIA_TEST_STOP_GATE': gatePath},
        );
        children.add(previous);
        await previous.waitUntilReady();

        // Its exit deadline starts now but must cover the time this test
        // holds the gate while two replacements compile and start.
        final previousExit = previous.closeStdin(
          deadline: const Duration(minutes: 3),
        );
        await previous.waitForOutput(RegExp('test gate: waiting'));
        expect(previous.hasExited, isFalse);
        expect(root.postmasterPid.existsSync(), isTrue);

        // A replacement with a one second deadline fails naming the root,
        // and leaves the previous child's cluster alone.
        final impatient = await ChildServer.start(
          serverDir: serverDir,
          root: root.dir,
          readyTimeout: const Duration(seconds: 1),
        );
        children.add(impatient);
        expect(
          await impatient.exitCode.timeout(const Duration(seconds: 60)),
          isNonZero,
          reason: impatient.output,
        );
        expect(impatient.output, contains(root.dir.path));
        expect(impatient.output, contains('owner.lock'));
        expect(
          impatient.output,
          isNot(contains('SERVERPOD version')),
          reason: 'it never reached Serverpod, so never touched the cluster',
        );
        expect(previous.hasExited, isFalse);
        expect(root.postmasterPid.existsSync(), isTrue);
        expect(processesNaming(root.pgdata), isNotEmpty);

        // A replacement with the full deadline waits.
        final replacement = await ChildServer.start(
          serverDir: serverDir,
          root: root.dir,
        );
        children.add(replacement);
        await replacement.waitForOutput(RegExp('Waiting for root lock'));
        expect(previous.hasExited, isFalse);
        expect(replacement.output, isNot(contains('Acquired root lock')));
        expect(replacement.output, isNot(contains('SERVERPOD version')));
        expect(await replacement.statusOf('/livez'), isNull);

        // The previous child finishes shutting down; the replacement starts.
        await gate.unlock();
        expect(await previousExit, 0, reason: previous.output);
        await replacement.waitUntilReady();
        expect(previous.hasExited, isTrue);
        expect(replacement.output, contains('Acquired root lock'));
        expect(await replacement.statusOf('/readyz'), 200);
        expect(await replacement.closeStdin(), 0, reason: replacement.output);
      } finally {
        await gate?.close();
        await tearDownChildren(children, root: root);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
