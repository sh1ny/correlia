import 'dart:async';

import 'package:correlia_server/src/plugin/bounded_channel.dart';
import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

void main() {
  test('closed_delegate_write_fails_rpc', () async {
    final raw = _FakeConnector();
    addTearDown(raw.dispose);
    await raw.stream.outgoing.close();
    final connector = BoundedPluginConnector(raw);
    final stream = (await connector.connect()).makeRequest(<Header>[]);
    final errors = <Object>[];
    final received = <StreamMessage>[];
    final done = Completer<void>();
    stream.incomingMessages.listen(
      received.add,
      onError: errors.add,
      onDone: done.complete,
    );

    stream.sendData([0, 0, 0, 0, 0]);
    stream.sendData([0, 0, 0, 0, 0]);
    await stream.outgoingMessages.close();
    await done.future;

    expect(received, isEmpty);
    expect(errors, [
      isA<GrpcError>().having(
        (error) => error.code,
        'status',
        StatusCode.unavailable,
      ),
    ]);
    expect(raw.stream.terminated, isTrue);
    expect(connector.frameFailure, isNull);
  });

  test('non_state_error_propagates', () async {
    final raw = _FakeConnector();
    addTearDown(raw.dispose);
    final connector = BoundedPluginConnector(raw);
    final stream = (await connector.connect()).makeRequest(<Header>[]);
    final errors = <Object>[];
    var closed = false;
    final delivered = Completer<void>();
    final subscription = stream.incomingMessages.listen(
      (_) => delivered.complete(),
      onError: errors.add,
      onDone: () => closed = true,
    );
    final written = <StreamMessage>[];
    raw.stream.outgoing.stream.listen(written.add);
    final error = ArgumentError('delegate bug');
    raw.stream.sink.nextError = error;
    expect(
      () => stream.sendData([0, 0, 0, 0, 0]),
      throwsA(same(error)),
    );
    stream.sendData([0, 0, 0, 0, 0]);
    raw.stream.incoming.add(DataStreamMessage([0, 0, 0, 0, 0]));
    await delivered.future;

    expect(written, hasLength(1));
    expect(errors, isEmpty);
    expect(closed, isFalse);
    expect(raw.stream.terminated, isFalse);
    expect(connector.frameFailure, isNull);
    await subscription.cancel();
  });

  test('invalid_frames_still_fail', () async {
    for (final bytes in [
      [1, 0, 0, 0, 0],
      [0, 0, 0x20, 0, 1],
    ]) {
      final raw = _FakeConnector();
      addTearDown(raw.dispose);
      final connector = BoundedPluginConnector(raw);
      final stream = (await connector.connect()).makeRequest(<Header>[]);
      final errors = <Object>[];
      final done = Completer<void>();
      stream.incomingMessages.listen(
        (_) => fail('invalid frame emitted a response'),
        onError: errors.add,
        onDone: done.complete,
      );
      final written = <StreamMessage>[];
      raw.stream.outgoing.stream.listen(written.add);

      stream.sendData(bytes);
      await done.future;

      expect(errors, [isA<FormatException>()]);
      expect(connector.frameFailure, same(errors.single));
      expect(raw.stream.terminated, isTrue);
      expect(written, isEmpty);
    }
  });
}

final class _FakeConnector implements ClientTransportConnector {
  final stream = _FakeStream();
  final closed = Completer<void>();
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

  Future<void> dispose() async {
    await stream.incoming.close();
    await stream.outgoing.close();
    shutdown();
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
  final incoming = StreamController<StreamMessage>();
  final outgoing = StreamController<StreamMessage>.broadcast(sync: true);
  late final sink = _FailingSink(outgoing.sink);
  bool terminated = false;
  @override
  int get id => 1;
  @override
  Stream<StreamMessage> get incomingMessages => incoming.stream;
  @override
  StreamSink<StreamMessage> get outgoingMessages => sink;
  @override
  set onTerminated(void Function(int?) value) {}
  @override
  Stream<TransportStreamPush> get peerPushes =>
      const Stream<TransportStreamPush>.empty();
  @override
  void terminate() => terminated = true;
  @override
  void sendHeaders(List<Header> headers, {bool endStream = false}) =>
      sink.add(HeadersStreamMessage(headers, endStream: endStream));
  @override
  void sendData(List<int> bytes, {bool endStream = false}) =>
      sink.add(DataStreamMessage(bytes, endStream: endStream));
}

final class _FailingSink implements StreamSink<StreamMessage> {
  _FailingSink(this.delegate);
  final StreamSink<StreamMessage> delegate;
  Object? nextError;
  @override
  void add(StreamMessage event) {
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
    delegate.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      delegate.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<StreamMessage> stream) =>
      delegate.addStream(stream);
  @override
  Future<void> close() => delegate.close();
  @override
  Future<void> get done => delegate.done;
}
