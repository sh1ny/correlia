@Tags(['plugin'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/plugin/bounded_channel.dart';
import 'package:correlia_server/src/plugin/plugin_rpc_connection.dart';
import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

import 'support/plugin_fixture_support.dart';

void main() {
  group('gRPC frame guard', () {
    test('oversize prefix is rejected before any body', () {
      final guard = GrpcFrameGuard();
      guard.add([0, 0, 0x20, 0]);
      expect(() => guard.add([1]), throwsFormatException);
    });
    test('compressed and truncated frames fail', () {
      expect(
        () => GrpcFrameGuard().add([1, 0, 0, 0, 0]),
        throwsFormatException,
      );
      final partial = GrpcFrameGuard()..add([0, 0, 0, 0, 2, 1]);
      expect(partial.finish, throwsFormatException);
      final prefix = GrpcFrameGuard()..add([0, 0]);
      expect(prefix.finish, throwsFormatException);
    });
    test(
      'transport rejects a split oversize header and resets the stream',
      () async {
        final raw = _FakeConnector();
        final connection = await BoundedPluginConnector(raw).connect();
        final stream = connection.makeRequest(<Header>[]);
        final received = <StreamMessage>[];
        final finished = Completer<Object>();
        stream.incomingMessages.listen(
          received.add,
          onError: (Object error) {
            finished.complete(error);
          },
          onDone: () {
            if (!finished.isCompleted) {
              finished.complete(StateError('unexpected end'));
            }
          },
        );
        raw.stream.incoming.add(DataStreamMessage([0, 0, 0x20, 0]));
        raw.stream.incoming.add(DataStreamMessage([1]));
        expect(await finished.future, isA<FormatException>());
        expect(received, hasLength(1));
        expect(raw.stream.terminated, isTrue);
        await raw.stream.incoming.close();
        await raw.stream.outgoing.close();
      },
    );
    test('cancelling a response resets its underlying stream', () async {
      final raw = _FakeConnector();
      final connection = await BoundedPluginConnector(raw).connect();
      final subscription = connection
          .makeRequest(<Header>[])
          .incomingMessages
          .listen((_) {});
      await subscription.cancel();
      expect(raw.stream.terminated, isTrue);
      await raw.stream.incoming.close();
      await raw.stream.outgoing.close();
    });
  });

  group('stock AutoMTLS', () {
    late PluginFixtureSuite suite;
    late PluginFixtureSuite other;
    late PluginFixtureCredentials credentials;
    late PluginFixtureCredentials wrong;
    setUpAll(() async {
      suite = PluginFixtureSuite.create();
      other = PluginFixtureSuite.create();
      credentials = await suite.createCredentials();
      wrong = await other.createCredentials();
    });
    tearDownAll(() async {
      await suite.dispose();
      await other.dispose();
    });

    test('mutual P-521 authentication protects application RPC', () async {
      final fixture = await _Fixture.start(suite, credentials);
      try {
        final connection = await fixture.connect(credentials);
        try {
          final evidence = connection.tlsEvidence!;
          expect(evidence.protocol, 'TLSv1.3');
          expect(evidence.backendVersion, contains('OpenSSL 3'));
          expect(evidence.serverCertificateCurve, anyOf('secp521r1', 'P-521'));
          expect(evidence.clientCertificateCurve, anyOf('secp521r1', 'P-521'));
          expect(evidence.configurationPolicy, isNotEmpty);
          expect(evidence.configurationSource, isNotEmpty);
          expect(
            evidence.configurationEnvironment.keys,
            containsAll([
              'OPENSSL_CONF',
              'OPENSSL_CONF_INCLUDE',
              'OPENSSL_MODULES',
            ]),
          );
          await connection.probe();
        } finally {
          await connection.close();
        }
      } finally {
        await fixture.stop();
      }
    });

    test(
      'wrong pin and absent or wrong client identity fail after fixture readiness',
      () async {
        final fixture = await _Fixture.start(suite, credentials);
        try {
          final good = await fixture.connect(credentials);
          await good.probe();
          await good.close();
          final wrongPin = await wrong.certificate.readAsString();
          await expectLater(
            fixture.connect(credentials, pin: wrongPin),
            throwsA(isA<TlsException>()),
          );
          await expectLater(
            fixture.connect(null),
            throwsA(anyOf(isA<TlsException>(), isA<SocketException>())),
          );
          await expectLater(
            fixture.connect(wrong),
            throwsA(anyOf(isA<TlsException>(), isA<SocketException>())),
          );
          final recovered = await fixture.connect(credentials);
          try {
            await recovered.probe();
          } finally {
            await recovered.close();
          }
        } finally {
          await fixture.stop();
        }
      },
    );
  });
}

final class _Fixture {
  _Fixture(this.process, this.lines, this.socket, this.certificate);
  final Process process;
  final StreamIterator<String> lines;
  final String socket;
  final String certificate;

  static Future<_Fixture> start(
    PluginFixtureSuite suite,
    PluginFixtureCredentials identity,
  ) async {
    final build = await suite.build();
    final executable = build.binaries[PluginFixtureBinary.plainStock]!.path;
    final arguments = PluginFixtureArguments(
      journalPath: suite.journalFile.path,
    ).toArguments();
    final process = await Process.start(
      '/bin/sh',
      ['-c', 'umask 0177; exec "\$@"', 'plugin-test', executable, ...arguments],
      environment: PluginFixtureEnvironment.standard(
        suite: suite,
        clientCertificatePem: await identity.certificate.readAsString(),
      ).toEnvironment(),
      includeParentEnvironment: false,
    );
    unawaited(process.stderr.drain<void>());
    final lines = StreamIterator<String>(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    try {
      if (!await lines.moveNext().timeout(const Duration(seconds: 10))) {
        throw StateError('fixture exited before handshake');
      }
      final fields = lines.current.split('|');
      if (fields.length < 6 ||
          fields[2] != 'unix' ||
          fields[4] != 'grpc' ||
          fields[5].isEmpty) {
        throw StateError('invalid fixture handshake: ${lines.current}');
      }
      return _Fixture(process, lines, fields[3], fields[5]);
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await lines.cancel();
      rethrow;
    }
  }

  Future<PluginRpcConnection> connect(
    PluginFixtureCredentials? credentials, {
    String? pin,
  }) async {
    final identity = credentials == null
        ? null
        : PluginClientIdentity(
            certificatePem: await credentials.certificate.readAsBytes(),
            privateKeyPem: await credentials.privateKey.readAsBytes(),
          );
    return PluginRpcConnection.connect(
      socketPath: socket,
      serverCertificateDerBase64: certificate,
      identity: identity,
      expectedServerCertificatePem: pin,
      timeout: const Duration(seconds: 3),
    );
  }

  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 5));
    }
    await lines.cancel();
    await process.stdin.close();
  }
}

