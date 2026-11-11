import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';
import 'package:uuid/uuid.dart';

import '../plugin_generated/correlia/plugin/spike/v1/output.pbgrpc.dart';
import 'bounded_channel.dart';
import 'openssl_socket.dart';
import 'plugin_tls.dart';

/// An immutable PEM client certificate and private key snapshot.
final class PluginClientIdentity {
  /// Snapshots the supplied identity bytes.
  PluginClientIdentity({
    required List<int> certificatePem,
    required List<int> privateKeyPem,
  }) : certificatePem = List<int>.unmodifiable(certificatePem),
       privateKeyPem = List<int>.unmodifiable(privateKeyPem);

  /// The PEM certificate bytes.
  final List<int> certificatePem;

  /// The PEM private key bytes.
  final List<int> privateKeyPem;
}

/// An authenticated, bounded connection to one stock plugin.
final class PluginRpcConnection {
  PluginRpcConnection._(this._channel, this._connector, this._timeout)
    : outputClient = OutputServiceClient(_channel),
      _compat = _CompatibilityClient(_channel);

  final ClientTransportConnectorChannel _channel;
  final _SocketConnector _connector;
  final Duration _timeout;
  final _CompatibilityClient _compat;
  StreamSubscription<List<int>>? _stdio;
  ResponseStream<List<int>>? _stdioCall;
  bool _closed = false;

  /// The experimental application client, without a whole-stream deadline.
  final OutputServiceClient outputClient;

  /// The observed native TLS facts, retained after closing the connection.
  PluginTlsEvidence? get tlsEvidence => _connector.tlsEvidence;

  /// The original socket or native TLS failure, when one occurred.
  Object? get transportFailure => _connector.failure;

  /// Connects and requires the stock health service to report SERVING.
  static Future<PluginRpcConnection> connect({
    required String socketPath,
    required String? serverCertificateDerBase64,
    required PluginClientIdentity? identity,
    bool secure = true,
    Duration timeout = const Duration(seconds: 10),
    String? expectedServerCertificatePem,
    PluginTlsTestControls testControls = const PluginTlsTestControls(),
  }) async {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    final watch = Stopwatch()..start();
    List<int>? pinnedDer;
    if (secure) {
      if (expectedServerCertificatePem != null) {
        pinnedDer = _pemDer(expectedServerCertificatePem);
      } else {
        if (serverCertificateDerBase64 == null ||
            serverCertificateDerBase64.isEmpty) {
          throw const FormatException('missing server certificate');
        }
        pinnedDer = base64.decode(base64.normalize(serverCertificateDerBase64));
      }
    }
    final connector = _SocketConnector(
      socketPath,
      pinnedDer,
      identity,
      timeout,
      testControls,
    );
    try {
      // Readiness owns its deadline; a competing health deadline must not hide
      // an original native handshake failure or an HTTP/2 SETTINGS stall.
      await connector.prepare();
    } on Object {
      connector.shutdown();
      rethrow;
    }
    final options = ChannelOptions(
      credentials: secure
          ? const ChannelCredentials.secure(authority: 'localhost')
          : const ChannelCredentials.insecure(authority: 'localhost'),
      connectTimeout: timeout,
    );
    final channel = ClientTransportConnectorChannel(
      BoundedPluginConnector(connector),
      options: options,
    );
    final result = PluginRpcConnection._(channel, connector, timeout);
    try {
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('plugin startup deadline');
      }
      final status = await result._compat.health(remaining);
      if (status != 1) {
        throw StateError('plugin health is not SERVING: $status');
      }
      result._startStdio();
      return result;
    } on Object catch (error, stack) {
      await result.close();
      Error.throwWithStackTrace(connector.failure ?? error, stack);
    }
  }

  /// Checks the protected output service using a fresh epoch and exact ack.
  Future<void> probe() async {
    final epoch = const Uuid().v4();
    final sequence = Int64.ONE;
    final call = outputClient.deliver(
      Stream.value(DeliverRequest(epoch: epoch, sequence: sequence)),
      options: CallOptions(timeout: _timeout),
    );
    try {
      final response = await call.single;
      if (response.epoch != epoch || response.sequence != sequence) {
        throw StateError('plugin returned an incorrect probe acknowledgement');
      }
    } finally {
      await call.cancel();
    }
  }

  /// Requests stock controller shutdown with a bounded deadline.
  Future<void> requestShutdown() async {
    await _compat.shutdown(_timeout);
  }

  void _startStdio() {
    final call = _compat.stdio();
    _stdioCall = call;
    _stdio = call.listen((_) {}, onError: (Object _, StackTrace _) {});
  }

  /// Cancels stdio and closes the connection without waiting indefinitely.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connector.shutdown();
    try {
      await _stdioCall?.cancel().timeout(_timeout);
      await _stdio?.cancel().timeout(_timeout);
      await _channel.terminate().timeout(_timeout);
    } on TimeoutException {
      _connector.shutdown();
      rethrow;
    }
  }
}

List<int> _pemDer(String pem) {
  final body = pem
      .replaceAll('-----BEGIN CERTIFICATE-----', '')
      .replaceAll('-----END CERTIFICATE-----', '')
      .replaceAll(RegExp(r'\s'), '');
  return base64.decode(body);
}

