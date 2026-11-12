@Tags(['plugin'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/plugin/output_plugin_connection.dart';
import 'package:test/test.dart';

import '../unit/event/fixture.dart';
import 'support/natsdev.dart';

const _trace = '00-11111111111111111111111111111111-2222222222222222-01';

// Minimal test-owned NATS wire client. It inspects the actual delivered bytes
// and headers and uses JetStream's management API only to provision the stream.
final class _Nats {
  _Nats(this.socket) : input = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<List<int>> input;
  final List<int> buffer = [];
  int sid = 0;

  static Future<_Nats> connect(Uri url, {String? token}) async {
    final client = _Nats(await Socket.connect(url.host, url.port));
    final info = await client.line();
    if (!info.startsWith('INFO ')) throw StateError('missing NATS INFO');
    client.socket.write(
      'CONNECT ${jsonEncode({'verbose': false, 'headers': true, 'auth_token': ?token})}\r\nPING\r\n',
    );
    while (true) {
      final response = await client.line();
      if (response == 'PONG') break;
      if (response == 'PING') {
        client.socket.write('PONG\r\n');
      } else if (response != '+OK' && !response.startsWith('INFO ')) {
        throw StateError('NATS connection failed: $response');
      }
    }
    return client;
  }

  Future<void> fill(int count) async {
    while (buffer.length < count) {
      if (!await input.moveNext().timeout(const Duration(seconds: 10))) {
        throw StateError('NATS connection closed');
      }
      buffer.addAll(input.current);
    }
  }

  Future<String> line() async {
    while (true) {
      for (var i = 0; i + 1 < buffer.length; i++) {
        if (buffer[i] == 13 && buffer[i + 1] == 10) {
          final line = utf8.decode(buffer.sublist(0, i));
          buffer.removeRange(0, i + 2);
          return line;
        }
      }
      await fill(buffer.length + 1);
    }
  }

  Future<_Message> message() async {
    while (true) {
      final header = await line();
      if (header == 'PING') {
        socket.write('PONG\r\n');
        continue;
      }
      if (header == 'PONG' || header.startsWith('+OK')) continue;
      final parts = header.split(' ');
      if (parts.first != 'MSG' && parts.first != 'HMSG') {
        throw StateError('unexpected NATS response: $header');
      }
      final total = int.parse(parts.last);
      final headerLength = parts.first == 'HMSG'
          ? int.parse(parts[parts.length - 2])
          : 0;
      await fill(total + 2);
      final bytes = buffer.sublist(0, total);
      buffer.removeRange(0, total + 2);
      final headers = <String, String>{};
      if (headerLength != 0) {
        for (final entry
            in utf8
                .decode(bytes.sublist(0, headerLength))
                .split('\r\n')
                .skip(1)) {
          final split = entry.indexOf(':');
          if (split > 0) {
            headers[entry.substring(0, split).toLowerCase()] = entry
                .substring(split + 1)
                .trim();
          }
        }
      }
      return _Message(parts[1], headers, bytes.sublist(headerLength));
    }
  }

  Future<void> createStream() async {
    const inbox = '_INBOX.correlia_test';
    final body = utf8.encode(
      jsonEncode({
        'name': 'CORRELIA_EVENTS',
        'subjects': ['correlia.v1.ev.>'],
        'duplicate_window': 600000000000,
      }),
    );
    socket.write(
      'SUB $inbox ${++sid}\r\nPUB \$JS.API.STREAM.CREATE.CORRELIA_EVENTS $inbox ${body.length}\r\n',
    );
    socket.add(body);
    socket.write('\r\n');
    final result =
        jsonDecode(utf8.decode((await message()).body)) as Map<String, Object?>;
    if (result.containsKey('error')) {
      throw StateError('stream setup failed: ${result['error']}');
    }
  }

  Future<Map<String, Object?>> streamInfo() async {
    final inbox = '_INBOX.correlia_info_${++sid}';
    final subscription = sid;
    socket.write(
      'SUB $inbox $subscription\r\nUNSUB $subscription 1\r\n'
      'PUB \$JS.API.STREAM.INFO.CORRELIA_EVENTS $inbox 0\r\n\r\n',
    );
    return jsonDecode(utf8.decode((await message()).body))
        as Map<String, Object?>;
  }

  Future<void> subscribe() async {
    socket.write('SUB correlia.v1.ev.> ${++sid}\r\nPING\r\n');
    while (await line() != 'PONG') {}
  }

  Future<void> close() async {
    await input.cancel();
    socket.destroy();
  }
}

final class _Message {
  _Message(this.subject, this.headers, this.body);
  final String subject;
  final Map<String, String> headers;
  final List<int> body;
}

void main() {
  final executable =
      '${Directory.current.parent.path}/build/plugins/output-nats';
  final servers = <NatsTestServer>[];
  final clients = <_Nats>[];
  final connections = <OutputPluginConnection>[];

  tearDown(() async {
    for (final connection in connections.reversed) {
      await connection.stop();
    }
    for (final client in clients.reversed) {
      await client.close();
    }
    for (final server in servers.reversed) {
      await server.close();
    }
    connections.clear();
    clients.clear();
    servers.clear();
  });

  Future<(NatsTestServer, _Nats)> server({
    String? token,
    int? maxPayload,
    bool stream = true,
  }) async {
    final nats = await NatsTestServer.start(
      token: token,
      maxPayload: maxPayload,
    );
    servers.add(nats);
    final client = await _Nats.connect(nats.url, token: token);
    clients.add(client);
    if (stream) await client.createStream();
    return (nats, client);
  }

  Future<OutputPluginConnection> connect(
    NatsTestServer nats, {
    Map<String, List<int>> secrets = const {},
  }) async {
    final connection = await OutputPluginConnection.start(
      executable: executable,
      configJson: utf8.encode(
        jsonEncode({
          'server': nats.url.toString(),
          'stream': 'CORRELIA_EVENTS',
        }),
      ),
      secrets: secrets,
    );
    connections.add(connection);
    return connection;
  }

  OutputPluginEvent event({
    bool trace = false,
    String? tenant,
    int? padding,
    bool critical = false,
  }) {
    final envelope = eventFixture();
    if (trace) envelope['traceparent'] = _trace;
    if (tenant != null) {
      (envelope['data']! as Map<String, Object?>)['tenant'] = tenant;
    }
    if (padding != null) {
      (envelope['data']! as Map<String, Object?>)['summary'] = 'x' * padding;
    }
    if (critical) {
      (envelope['data']! as Map<String, Object?>)['severity'] =
          'EVENT_SEVERITY_CRITICAL';
    }
    return OutputPluginEvent(
      envelope['id']! as String,
      utf8.encode(jsonEncode(envelope)),
    );
  }

  Future<_Message> publish(
    OutputPluginConnection connection,
    _Nats client,
    OutputPluginEvent value,
  ) async {
    await client.subscribe();
    final results = await connection.deliver([value]);
    expect(results.single.outcome, OutputPluginOutcome.acknowledged);
    return client.message();
  }

  test('alert_event_subject', () async {
    final (nats, client) = await server();
    final connection = await connect(nats);
    final value = event(critical: true);
    final message = await publish(connection, client, value);
    expect(
      message.subject,
      'correlia.v1.ev.default.alert.alertmanager.critical',
    );
  });

  test('unsafe_subject_token', () async {
    final (nats, client) = await server();
    final connection = await connect(nats);
    await client.subscribe();
    final bad = event(tenant: 'bad.*');
    final good = event();
    final result = await connection.deliver([
      OutputPluginEvent('bad', bad.payload),
      good,
    ]);
    expect(result[0].outcome, OutputPluginOutcome.rejected);
    expect(result[0].errorClass, 'invalid_subject_token');
    expect(result[1].outcome, OutputPluginOutcome.acknowledged);
    expect(
      (await client.message()).subject,
      'correlia.v1.ev.default.alert.alertmanager.warning',
    );
    final info = await client.streamInfo();
    expect((info['state']! as Map<String, Object?>)['messages'], 1);
  });

  test('subscriber_parses_the_event', () async {
    final (nats, client) = await server();
    final value = event(trace: true);
    final message = await publish(await connect(nats), client, value);
    expect(message.body, value.payload);
    expect(
      CloudEvent.decode(Uint8List.fromList(message.body)).event.eventId,
      value.id,
    );
    final envelope =
        jsonDecode(utf8.decode(value.payload)) as Map<String, Object?>;
    expect(message.headers['nats-msg-id'], value.id);
    expect(message.headers['content-type'], 'application/cloudevents+json');
    for (final key in [
      'specversion',
      'id',
      'type',
      'source',
      'subject',
      'time',
    ]) {
      expect(message.headers['ce-$key'], envelope[key]);
    }
    expect(message.headers['traceparent'], _trace);
  });

  test('envelope_without_traceparent', () async {
    final (nats, client) = await server();
    final message = await publish(await connect(nats), client, event());
    expect(message.headers.containsKey('traceparent'), isFalse);
    for (final key in [
      'nats-msg-id',
      'content-type',
      'ce-specversion',
      'ce-id',
      'ce-type',
      'ce-source',
      'ce-subject',
      'ce-time',
    ]) {
      expect(message.headers[key], isNotEmpty);
    }
  });

  test('nats_unavailable', () async {
    final (nats, _) = await server();
    final connection = await connect(nats);
    await nats.close();
    final result = (await connection.deliver([event()])).single;
    expect(result.outcome, OutputPluginOutcome.retryable);
    expect(result.errorClass, anyOf('nats_unavailable', 'publish_timeout'));
  });

  test('payload_too_large', () async {
    final (nats, _) = await server(maxPayload: 4096);
    final connection = await connect(nats);
    final result = (await connection.deliver([event(padding: 6000)])).single;
    expect(result.outcome, OutputPluginOutcome.rejected);
    expect(result.errorClass, 'payload_too_large');
  });

  test('stream_captures_the_subjects', () async {
    final (nats, _) = await server();
    final connection = await connect(nats);
    expect(connection.configurationInfo['stream'], 'CORRELIA_EVENTS');
    expect(connection.configurationInfo['duplicate_window_ms'], '600000');
  });

  test('no_stream_for_the_subjects', () async {
    final (nats, client) = await server(stream: false);
    await expectLater(
      connect(nats),
      throwsA(
        isA<OutputPluginException>()
            .having((e) => e.fields, 'fields', contains('stream'))
            .having(
              (e) => e.pluginErrorClass,
              'plugin class',
              'stream_missing',
            ),
      ),
    );
    final info = await client.streamInfo();
    expect((info['error']! as Map<String, Object?>)['err_code'], 10059);
  });

  test('token_authentication', () async {
    const token = 'private-test-token-value';
    final (nats, client) = await server(token: token);
    final connection = await connect(
      nats,
      secrets: {'token': utf8.encode(token)},
    );
    final message = await publish(connection, client, event());
    expect(utf8.decode(message.body), isNot(contains(token)));
    expect(message.headers.values.join(' '), isNot(contains(token)));
    expect((await connection.health()).reason, isNot(contains(token)));
    expect(connection.configurationInfo.toString(), isNot(contains(token)));
  });

  test('wrong_credentials', () async {
    final (nats, _) = await server(token: 'correct-private-token');
    const wrong = 'wrong-private-token';
    await expectLater(
      connect(nats, secrets: {'token': utf8.encode(wrong)}),
      throwsA(
        isA<OutputPluginException>()
            .having(
              (e) => e.pluginErrorClass,
              'plugin class',
              'nats_auth_failed',
            )
            .having((e) => e.toString(), 'diagnostic', isNot(contains(wrong))),
      ),
    );
  });

  test('stdin_stays_open', () async {
    final (nats, _) = await server();
    final connection = await connect(nats);
    expect((await connection.health()).serving, isTrue);
    expect(
      (await connection.deliver([event()])).single.outcome,
      OutputPluginOutcome.acknowledged,
    );
    expect((await connection.health()).serving, isTrue);
  });
}
