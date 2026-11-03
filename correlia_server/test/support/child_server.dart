import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// How many output lines a [ChildServer] keeps for failure messages.
const int _outputLines = 200;

/// A real Correlia server process: the real entry point `bin/main.dart` in run
/// mode `test`, with its ports and its embedded Postgres data directory taken
/// from `SERVERPOD_*` environment variables (design D16).
///
/// The child is started with `dart bin/main.dart`, not `dart run`, so
/// [pid] is the server VM itself and SIGKILL reaches it. The harness keeps the
/// child's stdin open for the child's lifetime and the child exits when it
/// closes (`CORRELIA_EXIT_ON_STDIN_CLOSE`); the child also holds
/// `<root>/owner.lock` until it exits, so a replacement waits for it.
final class ChildServer {
  ChildServer._(this._process, this.apiPort, this._readyTimeout) {
    unawaited(_process.exitCode.then((_) => hasExited = true));
    for (final stream in [_process.stdout, _process.stderr]) {
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_remember);
    }
  }

  /// Starts the server in [serverDir] on the cluster [root].
  ///
  /// A fresh cluster has no tables, so migrations are applied by default.
  /// The Postgres data directory is `<root>/pgdata`, so its socket directory
  /// is `<root>/run`. [environment] is added to the child's environment.
  /// [readyTimeout] bounds [waitUntilReady] and the root lock wait.
  static Future<ChildServer> start({
    required Directory serverDir,
    required Directory root,
    List<String> args = const ['--mode', 'test', '--apply-migrations'],
    Map<String, String> environment = const {},
    Duration readyTimeout = const Duration(seconds: 60),
  }) async {
    await root.create(recursive: true);
    final apiPort = await _freePort();
    final webPort = await _freePort();
    final insightsPort = await _freePort();
    final process = await Process.start(
      Platform.resolvedExecutable,
      [p.join('bin', 'main.dart'), ...args],
      workingDirectory: serverDir.path,
      environment: {
        'SERVERPOD_API_SERVER_PORT': '$apiPort',
        'SERVERPOD_WEB_SERVER_PORT': '$webPort',
        'SERVERPOD_INSIGHTS_SERVER_PORT': '$insightsPort',
        'SERVERPOD_DATABASE_DATA_PATH': p.join(root.path, 'pgdata'),
        'CORRELIA_TEST_ROOT_LOCK': p.join(root.path, 'owner.lock'),
        'CORRELIA_TEST_ROOT_LOCK_TIMEOUT': '${readyTimeout.inSeconds}',
        'CORRELIA_EXIT_ON_STDIN_CLOSE': '1',
        ...environment,
      },
    );
    return ChildServer._(process, apiPort, readyTimeout);
  }

  /// A port that was free a moment ago: bound on 0, then released.
  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  final Process _process;
  final Duration _readyTimeout;
  final Queue<String> _output = Queue();

  /// The port of the API server (it serves the health endpoints).
  final int apiPort;

  void _remember(String line) {
    _output.addLast(line);
    if (_output.length > _outputLines) _output.removeFirst();
  }

  /// Whether the process has exited.
  bool hasExited = false;

  /// The server VM's process id.
  int get pid => _process.pid;

  /// Completes with the exit code (a negative signal number when killed).
  Future<int> get exitCode => _process.exitCode;

  /// The last [_outputLines] lines of stdout and stderr.
  String get output => _output.join('\n');

  /// GET [path] on the API port: the status code, or null if the connection
  /// failed.
  Future<int?> statusOf(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.get('localhost', apiPort, path);
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();
      return response.statusCode;
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Polls `/startupz` until it answers 200, for at most [timeout] (default:
  /// the `readyTimeout` given to [start]). Fails with the child's output if it
  /// exits first or the deadline passes.
  Future<void> waitUntilReady([Duration? timeout]) async {
    final limit = timeout ?? _readyTimeout;
    final deadline = DateTime.now().add(limit);
    var exited = false;
    unawaited(exitCode.then((_) => exited = true));
    while (!exited && DateTime.now().isBefore(deadline)) {
      if (await statusOf('/startupz') == 200) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final why = exited
        ? 'exited with ${await exitCode}'
        : 'not ready in $limit';
    throw StateError('Server (pid $pid) $why. Output:\n$output');
  }

  /// SIGKILL: the only signal the server cannot handle.
  void kill() => _process.kill(ProcessSignal.sigkill);

  /// Closes the child's stdin, which makes the server run its graceful
  /// shutdown and exit (`CORRELIA_EXIT_ON_STDIN_CLOSE`, design D16).
  ///
  /// Prefer this over [stop] when the exit code matters: with an embedded
  /// Postgres, Serverpod's Postgres supervisor handles SIGTERM itself and
  /// exits 143 instead of letting Serverpod's own shutdown finish.
  Future<int> closeStdin({
    Duration deadline = const Duration(seconds: 30),
  }) async {
    await _process.stdin.close();
    return _awaitExit(deadline, 'closing stdin');
  }

  Future<int> _awaitExit(Duration deadline, String action) => exitCode.timeout(
    deadline,
    onTimeout: () {
      kill();
      throw StateError(
        'Server (pid $pid) still running $deadline after $action. '
        'Output:\n$output',
      );
    },
  );

  /// SIGTERM, then SIGKILL if the server has not exited within [deadline].
  /// Returns the exit code.
  Future<int> stop({Duration deadline = const Duration(seconds: 30)}) async {
    _process.kill(ProcessSignal.sigterm);
    return _awaitExit(deadline, 'SIGTERM');
  }
}

/// The command lines (arguments joined by spaces) of the processes whose
/// command line contains [path]. Inspects `/proc`; signals nothing.
List<String> processesNaming(String path) {
  // Listing /proc fails when a process ends during the listing; list again.
  for (var attempt = 0; ; attempt++) {
    try {
      return _scanProc(path);
    } on FileSystemException {
      if (attempt == 9) rethrow;
    }
  }
}

List<String> _scanProc(String path) {
  final found = <String>[];
  for (final entry in Directory('/proc').listSync()) {
    if (int.tryParse(p.basename(entry.path)) == null) continue;
    try {
      final bytes = File(p.join(entry.path, 'cmdline')).readAsBytesSync();
      final commandLine = utf8
          .decode(bytes, allowMalformed: true)
          .replaceAll('\u0000', ' ');
      if (commandLine.contains(path)) found.add(commandLine.trim());
    } on FileSystemException {
      // The process ended while it was being read.
    }
  }
  return found;
}
