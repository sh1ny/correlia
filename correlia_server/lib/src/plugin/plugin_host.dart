import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:grpc/grpc.dart';
import 'package:meta/meta.dart';

import '../plugin_generated/correlia/plugin/spike/v1/output.pbgrpc.dart';
import 'plugin_rpc_connection.dart';
import 'plugin_tls.dart';

typedef PluginProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments,
      Map<String, String> environment,
    );
typedef PluginDirectoryStarter = Future<Directory> Function();

enum PluginLaunchUmask {
  restrictive0177,
  inherited,
  permissive0002,
  readable0022,
}

final class PluginHostTestControls {
  const PluginHostTestControls({
    this.diagnosticPlaintext = false,
    this.launchUmask = PluginLaunchUmask.restrictive0177,
    this.omitIdentity = false,
    this.identityOverride,
    this.advertisedCertificateOverride,
    this.pinOverride,
    this.tls = const PluginTlsTestControls(),
    this.processStarter,
    this.directoryStarter,
  });

  final bool diagnosticPlaintext;
  final PluginLaunchUmask launchUmask;
  final bool omitIdentity;
  final PluginClientIdentity? identityOverride;
  final String? advertisedCertificateOverride;
  final String? pinOverride;
  final PluginTlsTestControls tls;
  final PluginProcessStarter? processStarter;
  final PluginDirectoryStarter? directoryStarter;
}

PluginHost createPluginHostForTesting(
  PluginHostConfig config, {
  PluginHostTestControls controls = const PluginHostTestControls(),
}) => PluginHost._(config, controls);

/// Opens the owned experimental stream without a whole-stream deadline.
///
/// This internal helper is deliberately absent from the public export list.
ResponseStream<DeliverResponse> openPluginDeliver(
  PluginHost host,
  Stream<DeliverRequest> requests,
) {
  final connection = host._connection;
  if (host._state is! _Ready || connection == null) {
    throw StateError('Plugin is not ready');
  }
  return connection.outputClient.deliver(requests);
}

/// Configuration for one experimental plugin process.
final class PluginHostConfig {
  /// Creates a launch configuration.
  PluginHostConfig({
    required this.executable,
    required List<String> arguments,
    required this.identity,
    this.timeout = const Duration(seconds: 10),
    this.cookie = 'correlia-plugin-host-spike',
    this.versions = '1',
  }) : arguments = List.unmodifiable(arguments) {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
  }

  /// The plugin executable path.
  final String executable;

  /// Arguments passed unchanged to the executable.
  final List<String> arguments;

  /// Client identity used by the protected connection.
  final PluginClientIdentity identity;

  /// Total startup deadline.
  final Duration timeout;

  /// Value of the fixture's magic cookie.
  final String cookie;

  /// Comma-separated supported application versions.
  final String versions;
}

/// Negotiation and observed socket facts preserved independently of TLS.
final class PluginHandshakeEvidence {
  /// Creates observed handshake evidence.
  PluginHandshakeEvidence(
    this.version,
    this.socketMode,
    this.certificate,
    this.socketUid,
  );

  /// The negotiated application version.
  final int version;

  /// Actual socket permission bits.
  final int socketMode;

  /// The socket owner's UID observed in the host's namespace.
  final int socketUid;

  /// The server certificate as unpadded base64 DER, if present.
  final String? certificate;
}

/// A failed startup and any negotiation facts obtained before the failure.
final class PluginStartupException implements Exception {
  /// Creates a startup failure.
  PluginStartupException(
    this.message, {
    this.evidence,
    this.diagnostics = '',
    this.cause,
  });

  /// A description of the failure.
  final String message;

  /// Handshake and socket evidence, when available.
  final PluginHandshakeEvidence? evidence;

  /// The bounded tail of process output.
  final String diagnostics;

  /// The original startup failure.
  final Object? cause;
  @override
  String toString() => 'PluginStartupException: $message';
}

