import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'plugin_fixture_suite.dart';
import 'plugin_process_identity.dart';
import 'plugin_process_listing.dart';

const _bound = Duration(seconds: 5);

final class _PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

final _libc = DynamicLibrary.open('libc.so.6');
final _syscall = _libc
    .lookupFunction<
      Int64 Function(Int64, Int64, Int64),
      int Function(int, int, int)
    >('syscall');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);

int _openPidfd(PluginProcessIdentity identity) {
  // pidfd_open has the same syscall number on Linux x86-64 and arm64.
  final fd = _syscall(434, identity.pid, 0);
  if (fd < 0) throw StateError('pidfd_open failed for $identity');
  if (!identity.matchesCurrentProcess()) {
    _close(fd);
    throw StateError('process identity changed while opening pidfd: $identity');
  }
  return fd;
}

int _pollPidfd((int, int) arguments) {
  final (fd, milliseconds) = arguments;
  final poll = DynamicLibrary.open('libc.so.6')
      .lookupFunction<
        Int32 Function(Pointer<_PollFd>, Uint64, Int32),
        int Function(Pointer<_PollFd>, int, int)
      >('poll');
  final entry = calloc<_PollFd>();
  try {
    entry.ref
      ..fd = fd
      ..events = 1;
    final result = poll(entry, 1, milliseconds);
    if (result < 0) throw StateError('pidfd poll failed');
    return result == 0 ? 0 : entry.ref.revents;
  } finally {
    calloc.free(entry);
  }
}

Future<int> _waitPidfd(int fd, Duration timeout) =>
    Isolate.run(() => _pollPidfd((fd, timeout.inMilliseconds)));

bool _isRunning(PluginProcessIdentity identity) {
  final snapshot = readPluginProcessSnapshot(identity.pid);
  return snapshot != null &&
      snapshot.identity == identity &&
      snapshot.state != 'Z';
}

/// Facts captured during a direct host-death experiment before teardown.
final class PluginHostDeathObservation {
  /// Creates an observation from real process and marker receipts.
  const PluginHostDeathObservation({
    required this.host,
    required this.plugin,
    required this.pluginParentPid,
    required this.pluginState,
    required this.marker,
    required this.elapsed,
    required this.hostExitCode,
    required this.decoy,
    required this.decoyAliveBefore,
    required this.decoyAliveAfter,
    required this.command,
    required this.securityMode,
    required this.socketMode,
    required this.socketUid,
    required this.tlsProtocol,
  });

  /// The direct Dart host identity.
  final PluginProcessIdentity host;

  /// The watched Go child identity.
  final PluginProcessIdentity plugin;

  /// The child's observed parent before the host was killed.
  final int pluginParentPid;

  /// The child's final state, or `absent` if its PID disappeared.
  final String pluginState;

  /// The complete synced EOF-cause marker.
  final String marker;

  /// Time from host SIGKILL to both observations.
  final Duration elapsed;

  /// The reaped direct host's actual exit code.
  final int hostExitCode;

  /// The unrelated child identity.
  final PluginProcessIdentity decoy;

  /// Whether the decoy was alive before the host signal.
  final bool decoyAliveBefore;

  /// Whether the decoy was alive after the EOF and death observations.
  final bool decoyAliveAfter;

  /// The exact direct Dart command and arguments.
  final List<String> command;

  /// The explicitly selected transport mode.
  final String securityMode;

  /// The observed plugin socket permission bits.
  final int socketMode;

  /// The observed plugin socket owner's UID.
  final int socketUid;

  /// The negotiated TLS protocol, absent for the diagnostic mode.
  final String? tlsProtocol;

  /// Serializes the observed facts for evidence output.
  Map<String, Object?> toJson() => {
    'host_pid': host.pid,
    'host_start_time': host.startTime,
    'plugin_pid': plugin.pid,
    'plugin_start_time': plugin.startTime,
    'plugin_parent_pid_before_sigkill': pluginParentPid,
    'plugin_state_before_teardown': pluginState,
    'eof_marker': marker,
    'elapsed_ms': elapsed.inMilliseconds,
    'bound_ms': _bound.inMilliseconds,
    'host_exit_code': hostExitCode,
    'decoy_pid': decoy.pid,
    'decoy_start_time': decoy.startTime,
    'decoy_alive_before': decoyAliveBefore,
    'decoy_alive_after': decoyAliveAfter,
    'command': command,
    'security_mode': securityMode,
    'socket_mode': socketMode,
    'socket_uid': socketUid,
    'tls_protocol': tlsProtocol,
    'assertions_before_plugin_teardown': true,
    'orphan_reaped_by_observer': false,
  };
}

