import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'plugin_fixture_suite.dart';

/// A pre-ack barrier observed by the independent test controller.
final class PluginBarrierObservation {
  /// Creates a barrier observation.
  PluginBarrierObservation({
    required this.epoch,
    required this.sequence,
  });

  /// The connection epoch of the paused batch.
  final String epoch;

  /// The sequence of the paused batch.
  final int sequence;
}

/// A one-shot Unix-socket observer for the receiver's pre-ack barrier.
///
/// The receiver connects to the socket, sends one bounded JSON frame, and
/// waits for one bounded release frame. The socket accepts one connection and
/// rejects additional concurrent connections.
final class PluginControlSocket {
  PluginControlSocket._(this._server, this.socketPath);

  /// Creates a control socket beneath [directory].
  static Future<PluginControlSocket> bind(Directory directory) async {
    final path = '${directory.path}/barrier.sock';
    final file = File(path);
    if (file.existsSync()) await file.delete();

    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    return PluginControlSocket._(server, path);
  }

  final ServerSocket _server;
  final String socketPath;
  _BarrierConnection? _connection;

  /// Waits for the receiver to reach the barrier.
  ///
  /// The accepted socket remains open until [release] or [dispose] is called.
  Future<PluginBarrierObservation> waitForBarrier({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_connection != null) {
      throw StateError('the control barrier already has a connection');
    }
    final socket = await _server.first.timeout(timeout);
    final connection = _BarrierConnection(socket);
    _connection = connection;
    final frame = await connection.readFrame().timeout(timeout);
    final value = jsonDecode(frame);
    if (value is! Map<String, Object?>) {
      throw const FormatException('barrier frame is not an object');
    }
    final type = value['type'];
    final epoch = value['epoch'];
    final sequence = value['sequence'];
    if (type != 'barrier' || epoch is! String || sequence is! int) {
      throw const FormatException('barrier frame is incomplete');
    }
    return PluginBarrierObservation(epoch: epoch, sequence: sequence);
  }

  /// Releases the receiver after the observer has captured its evidence.
  Future<void> release() async {
    final connection = _connection;
    if (connection == null) {
      throw StateError('no receiver is waiting at the control barrier');
    }
    final payload = utf8.encode('${jsonEncode({'type': 'release'})}\n');
    if (payload.length > pluginControlFrameBytes) {
      throw StateError('control release frame exceeds 8 KiB');
    }
    connection.socket.add(payload);
    await connection.socket.flush();
    await connection.socket.close();
  }

  /// Closes the socket without releasing a paused receiver.
  Future<void> dispose() async {
    await _connection?.socket.close();
    await _server.close();
  }
}

final class _BarrierConnection {
  _BarrierConnection(this.socket) {
    socket.listen(
      (chunk) {
        _bytes.addAll(chunk);
        if (_bytes.length > pluginControlFrameBytes) {
          _completeError(const FormatException('control frame exceeds 8 KiB'));
          return;
        }
        if (_bytes.contains(0x0a) && !_completer.isCompleted) {
          final newline = _bytes.indexOf(0x0a);
          _completer.complete(utf8.decode(_bytes.sublist(0, newline)));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _completeError(error, stackTrace);
      },
      onDone: () {
        _completeError(const FormatException('control socket closed'));
      },
      cancelOnError: true,
    );
  }

  final Socket socket;
  final List<int> _bytes = <int>[];
  final Completer<String> _completer = Completer<String>();

  Future<String> readFrame() => _completer.future;

  void _completeError(Object error, [StackTrace? stackTrace]) {
    if (_completer.isCompleted) return;
    if (stackTrace == null) {
      _completer.completeError(error);
    } else {
      _completer.completeError(error, stackTrace);
    }
  }
}