/// Owns one authenticated plugin process independently of its application protocol.
base class PluginLaunchCore {
  /// Creates an idle launch core.
  PluginLaunchCore(
    this.config, {
    this.cookieKey = 'CORRELIA_PLUGIN',
    this.afterForcedStop,
  }) : _controls = const PluginHostTestControls();

  PluginLaunchCore._(this.config, this._controls, this.cookieKey)
    : afterForcedStop = null;

  /// The handshake cookie environment key.
  final String cookieKey;

  /// The test-only failure injection after a forced reap and resource cleanup.
  @visibleForTesting
  final Future<void> Function()? afterForcedStop;

  final PluginHostTestControls _controls;

  /// Launch and security settings.
  final PluginHostConfig config;
  PluginHandshakeEvidence? _evidence;
  PluginTlsEvidence? _tlsEvidence;
  int? _inheritedUmask;
  int? _effectiveUmask;
  Process? _process;
  int? _childPid;
  Directory? _directory;
  PluginRpcConnection? _connection;
  StreamSubscription<List<int>>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  final List<int> _tail = <int>[];
  Future<void> _serial = Future<void>.value();
  _HostState _state = const _Idle();
  int _discardedDiagnosticBytes = 0;

  /// The authenticated application channel after startup.
  ClientTransportConnectorChannel get channel {
    final connection = _connection;
    if (_state is! _Ready || connection == null) {
      throw StateError('Plugin is not ready');
    }
    return connection.channel;
  }

  /// The last rejected gRPC frame while the connection is active.
  FormatException? get frameFailure => _connection?.frameFailure;

  /// The child exit code after a process has been started.
  Future<int>? get onExit => _process?.exitCode;

  /// Facts obtained before TLS, including on authentication failure.
  PluginHandshakeEvidence? get evidence => _evidence;

  /// TLS facts retained after the connection is closed.
  PluginTlsEvidence? get tlsEvidence => _tlsEvidence;

  /// The parent process's observed umask.
  int? get inheritedUmask => _inheritedUmask;

  /// The umask selected for the child process.
  int? get effectiveUmask => _effectiveUmask;

  /// The exact child PID, retained after reaping for independent observation.
  int? get childPid => _childPid;

  /// Whether normal shutdown required forcing the child to terminate.
  bool get forcedStop => _forcedStop;
  bool _forcedStop = false;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Starts the plugin and waits for its health service to report serving.
  Future<void> start() => _serialize(() async {
    if (_state is! _Idle) {
      throw StateError('A host instance can only be started once');
    }
    _state = const _Starting();
    final watch = Stopwatch()..start();
    Duration remaining() {
      final value = config.timeout - watch.elapsed;
      if (value <= Duration.zero) {
        throw TimeoutException('plugin startup deadline');
      }
      return value;
    }

    try {
      if (!Platform.isLinux) {
        throw UnsupportedError('Plugin host requires Linux');
      }
      final directoryDeadline = remaining();
      _directory = await _acquire<Directory>(
        (_controls.directoryStarter ?? _createDirectory)(),
        directoryDeadline,
        (directory) async {
          if (await directory.exists()) await directory.delete(recursive: true);
        },
      );
      final uidText = await File(
        '/proc/self/status',
      ).readAsString().timeout(remaining());
      final uidMatch = RegExp(
        r'^Uid:\s+(\d+)',
        multiLine: true,
      ).firstMatch(uidText);
      if (uidMatch == null) throw StateError('Cannot determine current uid');
      final uid = int.parse(uidMatch.group(1)!);
      final umaskMatch = RegExp(
        r'^Umask:\s+([0-7]+)',
        multiLine: true,
      ).firstMatch(uidText);
      if (umaskMatch == null) {
        throw StateError('Cannot determine inherited umask');
      }
      _inheritedUmask = int.parse(umaskMatch.group(1)!, radix: 8);
      _effectiveUmask = switch (_controls.launchUmask) {
        PluginLaunchUmask.restrictive0177 => 0x7f,
        PluginLaunchUmask.inherited => _inheritedUmask,
        PluginLaunchUmask.permissive0002 => 2,
        PluginLaunchUmask.readable0022 => 0x12,
      };
      final directory = await _directory!.resolveSymbolicLinks().timeout(
        remaining(),
      );
      final directoryInfo = await _stat(directory).timeout(remaining());
      if (directoryInfo.uid != uid ||
          directoryInfo.mode != 0x1c0 ||
          directoryInfo.type != 'directory') {
        throw StateError('Unsafe attempt directory');
      }
      final environment = <String, String>{
        cookieKey: config.cookie,
        'PLUGIN_PROTOCOL_VERSIONS': config.versions,
        'PLUGIN_UNIX_SOCKET_DIR': directory,
        'PLUGIN_CLIENT_CERT':
            _controls.advertisedCertificateOverride ??
            utf8.decode(config.identity.certificatePem),
      };
      final mask = _effectiveUmask!.toRadixString(8).padLeft(4, '0');
      final executable = '/bin/sh';
      final arguments = <String>[
        '-c',
        'umask $mask; exec "\$@"',
        'correlia-plugin',
        config.executable,
        ...config.arguments,
      ];
      final processDeadline = remaining();
      _process = await _acquire<Process>(
        (_controls.processStarter ?? _startProcess)(
          executable,
          arguments,
          environment,
        ),
        processDeadline,
        (process) async {
          final stdoutDone = process.stdout.drain<void>();
          final stderrDone = process.stderr.drain<void>();
          process.kill(ProcessSignal.sigkill);
          try {
            await process.stdin.close();
          } on IOException {
            // A late child may have closed its input before receipt.
          }
          await process.exitCode.timeout(const Duration(seconds: 5));
          await stdoutDone;
          await stderrDone;
        },
      );
      final process = _process!;
      _childPid = process.pid;
      final line = Completer<String>();
      final handshake = <int>[];
      var complete = false;
      _stdout = process.stdout.listen(
        (bytes) {
          if (complete) {
            _append(bytes);
            return;
          }
          for (var i = 0; i < bytes.length; i++) {
            final byte = bytes[i];
            handshake.add(byte);
            if (handshake.length > 16 * 1024) {
              complete = true;
              if (!line.isCompleted) {
                line.completeError(FormatException('Handshake exceeds 16 KiB'));
              }
              if (i + 1 < bytes.length) _append(bytes.sublist(i + 1));
              return;
            }
            if (byte == 10) {
              complete = true;
              try {
                line.complete(
                  utf8.decode(handshake.sublist(0, handshake.length - 1)),
                );
              } on Object catch (error, stack) {
                line.completeError(error, stack);
              }
              if (i + 1 < bytes.length) _append(bytes.sublist(i + 1));
              return;
            }
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!line.isCompleted) line.completeError(error, stack);
        },
        onDone: () {
          if (!line.isCompleted) {
            line.completeError(
              StateError('Plugin exited before completing handshake'),
            );
          }
        },
      );
      _stderr = process.stderr.listen(_append);
      final value = await line.future.timeout(remaining());
      final fields = value.split('|');
      if (fields.length != 6 && fields.length != 7) {
        throw FormatException('Expected six handshake fields');
      }
      if (fields.length == 7 && fields[6] != 'false') {
        throw FormatException('Unsupported handshake extension');
      }
      final version = int.tryParse(fields[1]);
      if (fields[0] != '1' ||
          version == null ||
          !config.versions.split(',').contains(fields[1]) ||
          fields[2] != 'unix' ||
          fields[4] != 'grpc' ||
          fields[3].isEmpty ||
          (!_controls.diagnosticPlaintext && fields[5].isEmpty)) {
        throw FormatException('Unsupported plugin handshake');
      }
      final socket = await File(
        fields[3],
      ).resolveSymbolicLinks().timeout(remaining());
      if (!socket.startsWith('$directory/')) {
        throw StateError('Socket escapes attempt directory');
      }
      final socketInfo = await _stat(socket).timeout(remaining());
      _evidence = PluginHandshakeEvidence(
        version,
        socketInfo.mode,
        fields[5].isEmpty ? null : fields[5],
        socketInfo.uid,
      );
      if (socketInfo.uid != uid ||
          socketInfo.type != 'socket' ||
          socketInfo.mode & 0x12 != 0 ||
          (_controls.diagnosticPlaintext && socketInfo.mode != 0x180)) {
        throw StateError('Unsafe socket owner, type, or mode');
      }
      final connecting = PluginRpcConnection.connect(
        socketPath: socket,
        serverCertificateDerBase64: _evidence!.certificate,
        identity: _controls.omitIdentity
            ? null
            : (_controls.identityOverride ?? config.identity),
        secure: !_controls.diagnosticPlaintext,
        timeout: remaining(),
        expectedServerCertificatePem: _controls.pinOverride,
        testControls: _controls.tls,
      );
      var abandoned = false;
      unawaited(
        connecting.then((connection) {
          if (abandoned) unawaited(connection.close());
        }, onError: (Object _, StackTrace _) {}),
      );
      try {
        _connection = await connecting.timeout(remaining());
      } on Object {
        abandoned = true;
        rethrow;
      }
      _tlsEvidence = _connection!.tlsEvidence;
      _state = const _Ready();
    } on Object catch (error) {
      _state = const _Failed();
      Object? cleanupError;
      try {
        await _cleanup();
      } on Object catch (failure) {
        cleanupError = failure;
      }
      final truncation = _discardedDiagnosticBytes == 0
          ? ''
          : '\n[$_discardedDiagnosticBytes diagnostic bytes discarded]';
      throw PluginStartupException(
        cleanupError == null
            ? '$error'
            : '$error; cleanup failed: $cleanupError',
        evidence: _evidence,
        cause: error,
        diagnostics: '${utf8.decode(_tail, allowMalformed: true)}$truncation',
      );
    }
  });

  void _append(List<int> bytes) {
    for (var offset = 0; offset < bytes.length; offset += 8192) {
      final end = math.min(offset + 8192, bytes.length);
      _tail.addAll(bytes.sublist(offset, end));
      if (_tail.length > 65536) {
        final excess = _tail.length - 65536;
        _discardedDiagnosticBytes += excess;
        _tail.removeRange(0, excess);
      }
    }
  }

  /// Requests shutdown, then forcibly terminates and reaps an uncooperative child.
  Future<void> stop() => stopWithGrace(const Duration(seconds: 2));

  /// Requests shutdown with the supplied grace period, then reaps the child.
  Future<void> stopWithGrace(Duration grace) => _serialize(() async {
    if (grace.isNegative) throw ArgumentError.value(grace, 'grace');
    if (_state is _Stopped) return;
    _state = const _Stopping();
    final watch = Stopwatch()..start();
    final connection = _connection;
    if (connection != null) {
      try {
        await connection.requestShutdown().timeout(grace);
      } on Object {
        /* Forced cleanup follows. */
      }
    }
    final remaining = grace - watch.elapsed;
    await _cleanup(grace: remaining.isNegative ? Duration.zero : remaining);
    _state = const _Stopped();
  });

  Future<void> _cleanup({Duration grace = Duration.zero}) async {
    final connection = _connection;
    _connection = null;
    Object? closeError;
    StackTrace? closeStack;
    if (connection != null) {
      try {
        await connection.close();
      } on Object catch (error, stack) {
        closeError = error;
        closeStack = stack;
      }
    }
    final process = _process;
    _process = null;
    var forcedThisCleanup = false;
    if (process != null) {
      try {
        await process.stdin.close();
      } on IOException {
        // The child may already have closed its input.
      }
      try {
        await process.exitCode.timeout(grace);
      } on TimeoutException {
        _forcedStop = true;
        forcedThisCleanup = true;
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
    final directory = _directory;
    _directory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
    if (closeError != null) Error.throwWithStackTrace(closeError, closeStack!);
    if (forcedThisCleanup) await afterForcedStop?.call();
  }
}

/// Owns exactly one experimental plugin process and its connection.
final class PluginHost extends PluginLaunchCore {
  /// Creates an idle experimental host.
  PluginHost(super.config) : super(cookieKey: 'CORRELIA_PLUGIN_COOKIE');

  PluginHost._(PluginHostConfig config, PluginHostTestControls controls)
    : super._(config, controls, 'CORRELIA_PLUGIN_COOKIE');

  /// Performs a protected empty application batch and validates its acknowledgement.
  Future<void> probe() async {
    final connection = _connection;
    if (_state is! _Ready || connection == null) {
      throw StateError('Plugin is not ready');
    }
    await connection.probe();
  }
}

Future<T> _acquire<T>(
  Future<T> future,
  Duration timeout,
  Future<void> Function(T) dispose,
) async {
  var abandoned = false;
  unawaited(
    future.then((value) {
      if (abandoned) {
        unawaited(
          dispose(value).catchError((Object error, StackTrace stack) {
            Zone.current.handleUncaughtError(error, stack);
          }),
        );
      }
    }, onError: (Object _, StackTrace _) {}),
  );
  try {
    return await future.timeout(timeout);
  } on Object {
    abandoned = true;
    rethrow;
  }
}

Future<Directory> _createDirectory() async {
  final result = await Process.run('/usr/bin/mktemp', [
    '-d',
    '${Directory.systemTemp.path}/correlia-plugin-XXXXXXXX',
  ]);
  if (result.exitCode != 0) {
    throw StateError('Cannot create private attempt directory');
  }
  return Directory((result.stdout as String).trim());
}

Future<Process> _startProcess(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
) => Process.start(
  executable,
  arguments,
  environment: environment,
  includeParentEnvironment: false,
);

sealed class _HostState {
  const _HostState();
}

final class _Idle extends _HostState {
  const _Idle();
}

final class _Starting extends _HostState {
  const _Starting();
}

final class _Ready extends _HostState {
  const _Ready();
}

final class _Failed extends _HostState {
  const _Failed();
}

final class _Stopping extends _HostState {
  const _Stopping();
}

final class _Stopped extends _HostState {
  const _Stopped();
}

final class _FileInfo {
  _FileInfo(this.uid, this.mode, this.type);
  final int uid;
  final int mode;
  final String type;
}

Future<_FileInfo> _stat(String path) async {
  final result = await Process.run('/usr/bin/stat', [
    '-Lc',
    '%u:%a:%F',
    '--',
    path,
  ]);
  if (result.exitCode != 0) {
    throw FileSystemException('Cannot stat plugin path', path);
  }
  final parts = (result.stdout as String).trim().split(':');
  if (parts.length != 3) throw FormatException('Unexpected stat output');
  return _FileInfo(
    int.parse(parts[0]),
    int.parse(parts[1], radix: 8),
    parts[2],
  );
}