/// Proves that killing the direct Dart host causes its watched child to exit.
///
/// Plaintext is available only when explicitly requested for diagnostics.
Future<PluginHostDeathObservation> observePluginHostDeath(
  PluginFixtureSuite suite, {
  bool diagnosticPlaintext = false,
}) async {
  if (!Platform.isLinux) {
    throw UnsupportedError('Linux process receipts required');
  }
  final build = await suite.build();
  final credentials = await suite.createCredentials();
  final created = Process.runSync('mktemp', [
    '-d',
    '${suite.scratchDirectory.path}/host-death-XXXXXXXX',
  ]);
  if (created.exitCode != 0) throw StateError('mktemp: ${created.stderr}');
  final attempt = Directory((created.stdout as String).trim());
  Process? hostProcess;
  Process? decoyProcess;
  PluginProcessIdentity? hostIdentity;
  PluginProcessIdentity? pluginIdentity;
  PluginProcessIdentity? decoyIdentity;
  int? pidfd;
  StreamIterator<String>? lines;
  Future<void>? stderrDone;
  Future<List<void>>? decoyDrains;
  final diagnostics = StringBuffer();
  try {
    final hostDirectory = Directory('${attempt.path}/host');
    final mkdir = Process.runSync('mkdir', ['-m', '700', hostDirectory.path]);
    if (mkdir.exitCode != 0) throw StateError('mkdir: ${mkdir.stderr}');
    final childScript = File(
      'test/plugin/fixtures/dart/host_lifecycle_child.dart',
    ).absolute.path;
    final command = <String>[
      Platform.resolvedExecutable,
      childScript,
      build.binaries[PluginFixtureBinary.stdinWatched]!.path,
      attempt.path,
      credentials.certificate.path,
      credentials.privateKey.path,
      diagnosticPlaintext ? 'diagnostic-plaintext' : 'native-authenticated-tls',
    ];
    decoyProcess = await Process.start('/bin/cat', []);
    decoyIdentity = PluginProcessIdentity.read(decoyProcess.pid);
    if (decoyIdentity == null) throw StateError('cannot identify decoy');
    decoyDrains = Future.wait([
      decoyProcess.stdout.drain<void>(),
      decoyProcess.stderr.drain<void>(),
    ]);
    hostProcess = await Process.start(command.first, command.sublist(1));
    hostIdentity = PluginProcessIdentity.read(hostProcess.pid);
    if (hostIdentity == null) throw StateError('cannot identify direct host');
    stderrDone = hostProcess.stderr.transform(utf8.decoder).forEach((text) {
      if (diagnostics.length < 65536) diagnostics.write(text);
    });
    lines = StreamIterator(
      hostProcess.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
    Future<Map<String, Object?>> nextReceipt() async {
      if (!await lines!.moveNext().timeout(const Duration(seconds: 20))) {
        throw StateError('host exited before receipt: $diagnostics');
      }
      final value = jsonDecode(lines!.current);
      if (value is! Map<String, Object?>) {
        throw FormatException('invalid host receipt: $value');
      }
      return value;
    }

    final spawned = await nextReceipt();
    if (spawned['event'] != 'spawned' ||
        spawned['hostPid'] != hostProcess.pid ||
        spawned['pluginPid'] is! int) {
      throw StateError('invalid direct host spawn receipt: $spawned');
    }
    pluginIdentity = PluginProcessIdentity.read(spawned['pluginPid']! as int);
    if (pluginIdentity == null) {
      throw StateError('cannot identify watched plugin: $spawned');
    }
    pidfd = _openPidfd(pluginIdentity);
    final ready = await nextReceipt();
    if (ready['event'] != 'ready' ||
        ready['hostPid'] != hostProcess.pid ||
        ready['pluginPid'] != pluginIdentity.pid) {
      throw StateError(
        'invalid direct host ready receipt: $ready; $diagnostics',
      );
    }
    final snapshot = readPluginProcessSnapshot(pluginIdentity.pid);
    if (snapshot == null ||
        snapshot.identity != pluginIdentity ||
        snapshot.parentPid != hostIdentity.pid ||
        snapshot.state == 'Z' ||
        !hostIdentity.matchesCurrentProcess()) {
      throw StateError(
        'host or plugin identity/parent changed before signal: $snapshot',
      );
    }
    final decoyBefore = _isRunning(decoyIdentity);
    if (!decoyBefore) throw StateError('decoy died before host signal');
    final stopwatch = Stopwatch()..start();
    if (!hostIdentity.signalIfExact(ProcessSignal.sigkill)) {
      throw StateError('could not signal exact direct host $hostIdentity');
    }
    final hostExit = await hostProcess.exitCode.timeout(_bound);
    final remaining = _bound - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      throw StateError('host exit exceeded five seconds');
    }
    final pollResult = await _waitPidfd(pidfd, remaining);
    final finalSnapshot = readPluginProcessSnapshot(pluginIdentity.pid);
    final state = finalSnapshot == null ? 'absent' : finalSnapshot.state;
    final markerFile = File('${attempt.path}/stdin-eof.marker');
    final marker = markerFile.existsSync()
        ? markerFile.readAsStringSync()
        : '<absent>';
    final decoyAfter = _isRunning(decoyIdentity);
    final elapsed = stopwatch.elapsed;
    if (pollResult & 1 == 0 ||
        elapsed > _bound ||
        (finalSnapshot != null &&
            (finalSnapshot.identity != pluginIdentity || state != 'Z')) ||
        marker != 'stdin-eof\n' ||
        !decoyAfter) {
      throw StateError(
        'host-death proof failed before teardown: poll=$pollResult elapsed=$elapsed state=$state identity=${finalSnapshot?.identity} marker=$marker decoy=$decoyAfter; $diagnostics',
      );
    }
    if (hostExit != -ProcessSignal.sigkill.signalNumber) {
      throw StateError('direct host exit was not SIGKILL: $hostExit');
    }
    final socketMode = ready['socketMode'];
    final socketUid = ready['socketUid'];
    final tlsProtocol = ready['tlsProtocol'];
    if (socketMode is! int ||
        socketUid is! int ||
        (diagnosticPlaintext
            ? (socketMode != 384 || tlsProtocol != null)
            : tlsProtocol != 'TLSv1.3')) {
      throw StateError('unexpected transport evidence: $ready');
    }
    return PluginHostDeathObservation(
      host: hostIdentity,
      plugin: pluginIdentity,
      pluginParentPid: snapshot.parentPid,
      pluginState: state,
      marker: marker,
      elapsed: elapsed,
      hostExitCode: hostExit,
      decoy: decoyIdentity,
      decoyAliveBefore: decoyBefore,
      decoyAliveAfter: decoyAfter,
      command: List.unmodifiable(command),
      securityMode: diagnosticPlaintext
          ? 'diagnostic-plaintext'
          : 'native-authenticated-tls',
      socketMode: socketMode,
      socketUid: socketUid,
      tlsProtocol: tlsProtocol as String?,
    );
  } finally {
    // Only after all proof observations, or a failure, may teardown signal a child.
    if (pluginIdentity == null) {
      final receipt = File('${attempt.path}/spawned.json');
      if (receipt.existsSync()) {
        try {
          final value = jsonDecode(receipt.readAsStringSync());
          if (value is Map<String, Object?> &&
              value['pid'] is int &&
              value['startTime'] is int) {
            pluginIdentity = PluginProcessIdentity(
              pid: value['pid']! as int,
              startTime: value['startTime']! as int,
            );
          }
        } on FormatException {
          // A partially written receipt is not an identity.
        }
      }
    }
    // Capture children when startup failed before the spawned receipt.
    final unreportedChildren = <PluginProcessIdentity>[];
    if (pluginIdentity == null &&
        hostIdentity != null &&
        hostIdentity.matchesCurrentProcess()) {
      try {
        final children = File(
          '/proc/${hostIdentity.pid}/task/${hostIdentity.pid}/children',
        ).readAsStringSync().trim().split(RegExp(r'\s+'));
        for (final child in children) {
          final childPid = int.tryParse(child);
          if (childPid == null) continue;
          final identity = PluginProcessIdentity.read(childPid);
          if (identity != null) unreportedChildren.add(identity);
        }
      } on FileSystemException {
        // The host may already have exited.
      }
    }
    if (hostIdentity != null) hostIdentity.signalIfExact(ProcessSignal.sigkill);
    if (hostProcess != null) {
      await hostProcess.exitCode.timeout(_bound);
      await hostProcess.stdin.close();
    }
    for (final identity in unreportedChildren) {
      final current = readPluginProcessSnapshot(identity.pid);
      if (current == null ||
          current.identity != identity ||
          current.state == 'Z') {
        continue;
      }
      final childFd = _openPidfd(identity);
      try {
        identity.signalIfExact(ProcessSignal.sigkill);
        await _waitPidfd(childFd, _bound);
        if (_isRunning(identity)) {
          throw StateError('owned child remains alive: $identity');
        }
      } finally {
        _close(childFd);
      }
    }
    if (pluginIdentity != null) {
      final current = readPluginProcessSnapshot(pluginIdentity.pid);
      if (current != null &&
          current.identity == pluginIdentity &&
          current.state != 'Z') {
        pidfd ??= _openPidfd(pluginIdentity);
        pluginIdentity.signalIfExact(ProcessSignal.sigkill);
        await _waitPidfd(pidfd, _bound);
      }
      final after = readPluginProcessSnapshot(pluginIdentity.pid);
      if (after != null &&
          after.identity == pluginIdentity &&
          after.state != 'Z') {
        throw StateError(
          'owned plugin remains alive after cleanup: $pluginIdentity',
        );
      }
    }
    if (pidfd != null) _close(pidfd);
    if (decoyIdentity != null) {
      decoyIdentity.signalIfExact(ProcessSignal.sigkill);
    }
    if (decoyProcess != null) {
      await decoyProcess.exitCode.timeout(_bound);
      await decoyProcess.stdin.close();
    }
    await decoyDrains;
    await lines?.cancel();
    await stderrDone;
    if (attempt.existsSync()) await attempt.delete(recursive: true);
  }
}
