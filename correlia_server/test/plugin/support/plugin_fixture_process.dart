import 'dart:async';
import 'dart:io';

import 'plugin_fixture_suite.dart';
import 'plugin_process_identity.dart';

/// A plugin fixture process owned by one test attempt.
///
/// The object keeps stdin open for the process lifetime and records the exact
/// Linux PID and start identity before returning. Cleanup never matches a
/// process by name and never signals a reused PID.
final class PluginFixtureProcess {
  PluginFixtureProcess._(this._process, this.identity);

  /// Starts a plugin fixture from [suite].
  ///
  /// The process receives only the explicit [environment] supplied by the
  /// caller. The caller must keep [stdin] open until the process is stopped.
  static Future<PluginFixtureProcess> start({
    required PluginFixtureSuite suite,
    required PluginFixtureBinary binary,
    required List<String> arguments,
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final build = await suite.build();
    final executable = build.binaries[binary];
    if (executable == null) {
      throw StateError('$binary was not built');
    }

    final process = await Process.start(
      executable.path,
      arguments,
      workingDirectory: workingDirectory ?? suite.scratchDirectory.path,
      environment: environment ?? const <String, String>{},
      includeParentEnvironment: false,
    );
    final identity = PluginProcessIdentity.read(process.pid);
    if (identity == null) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      throw StateError('the fixture exited before its identity was captured');
    }
    final fixture = PluginFixtureProcess._(process, identity);
    suite.registerChild(fixture);
    return fixture;
  }

  final Process _process;
  bool _stopped = false;

  /// The exact identity captured immediately after process creation.
  final PluginProcessIdentity identity;

  /// The process id.
  int get pid => _process.pid;

  /// The process standard input.
  IOSink get stdin => _process.stdin;

  /// The process standard output.
  Stream<List<int>> get stdout => _process.stdout;

  /// The process standard error.
  Stream<List<int>> get stderr => _process.stderr;

  /// Completes with the process exit code.
  Future<int> get exitCode => _process.exitCode;

  /// Stops this exact process and waits for it to exit.
  ///
  /// SIGTERM is attempted first. SIGKILL is sent only while the captured
  /// start identity still owns the PID. The call is idempotent.
  Future<void> stop({
    Duration grace = const Duration(seconds: 2),
    Duration forceTimeout = const Duration(seconds: 5),
  }) async {
    if (_stopped) return;
    _stopped = true;
    if (identity.signalIfExact(ProcessSignal.sigterm)) {
      try {
        await _process.exitCode.timeout(grace);
        return;
      } on TimeoutException {
        identity.signalIfExact(ProcessSignal.sigkill);
      }
    }
    try {
      await _process.exitCode.timeout(forceTimeout);
    } on TimeoutException {
      throw StateError('fixture pid $pid did not exit after SIGKILL');
    }
  }

  /// Closes stdin, which is the host-death signal for the watched fixture.
  Future<void> closeStdin() async {
    await _process.stdin.close();
  }
}
