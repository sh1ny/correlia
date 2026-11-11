import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Forwards every operation to a real socket while observing its I/O results.
final class ObservedRawSocket extends Stream<RawSocketEvent>
    implements RawSocket {
  ObservedRawSocket(this._socket);

  final RawSocket _socket;
  int bytesRead = 0;
  int partialWrites = 0;
  int partialWriteRequested = 0;
  int partialWriteAccepted = 0;

  @override
  Uint8List? read([int? len]) {
    final bytes = _socket.read(len);
    bytesRead += bytes?.length ?? 0;
    return bytes;
  }

  @override
  int write(List<int> buffer, [int offset = 0, int? count]) {
    final requested = count ?? buffer.length - offset;
    final accepted = _socket.write(buffer, offset, count);
    if (accepted > 0 && accepted < requested) {
      partialWrites++;
      partialWriteRequested = requested;
      partialWriteAccepted = accepted;
    }
    return accepted;
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _socket.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  bool get readEventsEnabled => _socket.readEventsEnabled;
  @override
  set readEventsEnabled(bool value) => _socket.readEventsEnabled = value;
  @override
  bool get writeEventsEnabled => _socket.writeEventsEnabled;
  @override
  set writeEventsEnabled(bool value) => _socket.writeEventsEnabled = value;
  @override
  int available() => _socket.available();
  @override
  SocketMessage? readMessage([int? count]) => _socket.readMessage(count);
  @override
  int sendMessage(
    List<SocketControlMessage> controlMessages,
    List<int> data, [
    int offset = 0,
    int? count,
  ]) => _socket.sendMessage(controlMessages, data, offset, count);
  @override
  int get port => _socket.port;
  @override
  int get remotePort => _socket.remotePort;
  @override
  InternetAddress get address => _socket.address;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
  @override
  Future<RawSocket> close() async {
    await _socket.close();
    return this;
  }

  @override
  void shutdown(SocketDirection direction) => _socket.shutdown(direction);
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}
