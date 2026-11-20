import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A TCP proxy that holds back the last byte of every request until
/// [release] is called.
///
/// A request waiting for the rest of its body keeps its admission slot, so the
/// requests held here overlap for as long as the test wants, with no sleep.
final class HoldingProxy {
  HoldingProxy._(this._server, this._target);

  static Future<HoldingProxy> start(int target) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = HoldingProxy._(server, target);
    server.listen(proxy._accept);
    return proxy;
  }

  final ServerSocket _server;
  final int _target;
  final _release = Completer<void>();
  final _sockets = <Socket>[];

  int get port => _server.port;

  /// Lets every held final byte through.
  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Future<void> _accept(Socket client) async {
    _sockets.add(client);
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _target,
    );
    _sockets.add(upstream);
    upstream.listen(
      client.add,
      onDone: client.destroy,
      onError: (_) => client.destroy(),
    );
    final buffer = BytesBuilder();
    int? total;
    var forwarded = 0;
    client.listen(
      (data) {
        buffer.add(data);
        final bytes = buffer.toBytes();
        total ??= _requestLength(bytes);
        final length = total;
        if (length == null) return;
        // Forward all but the final byte of the request.
        final upTo = bytes.length < length ? bytes.length : length - 1;
        if (upTo > forwarded) {
          upstream.add(bytes.sublist(forwarded, upTo));
          forwarded = upTo;
        }
        if (bytes.length >= length && forwarded == length - 1) {
          forwarded = length;
          final last = bytes.sublist(length - 1, length);
          unawaited(
            _release.future.then((_) {
              try {
                upstream.add(last);
              } on Object {
                // The upstream may already be closed after a refusal.
              }
            }),
          );
        }
      },
      onDone: upstream.destroy,
      onError: (_) => upstream.destroy(),
    );
  }

  /// The byte length of the request whose head is in [bytes], once known.
  static int? _requestLength(List<int> bytes) {
    final text = latin1.decode(bytes);
    final end = text.indexOf('\r\n\r\n');
    if (end < 0) return null;
    final match = RegExp(
      r'content-length:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(text.substring(0, end));
    return end + 4 + int.parse(match!.group(1)!);
  }

  Future<void> close() async {
    release();
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}