final class _FakeConnector implements ClientTransportConnector {
  final _FakeStream stream = _FakeStream();
  final Completer<void> closed = Completer<void>();
  @override
  String get authority => 'localhost';
  @override
  Future<void> get done => closed.future;
  @override
  Future<ClientTransportConnection> connect() async => _FakeConnection(stream);
  @override
  void shutdown() {
    if (!closed.isCompleted) closed.complete();
  }
}

final class _FakeConnection implements ClientTransportConnection {
  _FakeConnection(this.stream);
  final _FakeStream stream;
  @override
  bool get isOpen => true;
  @override
  ClientTransportStream makeRequest(
    List<Header> headers, {
    bool endStream = false,
  }) => stream;
  @override
  Future<void> ping() async {}
  @override
  set onActiveStateChanged(ActiveStateHandler callback) {}
  @override
  Future<void> get onInitialPeerSettingsReceived async {}
  @override
  Stream<int> get onPingReceived => const Stream<int>.empty();
  @override
  Stream<void> get onFrameReceived => const Stream<void>.empty();
  @override
  Future<void> finish() async {}
  @override
  Future<void> terminate([int? errorCode]) async {}
}

final class _FakeStream implements ClientTransportStream {
  final StreamController<StreamMessage> incoming =
      StreamController<StreamMessage>();
  final StreamController<StreamMessage> outgoing =
      StreamController<StreamMessage>.broadcast();
  bool terminated = false;
  @override
  int get id => 1;
  @override
  Stream<StreamMessage> get incomingMessages => incoming.stream;
  @override
  StreamSink<StreamMessage> get outgoingMessages => outgoing.sink;
  @override
  set onTerminated(void Function(int?) value) {}
  @override
  Stream<TransportStreamPush> get peerPushes =>
      const Stream<TransportStreamPush>.empty();
  @override
  void terminate() {
    terminated = true;
  }

  @override
  void sendHeaders(List<Header> headers, {bool endStream = false}) =>
      outgoing.add(HeadersStreamMessage(headers, endStream: endStream));
  @override
  void sendData(List<int> bytes, {bool endStream = false}) =>
      outgoing.add(DataStreamMessage(bytes, endStream: endStream));
}
