import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A transparent test-owned proxy that can hold replies to a real publish.
final class NatsAckProxy {
  NatsAckProxy._(this._server, this._target) {
    _server.listen(_accept);
  }

  /// Listens on a private loopback port and forwards to [target].
  static Future<NatsAckProxy> start(Uri target) async => NatsAckProxy._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    target,
  );

  final ServerSocket _server;
  final Uri _target;
  final Set<Socket> _sockets = {};
  final Set<Future<void>> _connections = {};
  final Completer<void> _published = Completer<void>();
  bool _hold = true;

  /// The proxy's loopback NATS URL.
  Uri get url => Uri(scheme: 'nats', host: '127.0.0.1', port: _server.port);

  /// Completes after a real JetStream acknowledgement is held from the plugin.
  Future<void> get published => _published.future;

  void _accept(Socket downstream) {
    late Future<void> connection;
    connection = _forward(
      downstream,
    ).whenComplete(() => _connections.remove(connection));
    _connections.add(connection);
  }

  Future<void> _forward(Socket downstream) async {
    _sockets.add(downstream);
    Socket? upstream;
    StreamSubscription<List<int>>? fromClient;
    StreamSubscription<List<int>>? fromServer;
    final closed = Completer<void>();
    var observed = false;
    var prefix = '';
    final held = <List<int>>[];
    try {
      final server = await Socket.connect(_target.host, _target.port);
      upstream = server;
      _sockets.add(server);
      fromClient = downstream.listen(
        (bytes) {
          if (!observed && _hold) {
            prefix += latin1.decode(bytes);
            if (prefix.contains('HPUB correlia.v1.ev.')) {
              observed = true;
            } else if (prefix.length > 256) {
              prefix = prefix.substring(prefix.length - 256);
            }
          }
          server.add(bytes);
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object _) {
          if (!closed.isCompleted) closed.complete();
        },
      );
      fromServer = server.listen(
        (bytes) {
          if (observed && _hold) {
            held.add(bytes);
            if (held.fold<int>(0, (sum, chunk) => sum + chunk.length) > 65536) {
              if (!closed.isCompleted) {
                closed.completeError(
                  StateError('Held NATS reply exceeded 64 KiB'),
                );
              }
              return;
            }
            final captured = latin1.decode(
              held.expand((chunk) => chunk).toList(),
            );
            if (captured.contains('"stream":"CORRELIA_EVENTS"') &&
                !_published.isCompleted) {
              _published.complete();
            }
          } else {
            downstream.add(bytes);
          }
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object _) {
          if (!closed.isCompleted) closed.complete();
        },
      );
      await closed.future;
    } finally {
      await fromClient?.cancel();
      await fromServer?.cancel();
      downstream.destroy();
      upstream?.destroy();
      _sockets.remove(downstream);
      if (upstream != null) _sockets.remove(upstream);
    }
  }

  /// Allows replies on new connections after the held plugin has died.
  void resume() => _hold = false;

  /// Closes all owned connections and the listener.
  Future<void> close() async {
    await _server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await Future.wait(_connections.toList());
  }
}
