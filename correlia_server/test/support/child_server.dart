import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:meta/meta.dart';

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
  ChildServer._({
    required this._serverDir,
    required List<String> args,
    required this._executable,
    required List<String> vmArgs,
    required Map<String, String> environment,
    required Duration readyTimeout,
    required this._portPicker,
    required this._logDirectory,
    required this._deleteLogDirectory,
  }) : _args = List.of(args),
       _vmArgs = List.of(vmArgs),
       _environment = Map.of(environment),
       _readyTimeout = readyTimeout,
       _deadline = DateTime.now().add(readyTimeout);

  /// Starts the server in [serverDir] on the cluster [root].
  ///
  /// A fresh cluster has no tables, so migrations are applied by default.
  /// The Postgres data directory is `<root>/pgdata`, and the child holds
  /// `<root>/owner.lock` until it exits. [environment] augments its environment.
  /// [readyTimeout] bounds all startup attempts and the root lock wait.
  /// [portPicker] replaces ephemeral port selection in deterministic tests.
  /// Tests budget at least `n × (readiness deadline + 30 s shutdown) + 60 s`
  /// for sequential children; children started together count once.
  static Future<ChildServer> start({
    required Directory serverDir,
    required Directory root,
    List<String> args = const ['--mode', 'test', '--apply-migrations'],
    Map<String, String> environment = const {},
    List<String> vmArgs = const [],
    Duration readyTimeout = const Duration(seconds: 60),
    @visibleForTesting Future<int> Function()? portPicker,
  }) {
    root.createSync(recursive: true);
    return _spawn(
      serverDir: serverDir,
      args: args,
      vmArgs: vmArgs,
      readyTimeout: readyTimeout,
      portPicker: portPicker,
      logs: Directory(p.join(root.path, 'logs')),
      environment: {
        'SERVERPOD_DATABASE_DATA_PATH': p.join(root.path, 'pgdata'),
        'CORRELIA_TEST_ROOT_LOCK': p.join(root.path, 'owner.lock'),
        'CORRELIA_TEST_ROOT_LOCK_TIMEOUT': '${readyTimeout.inSeconds}',
        if (environment.containsKey('CORRELIA_INGEST_CONFIG') &&
            !environment.containsKey('CORRELIA_SECRET_KEY_FILE'))
          'CORRELIA_SECRET_KEY_FILE': childSecretKeyFile(root),
        ...environment,
      },
    );
  }

  /// Starts the server on [database], without supervising embedded Postgres.
  ///
  /// It owns no cluster root and takes no root lock. Without Serverpod's
  /// embedded supervisor it exits 0 on SIGTERM. [readyTimeout] bounds all
  /// startup attempts. [portPicker] injects port selection for tests.
  /// Tests budget at least `n × (readiness deadline + 30 s shutdown) + 60 s`
  /// for sequential children; children started together count once.
  /// An optional [logs] directory is kept for full-output assertions.
  /// Pass [executable] to run a built server instead of the Dart entry point.
  static Future<ChildServer> startOnSharedCluster({
    required Directory serverDir,
    required SharedClusterDatabase database,
    List<String> args = const ['--mode', 'test', '--apply-migrations'],
    String? executable,
    Map<String, String> environment = const {},
    List<String> vmArgs = const [],
    Duration readyTimeout = const Duration(seconds: 60),
    Directory? logs,
    @visibleForTesting Future<int> Function()? portPicker,
  }) => _spawn(
    serverDir: serverDir,
    args: args,
    executable: executable,
    vmArgs: vmArgs,
    readyTimeout: readyTimeout,
    portPicker: portPicker,
    logs: logs,
    environment: {
      ...database.environment,
      if (environment.containsKey('CORRELIA_INGEST_CONFIG') &&
          !environment.containsKey('CORRELIA_SECRET_KEY_FILE'))
        'CORRELIA_SECRET_KEY_FILE': database.secretKeyFile,
      ...environment,
    },
  );

  static Future<ChildServer> _spawn({
    required Directory serverDir,
    required List<String> args,
    required List<String> vmArgs,
    String? executable,
    required Duration readyTimeout,
    required Map<String, String> environment,
    Future<int> Function()? portPicker,
    Directory? logs,
  }) async {
    final logDirectory = logs ?? Directory.systemTemp.createTempSync('child_');
    logDirectory.createSync(recursive: true);
    final child = ChildServer._(
      serverDir: serverDir,
      args: args,
      executable: executable,
      vmArgs: vmArgs,
      environment: environment,
      readyTimeout: readyTimeout,
      portPicker: portPicker ?? _freePort,
      logDirectory: logDirectory,
      deleteLogDirectory: logs == null,
    );
    try {
      await child._startAttempt();
      return child;
    } on Object {
      child._cleanLogs();
      rethrow;
    }
  }

  Future<void> _startAttempt() async {
    final apiPort = await _portPicker();
    final webPort = await _portPicker();
    final insightsPort = await _portPicker();
    if (_stopping || (_attempts > 0 && !DateTime.now().isBefore(_deadline))) {
      return;
    }
    final log = File(
      p.join(
        _logDirectory.path,
        'child-${_logCounter++}-${DateTime.now().microsecondsSinceEpoch}.log',
      ),
    )..createSync();
    final process = await Process.start(
      '/bin/sh',
      [
        '-c',
        // exec keeps the process id equal to the server VM's.
        r'log=$1; shift; exec "$@" >"$log" 2>&1',
        'sh', log.path,
        if (_executable case final executable?)
          executable
        else ...[
          Platform.resolvedExecutable,
          ..._vmArgs,
          p.join('bin', 'main.dart'),
        ],
        ..._args,
      ],
      workingDirectory: _serverDir.path,
      environment: {
        ..._environment,
        'SERVERPOD_API_SERVER_PORT': '$apiPort',
        'SERVERPOD_WEB_SERVER_PORT': '$webPort',
        'SERVERPOD_INSIGHTS_SERVER_PORT': '$insightsPort',
        'CORRELIA_EXIT_ON_STDIN_CLOSE': '1',
      },
    );
    _attempts++;
    _process = process;
    _apiPort = apiPort;
    _webPort = webPort;
    _insightsPort = insightsPort;
    _output.clear();
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final tail = _LogTail(log, _remember)..start();
    unawaited(_onExit(process, tail));
    if (_stopping) process.kill(ProcessSignal.sigkill);
  }

  Future<void> _onExit(Process process, _LogTail tail) async {
    final code = await process.exitCode;
    tail.finish();
    if (!_ready &&
        !_stopping &&
        _attempts < 3 &&
        DateTime.now().isBefore(_deadline) &&
        isBindFailure(output)) {
      final lost = 'api=$_apiPort web=$_webPort insights=$_insightsPort';
      _lostPorts.add(lost);
      final line =
          'ChildServer lost-port retry after attempt $_attempts ($lost)';
      stdout.writeln(line);
      final spawning = _startAttempt();
      _spawning = spawning;
      try {
        await spawning;
        // No process is spawned if teardown or the deadline wins port picking.
        if (!identical(process, _process)) return;
      } on Object catch (error, stack) {
        _finishExit(error: error, stack: stack);
        return;
      } finally {
        if (identical(_spawning, spawning)) _spawning = null;
      }
    }
    _finishExit(code: code);
  }

  void _finishExit({int? code, Object? error, StackTrace? stack}) {
    if (_exit.isCompleted) return;
    _cleanLogs();
    if (error != null) {
      _exit.completeError(error, stack);
    } else {
      _exit.complete(code!);
    }
  }

  void _cleanLogs() {
    if (_deleteLogDirectory && _logDirectory.existsSync()) {
      _logDirectory.deleteSync(recursive: true);
    }
  }

  // Port 0 is released before compilation; only the exit handler retries a
  // lost reservation. Parsing logs cannot supply a port before startup.
  static int _logCounter = 0;
  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  final Directory _serverDir;
  final List<String> _args;
  final String? _executable;
  final List<String> _vmArgs;
  final Map<String, String> _environment;
  final Duration _readyTimeout;
  DateTime _deadline;
  final Future<int> Function() _portPicker;
  final Directory _logDirectory;
  final bool _deleteLogDirectory;
  late Process _process;
  late int _apiPort;
  late int _webPort;
  late int _insightsPort;
  int _attempts = 0;
  bool _ready = false;
  bool _stopping = false;
  Future<void>? _spawning;
  final Completer<int> _exit = Completer<int>();
  final List<String> _lostPorts = [];
  final Queue<String> _output = Queue();
  final List<(RegExp, Completer<void>)> _waiters = [];

  /// The API port of the current attempt, stable after [waitUntilReady].
  int get apiPort => _apiPort;

  /// The web port of the current attempt, stable after [waitUntilReady].
  int get webPort => _webPort;

  /// The number of processes started for this logical child, at most three.
  int get attempts => _attempts;

  /// Whether the logical child has exited without another retry pending.
  bool get hasExited => _exit.isCompleted;

  /// The current server VM's process id, stable after [waitUntilReady].
  int get pid => _process.pid;

  /// Completes once with the final attempt's exit, after draining its output.
  Future<int> get exitCode => _exit.future;

  /// The current attempt's last output lines, prefixed by retry diagnostics.
  String get output => [
    if (_attempts > 1 || _lostPorts.isNotEmpty)
      'ChildServer: $_attempts attempts; lost ports: ${_lostPorts.join('; ')}',
    ..._output,
  ].join('\n');

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

  /// Completes on matching output or final exit; null [timeout] uses the test guard.
  Future<void> waitForOutput(
    RegExp pattern, {
    Duration? timeout = const Duration(seconds: 60),
  }) {
    if (_output.any(pattern.hasMatch)) return Future.value();
    final done = Completer<void>();
    final waiter = (pattern, done);
    _waiters.add(waiter);
    unawaited(
      exitCode.then((code) {
        if (!done.isCompleted) {
          done.completeError(
            StateError(
              'Server (pid $pid) exited with $code before printing $pattern. Output:\n$output',
            ),
          );
        }
      }),
    );
    final completion = timeout == null
        ? done.future
        : done.future.timeout(
            timeout,
            onTimeout: () => throw StateError(
              'Server (pid $pid) printed no $pattern within $timeout. Output:\n$output',
            ),
          );
    return completion.whenComplete(() => _waiters.remove(waiter));
  }

  /// Returns the HTTP status on the current API port, or web port if [web].
  Future<int?> statusOf(String path, {bool web = false}) async =>
      (await fetch(path, web: web))?.status;

  /// Fetches [path] from the current attempt, or returns null on failure.
  /// Pass a null [requestTimeout] when the enclosing test owns the hang guard.
  Future<({int status, String body})?> fetch(
    String path, {
    bool web = false,
    Duration? requestTimeout = const Duration(seconds: 5),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = requestTimeout == null
          ? null
          : const Duration(seconds: 2);
    try {
      final request = await client.get(
        'localhost',
        web ? webPort : apiPort,
        path,
      );
      final response = requestTimeout == null
          ? await request.close()
          : await request.close().timeout(requestTimeout);
      final body = await response.transform(utf8.decoder).join();
      return (status: response.statusCode, body: body);
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  bool _ownsApiListener() {
    try {
      final links = Directory('/proc/$pid/fd')
          .listSync(followLinks: false)
          .whereType<Link>()
          .map((link) => link.targetSync())
          .toSet();
      return ownsListeningSocket(
        apiPort,
        File('/proc/net/tcp').readAsStringSync(),
        File('/proc/net/tcp6').readAsStringSync(),
        links,
      );
    } on FileSystemException {
      return false;
    }
  }

  /// Waits for readiness and ownership of the current attempt's API listener.
  ///
  /// All attempts share the startup deadline. [timeout] may shorten it, never
  /// renew it. A foreign listener's 200 is ignored. Final exit or expiry raises
  /// a [StateError] containing the current output and attempt diagnostics.
  Future<void> waitUntilReady([Duration? timeout]) async {
    final limit = timeout ?? _readyTimeout;
    if (timeout != null) {
      final shortened = DateTime.now().add(timeout);
      if (shortened.isBefore(_deadline)) _deadline = shortened;
    }
    while (!hasExited && DateTime.now().isBefore(_deadline)) {
      final process = _process;
      if (await statusOf('/startupz') == 200 &&
          identical(process, _process) &&
          !hasExited &&
          !_stopping &&
          _ownsApiListener() &&
          DateTime.now().isBefore(_deadline)) {
        _ready = true;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final why = hasExited
        ? 'exited with ${await exitCode}'
        : 'not ready in $limit';
    throw StateError('Server (pid $pid) $why. Output:\n$output');
  }

  /// Waits for the current Correlia attempt's startup event, then checks it once.
  Future<void> waitForReadyEvent() async {
    await waitForOutput(RegExp(r'\[correlia\] Ready to serve$'), timeout: null);
    final process = _process;
    final client = HttpClient();
    try {
      final request = await client.get('localhost', apiPort, '/startupz');
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != 200 ||
          !identical(process, _process) ||
          hasExited ||
          _stopping ||
          !_ownsApiListener()) {
        throw StateError(
          'Startup receipt did not match the running child:\n$output',
        );
      }
      _ready = true;
    } finally {
      client.close(force: true);
    }
  }

  /// Suppresses retries and sends SIGKILL, including to an in-flight spawn.
  void kill() {
    _stopping = true;
    _process.kill(ProcessSignal.sigkill);
    // _startAttempt checks the stop flag after Process.start returns.
  }

  /// Suppresses retries and closes stdin for graceful shutdown.
  ///
  /// Waits for any in-flight spawn. Prefer this over [stop] when exit status
  /// matters: embedded Postgres's SIGTERM handler exits 143.
  Future<int> closeStdin({
    Duration? deadline = const Duration(seconds: 30),
  }) async {
    _stopping = true;
    await _spawning;
    try {
      await _process.stdin.close();
    } on Object {
      // Already exited or closed its end; the final exit code is authoritative.
    }
    return deadline == null ? exitCode : _awaitExit(deadline, 'closing stdin');
  }

  Future<int> _awaitExit(Duration deadline, String action) => exitCode.timeout(
    deadline,
    onTimeout: () {
      kill();
      throw StateError(
        'Server (pid $pid) still running $deadline after $action. Output:\n$output',
      );
    },
  );

  /// Suppresses retries, then sends SIGTERM, or SIGKILL after [deadline].
  Future<int> stop({Duration? deadline = const Duration(seconds: 30)}) async {
    _stopping = true;
    await _spawning;
    _process.kill(ProcessSignal.sigterm);
    return deadline == null ? exitCode : _awaitExit(deadline, 'SIGTERM');
  }
}

/// Whether [output] contains a Serverpod or operating-system bind failure.
bool isBindFailure(String output) =>
    output.contains('Failed to bind socket') ||
    output.contains('Address already in use');

/// Whether [fdTargets] owns a listening inode for [port] in Linux TCP tables.
///
/// Accepts both IPv4 [tcp] and IPv6 [tcp6] text, ignoring non-listening rows.
bool ownsListeningSocket(
  int port,
  String tcp,
  String tcp6,
  Set<String> fdTargets,
) {
  for (final table in [tcp, tcp6]) {
    for (final line in const LineSplitter().convert(table)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 10 || fields[3] != '0A') continue;
      final address = fields[1].split(':');
      if (address case [
        _,
        final hexPort,
      ] when int.tryParse(hexPort, radix: 16) == port) {
        if (fdTargets.contains('socket:[${fields[9]}]')) return true;
      }
    }
  }
  return false;
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
