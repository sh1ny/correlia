import 'dart:async';
import 'dart:io';

import 'src/generated/serverpod.dart';
import 'src/runtime/process_options.dart';
import 'src/runtime/console_subsystem.dart';
import 'src/runtime/registry.dart';
import 'src/runtime/role_runtime.dart';
import 'src/runtime/serverpod_adapter.dart';
import 'src/runtime/startup_state.dart';
import 'src/runtime/test_mode_switches.dart';
import 'src/runtime/test_stop_hooks.dart';

/// How long to wait for the root lock when the harness gave no deadline.
const Duration _defaultRootLockTimeout = Duration(seconds: 60);

/// The Correlia entry point.
///
/// Exit codes: 2 for a rejected command line, 1 for a failed start, a failed
/// root lock or a failed shutdown, 0 for a clean SIGTERM.
Future<void> run(List<String> args) async {
  final environment = Platform.environment;
  final options = switch (ProcessOptions.parse(
    args,
    environment: environment,
  )) {
    final ProcessOptionsError error => _exitWith(error.message, error.exitCode),
    final ProcessOptions options => options,
  };
  void log(String line) => stderr.writeln('[correlia] $line');
  log('Run mode: ${options.runMode}; process role: ${options.role.name}');

  final switches = TestModeSwitches.fromEnvironment(
    options.runMode,
    environment,
  );
  if (switches.rootLock case final String lockPath) {
    log('Waiting for root lock $lockPath');
    try {
      await acquireRootLock(
        lockPath,
        switches.rootLockTimeout ?? _defaultRootLockTimeout,
      );
    } on RootLockTimeout catch (e) {
      _exitWith('$e', ExitCodes.failure);
    }
    log('Acquired root lock $lockPath');
  }

  final startup = StartupState();
  final pod = Serverpod(
    options.serverpodArgs,
    healthConfig: HealthConfig(
      additionalStartupIndicators: [CorreliaStartupIndicator(startup)],
    ),
  );

  if (switches.exitOnStdinClose) {
    watchStdinForEof(stdin, () => pod.shutdown());
  }

  final runtime = RoleRuntime(
    role: options.role,
    registry: [
      ...buildSubsystemRegistry(),
      ConsoleSubsystem.forRunMode(options.runMode, environment, log: log),
      if (switches.stopProbe || switches.stopGate != null)
        _testStopHooks(switches, pod, log),
    ],
    port: ServerpodAdapter(pod),
    startup: startup,
    log: log,
  );

  switch (await runtime.start()) {
    case Started():
      break;
    case final StartFailed failed:
      stderr.writeln(failed.message);
      stderr.writeln(failed.stackTrace);
      try {
        await pod.shutdown(exitProcess: false);
      } catch (e) {
        stderr.writeln('Shutdown after failed start also failed: $e');
      }
      await stderr.flush();
      exit(failed.exitCode);
  }
}

/// The end-to-end test hooks, built only from [switches] that are set (run
/// mode `test` only). Registered last, so they stop first.
TestStopHooks _testStopHooks(
  TestModeSwitches switches,
  Serverpod pod,
  void Function(String line) log,
) => TestStopHooks(
  log: log,
  awaitGate: switch (switches.stopGate) {
    final String gate => () async {
      final file = await File(gate).open(mode: FileMode.write);
      try {
        await file.lock(FileLock.blockingExclusive);
      } finally {
        await file.close();
      }
    },
    null => null,
  },
  probe: switches.stopProbe
      ? () async {
          final session = await pod.createSession(enableLogging: false);
          try {
            final result = await session.db.unsafeQuery(
              "SELECT current_database(), current_setting('data_directory')",
            );
            return result.first.join(' ');
          } finally {
            await session.close();
          }
        }
      : null,
);

Never _exitWith(String message, int code) {
  stderr.writeln(message);
  exit(code);
}
