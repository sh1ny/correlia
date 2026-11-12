import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'plugin_process_identity.dart';

/// A failure to start the test-owned NATS server.
final class NatsStartupException implements Exception {
  /// Creates a startup failure with bounded diagnostics.
  NatsStartupException(this.message);

  /// The startup diagnostic.
  final String message;

  @override
  String toString() => 'NATS startup: $message';
}

/// A test-owned embedded NATS server and its private scratch directory.
final class NatsTestServer {
  NatsTestServer._(
    this._process,
    this._identity,
    this.scratch,
    this.url,
    this._stderrDone,
  );

  /// Starts an isolated loopback server with private storage.
  ///
  /// [storePath] overrides the storage path for startup failure tests. The
  /// caller owns that path; only this server's private scratch is removed.
  static Future<NatsTestServer> start({
    String? storePath,
    String? token,
    int? maxPayload,
  }) async {
    final created = Process.runSync('mktemp', [
      '-d',
      '${Directory.systemTemp.path}/correlia-nats-XXXXXXXX',
    ]);
    if (created.exitCode != 0) {
      throw NatsStartupException('cannot create scratch: ${created.stderr}');
    }
    final scratch = Directory((created.stdout as String).trim());
    Process? process;
    PluginProcessIdentity? identity;
    var exited = false;
    final stderrBytes = <int>[];
    final stderrDone = Completer<void>();
    try {
      process = await Process.start(
        '${Directory.current.parent.path}/build/plugins/natsdev',
        [
          'serve',
          '--port',
          '0',
          '--store',
          storePath ?? '${scratch.path}/store',
          if (token != null) ...['--token', token],
          if (maxPayload != null) ...['--max-payload', '$maxPayload'],
        ],
        environment: const <String, String>{},
        includeParentEnvironment: false,
      );
      process.stderr.listen(
        (chunk) {
          final remaining = 64 * 1024 - stderrBytes.length;
          if (remaining > 0) stderrBytes.addAll(chunk.take(remaining));
        },
        onDone: stderrDone.complete,
        onError: (Object error, StackTrace stack) {
          stderrDone.completeError(error, stack);
        },
      );
      identity = PluginProcessIdentity.read(process.pid);
      if (identity == null) {
        await process.exitCode;
        exited = true;
        throw const FormatException(
          'server exited before its identity was captured',
        );
      }
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      if (!line.startsWith('ready ')) {
        throw FormatException('unexpected readiness line: $line');
      }
      final url = Uri.parse(line.substring(6));
      if (url.scheme != 'nats' ||
          url.host != '127.0.0.1' ||
          !url.hasPort ||
          url.port == 0) {
        throw FormatException('server returned a non-loopback URL: $url');
      }
      return NatsTestServer._(
        process,
        identity,
        scratch,
        url,
        stderrDone.future,
      );
    } on Object catch (error) {
      if (process != null) {
        if (!exited) {
          if (identity == null) {
            process.kill(ProcessSignal.sigkill);
          } else {
            identity.signalIfExact(ProcessSignal.sigkill);
          }
          await process.exitCode;
        }
        await stderrDone.future;
      }
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      final diagnostic = utf8.decode(stderrBytes, allowMalformed: true).trim();
      throw NatsStartupException(
        '$error${diagnostic.isEmpty ? '' : ': $diagnostic'}',
      );
    }
  }

  final Process _process;
  final PluginProcessIdentity _identity;
  final Future<void> _stderrDone;
  bool _closed = false;

  /// The server's loopback URL.
  final Uri url;

  /// The owner-only scratch directory, removed on close.
  final Directory scratch;

  /// The exact server process id.
  int get pid => _process.pid;

  /// Stops the owned server and removes its scratch directory.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _process.stdin.close();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _identity.signalIfExact(ProcessSignal.sigkill);
      await _process.exitCode.timeout(const Duration(seconds: 5));
    }
    await _stderrDone;
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }
}
