import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Constructs the production socket adapter around controlled raw sockets.
@visibleForTesting
Socket tlsSocketForTesting(
  RawSecureSocket secure,
  RawSocket raw,
  bool Function() isLive,
) => _TlsSocket(secure, raw, isLive);

/// A cancellable connection attempt whose TLS continuation can be detached.
final class TlsAttempt {
  TlsAttempt(this.host, this.port, this.context, this.isLive);

  final String host;
  final int port;
  final SecurityContext context;
  final bool Function() isLive;
  final _result = Completer<Socket>();
  final _continuation = _TlsContinuation();
  ConnectionTask<RawSocket>? _dial;
  RawSocket? _raw;
  _TlsSocket? _socket;
  bool _aborted = false;

  ConnectionTask<Socket> start() {
    _continuation.success = _connected;
    _continuation.failure = _failed;
    unawaited(_startDial());
    return ConnectionTask.fromSocket(_result.future, abort);
  }

  Future<void> _startDial() async {
    try {
      final dial = await RawSocket.startConnect(host, port);
      if (_aborted) {
        dial.cancel();
        return;
      }
      _dial = dial;
      final raw = await dial.socket;
      _dial = null;
      if (_aborted || !isLive()) {
        unawaited(raw.close());
        abort();
        return;
      }
      _raw = raw;
      for (final (level, option, value) in [
        (RawSocketOption.levelSocket, 9, 1),
        (RawSocketOption.levelTcp, 4, 60),
        (RawSocketOption.levelTcp, 5, 10),
        (RawSocketOption.levelTcp, 6, 6),
      ]) {
        raw.setRawOption(RawSocketOption.fromInt(level, option, value));
      }
      // Only the detachable cell is retained by the SDK's potentially
      // never-settling handshake future.
      final continuation = _continuation;
      unawaited(
        RawSecureSocket.secure(raw, host: host, context: context).then(
          continuation.onSuccess,
          onError: continuation.onFailure,
        ),
      );
    } on Object catch (error, stack) {
      _failed(error, stack);
    }
  }

  void _connected(RawSecureSocket secure) {
    if (_aborted || !isLive()) {
      secure.close();
      abort();
      return;
    }
    _continuation.clear();
    final socket = _TlsSocket(secure, _raw!, isLive);
    _socket = socket;
    _result.complete(socket);
  }

  void _failed(Object error, StackTrace stack) {
    if (_aborted) return;
    _continuation.clear();
    _raw?.close();
    if (!_result.isCompleted) _result.completeError(error, stack);
  }

  /// Immediately cancels dialing, handshake, and any handed-off socket.
  void abort() {
    if (_aborted) return;
    _aborted = true;
    _continuation.clear();
    _dial?.cancel();
    _dial = null;
    _socket?.destroy();
    _raw?.shutdown(SocketDirection.both);
    _raw?.close();
    _raw = null;
    if (!_result.isCompleted) {
      _result.completeError(const SocketException('Connection cancelled'));
    }
  }
}

final class _TlsContinuation {
  void Function(RawSecureSocket)? success;
  void Function(Object, StackTrace)? failure;

  void clear() {
    success = null;
    failure = null;
  }

  void onSuccess(RawSecureSocket socket) {
    final callback = success;
    if (callback == null) {
      socket.shutdown(SocketDirection.both);
      socket.close();
    } else {
      callback(socket);
    }
  }

  void onFailure(Object error, StackTrace stack) => failure?.call(error, stack);
}

final class _TlsSocket extends StreamView<Uint8List> implements Socket {
  factory _TlsSocket(
    RawSecureSocket secure,
    RawSocket raw,
    bool Function() live,
  ) {
    final bridge = _SocketBridge(secure, raw, live);
    return _TlsSocket._(bridge);
  }

  _TlsSocket._(this._bridge) : super(_bridge.input.stream) {
    _sink = IOSink(_bridge);
  }

  final _SocketBridge _bridge;
  late final IOSink _sink;
  @override
  Encoding get encoding => _sink.encoding;
  @override
  set encoding(Encoding value) => _sink.encoding = value;
  @override
  void add(List<int> data) => _sink.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _sink.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _sink.addStream(stream);
  @override
  Future<void> flush() => _sink.flush();
  @override
  Future<void> close() => _sink.close();
  @override
  Future<void> get done => _sink.done;
  @override
  void write(Object? object) => _sink.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _sink.writeln(object);
  @override
  void destroy() => _bridge.abort();
  @override
  InternetAddress get address => _bridge.secure.address;
  @override
  InternetAddress get remoteAddress => _bridge.secure.remoteAddress;
  @override
  int get port => _bridge.secure.port;
  @override
  int get remotePort => _bridge.secure.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _bridge.secure.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _bridge.secure.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) =>
      _bridge.secure.setRawOption(option);
}

final class _SocketBridge implements StreamConsumer<List<int>> {
  _SocketBridge(this.secure, this.raw, this.live) {
    secure.readEventsEnabled = false;
    input = StreamController<Uint8List>(
      sync: true,
      onListen: () => secure.readEventsEnabled = true,
      onPause: () => secure.readEventsEnabled = false,
      onResume: () => secure.readEventsEnabled = true,
      onCancel: abort,
    );
    _events = secure.listen(
      _event,
      onError: (Object e, StackTrace s) {
        if (!input.isClosed) input.addError(e, s);
        abort();
      },
      onDone: abort,
    );
    secure.writeEventsEnabled = false;
  }

  final RawSecureSocket secure;
  final RawSocket raw;
  final bool Function() live;
  late final StreamController<Uint8List> input;
  late final StreamSubscription<RawSocketEvent> _events;
  Completer<void>? _writable;
  bool _closed = false;

  void _event(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = secure.read();
        if (data != null && !input.isClosed) input.add(data);
      case RawSocketEvent.write:
        final waiter = _writable;
        _writable = null;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      case RawSocketEvent.readClosed:
      case RawSocketEvent.closed:
        abort();
    }
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      var offset = 0;
      while (offset < bytes.length) {
        if (_closed || !live()) {
          abort();
          throw const SocketException('Connection cancelled');
        }
        final written = secure.write(bytes, offset);
        offset += written;
        if (offset < bytes.length) {
          final waiter = _writable = Completer<void>();
          secure.writeEventsEnabled = true;
          await waiter.future;
        }
      }
    }
  }

  @override
  Future<void> close() async {
    if (!_closed) secure.shutdown(SocketDirection.send);
  }

  void abort() {
    if (_closed) return;
    _closed = true;
    final waiter = _writable;
    _writable = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    raw.shutdown(SocketDirection.both);
    raw.close();
    secure.shutdown(SocketDirection.both);
    secure.close();
    _events.cancel();
    if (!input.isClosed) input.close();
  }
}
