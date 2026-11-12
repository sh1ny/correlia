import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'shared_cluster.dart';

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
///
/// The child's stdout and stderr go to a log file, not to pipes of the
/// harness: if the harness died, a pipe to it would be broken, and writing to
/// a broken pipe kills the child during its graceful shutdown, before its
/// embedded Postgres is stopped (found while writing the interrupted-run
/// test). The harness follows the file and keeps the last 200 lines.
final class ChildServer {
  ChildServer._(
    this._process,
    this.apiPort,
    this.webPort,
    this._readyTimeout,
    this._log,
    this._deleteLogDirectory,
  ) {
    unawaited(_process.stdout.drain<void>());
    unawaited(_process.stderr.drain<void>());
    _tail = _LogTail(_log, _remember)..start();
    exitCode = _process.exitCode.then((code) {
      _tail.finish();
      hasExited = true;
      _deleteLogDirectory?.deleteSync(recursive: true);
      return code;
    });
  }

  /// Starts the server in [serverDir] on the cluster [root].
  ///
  /// A fresh cluster has no tables, so migrations are applied by default.
  /// The Postgres data directory is `<root>/pgdata`, so its socket directory
  /// is `<root>/run`, and the child holds `<root>/owner.lock` until it exits.
  /// [environment] is added to the child's environment. [readyTimeout] bounds
  /// [waitUntilReady] and, in whole seconds, the root lock wait.
  static Future<ChildServer> start({
    required Directory serverDir,
    required Directory root,
    List<String> args = const ['--mode', 'test', '--apply-migrations'],
    Map<String, String> environment = const {},
    List<String> vmArgs = const [],
    Duration readyTimeout = const Duration(seconds: 60),
  }) {
    root.createSync(recursive: true);
    return _spawn(
      serverDir: serverDir,
      args: args,
      vmArgs: vmArgs,
      readyTimeout: readyTimeout,
      logs: Directory(p.join(root.path, 'logs')),
      environment: {
        'SERVERPOD_DATABASE_DATA_PATH': p.join(root.path, 'pgdata'),
        'CORRELIA_TEST_ROOT_LOCK': p.join(root.path, 'owner.lock'),
        'CORRELIA_TEST_ROOT_LOCK_TIMEOUT': '${readyTimeout.inSeconds}',
        ...environment,
      },
    );
  }

  /// Starts the server on [database], an empty database on the shared test
  /// cluster, with no `dataPath`: the child starts no embedded Postgres, so
  /// it installs no SIGTERM hook of Serverpod's Postgres supervisor and exits
  /// 0 on SIGTERM (design D7). It owns no cluster root, so it takes no root
  /// lock.
  static Future<ChildServer> startOnSharedCluster({
    required Directory serverDir,
    required SharedClusterDatabase database,
    List<String> args = const ['--mode', 'test', '--apply-migrations'],
    Map<String, String> environment = const {},
    List<String> vmArgs = const [],
    Duration readyTimeout = const Duration(seconds: 60),
  }) => _spawn(
    serverDir: serverDir,
    args: args,
    vmArgs: vmArgs,
    readyTimeout: readyTimeout,
    environment: {...database.environment, ...environment},
  );

  static Future<ChildServer> _spawn({
    required Directory serverDir,
    required List<String> args,
    required List<String> vmArgs,
    required Duration readyTimeout,
    required Map<String, String> environment,
    Directory? logs,
  }) async {
    final apiPort = await _freePort();
    final webPort = await _freePort();
    final insightsPort = await _freePort();
    final logDirectory = logs ?? Directory.systemTemp.createTempSync('child_');
    logDirectory.createSync(recursive: true);
    final log = File(
      p.join(
        logDirectory.path,
        'child-${_logCounter++}-${DateTime.now().microsecondsSinceEpoch}.log',
      ),
    )..createSync();
    final process = await Process.start(
      '/bin/sh',
      [
        '-c',
        // exec: the shell becomes the server VM, so [pid] is the server.
        r'log=$1; shift; exec "$@" >"$log" 2>&1',
        'sh',
        log.path,
        Platform.resolvedExecutable,
        ...vmArgs,
        p.join('bin', 'main.dart'),
        ...args,
      ],
      workingDirectory: serverDir.path,
      environment: {
        'SERVERPOD_API_SERVER_PORT': '$apiPort',
        'SERVERPOD_WEB_SERVER_PORT': '$webPort',
        'SERVERPOD_INSIGHTS_SERVER_PORT': '$insightsPort',
        'CORRELIA_EXIT_ON_STDIN_CLOSE': '1',
        ...environment,
      },
    );
    return ChildServer._(
      process,
      apiPort,
      webPort,
      readyTimeout,
      log,
      logs == null ? logDirectory : null,
    );
  }

  /// A port that was free a moment ago: bound on 0, then released. Design
  /// Open Questions settled this way: parsing the child's log for the bound
  /// port would couple the harness to Serverpod's log format and could not
  /// supply the API port that `/startupz` polling needs before any log line.
  static int _logCounter = 0;

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  final Process _process;
  final File _log;
  final Directory? _deleteLogDirectory;
  late final _LogTail _tail;
  final Duration _readyTimeout;
  final Queue<String> _output = Queue();

  /// The port of the API server (it serves the health endpoints).
  final int apiPort;

  /// The port of the web server (it serves the console).
  final int webPort;

  final List<(RegExp, Completer<void>)> _waiters = [];

