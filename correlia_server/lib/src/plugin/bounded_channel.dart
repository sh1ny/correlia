import 'dart:async';
import 'dart:convert';

import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';

/// The largest permitted encoded gRPC message in either direction.
const int pluginGrpcMessageLimit = 2 * 1024 * 1024;

/// Incrementally validates gRPC message envelopes without buffering bodies.
final class GrpcFrameGuard {
  /// Creates a guard with the maximum encoded message size.
  GrpcFrameGuard({this.limit = pluginGrpcMessageLimit});

  /// The maximum encoded message body size.
  final int limit;

  int _prefixBytes = 0;
  int _length = 0;
  int _remaining = 0;

  /// Validates the next bytes before they reach the gRPC decoder.
  void add(List<int> bytes) {
    var offset = 0;
    while (offset < bytes.length) {
      if (_remaining > 0) {
        final available = bytes.length - offset;
        final count = available < _remaining ? available : _remaining;
        offset += count;
        _remaining -= count;
        continue;
      }
      final byte = bytes[offset++];
      if (_prefixBytes == 0) {
        if (byte != 0) {
          throw const FormatException('compressed or invalid gRPC frame');
        }
        _length = 0;
      } else {
        _length = (_length << 8) | byte;
      }
      _prefixBytes++;
      if (_prefixBytes == 5) {
        if (_length > limit) {
          throw FormatException('gRPC message exceeds $limit bytes');
        }
        _remaining = _length;
        _prefixBytes = 0;
      }
    }
  }

  /// Rejects a stream ending in a partial envelope or body.
  void finish() {
    if (_prefixBytes != 0 || _remaining != 0) {
      throw const FormatException('truncated gRPC frame');
    }
  }
}

/// Wraps a connector so every stream is validated before gRPC decoding.
final class BoundedPluginConnector implements ClientTransportConnector {
  /// Wraps [delegate].
  BoundedPluginConnector(this.delegate);

  /// The underlying socket connector.
  final ClientTransportConnector delegate;

  /// The last rejected gRPC frame, when one has been observed.
  FormatException? frameFailure;

  @override
  Future<ClientTransportConnection> connect() async =>
      _Connection(await delegate.connect(), this);
  @override
  Future<void> get done async {
    await delegate.done;
  }

  @override
  void shutdown() => delegate.shutdown();
  @override
  String get authority => delegate.authority;
}

final class _Connection implements ClientTransportConnection {
  _Connection(this._delegate, this._owner);
  final ClientTransportConnection _delegate;
  final BoundedPluginConnector _owner;
  @override
  bool get isOpen => _delegate.isOpen;
  @override
  ClientTransportStream makeRequest(
    List<Header> headers, {
    bool endStream = false,
  }) {
    var responseLimit = pluginGrpcMessageLimit;
    for (final header in headers) {
      if (ascii.decode(header.name) != ':path') continue;
      final path = ascii.decode(header.value);
      if (path == '/correlia.plugin.v1.PluginService/GetMetadata' ||
          path == '/correlia.plugin.v1.PluginService/Configure') {
        responseLimit = 64 * 1024;
      }
      break;
    }
    return _Stream(
      _delegate.makeRequest(headers, endStream: endStream),
      responseLimit,
      _owner,
    );
  }

  @override
  Future<void> ping() async {
    await _delegate.ping();
  }

  @override
  set onActiveStateChanged(ActiveStateHandler callback) =>
      _delegate.onActiveStateChanged = callback;
  @override
  Future<void> get onInitialPeerSettingsReceived =>
      _delegate.onInitialPeerSettingsReceived;
  @override
  Stream<int> get onPingReceived => _delegate.onPingReceived;
  @override
  Stream<void> get onFrameReceived => _delegate.onFrameReceived;
  @override
  Future<void> finish() async {
    await _delegate.finish();
  }

  @override
  Future<void> terminate([int? errorCode]) async {
    await _delegate.terminate(errorCode);
  }
}

