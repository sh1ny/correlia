@Tags(['e2e'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/icinga2/stream/https_client.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_reader.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/tls_socket.dart';
import 'package:test/test.dart';

import '../support/icinga2_consumer_loopback.dart';

const _fixtures = '../correlia_icinga2_notify/test/fixtures';
const _password = 'stream-password';
const _user = 'stream-user';

final class _RecordedRequest {
  _RecordedRequest(this.method, this.uri, this.authorization, this.body);

  final String method;
  final Uri uri;
  final String? authorization;
  final String body;
}

final class _HttpsServer {
  _HttpsServer(this.server);

  final HttpServer server;
  final requests = <_RecordedRequest>[];
  int status = HttpStatus.ok;
  String? location;
  String responseBody = '{"type":"StateChange"}\n';

  static Future<_HttpsServer> start({String certificate = 'one'}) async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain('$_fixtures/server_$certificate.pem')
        ..usePrivateKey('$_fixtures/server_$certificate.key'),
    );
    final fixture = _HttpsServer(server);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      fixture.requests.add(
        _RecordedRequest(
          request.method,
          request.uri,
          request.headers.value(HttpHeaders.authorizationHeader),
          body,
        ),
      );
      request.response.statusCode = fixture.status;
      if (fixture.location case final location?) {
        request.response.headers.set(HttpHeaders.locationHeader, location);
      }
      request.response.write(fixture.responseBody);
      await request.response.close();
    });
    return fixture;
  }

  Uri endpoint({String host = '127.0.0.1'}) =>
      Uri(scheme: 'https', host: host, port: server.port);

  Future<void> close() => server.close(force: true);
}

final class _ProxyTripwire {
  _ProxyTripwire(this.socket);
  final ServerSocket socket;
  final ports = <int>{};
  Completer<void>? waiting;

  static Future<_ProxyTripwire> start() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tripwire = _ProxyTripwire(socket);
    socket.listen((client) {
      tripwire.ports.add(client.remotePort);
      client.destroy();
      tripwire.waiting?.complete();
      tripwire.waiting = null;
    });
    return tripwire;
  }

  Future<int> contacts() async {
    final probe = await Socket.connect(
      InternetAddress.loopbackIPv4,
      socket.port,
    );
    while (!ports.contains(probe.port)) {
      await (waiting = Completer<void>()).future;
    }
    probe.destroy();
    return ports.length - 1;
  }

  Future<void> close() => socket.close();
}

Future<IcingaStreamHttpClient> _client(
  Uri endpoint, {
  String ca = 'one',
  bool Function()? isLive,
  Duration headerDeadline = const Duration(seconds: 10),
  String username = _user,
}) async => IcingaStreamHttpClient(
  endpoint: endpoint,
  username: username,
  password: utf8.encode(_password),
  ca: await File('$_fixtures/ca_$ca.pem').readAsBytes(),
  isLive: isLive,
  headerDeadline: headerDeadline,
);

Matcher _failure(String code) => throwsA(
  isA<StreamHttpFailure>().having((error) => error.code, 'code', code),
);

Future<Map<String, Object?>> _hostileProbe(
  Uri endpoint,
  String kernel,
  int proxyPort, {
  String ca = 'one',
  bool proveDefault = false,
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      kernel,
      endpoint.toString(),
      File('$_fixtures/ca_$ca.pem').absolute.path,
      if (proveDefault) '--prove-default',
    ],
    environment: {
      'SSL_CERT_FILE': File('$_fixtures/ca_two.pem').absolute.path,
      'https_proxy': 'http://127.0.0.1:$proxyPort',
      'HTTPS_PROXY': 'http://127.0.0.1:$proxyPort',
      'no_proxy': '',
      'NO_PROXY': '',
    },
  );
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return (jsonDecode(result.stdout as String) as Map<String, Object?>);
}

final class _HandshakeStall {
  _HandshakeStall(this.server);

  final ServerSocket server;
  final connected = Completer<void>();
  final hello = Completer<void>();
  final eof = Completer<void>();
  final bytes = <int>[];
  Socket? peer;

