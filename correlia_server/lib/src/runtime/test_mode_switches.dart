import 'dart:async';
import 'dart:io';

/// Switches that exist only for the end-to-end harness and are honoured only
/// in run mode `test`; in every other run mode they are ignored.
final class TestModeSwitches {
  const TestModeSwitches._({
    this.consoleDir,
    this.exitOnStdinClose = false,
    this.rootLock,
    this.rootLockTimeout,
    this.stopProbe = false,
    this.stopGate,
  });

  /// Reads the switches from [environment] if [runMode] is `test`.
  factory TestModeSwitches.fromEnvironment(
    String runMode,
    Map<String, String> environment,
  ) {
    if (runMode != 'test') return const TestModeSwitches._();
    final timeoutSeconds = int.tryParse(
      environment['CORRELIA_TEST_ROOT_LOCK_TIMEOUT'] ?? '',
    );
    return TestModeSwitches._(
      consoleDir: environment['CORRELIA_TEST_CONSOLE_DIR'],
      exitOnStdinClose: environment['CORRELIA_EXIT_ON_STDIN_CLOSE'] == '1',
      rootLock: environment['CORRELIA_TEST_ROOT_LOCK'],
      rootLockTimeout: timeoutSeconds == null
          ? null
          : Duration(seconds: timeoutSeconds),
      stopProbe: environment['CORRELIA_TEST_STOP_PROBE'] == '1',
      stopGate: environment['CORRELIA_TEST_STOP_GATE'],
    );
  }

  /// `CORRELIA_TEST_CONSOLE_DIR`: where the console is served from.
  final String? consoleDir;

  /// `CORRELIA_EXIT_ON_STDIN_CLOSE=1`: shut down when stdin reaches EOF.
  final bool exitOnStdinClose;

  /// `CORRELIA_TEST_ROOT_LOCK`: the `<root>/owner.lock` file to lock.
  final String? rootLock;

  /// `CORRELIA_TEST_ROOT_LOCK_TIMEOUT`, in whole seconds: how long to wait
  /// for [rootLock] (the harness's readiness deadline).
  final Duration? rootLockTimeout;

  /// `CORRELIA_TEST_STOP_PROBE=1`: on stop, run a database query and log it.
  final bool stopProbe;

  /// `CORRELIA_TEST_STOP_GATE`: a file whose exclusive lock, held by the
  /// test, keeps the server in shutdown until the test releases it.
  final String? stopGate;
}

/// Runs [onEof] once when [stdin] ends, which is how a child learns that its
/// harness died: the kernel closes the pipe.
void watchStdinForEof(Stream<List<int>> stdin, Future<void> Function() onEof) {
  stdin.listen((_) {}, onDone: () => unawaited(onEof()), cancelOnError: false);
}

/// Thrown when the root lock was not obtained within the deadline.
final class RootLockTimeout implements Exception {
  /// Creates the exception for [lockPath].
  const RootLockTimeout(this.lockPath, this.timeout);

  /// The lock file.
  final String lockPath;

  /// The deadline that passed.
  final Duration timeout;

  @override
  String toString() =>
      'Could not lock $lockPath for the root '
      '${File(lockPath).parent.path} within $timeout; another server still '
      'owns that root.';
}

/// Opens [lockPath] and takes a blocking exclusive lock on it, waiting at most
/// [timeout]. The lock is held until the process exits.
///
/// Run this before Serverpod is constructed, so a replacement server cannot
/// touch a cluster an earlier server is still shutting down. [lock] is
/// injectable for tests.
Future<RandomAccessFile> acquireRootLock(
  String lockPath,
  Duration timeout, {
  Future<void> Function(RandomAccessFile file)? lock,
}) async {
  final file = await File(lockPath).open(mode: FileMode.write);
  final acquire = lock ?? (f) => f.lock(FileLock.blockingExclusive);
  try {
    await acquire(file).timeout(
      timeout,
      onTimeout: () => throw RootLockTimeout(lockPath, timeout),
    );
  } on RootLockTimeout {
    unawaited(file.close().then<void>((_) {}, onError: (Object _) {}));
    rethrow;
  }
  return file;
}
