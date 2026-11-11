import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'openssl_engine.dart';
import 'plugin_tls.dart';

/// A bounded asynchronous Unix socket backed by the native TLS engine.
final class OpenSslSocket implements StreamSink<List<int>> {
  OpenSslSocket._(this._raw, this._engine) {
    unawaited(
      _handshake.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    _incoming = StreamController<List<int>>(
      sync: true,
      // HTTP/2 initializes its writer after subscribing to its reader.
      onListen: () => scheduleMicrotask(_pump),
      onPause: _pump,
      onResume: () => scheduleMicrotask(_pump),
      onCancel: destroy,
    );
    _raw.readEventsEnabled = true;
    _raw.writeEventsEnabled = false;
    _subscription = _raw.listen(_event, onError: _fail, onDone: _rawDone);
  }

  /// Connects and authenticates the peer before returning the socket.
  static Future<OpenSslSocket> connect(
    String path, {
    required List<int> peerCertificateDer,
    List<int>? certificatePem,
    List<int>? privateKeyPem,
    Duration timeout = const Duration(seconds: 10),
    PluginTlsTestControls testControls = const PluginTlsTestControls(),
  }) async {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    NativeTlsEngine.verifyBackend(testControls);
    final deadline = Stopwatch()..start();
    var expired = false;
    final connector =
        testControls.socketConnector ??
        (InternetAddress address, int port) => RawSocket.connect(address, port);
    final connecting = connector(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    // A timeout does not cancel the OS acquisition; its late receipt remains owned.
    unawaited(
      connecting.then<void>((raw) {
        if (expired) raw.close();
      }, onError: (Object _, StackTrace _) {}),
    );
    RawSocket raw;
    try {
      raw = await connecting.timeout(timeout);
    } on Object {
      expired = true;
      rethrow;
    }
    NativeTlsEngine? engine;
    OpenSslSocket? socket;
    try {
      engine = NativeTlsEngine(
        peerCertificateDer: peerCertificateDer,
        certificatePem: certificatePem,
        privateKeyPem: privateKeyPem,
        testControls: testControls,
      );
      socket = OpenSslSocket._(raw, engine);
      socket._pump();
      final remaining = timeout - deadline.elapsed;
      if (remaining <= Duration.zero)
        throw TimeoutException('TLS handshake timed out', timeout);
      await socket._handshake.future.timeout(remaining);
      return socket;
    } on Object {
      if (socket != null) {
        socket.destroy();
      } else {
        raw.close();
        engine?.dispose();
      }
      rethrow;
    }
  }

  final RawSocket _raw;
  final NativeTlsEngine _engine;
  late final StreamSubscription<RawSocketEvent> _subscription;
  late final StreamController<List<int>> _incoming;
  late final PluginTlsEvidence _tlsEvidence;
  final Completer<void> _handshake = Completer<void>();
  final Completer<void> _done = Completer<void>();
  final Queue<Uint8List> _queue = Queue<Uint8List>();
  final Uint8List _cipher = Uint8List(16384);
  int _cipherOffset = 0;
  int _cipherCount = 0;
  int _plainOffset = 0;
  int _queuedBytes = 0;
  int? _retryLength;
  Completer<void>? _writable;
  StreamIterator<List<int>>? _source;
  bool _authenticated = false;
  bool _pumping = false;
  bool _repump = false;
  bool _closing = false;
  bool _closed = false;
  bool _addingStream = false;
  Object? _failure;

  /// The authenticated plaintext stream.
  Stream<List<int>> get incoming => _incoming.stream;

  /// The plaintext sink.
  StreamSink<List<int>> get outgoing => this;

  /// The observed TLS facts, retained after native state is released.
  PluginTlsEvidence get tlsEvidence => _tlsEvidence;

  /// The negotiated TLS protocol version.
  String get tlsVersion => _tlsEvidence.protocol;

  /// The loaded OpenSSL library version.
  String get libraryVersion => _tlsEvidence.backendVersion;

  /// The original transport failure, if the socket failed.
  Object? get failure => _failure;

  /// The plaintext bytes currently retained by the bounded output queue.
  int get queuedPlaintextBytes => _queuedBytes;

  @override
  Future<void> get done => _done.future;

  @override
  void add(List<int> data) {
    if (_closed || _closing || _addingStream)
      throw StateError('socket sink is closed or busy');
    _admit(data);
  }

  void _admit(List<int> data, [int offset = 0, int? count]) {
    final length = count ?? data.length;
    if (_closed || _closing) throw StateError('socket sink is closed');
    if (length == 0) return;
    if (_queuedBytes + length > 256 * 1024) {
      final error = StateError('TLS plaintext queue exceeds 256 KiB');
      _fail(error, StackTrace.current);
      throw error;
    }
    final retained = Uint8List(length)..setRange(0, length, data, offset);
    _queue.add(retained);
    _queuedBytes += length;
    _pump();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _fail(error, stackTrace ?? StackTrace.current);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    if (_closed || _closing || _addingStream)
      throw StateError('socket sink is closed or busy');
    _addingStream = true;
    final source = StreamIterator<List<int>>(stream);
    _source = source;
    try {
      while (await source.moveNext()) {
        final data = source.current;
        var offset = 0;
        while (offset < data.length) {
          // Cancellation retires this writer; native failures are already
          // reported through incoming and retained in failure, not duplicated
          // as a new error from the HTTP/2 writer's canceled source.
          if (_closed || _closing) return;
          if (_queuedBytes == 256 * 1024) {
            await (_writable ??= Completer<void>()).future;
            continue;
          }
          final length = math.min(
            16384,
            math.min(data.length - offset, 256 * 1024 - _queuedBytes),
          );
          _admit(data, offset, length);
          offset += length;
        }
      }
    } finally {
      _source = null;
      await source.cancel();
      _addingStream = false;
    }
  }

  @override
  Future<void> close() {
    if (!_closed) {
      _closing = true;
      _pump();
    }
    return done;
  }

  /// Immediately releases the raw socket and native TLS state.
  void destroy() => _finish();

  void _event(RawSocketEvent event) {
    if (event == RawSocketEvent.readClosed || event == RawSocketEvent.closed) {
      if (!_closed)
        _fail(
          const SocketException('TLS socket closed by peer'),
          StackTrace.current,
        );
      return;
    }
    _pump();
  }

  void _rawDone() {
    if (!_closed)
      _fail(
        const SocketException('TLS socket ended unexpectedly'),
        StackTrace.current,
      );
  }

  void _pump() {
    if (_closed) return;
    if (_pumping) {
      _repump = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _repump = false;
        var progress = true;
        while (progress && !_closed) {
          progress = false;
          if (_cipherOffset < _cipherCount) {
            final n = _raw.write(
              _cipher,
              _cipherOffset,
              _cipherCount - _cipherOffset,
            );
            if (n > 0) {
              _cipherOffset += n;
              progress = true;
            }
          }
          if (_cipherOffset == _cipherCount) {
            _cipherOffset = 0;
            _cipherCount = _engine.takeCipher(_cipher);
            if (_cipherCount > 0) progress = true;
          }
          final canRead =
              !_authenticated || (_incoming.hasListener && !_incoming.isPaused);
          if (canRead && _engine.receiveCapacity > 0) {
            final bytes = _raw.read(math.min(_engine.receiveCapacity, 16384));
            if (bytes != null && bytes.isNotEmpty) {
              _engine.receive(bytes);
              progress = true;
            }
          }
          if (!_authenticated) {
            if (_engine.handshake()) {
              _tlsEvidence = _engine.evidence;
              _authenticated = true;
              _handshake.complete();
              progress = true;
            }
          } else {
            if (canRead) {
              final bytes = _engine.readPlain();
              if (bytes != null && bytes.isNotEmpty) {
                _incoming.add(bytes);
                if (_closed) break;
                progress = true;
              }
              if (_engine.peerClosed) {
                _finish();
                break;
              }
            }
            if (_queue.isNotEmpty) {
              final head = _queue.first;
              final length =
                  _retryLength ?? math.min(16384, head.length - _plainOffset);
              final n = _engine.writePlain(head, _plainOffset, length);
              if (n == 0) {
                _retryLength = length;
              } else {
                _retryLength = null;
                _plainOffset += n;
                if (_plainOffset == head.length) {
                  _queue.removeFirst();
                  _queuedBytes -= head.length;
                  _plainOffset = 0;
                  final writable = _writable;
                  _writable = null;
                  writable?.complete();
                }
                progress = true;
              }
            }
          }
          // A WANT result can still produce outgoing handshake or record bytes.
          if (_cipherOffset == _cipherCount) {
            _cipherOffset = 0;
            _cipherCount = _engine.takeCipher(_cipher);
            if (_cipherCount > 0) progress = true;
          }
          if (_closing && _queue.isEmpty && _cipherOffset == _cipherCount)
            _finish();
        }
        if (!_closed) {
          _raw.readEventsEnabled =
              !_authenticated ||
              (_incoming.hasListener &&
                  !_incoming.isPaused &&
                  _engine.receiveCapacity > 0);
          _raw.writeEventsEnabled = _cipherOffset < _cipherCount;
        }
      } while (_repump && !_closed);
    } on Object catch (error, stackTrace) {
      _fail(error, stackTrace);
    } finally {
      _pumping = false;
    }
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_closed) return;
    _failure = error;
    if (!_handshake.isCompleted) {
      _handshake.completeError(error, stackTrace);
    } else if (_incoming.hasListener) {
      _incoming.addError(error, stackTrace);
    }
    _finish();
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    if (!_handshake.isCompleted) {
      _handshake.completeError(
        const SocketException('TLS socket closed during handshake'),
      );
    }
    unawaited(_subscription.cancel());
    _raw.close();
    _engine.dispose();
    _queue.clear();
    _queuedBytes = 0;
    final source = _source;
    if (source != null) unawaited(source.cancel());
    final writable = _writable;
    _writable = null;
    writable?.complete();
    // A paused or absent reader must not retain resources or prevent completion.
    unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }
}