  static Future<_HandshakeStall> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _HandshakeStall(server);
    server.listen((socket) {
      fixture.peer = socket;
      socket.listen(
        (bytes) {
          fixture.bytes.addAll(bytes);
          if (bytes.isNotEmpty && !fixture.hello.isCompleted) {
            fixture.hello.complete();
          }
        },
        onDone: fixture.eof.complete,
        onError: (Object error, StackTrace stack) {
          if (!fixture.eof.isCompleted) fixture.eof.completeError(error, stack);
        },
      );
      fixture.connected.complete();
    });
    return fixture;
  }

  Uri get endpoint =>
      Uri(scheme: 'https', host: '127.0.0.1', port: server.port);

  Future<void> close() async {
    peer?.destroy();
    await server.close();
  }
}

final class _RawHttpsServer {
  _RawHttpsServer(this.server);

  final SecureServerSocket server;
  final connected = Completer<SecureSocket>();

  static Future<_RawHttpsServer> start() async {
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain('$_fixtures/server_one.pem')
        ..usePrivateKey('$_fixtures/server_one.key'),
    );
    final fixture = _RawHttpsServer(server);
    server.listen(fixture.connected.complete);
    return fixture;
  }

  Uri get endpoint =>
      Uri(scheme: 'https', host: '127.0.0.1', port: server.port);

  Future<void> close() async {
    await server.close();
  }
}

final class _ProbeTimer implements Timer {
  _ProbeTimer(this.at, this._callback);
  final Duration at;
  final void Function() _callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    if (!isActive) return;
    isActive = false;
    tick = 1;
    _callback();
  }
}

