@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/decoy.dart';

/// How long to wait for a child to notice that its harness died and exit.
const _exitDeadline = Duration(seconds: 60);

/// A harness process (`test/support/interrupted_harness.dart`) and the pid of
/// the child server it started.
final class _Harness {
  _Harness(this.process, this.childPid, this.lines);

  final Process process;
  final int childPid;
  final List<String> lines;
}

Future<_Harness> _startHarness(
  Directory serverDir,
  String testId,
  String mode,
) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    p.join('test', 'support', 'interrupted_harness.dart'),
    testId,
    mode,
  ], workingDirectory: serverDir.path);
  final lines = <String>[];
  final childLine = Completer<int>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (
      line,
    ) {
      lines.add(line);
      if (line.startsWith('CHILD ') && !childLine.isCompleted) {
        childLine.complete(int.parse(line.substring(6)));
      }
    },
  );
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        lines.add,
      );
  unawaited(
    process.exitCode.then((code) {
      if (!childLine.isCompleted) {
        childLine.completeError(
          StateError('harness exited $code early:\n${lines.join('\n')}'),
        );
      }
    }),
  );
  final childPid = await childLine.future.timeout(
    const Duration(seconds: 90),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      throw StateError('harness never reported a child:\n${lines.join('\n')}');
    },
  );
  return _Harness(process, childPid, lines);
}

/// Whether [pid] is a live server VM (a zombie or a reused pid is not).
bool _isServerRunning(int pid) {
  try {
    final stat = File('/proc/$pid/stat').readAsStringSync();
    // "pid (comm) S ...": the state follows the last closing parenthesis.
    final state = stat.substring(stat.lastIndexOf(')') + 2).split(' ').first;
    if (state == 'Z' || state == 'X') return false;
    final commandLine = File('/proc/$pid/cmdline').readAsStringSync();
    return commandLine.contains('bin/main.dart');
  } on FileSystemException {
    return false;
  }
}

Future<void> _waitForChildExit(int pid, String pgdata) async {
  final deadline = DateTime.now().add(_exitDeadline);
  while (_isServerRunning(pid) || processesNaming(pgdata).isNotEmpty) {
    if (!DateTime.now().isBefore(deadline)) {
      fail(
        'child $pid or a process naming $pgdata still runs '
        '$_exitDeadline after its harness was killed: '
        '${processesNaming(pgdata)}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  test(
    'killing only the harness twice leaves no child, no cluster process, '
    'no extra root, and leaves an outside decoy untouched',
    () async {
      final serverDir = Directory.current;
      final decoyDir = await Directory.systemTemp.createTemp('correlia-decoy-');
      final decoy = await Decoy.start(decoyDir);
      addTearDown(() async {
        await decoy.stop();
        await decoyDir.delete(recursive: true);
      });
      expect(p.isWithin(serverDir.path, decoyDir.path), isFalse);
      Future<void> expectDecoyUntouched(String when) async {
        expect(await decoy.ping(), 0, reason: '$when: accepted connections');
        expect(decoy.exited, isFalse, reason: '$when: the decoy runs');
        expect(File(decoy.socketPath).existsSync(), isTrue, reason: when);
      }

      final root = E2eRoot(serverDir, 'interrupted-run');
      final e2eRoots = Directory(p.dirname(root.dir.path));
      List<String> rootsOfThisTest() => e2eRoots.existsSync()
          ? [
              for (final e in e2eRoots.listSync())
                if (p.basename(e.path).startsWith('interrupted-run'))
                  p.basename(e.path),
            ]
          : [];

      // The harness is killed with SIGKILL, twice, in the same stable root.
      for (final attempt in [1, 2]) {
        final harness = await _startHarness(
          serverDir,
          'interrupted-run',
          'hold',
        );
        expect(
          processesNaming(root.pgdata),
          isNotEmpty,
          reason: 'attempt $attempt: its own postmaster is running',
        );
        harness.process.kill(ProcessSignal.sigkill);
        expect(await harness.process.exitCode, -9);

        await _waitForChildExit(harness.childPid, root.pgdata);
        expect(
          rootsOfThisTest(),
          ['interrupted-run'],
          reason: 'attempt $attempt: the stable root is left, and only it',
        );
        await expectDecoyUntouched('after killed attempt $attempt');
      }

      // The third run completes: graceful stop, root deleted.
      final complete = await _startHarness(
        serverDir,
        'interrupted-run',
        'complete',
      );
      expect(
        await complete.process.exitCode.timeout(const Duration(seconds: 60)),
        0,
        reason: complete.lines.join('\n'),
      );
      expect(_isServerRunning(complete.childPid), isFalse);
      expect(processesNaming(root.pgdata), isEmpty);
      expect(rootsOfThisTest(), isEmpty);
      await expectDecoyUntouched('after the completed run');
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
