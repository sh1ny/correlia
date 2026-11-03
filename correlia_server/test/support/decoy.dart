import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A running `decoy_listener.dart`: a stand-in for a foreign PostgreSQL
/// that counts every connection it accepts.
final class Decoy {
  Decoy._(this.process, this.tcpPort, this.socketPath, this._lines);

  /// The listener process.
  final Process process;

  /// The loopback TCP port it listens on.
  final int tcpPort;

  /// Its `.s.PGSQL.<port>` Unix socket.
  final String socketPath;

  final StreamIterator<String> _lines;

  /// Whether the listener process has exited.
  bool exited = false;

  /// Starts a decoy whose Unix socket lives in [dir].
  static Future<Decoy> start(Directory dir) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      p.join(Directory.current.path, 'test', 'support', 'decoy_listener.dart'),
      dir.path,
    ]);
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    unawaited(process.stderr.drain<void>());
    while (await lines.moveNext().timeout(const Duration(seconds: 60))) {
      if (lines.current.startsWith('READY ')) {
        final port = int.parse(lines.current.substring(6));
        final decoy = Decoy._(
          process,
          port,
          p.join(dir.path, '.s.PGSQL.$port'),
          lines,
        );
        unawaited(process.exitCode.then((_) => decoy.exited = true));
        return decoy;
      }
    }
    throw StateError('the decoy never became ready');
  }

  /// Asks the decoy how many connections it has accepted; proves it runs.
  Future<int> ping() async {
    process.stdin.writeln('ping');
    while (await _lines.moveNext()) {
      if (_lines.current.startsWith('PONG ')) {
        return int.parse(_lines.current.substring(5));
      }
    }
    throw StateError('the decoy closed its output');
  }

  /// Stops the listener and waits for it to exit.
  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode;
  }
}
