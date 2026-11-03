import 'dart:async';
import 'dart:io';

import 'package:correlia_server/src/runtime/test_mode_switches.dart';
import 'package:test/test.dart';

const _env = {
  'CORRELIA_TEST_CONSOLE_DIR': '/tmp/console',
  'CORRELIA_EXIT_ON_STDIN_CLOSE': '1',
  'CORRELIA_TEST_ROOT_LOCK': '/tmp/root/owner.lock',
  'CORRELIA_TEST_ROOT_LOCK_TIMEOUT': '30',
  'CORRELIA_TEST_STOP_PROBE': '1',
  'CORRELIA_TEST_STOP_GATE': '/tmp/root/stop.gate',
};

void main() {
  group('TestModeSwitches', () {
    for (final mode in ['development', 'staging', 'production']) {
      test('are ignored in run mode $mode', () {
        final switches = TestModeSwitches.fromEnvironment(mode, _env);
        expect(switches.consoleDir, isNull);
        expect(switches.exitOnStdinClose, isFalse);
        expect(switches.rootLock, isNull);
        expect(switches.stopProbe, isFalse);
        expect(switches.stopGate, isNull);
      });
    }

    test('are read in run mode test', () {
      final switches = TestModeSwitches.fromEnvironment('test', _env);
      expect(switches.consoleDir, '/tmp/console');
      expect(switches.exitOnStdinClose, isTrue);
      expect(switches.rootLock, '/tmp/root/owner.lock');
      expect(switches.rootLockTimeout, const Duration(seconds: 30));
      expect(switches.stopProbe, isTrue);
      expect(switches.stopGate, '/tmp/root/stop.gate');
    });

    test('stop probe needs the value 1', () {
      final switches = TestModeSwitches.fromEnvironment('test', {
        'CORRELIA_TEST_STOP_PROBE': 'true',
      });
      expect(switches.stopProbe, isFalse);
    });

    test('exit on stdin close needs the value 1', () {
      final switches = TestModeSwitches.fromEnvironment('test', {
        'CORRELIA_EXIT_ON_STDIN_CLOSE': '0',
      });
      expect(switches.exitOnStdinClose, isFalse);
    });
  });

  test('watchStdin runs the shutdown once on end of file', () async {
    final controller = StreamController<List<int>>();
    final done = Completer<void>();
    var calls = 0;
    watchStdinForEof(controller.stream, () async {
      calls++;
      done.complete();
    });
    controller.add([1, 2]);
    await controller.close();
    await done.future;
    expect(calls, 1);
  });

  group('acquireRootLock', () {
    test('holds a lock on the file', () async {
      final dir = Directory.systemTemp.createTempSync('correlia_lock_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/owner.lock';
      final held = await acquireRootLock(path, const Duration(seconds: 5));
      expect(File(path).existsSync(), isTrue);
      await held.close();
    });

    test('a timeout names the root and the lock', () async {
      final dir = Directory.systemTemp.createTempSync('correlia_lock_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final never = Completer<void>();
      await expectLater(
        acquireRootLock(
          '${dir.path}/owner.lock',
          const Duration(milliseconds: 20),
          lock: (_) => never.future,
        ),
        throwsA(
          isA<RootLockTimeout>().having(
            (e) => e.toString(),
            'message',
            allOf(contains(dir.path), contains('owner.lock')),
          ),
        ),
      );
    });
  });
}
