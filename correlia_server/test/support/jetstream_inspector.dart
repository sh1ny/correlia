import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One message read from the test-owned JetStream stream.
final class StoredNatsMessage {
  /// Captures exact stored body and headers.
  StoredNatsMessage(this.subject, this.headers, this.body);

  /// The NATS subject.
  final String subject;

  /// The decoded NATS headers.
  final Map<String, String> headers;

  /// The exact stored bytes.
  final List<int> body;
}

/// Minimal request client for inspecting the real JetStream management API.
final class JetStreamInspector {
  JetStreamInspector._(this._socket) : _input = StreamIterator(_socket);
  final Socket _socket;
  final StreamIterator<List<int>> _input;
  final List<int> _buffer = [];
  int _sequence = 0;

  /// Connects to an owned test server.
  static Future<JetStreamInspector> connect(Uri url) async {
    final client = JetStreamInspector._(
      await Socket.connect(url.host, url.port),
    );
    final info = await client._line();
    if (!info.startsWith('INFO ')) throw StateError('Missing NATS INFO');
    client._socket.write(
      'CONNECT {"verbose":false,"headers":true}\r\nPING\r\n',
    );
    while (await client._line() != 'PONG') {}
    return client;
  }

  Future<void> _fill(int size) async {
    while (_buffer.length < size) {
      if (!await _input.moveNext().timeout(const Duration(seconds: 10))) {
        throw StateError('NATS connection closed');
      }
      _buffer.addAll(_input.current);
    }
  }

  Future<String> _line() async {
    while (true) {
      for (var i = 0; i + 1 < _buffer.length; i++) {
        if (_buffer[i] == 13 && _buffer[i + 1] == 10) {
          final result = utf8.decode(_buffer.sublist(0, i));
          _buffer.removeRange(0, i + 2);
          return result;
        }
      }
      await _fill(_buffer.length + 1);
    }
  }

  Future<Map<String, Object?>> _request(
    String subject,
    Map<String, Object?> body,
  ) async {
    final id = ++_sequence;
    final inbox = '_INBOX.correlia_inspect_$id';
    final bytes = utf8.encode(jsonEncode(body));
    _socket.write(
      'SUB $inbox $id\r\nUNSUB $id 1\r\nPUB $subject $inbox ${bytes.length}\r\n',
    );
    _socket.add(bytes);
    _socket.write('\r\n');
    while (true) {
      final line = await _line();
      if (line == 'PING') {
        _socket.write('PONG\r\n');
        continue;
      }
      if (line == 'PONG' || line.startsWith('INFO ') || line == '+OK') continue;
      final parts = line.split(' ');
      if (parts.first != 'MSG') {
        throw StateError('Unexpected NATS response: $line');
      }
      final length = int.parse(parts.last);
      await _fill(length + 2);
      final response =
          jsonDecode(utf8.decode(_buffer.sublist(0, length)))
              as Map<String, Object?>;
      _buffer.removeRange(0, length + 2);
      if (response.containsKey('error')) {
        throw StateError('JetStream error: ${response['error']}');
      }
      return response;
    }
  }

  /// Reads every stored message, including its original message-id header.
  Future<List<StoredNatsMessage>> messages() async {
    final info = await _request(r'$JS.API.STREAM.INFO.CORRELIA_EVENTS', {});
    final state = info['state'] as Map<String, Object?>;
    final count = state['messages'] as int;
    if (count == 0) return [];
    final first = state['first_seq'] as int;
    final last = state['last_seq'] as int;
    final messages = <StoredNatsMessage>[];
    for (var seq = first; seq <= last; seq++) {
      final result = await _request(r'$JS.API.STREAM.MSG.GET.CORRELIA_EVENTS', {
        'seq': seq,
      });
      final message = result['message'] as Map<String, Object?>;
      final headerText = utf8.decode(base64.decode(message['hdrs'] as String));
      final headers = <String, String>{};
      for (final line in headerText.split('\r\n').skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          headers[line.substring(0, colon).toLowerCase()] = line
              .substring(colon + 1)
              .trim();
        }
      }
      messages.add(
        StoredNatsMessage(
          message['subject'] as String,
          headers,
          base64.decode(message['data'] as String),
        ),
      );
    }
    if (messages.length != count) {
      throw StateError('JetStream changed during inspection');
    }
    return messages;
  }

  /// Closes the inspection connection.
  Future<void> close() async {
    await _input.cancel();
    _socket.destroy();
  }
}