final class _SocketConnector implements ClientTransportConnector {
  _SocketConnector(
    this.path,
    this.pinnedDer,
    this.identity,
    this.timeout,
    this.testControls,
  );
  final String path;
  final List<int>? pinnedDer;
  final PluginClientIdentity? identity;
  final Duration timeout;
  final PluginTlsTestControls testControls;
  final Completer<void> _done = Completer<void>();
  final List<OpenSslSocket> _tlsSockets = [];
  final List<Socket> _diagnosticSockets = [];
  bool _closed = false;
  Object? failure;
  PluginTlsEvidence? tlsEvidence;
  ClientTransportConnection? _prepared;

  Future<void> prepare() async {
    _prepared = await _open();
  }

  @override
  String get authority => 'localhost';
  @override
  Future<void> get done => _done.future;

  @override
  Future<ClientTransportConnection> connect() {
    if (_closed) throw StateError('connector closed');
    final prepared = _prepared;
    if (prepared != null) {
      _prepared = null;
      return Future.value(prepared);
    }
    return _open();
  }

  Future<ClientTransportConnection> _open() async {
    if (_closed) throw StateError('connector closed');
    final watch = Stopwatch()..start();
    Duration remaining() {
      final value = timeout - watch.elapsed;
      if (value <= Duration.zero) {
        throw TimeoutException('plugin transport startup deadline');
      }
      return value;
    }

    OpenSslSocket? native;
    Socket? diagnostic;
    try {
      if (pinnedDer == null) {
        diagnostic = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
          timeout: remaining(),
        );
        if (_closed) throw StateError('connector closed during connection');
        _diagnosticSockets.add(diagnostic);
        unawaited(
          diagnostic.done.then<void>(
            (_) => _complete(),
            onError: (Object _, StackTrace _) => _complete(),
          ),
        );
        return ClientTransportConnection.viaSocket(diagnostic);
      }
      native = await OpenSslSocket.connect(
        path,
        peerCertificateDer: pinnedDer!,
        certificatePem: identity?.certificatePem,
        privateKeyPem: identity?.privateKeyPem,
        timeout: remaining(),
        testControls: testControls,
      );
      if (_closed) throw StateError('connector closed during connection');
      _tlsSockets.add(native);
      tlsEvidence = native.tlsEvidence;
      final socket = native;
      unawaited(
        socket.done.then<void>((_) {
          failure ??= socket.failure;
          _complete();
        }),
      );
      final transport = ClientTransportConnection.viaStreams(
        socket.incoming,
        socket.outgoing,
      );
      // TLS 1.3 can complete locally before the peer rejects our client identity.
      // A transport is ready only after its first authenticated HTTP/2 SETTINGS.
      await Future.any<void>([
        transport.onInitialPeerSettingsReceived,
        socket.done.then<void>((_) {
          throw socket.failure ??
              const SocketException('TLS closed before HTTP/2 readiness');
        }),
      ]).timeout(remaining());
      return transport;
    } on Object catch (error) {
      failure ??= error;
      native?.destroy();
      diagnostic?.destroy();
      rethrow;
    }
  }

  void _complete() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void shutdown() {
    _closed = true;
    for (final socket in _tlsSockets) {
      socket.destroy();
    }
    _tlsSockets.clear();
    for (final socket in _diagnosticSockets) {
      socket.destroy();
    }
    _diagnosticSockets.clear();
    _complete();
  }
}

// Wire method/field provenance: gRPC health checking protocol
// https://github.com/grpc/grpc/blob/master/doc/health-checking.md and stock
// https://github.com/hashicorp/go-plugin/tree/v1.8.0/internal/plugin.
final class _CompatibilityClient extends Client {
  _CompatibilityClient(super.channel);

  static final _health = ClientMethod<List<int>, int>(
    '/grpc.health.v1.Health/Check',
    (bytes) => bytes,
    _healthStatus,
  );
  static final _shutdown = ClientMethod<List<int>, List<int>>(
    '/plugin.GRPCController/Shutdown',
    (bytes) => bytes,
    (bytes) => bytes,
  );
  static final _stdio = ClientMethod<List<int>, List<int>>(
    '/plugin.GRPCStdio/StreamStdio',
    (bytes) => bytes,
    (bytes) => bytes,
  );

  Future<int> health(Duration timeout) => $createUnaryCall(_health, <int>[
    10,
    6,
    ...utf8.encode('plugin'),
  ], options: CallOptions(timeout: timeout));
  Future<List<int>> shutdown(Duration timeout) => $createUnaryCall(
    _shutdown,
    <int>[],
    options: CallOptions(timeout: timeout),
  );
  ResponseStream<List<int>> stdio() =>
      $createStreamingCall(_stdio, Stream.value(<int>[]));
}

int _healthStatus(List<int> bytes) {
  var index = 0;
  int varint() {
    var result = 0;
    var shift = 0;
    while (index < bytes.length && shift < 64) {
      final byte = bytes[index++];
      result |= (byte & 127) << shift;
      if (byte < 128) return result;
      shift += 7;
    }
    throw const FormatException('invalid protobuf varint');
  }

  var status = 0;
  while (index < bytes.length) {
    final tag = varint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 0) throw const FormatException('invalid protobuf field');
    switch (wire) {
      case 0:
        final value = varint();
        if (field == 1) status = value;
      case 1:
        index += 8;
      case 2:
        final length = varint();
        index += length;
      case 5:
        index += 4;
      default:
        throw const FormatException('invalid protobuf wire type');
    }
    if (index > bytes.length) throw const FormatException('truncated protobuf');
  }
  return status;
}