final class _ControlledSecureSocket extends Stream<RawSocketEvent>
    implements RawSecureSocket {
  final events = StreamController<RawSocketEvent>(sync: true);
  final limits = <int>[];
  final written = <int>[];
  final incoming = <Uint8List>[];
  Completer<void> blocked = Completer<void>();
  bool readEnabled = true;
  bool closed = false;
  int readCalls = 0;

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  set writeEventsEnabled(bool enabled) {
    if (enabled && !blocked.isCompleted) blocked.complete();
  }

  @override
  set readEventsEnabled(bool enabled) {
    readEnabled = enabled;
    if (enabled && incoming.isNotEmpty) events.add(RawSocketEvent.read);
  }

  void writable() {
    blocked = Completer<void>();
    events.add(RawSocketEvent.write);
  }

  void receive(Uint8List bytes) {
    incoming.add(bytes);
    if (readEnabled) events.add(RawSocketEvent.read);
  }

  @override
  Uint8List? read([int? len]) {
    readCalls++;
    return incoming.isEmpty ? null : incoming.removeAt(0);
  }

  @override
  int write(List<int> buffer, [int offset = 0, int? count]) {
    final remaining = count ?? buffer.length - offset;
    final limit = limits.removeAt(0);
    final size = remaining < limit ? remaining : limit;
    written.addAll(buffer.sublist(offset, offset + size));
    return size;
  }

  @override
  void shutdown(SocketDirection direction) {}

  @override
  Future<RawSecureSocket> close() async {
    closed = true;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ControlledRawSocket implements RawSocket {
  bool closed = false;

  @override
  void shutdown(SocketDirection direction) {}

  @override
  Future<RawSocket> close() async {
    closed = true;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late String kernel;
  setUpAll(() async {
    final temporary = await Directory.systemTemp.createTemp(
      'correlia-tls-probe-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    kernel = '${temporary.path}/probe.dill';
    // No Dart toolchain or package resolution runs in the hostile environment.
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'test/e2e/icinga2_stream_tls_probe.dart',
      '-o',
      kernel,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
  });
  test('negotiates_json_for_subscription_and_object_queries', () async {
    final peer = await IcingaConsumerLoopback.start();
    addTearDown(peer.close);
    final client = IcingaStreamHttpClient(
      endpoint: peer.url,
      username: _user,
      password: utf8.encode(_password),
      ca: peer.ca,
    );
    addTearDown(client.close);
    expect((await client.subscribe('queue')).statusCode, HttpStatus.ok);
    final sync = await client.query(SyncProjection.hosts);
    expect(sync.statusCode, HttpStatus.ok);
    expect(await utf8.decoder.bind(sync.body).join(), '{"results":[]}');
  }, timeout: const Timeout(Duration(seconds: 12)));

  test('adapter_retries_zero_and_partial_writes', () async {
    final secure = _ControlledSecureSocket()..limits.addAll([0, 2, 100]);
    final raw = _ControlledRawSocket();
    final socket = tlsSocketForTesting(secure, raw, () => true);
    addTearDown(() async {
      socket.destroy();
      await secure.events.close();
    });

    socket.add(utf8.encode('secret'));
    final flushed = socket.flush();
    await secure.blocked.future.timeout(const Duration(seconds: 5));
    expect(secure.written, isEmpty);
    secure.writable();
    await secure.blocked.future.timeout(const Duration(seconds: 5));
    expect(utf8.decode(secure.written), 'se');
    secure.writable();
    await flushed.timeout(const Duration(seconds: 5));
    expect(utf8.decode(secure.written), 'secret');
  });

  for (final leaseLoss in [false, true]) {
    test(
      'adapter_blocked_write_${leaseLoss ? 'lease_loss' : 'abort'}',
      () async {
        final secure = _ControlledSecureSocket()..limits.addAll([2, 100]);
        final raw = _ControlledRawSocket();
        var live = true;
        final socket = tlsSocketForTesting(secure, raw, () => live);
        addTearDown(() async {
          socket.destroy();
          await secure.events.close();
        });

        socket.add(utf8.encode('secret'));
        final flushed = expectLater(socket.flush(), throwsA(anything));
        await secure.blocked.future.timeout(const Duration(seconds: 5));
        expect(utf8.decode(secure.written), 'se');
        if (leaseLoss) {
          live = false;
          secure.writable();
        } else {
          socket.destroy();
        }
        await flushed.timeout(const Duration(seconds: 5));
        expect(utf8.decode(secure.written), 'se');
        expect(raw.closed, isTrue);
        expect(secure.closed, isTrue);
      },
    );
  }

  test('adapter_paused_subscriber_disables_raw_reads', () async {
    final secure = _ControlledSecureSocket();
    final raw = _ControlledRawSocket();
    final socket = tlsSocketForTesting(secure, raw, () => true);
    addTearDown(() async {
      socket.destroy();
      await secure.events.close();
    });
    final received = <int>[];
    final first = Completer<void>();
    late StreamSubscription<Uint8List> subscription;
    subscription = socket.listen((bytes) {
      received.addAll(bytes);
      if (!first.isCompleted) {
        subscription.pause();
        first.complete();
      }
    });
    secure.receive(Uint8List.fromList([1]));
    await first.future.timeout(const Duration(seconds: 5));
    expect(secure.readEnabled, isFalse);
    for (var i = 0; i < 128; i++) {
      secure.receive(Uint8List(1024));
    }
    expect(secure.readCalls, 1);
    expect(
      secure.incoming.fold<int>(0, (sum, bytes) => sum + bytes.length),
      131072,
    );
    expect(received, [1]);
    await subscription.cancel();
  });

  test('repeated_handshake_stalls_close_each_peer', () async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final server = await _HandshakeStall.start();
      final client = await _client(
        server.endpoint,
        headerDeadline: const Duration(milliseconds: 500),
      );
      try {
        final failure = expectLater(
          client.subscribe('source-one'),
          _failure('timeout'),
        );
        await server.connected.future.timeout(const Duration(seconds: 5));
        await failure.timeout(const Duration(seconds: 5));
        await server.eof.future.timeout(const Duration(seconds: 5));
      } finally {
        client.close();
        await server.close();
      }
    }
  });

  for (final sync in [false, true]) {
    final operation = sync ? 'sync' : 'subscribe';
    for (final cancellation in ['close', 'lease_loss', 'timeout']) {
      test('${operation}_handshake_stall_$cancellation', () async {
        final server = await _HandshakeStall.start();
        addTearDown(server.close);
        var live = true;
        final client = await _client(
          server.endpoint,
          isLive: () => live,
          headerDeadline: cancellation == 'timeout'
              ? const Duration(milliseconds: 500)
              : const Duration(seconds: 10),
        );
        addTearDown(client.close);

        final Future<Object> request = sync
            ? client.query(SyncProjection.hosts)
            : client.subscribe('source-one');
        final failure = expectLater(
          request,
          sync && cancellation == 'timeout'
              ? throwsA(isA<TimeoutException>())
              : _failure(cancellation == 'timeout' ? 'timeout' : 'interrupted'),
        );
        await server.hello.future.timeout(const Duration(seconds: 5));
        if (cancellation == 'lease_loss') live = false;
        if (cancellation != 'timeout') client.close();
        await failure.timeout(const Duration(seconds: 5));
        await server.eof.future.timeout(const Duration(seconds: 5));
        expect(server.bytes, isNotEmpty);
        expect(
          latin1.decode(server.bytes),
          isNot(contains('Authorization:')),
        );
      });
    }

    for (final cancellation in ['close', 'lease_loss', 'timeout']) {
      test('${operation}_header_write_stall_$cancellation', () async {
        final server = await _RawHttpsServer.start();
        addTearDown(server.close);
        var live = true;
        // The peer pauses reads while this header exceeds socket buffers.
        final username = 'u' * (16 * 1024 * 1024);
        final client = await _client(
          server.endpoint,
          username: username,
          isLive: () => live,
          headerDeadline: cancellation == 'timeout'
              ? const Duration(seconds: 2)
              : const Duration(seconds: 10),
        );
        addTearDown(client.close);
        final Future<Object> request = sync
            ? client.query(SyncProjection.hosts)
            : client.subscribe('source-one');
        final failure = expectLater(
          request,
          sync && cancellation == 'timeout'
              ? throwsA(isA<TimeoutException>())
              : _failure(cancellation == 'timeout' ? 'timeout' : 'interrupted'),
        );
        final peer = await server.connected.future.timeout(
          const Duration(seconds: 5),
        );
        addTearDown(peer.destroy);
        final firstBytes = Completer<void>();
        final eof = Completer<void>();
        var received = 0;
        late StreamSubscription<List<int>> input;
        input = peer.listen(
          (bytes) {
            received += bytes.length;
            if (!firstBytes.isCompleted) {
              input.pause();
              firstBytes.complete();
            }
          },
          onDone: eof.complete,
          onError: eof.completeError,
        );
        await firstBytes.future.timeout(const Duration(seconds: 5));
        if (cancellation == 'lease_loss') live = false;
        if (cancellation != 'timeout') client.close();
        await failure.timeout(const Duration(seconds: 5));
        input.resume();
        await eof.future.timeout(const Duration(seconds: 5));
        expect(received, lessThan(username.length));
      });
    }
  }

  test('one_header_budget_covers_tls_and_http_headers', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);
    final accepted = listener.first;
    final client = await _client(
      Uri.https('127.0.0.1:${listener.port}'),
      headerDeadline: const Duration(seconds: 11),
    );
    addTearDown(client.close);
    var now = Duration.zero;
    final timers = <_ProbeTimer>[];
    void advance(Duration elapsed) {
      now += elapsed;
      for (final timer in timers) {
        if (timer.at <= now) timer.fire();
      }
    }

    final response = runZoned(
      () => client.subscribe('source-one'),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, delay, callback) {
          if (delay != const Duration(seconds: 11)) {
            return parent.createTimer(zone, delay, callback);
          }
          final timer = _ProbeTimer(now + delay, zone.bindCallback(callback));
          timers.add(timer);
          return timer;
        },
      ),
    );
    final failed = expectLater(response, _failure('timeout'));
    final raw = await accepted;
    addTearDown(raw.destroy);
    advance(const Duration(seconds: 10));
    final peer = await SecureSocket.secureServer(
      raw,
      SecurityContext()
        ..useCertificateChain('$_fixtures/server_one.pem')
        ..usePrivateKey('$_fixtures/server_one.key'),
    );
    addTearDown(peer.destroy);
    final requestBegan = Completer<void>();
    final ended = Completer<void>();
    peer.listen(
      (_) {
        if (!requestBegan.isCompleted) requestBegan.complete();
      },
      onDone: ended.complete,
      onError: ended.completeError,
    );
    await requestBegan.future.timeout(const Duration(seconds: 5));
    expect(
      timers,
      hasLength(1),
      reason: 'TLS success must not reset the header budget',
    );
    advance(const Duration(seconds: 1));
    await failed;
    await ended.future.timeout(const Duration(seconds: 5));
  });

  for (final chunked in [true, false]) {
    test(
      'production_factory_${chunked ? 'chunked' : 'close_delimited'}_pause',
      () async {
        final server = await _RawHttpsServer.start();
        addTearDown(server.close);
        final client = await _client(server.endpoint);
        addTearDown(client.close);
        final responseFuture = client.subscribe('source-one');
        final peer = await server.connected.future.timeout(
          const Duration(seconds: 5),
        );
        addTearDown(peer.destroy);
        final headers = Completer<void>();
        var request = '';
        peer.listen((bytes) {
          if (headers.isCompleted) return;
          request += latin1.decode(bytes);
          if (request.contains('\r\n\r\n')) headers.complete();
        });
        await headers.future.timeout(const Duration(seconds: 5));
        peer.write(
          'HTTP/1.1 200 OK\r\n'
          '${chunked ? 'Transfer-Encoding: chunked' : 'Connection: close'}\r\n'
          '\r\n'
          '${chunked ? '5\r\nhello\r\n' : 'hello'}',
        );
        await peer.flush();
        final response = await responseFuture.timeout(
          const Duration(seconds: 5),
        );
        final first = Completer<void>();
        final done = Completer<void>();
        final body = <int>[];
        late StreamSubscription<List<int>> subscription;
        subscription = response.body.listen(
          (bytes) {
            body.addAll(bytes);
            if (!first.isCompleted) {
              subscription.pause();
              first.complete();
            }
          },
          onDone: done.complete,
          onError: done.completeError,
        );
        await first.future.timeout(const Duration(seconds: 5));
        peer.write(chunked ? '5\r\nworld\r\n0\r\n\r\n' : 'world');
        await peer.flush();
        await peer.close();
        expect(utf8.decode(body), 'hello');
        subscription.resume();
        await done.future.timeout(const Duration(seconds: 5));
        expect(utf8.decode(body), 'helloworld');
      },
    );
  }

  test('server_signed_by_the_configured_ca', () async {
    final server = await _HttpsServer.start();
    addTearDown(server.close);
    final client = await _client(server.endpoint());
    addTearDown(client.close);

    final response = await client.subscribe('source-one');
    expect(response.statusCode, HttpStatus.ok);
    expect(await utf8.decoder.bind(response.body).join(), server.responseBody);
    expect(server.requests, hasLength(1));
    final request = server.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/v1/events');
    expect(
      request.authorization,
      'Basic ${base64.encode(utf8.encode('$_user:$_password'))}',
    );
    final body = jsonDecode(request.body) as Map<String, Object?>;
    expect(body.keys, unorderedEquals(['queue', 'types']));
    expect(body['queue'], 'source-one');
    expect(
      body['types'],
      unorderedEquals([
        'StateChange',
        'AcknowledgementSet',
        'AcknowledgementCleared',
        'DowntimeStarted',
        'DowntimeRemoved',
        'Flapping',
      ]),
    );
  });

  test('server_signed_by_a_default_trusted_only_ca', () async {
    final server = await _HttpsServer.start(certificate: 'two');
    addTearDown(server.close);
    final proxy = await _ProxyTripwire.start();
    addTearDown(proxy.close);

    final result = await _hostileProbe(
      server.endpoint(),
      kernel,
      proxy.socket.port,
      proveDefault: true,
    );
    expect(result, {'error': 'tls'});
    expect(server.requests, isEmpty);
    expect(await proxy.contacts(), 0);
  });

  test('hostile_environment_does_not_block_configured_ca', () async {
    final server = await _HttpsServer.start();
    addTearDown(server.close);
    final proxy = await _ProxyTripwire.start();
    addTearDown(proxy.close);

    final result = await _hostileProbe(
      server.endpoint(),
      kernel,
      proxy.socket.port,
    );
    expect(result, {'status': HttpStatus.ok, 'body': server.responseBody});
    expect(server.requests, hasLength(1));
    expect(await proxy.contacts(), 0);
  });

  test('certificate_for_another_host', () async {
    final server = await _HttpsServer.start();
    addTearDown(server.close);
    final client = await _client(server.endpoint(host: 'localhost'));
    addTearDown(client.close);

    await expectLater(client.subscribe('source-one'), _failure('tls'));
    expect(server.requests, isEmpty);
  });

  test('redirect_answer', () async {
    final server = await _HttpsServer.start();
    addTearDown(server.close);
    final destination = await _HttpsServer.start();
    addTearDown(destination.close);
    server.status = HttpStatus.temporaryRedirect;
    server.location = destination.endpoint().resolve('/stolen').toString();
    final client = await _client(server.endpoint());
    addTearDown(client.close);

    await expectLater(client.subscribe('source-one'), _failure('http_status'));
    expect(server.requests, hasLength(1));
    expect(destination.requests, isEmpty);
  });

  test('wrong_password', () async {
    final server = await _HttpsServer.start();
    addTearDown(server.close);
    server.status = HttpStatus.unauthorized;
    final client = await _client(server.endpoint());
    addTearDown(client.close);

    await expectLater(client.subscribe('source-one'), _failure('unauthorized'));
    expect(server.requests, hasLength(1));
  });
}
