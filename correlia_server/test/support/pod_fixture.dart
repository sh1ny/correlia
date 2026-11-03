import 'dart:io';

import 'package:correlia_server/src/generated/serverpod.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:correlia_server/src/runtime/role_runtime.dart';
import 'package:correlia_server/src/runtime/serverpod_adapter.dart';
import 'package:correlia_server/src/runtime/startup_state.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod_test/serverpod_test.dart'
    show EphemeralTestDatabase, TestDatabaseManager;

/// An in-process Serverpod in run mode `test` with a [RoleRuntime] over fake
/// subsystems, on the shared test cluster.
///
/// Each fixture gets its own empty database on the shared test cluster (the
/// way `withServerpod` does), migrated at start, so fixtures in parallel test
/// files never touch one another. Every port is 0 in `config/test.yaml`; the
/// API port is read back from [apiPort] once the server has started.
final class PodFixture {
  PodFixture._(this.pod, this.runtime, this.startup, this.logs, this._database);

  /// Builds the server and the runtime without starting either.
  static Future<PodFixture> create(List<Subsystem> subsystems) async {
    final databaseName = TestDatabaseManager.generateDatabaseName();
    final database = await EphemeralTestDatabase.create(
      runMode: 'test',
      databaseName: databaseName,
      serverDirectory: Directory.current,
    );
    final startup = StartupState();
    final logs = <String>[];
    final pod = Serverpod(
      const ['--mode', 'test', '--apply-migrations'],
      configOverride: (config) => switch (config.database) {
        final PostgresDatabaseConfig db => config.copyWith(
          database: db.withName(databaseName),
        ),
        _ => config,
      },
      healthConfig: HealthConfig(
        // No caching, so a probe right after a state change sees the change.
        cacheTtl: Duration.zero,
        additionalStartupIndicators: [CorreliaStartupIndicator(startup)],
      ),
    );
    final runtime = RoleRuntime(
      role: role,
      registry: subsystems,
      port: _InProcessPort(ServerpodAdapter(pod), pod),
      startup: startup,
      log: logs.add,
    );
    return PodFixture._(pod, runtime, startup, logs, database);
  }

  /// The role used by every fixture.
  static const ProcessRole role = ProcessRole.all;

  /// The server.
  final Serverpod pod;

  /// The runtime under test.
  final RoleRuntime runtime;

  /// The startup state behind `/startupz`.
  final StartupState startup;

  /// Lines logged by the runtime.
  final List<String> logs;

  final EphemeralTestDatabase? _database;
  bool _shutDown = false;

  /// The bound port of the API server (valid once Serverpod has started).
  int get apiPort => pod.server.port;

  /// Starts the runtime.
  Future<StartResult> start() => runtime.start();

  /// Shuts the server down without exiting the process and drops the
  /// fixture's database; a second call does nothing. A failed shutdown is
  /// rethrown after the database is dropped.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    try {
      await pod.shutdown(exitProcess: false);
    } finally {
      await _database?.drop();
    }
  }
}

/// The real adapter, except that Serverpod starts in the caller's error zone:
/// a failed start throws instead of exiting the test process.
final class _InProcessPort implements ServerpodPort {
  _InProcessPort(this._adapter, this._pod);

  final ServerpodAdapter _adapter;
  final Serverpod _pod;

  @override
  void mountRoutes(Subsystem subsystem) => _adapter.mountRoutes(subsystem);

  @override
  Future<void> start() => _pod.start(runInGuardedZone: false);

  @override
  void addShutdownTask(Future<void> Function() task) =>
      _adapter.addShutdownTask(task);
}
