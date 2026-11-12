import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../plugin/support/plugin_process_identity.dart';

final class _PollFd extends Struct {
  @Int32()
  external int fd;

  @Int16()
  external int events;

  @Int16()
  external int revents;
}

final _libc = DynamicLibrary.open('libc.so.6');
final _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)
    >('open');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');
final _poll = _libc
    .lookupFunction<
      Int32 Function(Pointer<_PollFd>, Uint64, Int32),
      int Function(Pointer<_PollFd>, int, int)
    >('poll');
final _syscall = _libc
    .lookupFunction<
      Int64 Function(Int64, Int64, Int64),
      int Function(int, int, int)
    >('syscall');

/// Holds an independent reader on the exact plugin's stderr and its pidfd.
///
/// Open this before killing the worker; the worker's own stderr drainer dies
/// with it. The reader never touches the plugin's handshake stdout.
final class NatsMarkerObserver {
  NatsMarkerObserver._(this.identity, this._stderrFd, this._pidFd);

  /// Opens the pipe and pidfd while verifying the captured process identity.
  factory NatsMarkerObserver.open(PluginProcessIdentity identity) {
    if (!identity.matchesCurrentProcess()) {
      throw StateError('Plugin identity is no longer live: $identity');
    }
    final path = '/proc/${identity.pid}/fd/2'.toNativeUtf8();
    int stderrFd;
    try {
      // O_NONBLOCK keeps reads bounded even if the writer remains alive.
      stderrFd = _open(path, 0x800);
    } finally {
      calloc.free(path);
    }
    if (stderrFd < 0) throw StateError('Cannot open plugin stderr: $identity');
    // pidfd_open is syscall 434 on Linux x86-64 and arm64.
    final pidFd = _syscall(434, identity.pid, 0);
    if (pidFd < 0 || !identity.matchesCurrentProcess()) {
      _close(stderrFd);
      if (pidFd >= 0) _close(pidFd);
      throw StateError('Cannot pin plugin identity: $identity');
    }
    return NatsMarkerObserver._(identity, stderrFd, pidFd);
  }

  /// The PID and kernel start time captured before observation.
  final PluginProcessIdentity identity;
  final int _stderrFd;
  final int _pidFd;
  bool _closed = false;

  /// Waits for the JSON EOF marker and this exact process's pidfd to signal.
  Future<void> waitForExitMarker({
    Duration timeout = const Duration(seconds: 10),
  }) {
    if (_closed) throw StateError('Observer is closed');
    return Isolate.run(
      () => _observe((_stderrFd, _pidFd, timeout.inMilliseconds)),
    );
  }

  /// Stops a surviving owned plugin, waits for its pidfd, and releases handles.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (identity.isLive && !identity.isZombie) {
      identity.signalIfExact(ProcessSignal.sigkill);
    }
    try {
      final fd = _pidFd;
      await Isolate.run(() {
        final entry = calloc<_PollFd>();
        try {
          entry.ref
            ..fd = fd
            ..events = 1;
          if (_poll(entry, 1, 5000) <= 0) {
            throw StateError('Owned plugin did not exit during cleanup');
          }
        } finally {
          calloc.free(entry);
        }
      });
    } finally {
      _close(_stderrFd);
      _close(_pidFd);
    }
  }
}

void _observe((int, int, int) arguments) {
  final (stderrFd, pidFd, timeoutMs) = arguments;
  final watch = Stopwatch()..start();
  final entries = calloc<_PollFd>(2);
  final buffer = calloc<Uint8>(4096);
  final bytes = <int>[];
  var marker = false;
  var exited = false;
  try {
    entries[0]
      ..fd = stderrFd
      ..events = 1;
    entries[1]
      ..fd = pidFd
      ..events = 1;
    while (!marker || !exited) {
      final remaining = timeoutMs - watch.elapsedMilliseconds;
      if (remaining <= 0) {
        throw StateError(
          'Plugin EOF proof timed out: marker=$marker exited=$exited',
        );
      }
      final result = _poll(entries, 2, remaining);
      if (result < 0) throw StateError('Plugin observer poll failed');
      if (result == 0) continue;
      var readCount = 0;
      if (entries[0].revents & 1 != 0) {
        readCount = _read(stderrFd, buffer, 4096);
        if (readCount > 0) {
          bytes.addAll(buffer.asTypedList(readCount));
          if (bytes.length > 65536) {
            throw StateError('Plugin stderr proof exceeded 64 KiB');
          }
          final lines = const Utf8Decoder(
            allowMalformed: true,
          ).convert(bytes).split('\n');
          for (final line in lines.take(lines.length - 1)) {
            try {
              final value = jsonDecode(line);
              if (value is Map && value['event'] == 'stdin_eof') marker = true;
            } on FormatException {
              // Other bounded stderr diagnostics need not be JSON.
            }
          }
        }
        if (marker) entries[0].fd = -1;
      }
      if (entries[1].revents & 1 != 0) {
        exited = true;
        // Do not spin on a permanently readable pidfd while draining stderr.
        entries[1].fd = -1;
      }
      if (entries[0].revents & 16 != 0 && readCount <= 0 && !marker) {
        throw StateError('Plugin stderr closed without stdin_eof marker');
      }
    }
  } finally {
    calloc.free(buffer);
    calloc.free(entries);
  }
}