  void _remember(String line) {
    _output.addLast(line);
    if (_output.length > _outputLines) _output.removeFirst();
    _waiters.removeWhere((waiter) {
      final (pattern, done) = waiter;
      if (!pattern.hasMatch(line)) return false;
      done.complete();
      return true;
    });
  }

  /// Completes when a line of output matches [pattern] (also if one already
  /// has), or fails with the output if the child exits first or [timeout]
  /// passes. Event driven: no polling.
  Future<void> waitForOutput(
    RegExp pattern, {
    Duration timeout = const Duration(seconds: 60),
  }) {
    if (_output.any(pattern.hasMatch)) return Future.value();
    final done = Completer<void>();
    _waiters.add((pattern, done));
    unawaited(
      exitCode.then((code) {
        if (!done.isCompleted) {
          done.completeError(
            StateError(
              'Server (pid $pid) exited with $code before printing '
              '$pattern. Output:\n$output',
            ),
          );
        }
      }),
    );
    return done.future.timeout(
      timeout,
      onTimeout: () => throw StateError(
        'Server (pid $pid) printed no $pattern within $timeout. '
        'Output:\n$output',
      ),
    );
  }

  /// Whether the process has exited.
  bool hasExited = false;

  /// The server VM's process id.
  int get pid => _process.pid;

  /// Completes with the exit code (a negative signal number when killed),
  /// after the last line of output has been read.
  late final Future<int> exitCode;

  /// The last [_outputLines] lines of stdout and stderr.
  String get output => _output.join('\n');

  /// GET [path] on the API port (the web port if [web]): the status code, or
  /// null if the connection failed.
  Future<int?> statusOf(String path, {bool web = false}) async =>
      (await fetch(path, web: web))?.status;

  /// GET [path] on the API port (the web port if [web]): the status and the
  /// body, or null if the connection failed.
  Future<({int status, String body})?> fetch(
    String path, {
    bool web = false,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.get(
        'localhost',
        web ? webPort : apiPort,
        path,
      );
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final body = await response.transform(utf8.decoder).join();
      return (status: response.statusCode, body: body);
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
    try {
      await _process.stdin.close();
    } on Object {
      // The child already exited, or closed its end; the exit code says which.
    }
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

/// The stable cluster root of one e2e test: `.serverpod/test-e2e/<test-id>/`
/// (design D8). The id is fixed per test, never per run, so a run killed
/// before teardown leaves a root that the next run of the same test reuses and
/// Serverpod's data-directory recovery repairs.
final class E2eRoot {
  /// The root of the test named [testId] under [serverDir].
  E2eRoot(Directory serverDir, this.testId)
    : dir = Directory(
        p.join(serverDir.absolute.path, '.serverpod', 'test-e2e', testId),
      );

  /// The fixed test id (a directory name).
  final String testId;

  /// The root directory.
  final Directory dir;

  /// `<root>/pgdata`, what `SERVERPOD_DATABASE_DATA_PATH` names.
  String get pgdata => p.join(dir.path, 'pgdata');

  /// `<root>/pgdata/postmaster.pid`.
  File get postmasterPid => File(p.join(pgdata, 'postmaster.pid'));

  /// Deletes the root, which the caller has seen its child exit from. If
  /// `postmaster.pid` still exists the root is left for the next run's
  /// recovery and this throws.
  void deleteAfterExit() {
    if (postmasterPid.existsSync()) {
      throw StateError(
        'left ${dir.path} for the next run to recover: '
        '${postmasterPid.path} still exists',
      );
    }
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// Test teardown: stops every child still running through stdin end-of-file
/// (so Serverpod stops its own Postgres), SIGKILL after [deadline], then
/// deletes [root] if given and safe.
Future<void> tearDownChildren(
  Iterable<ChildServer> children, {
  E2eRoot? root,
  Duration deadline = const Duration(seconds: 30),
}) async {
  Object? failure;
  for (final child in children.where((c) => !c.hasExited)) {
    try {
      await child.closeStdin(deadline: deadline);
    } on Object catch (e) {
      failure ??= e;
      await child.exitCode;
    }
  }
  root?.deleteAfterExit();
  if (failure != null) throw failure;
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

/// Follows a growing log file and reports each complete line, driven by file
/// system events (inotify), not by a timer.
final class _LogTail {
  _LogTail(this._file, this._onLine);

  final File _file;
  final void Function(String line) _onLine;
  final List<int> _pending = [];
  int _offset = 0;
  StreamSubscription<FileSystemEvent>? _subscription;

  void start() {
    _subscription = _file
        .watch(events: FileSystemEvent.modify)
        .listen((_) => _drain());
    _drain();
  }

  /// Reads what the child wrote since the last read, then stops following.
  void finish() {
    unawaited(_subscription?.cancel());
    _drain();
    if (_pending.isNotEmpty) {
      _onLine(utf8.decode(_pending, allowMalformed: true));
      _pending.clear();
    }
  }

  void _drain() {
    if (!_file.existsSync()) return;
    final reader = _file.openSync();
    try {
      final length = reader.lengthSync();
      if (length <= _offset) return;
      reader.setPositionSync(_offset);
      final bytes = reader.readSync(length - _offset);
      _offset += bytes.length;
      for (final byte in bytes) {
        if (byte == 0x0A) {
          _onLine(utf8.decode(_pending, allowMalformed: true));
          _pending.clear();
        } else {
          _pending.add(byte);
        }
      }
    } finally {
      reader.closeSync();
    }
  }
}