final class _Stream implements ClientTransportStream {
  _Stream(this._delegate, int responseLimit, this._owner)
    : _guard = GrpcFrameGuard(limit: responseLimit) {
    _outgoing = _GuardedSink(_delegate, _fail);
    _incoming = StreamController<StreamMessage>(
      onListen: _listen,
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: () async {
        _delegate.terminate();
        await _subscription?.cancel();
      },
    );
  }
  final ClientTransportStream _delegate;
  final BoundedPluginConnector _owner;
  late final _GuardedSink _outgoing;
  late final StreamController<StreamMessage> _incoming;
  StreamSubscription<StreamMessage>? _subscription;
  final GrpcFrameGuard _guard;

  void _fail(Object error, [StackTrace? stackTrace]) {
    if (error is FormatException) _owner.frameFailure = error;
    _delegate.terminate();
    if (!_incoming.isClosed) {
      _incoming.addError(error, stackTrace);
      unawaited(_incoming.close());
    }
    unawaited(_subscription?.cancel());
  }

  void _listen() {
    _subscription = _delegate.incomingMessages.listen(
      (message) {
        try {
          if (message is DataStreamMessage) _guard.add(message.bytes);
          if (message.endStream) _guard.finish();
          if (!_incoming.isClosed) _incoming.add(message);
        } on FormatException catch (error, stackTrace) {
          _fail(error, stackTrace);
        }
      },
      onError: _fail,
      onDone: () {
        if (_incoming.isClosed) return;
        try {
          _guard.finish();
          unawaited(_incoming.close());
        } on FormatException catch (error, stackTrace) {
          _fail(error, stackTrace);
        }
      },
    );
  }

  @override
  int get id => _delegate.id;
  @override
  Stream<StreamMessage> get incomingMessages => _incoming.stream;
  @override
  StreamSink<StreamMessage> get outgoingMessages => _outgoing;
  @override
  set onTerminated(void Function(int?) value) => _delegate.onTerminated = value;
  @override
  void terminate() => _delegate.terminate();
  @override
  Stream<TransportStreamPush> get peerPushes => _delegate.peerPushes;
  @override
  void sendHeaders(List<Header> headers, {bool endStream = false}) {
    _outgoing.add(HeadersStreamMessage(headers, endStream: endStream));
    if (endStream) unawaited(_outgoing.close());
  }

  @override
  void sendData(List<int> bytes, {bool endStream = false}) {
    _outgoing.add(DataStreamMessage(bytes, endStream: endStream));
    if (endStream) unawaited(_outgoing.close());
  }
}

final class _GuardedSink implements StreamSink<StreamMessage> {
  _GuardedSink(this._stream, this._fail);
  final ClientTransportStream _stream;
  final void Function(Object, [StackTrace?]) _fail;
  final GrpcFrameGuard _guard = GrpcFrameGuard();
  bool _failed = false;
  @override
  void add(StreamMessage event) {
    if (_failed) return;
    try {
      if (event is DataStreamMessage) _guard.add(event.bytes);
      if (event.endStream) _guard.finish();
    } on FormatException catch (error, stackTrace) {
      _failed = true;
      _fail(error, stackTrace);
      return;
    }
    try {
      _stream.outgoingMessages.add(event);
    } on StateError catch (_, stackTrace) {
      _failed = true;
      _fail(const GrpcError.unavailable('plugin transport closed'), stackTrace);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _stream.outgoingMessages.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<StreamMessage> stream) async {
    await for (final message in stream) {
      add(message);
    }
  }

  @override
  Future<void> close() {
    if (!_failed) {
      try {
        _guard.finish();
      } on FormatException catch (error, stackTrace) {
        _failed = true;
        _fail(error, stackTrace);
      }
    }
    return _stream.outgoingMessages.close();
  }

  @override
  Future<void> get done => _stream.outgoingMessages.done;
}
