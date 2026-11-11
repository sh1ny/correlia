@Tags(['plugin'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/plugin/openssl_socket.dart';
import 'package:correlia_server/src/plugin/plugin_rpc_connection.dart';
import 'package:correlia_server/src/plugin/plugin_tls.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'support/observed_raw_socket.dart';
import 'support/plugin_fixture_support.dart';

const _totalBytes = 8 * 1024 * 1024;
const _chunkBytes = 16 * 1024;
const _deadline = Duration(milliseconds: 400);

int _byteAt(int offset) => (offset * 31 + offset ~/ 251) % 256;

void main() {
  late PluginFixtureSuite suite;
  late PluginFixtureCredentials credentials;
  late List<int> certificate;
  late List<int> key;

  setUpAll(() async {
    suite = PluginFixtureSuite.create();
    credentials = await suite.createCredentials();
    certificate = await credentials.certificate.readAsBytes();
    key = await credentials.privateKey.readAsBytes();
  });
  tearDownAll(() => suite.dispose());

  test(
    'oversize plaintext source chunks are rejected before admission',
    () async {
      const limit = 256 * 1024;
      final peer = await _Peer.start(suite, credentials, 'echo');
      OpenSslSocket? socket;
      StreamSubscription<List<int>>? incoming;
      late ObservedRawSocket raw;
      final received = Completer<void>();
      unawaited(
        received.future.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
      var count = 0;
      try {
        socket = await peer.connect(
          certificate,
          key,
          controls: PluginTlsTestControls(
            socketConnector: (address, port) async =>
                raw = ObservedRawSocket(await RawSocket.connect(address, port)),
          ),
        );
        await peer.expectLine('authenticated');
        incoming = socket.incoming.listen(
          (bytes) {
            for (final byte in bytes) {
              if (count >= limit || byte != _byteAt(count)) {
                if (!received.isCompleted) {
                  received.completeError(
                    StateError('unexpected plaintext at $count'),
                  );
                }
                return;
              }
              count++;
            }
            if (count == limit && !received.isCompleted) received.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!received.isCompleted) received.completeError(error, stack);
          },
        );
        final before = raw.bytesWritten;
        await expectLater(
          socket.addStream(Stream<List<int>>.value(Uint8List(limit + 1))),
          throwsArgumentError,
        );
        expect(socket.queuedPlaintextBytes, 0);
        expect(
          raw.bytesWritten,
          before,
          reason: 'rejected input must not reach the OS',
        );
        final accepted = Uint8List(limit);
        for (var index = 0; index < limit; index++) {
          accepted[index] = _byteAt(index);
        }
        peer.release();
        await peer.expectLine('reading');
        await socket.addStream(Stream<List<int>>.value(accepted));
        await received.future.timeout(const Duration(seconds: 5));
        expect(count, limit);
      } finally {
        socket?.destroy();
        await incoming?.cancel();
        await peer.stop();
      }
    },
  );

  test(
    'native TLS backpressures a bounded producer and preserves bytes across partial writes',
    () async {
      final peer = await _Peer.start(suite, credentials, 'echo');
      OpenSslSocket? socket;
      StreamSubscription<List<int>>? incoming;
      late ObservedRawSocket raw;
      var progress = Completer<void>();
      final received = Completer<void>();
      unawaited(
        received.future.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
      var receivedBytes = 0;
      var produced = 0;
      late StreamController<List<int>> producer;
      void pump() {
        if (producer.isClosed || producer.isPaused) return;
        if (produced == _totalBytes) {
          unawaited(producer.close());
          return;
        }
        final start = produced;
        produced += _chunkBytes;
        producer.add(
          Uint8List.fromList(
            List<int>.generate(_chunkBytes, (i) => _byteAt(start + i)),
          ),
        );
        final previousProgress = progress;
        progress = Completer<void>();
        if (!previousProgress.isCompleted) previousProgress.complete();
        scheduleMicrotask(pump);
      }

      producer = StreamController<List<int>>(
        sync: true,
        onListen: () => scheduleMicrotask(pump),
        onResume: () => scheduleMicrotask(pump),
      );
      try {
        socket = await peer.connect(
          certificate,
          key,
          controls: PluginTlsTestControls(
            socketConnector: (address, port) async {
              final actual = await RawSocket.connect(address, port);
              try {
                // Linux SOL_SOCKET/SO_SNDBUF: keep the real send buffer below a TLS record.
                actual.setRawOption(RawSocketOption.fromInt(1, 7, 4096));
                return raw = ObservedRawSocket(actual);
              } on Object {
                await actual.close();
                rethrow;
              }
            },
          ),
        );
        await peer.expectLine('authenticated');
        raw.partialWrites = 0;
        incoming = socket.incoming.listen(
          (bytes) {
            for (final byte in bytes) {
              if (byte != _byteAt(receivedBytes)) {
                if (!received.isCompleted) {
                  received.completeError(
                    StateError('byte mismatch at $receivedBytes'),
                  );
                }
                return;
              }
              receivedBytes++;
            }
            if (receivedBytes == _totalBytes && !received.isCompleted) {
              received.complete();
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!received.isCompleted) received.completeError(error, stack);
          },
        );
        final sending = socket.addStream(producer.stream);
        final deadline = Stopwatch()..start();
        while (true) {
          try {
            await Future.any<void>([
              progress.future,
              sending.then<void>(
                (_) =>
                    throw StateError('producer completed before peer release'),
              ),
            ]).timeout(_deadline);
          } on TimeoutException {
            break;
          }
          if (deadline.elapsed > const Duration(seconds: 10)) {
            throw StateError('producer never stalled under peer backpressure');
          }
        }
        expect(producer.isPaused, isTrue);
        expect(produced, lessThan(_totalBytes));
        expect(socket.queuedPlaintextBytes, lessThanOrEqualTo(256 * 1024));
        peer.release();
        await peer.expectLine('reading');
        await sending.timeout(const Duration(seconds: 20));
        await received.future.timeout(const Duration(seconds: 20));
        expect(
          raw.partialWrites,
          greaterThan(0),
          reason: 'the kernel must actually accept a short positive write',
        );
        expect(raw.partialWriteAccepted, greaterThan(0));
        expect(raw.partialWriteAccepted, lessThan(raw.partialWriteRequested));
        expect(receivedBytes, _totalBytes);
      } finally {
        socket?.destroy();
        await incoming?.cancel();
        if (!producer.isClosed) unawaited(producer.close());
        await peer.stop();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('unavailable native ABI fails closed before delivery', () async {
    for (final fault in PluginNativeTlsFault.values) {
      var connected = false;
      final allocator = _CountingAllocator();
      await expectLater(
        OpenSslSocket.connect(
          '/unused',
          peerCertificateDer: [1],
          testControls: PluginTlsTestControls(
            nativeFault: fault,
            allocator: allocator,
            socketConnector: (address, port) {
              connected = true;
              throw StateError('socket must not be acquired');
            },
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'native loader diagnostic',
            contains(
              fault == PluginNativeTlsFault.unavailableLibrary
                  ? 'correlia-openssl-unavailable.so'
                  : 'correlia_openssl_missing_abi_symbol',
            ),
          ),
        ),
      );
      expect(
        connected,
        isFalse,
        reason: '$fault must fail before socket acquisition',
      );
      expect(allocator.allocations, 0);
    }
  });

  test('unsupported P-521 signatures fail closed', () async {
    final peer = await _Peer.start(suite, credentials, 'echo');
    try {
      await expectLater(
        peer.connect(
          certificate,
          key,
          controls: const PluginTlsTestControls(withoutP521Signatures: true),
        ),
        throwsA(isA<HandshakeException>()),
      );
      expect(
        await peer.process.exitCode.timeout(const Duration(seconds: 5)),
        isNot(0),
      );
    } finally {
      await peer.stop();
    }
  });

  test('partial native initialization releases its allocations', () async {
    final output = '${suite.scratchDirectory.path}/alloc-counter.so';
    final built = await runBoundedProcess('mise', [
      'exec',
      '--',
      'cc',
      '-shared',
      '-fPIC',
      '-o',
      output,
      'test/plugin/fixtures/native/alloc_counter.c',
      '-lcrypto',
    ]);
    expect(built.exitCode, 0, reason: built.diagnostics);
    final result = await runBoundedProcess(Platform.resolvedExecutable, [
      'test/plugin/fixtures/native/allocation_child.dart',
      output,
      credentials.certificate.path,
      credentials.privateKey.path,
    ]);
    expect(result.exitCode, 0, reason: result.diagnostics);
    expect(result.diagnostics, contains('"dart_live":0'));
    expect(result.diagnostics, contains('"iterations":100'));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('late socket connection is closed after startup deadline', () async {
    final path = '${suite.scratchDirectory.path}/late.sock';
    final server = await RawServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final accepted = Completer<RawSocket>();
    final subscription = server.listen((socket) => accepted.complete(socket));
    final acquired = Completer<void>();
    final release = Completer<void>();
    RawSocket? remote;
    StreamSubscription<RawSocketEvent>? remoteEvents;
    final closed = Completer<void>();
    try {
      final start = OpenSslSocket.connect(
        path,
        peerCertificateDer: [1],
        timeout: _deadline,
        testControls: PluginTlsTestControls(
          socketConnector: (address, port) async {
            final raw = await RawSocket.connect(address, port);
            acquired.complete();
            await release.future;
            return raw;
          },
        ),
      );
      remote = await accepted.future;
      remoteEvents = remote.listen(
        (event) {
          if (event == RawSocketEvent.readClosed && !closed.isCompleted) {
            closed.complete();
          }
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
      await acquired.future;
      await expectLater(start, throwsA(isA<TimeoutException>()));
      release.complete();
      await closed.future.timeout(const Duration(seconds: 5));
    } finally {
      if (!release.isCompleted) release.complete();
      await remoteEvents?.cancel();
      remote?.close();
      await subscription.cancel();
      await server.close();
    }
  });

  test(
    'TLS and HTTP2 readiness stalls fail within the AutoMTLS startup deadline',
    () async {
      for (final mode in ['tls-stall', 'settings-stall']) {
        final peer = await _Peer.start(suite, credentials, mode);
        final watch = Stopwatch()..start();
        try {
          final connecting = PluginRpcConnection.connect(
            socketPath: peer.path,
            serverCertificateDerBase64: base64.encode(peer.pin),
            identity: PluginClientIdentity(
              certificatePem: certificate,
              privateKeyPem: key,
            ),
            timeout: _deadline,
          );
          final failure = expectLater(
            connecting,
            throwsA(isA<TimeoutException>()),
          );
          await peer.expectLine(
            mode == 'tls-stall' ? 'accepted' : 'authenticated',
          );
          await failure;
          expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
          await peer.expectLine('closed');
        } finally {
          await peer.stop();
        }
      }
    },
  );

  test(
    'paused native consumer bounds inbound ciphertext and resumes byte-identically',
    () async {
      final peer = await _Peer.start(suite, credentials, 'send');
      OpenSslSocket? socket;
      StreamSubscription<List<int>>? incoming;
      late ObservedRawSocket raw;
      final first = Completer<void>();
      final readsAtPause = Completer<int>();
      final all = Completer<void>();
      var count = 0;
      try {
        socket = await peer.connect(
          certificate,
          key,
          controls: PluginTlsTestControls(
            socketConnector: (address, port) async =>
                raw = ObservedRawSocket(await RawSocket.connect(address, port)),
          ),
        );
        await peer.expectLine('authenticated');
        incoming = socket.incoming.listen(
          (bytes) {
            for (final byte in bytes) {
              if (byte != _byteAt(count)) {
                if (!all.isCompleted) {
                  all.completeError(StateError('byte mismatch at $count'));
                }
                return;
              }
              count++;
            }
            if (!first.isCompleted) {
              incoming!.pause();
              readsAtPause.complete(raw.bytesRead);
              first.complete();
            }
            if (count == _totalBytes && !all.isCompleted) all.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!all.isCompleted) all.completeError(error, stack);
          },
        );
        peer.release();
        await peer.expectLine('sending');
        await first.future.timeout(const Duration(seconds: 5));
        final pausedReadCount = await readsAtPause.future;
        final sent = peer.nextLine();
        await expectLater(
          sent.timeout(_deadline),
          throwsA(isA<TimeoutException>()),
        );
        expect(count, lessThan(_totalBytes));
        expect(
          raw.available(),
          greaterThan(0),
          reason: 'peer ciphertext is waiting in the real socket',
        );
        expect(
          raw.bytesRead,
          pausedReadCount,
          reason: 'paused plaintext must stop ciphertext reads',
        );
        incoming.resume();
        expect(await sent.timeout(const Duration(seconds: 20)), 'sent');
        await all.future.timeout(const Duration(seconds: 20));
        expect(raw.bytesRead, greaterThan(pausedReadCount));
        expect(count, _totalBytes);
        peer.release();
      } finally {
        socket?.destroy();
        await incoming?.cancel();
        await peer.stop();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

final class _Peer {
  _Peer(this.process, this.lines, this.path, this.pin, this.stderrDone);
  final Process process;
  final StreamIterator<String> lines;
  final String path;
  final List<int> pin;
  final Future<void> stderrDone;
  static int _nextId = 0;

  static Future<_Peer> start(
    PluginFixtureSuite suite,
    PluginFixtureCredentials credentials,
    String mode,
  ) async {
    final build = await suite.build();
    final path = '${suite.scratchDirectory.path}/p${_nextId++}.sock';
    final process = await Process.start(
      build.binaries[PluginFixtureBinary.nativeTlsPeer]!.path,
      [
        '--socket',
        path,
        '--client-cert',
        credentials.certificate.path,
        '--mode',
        mode,
      ],
    );
    final stderrDone = process.stderr.drain<void>();
    final lines = StreamIterator<String>(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    try {
      if (!await lines.moveNext().timeout(const Duration(seconds: 10))) {
        throw StateError('peer exited before certificate');
      }
      return _Peer(
        process,
        lines,
        path,
        base64.decode(lines.current),
        stderrDone,
      );
    } on Object {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await lines.cancel();
      await stderrDone;
      rethrow;
    }
  }

  Future<OpenSslSocket> connect(
    List<int> certificate,
    List<int> key, {
    PluginTlsTestControls controls = const PluginTlsTestControls(),
  }) => OpenSslSocket.connect(
    path,
    peerCertificateDer: pin,
    certificatePem: certificate,
    privateKeyPem: key,
    testControls: controls,
  );

  void release() => process.stdin.writeln('continue');

  Future<String> nextLine() async {
    if (!await lines.moveNext()) {
      throw StateError('peer exited before expected barrier');
    }
    return lines.current;
  }

  Future<void> expectLine(String expected) async =>
      expect(await nextLine().timeout(const Duration(seconds: 10)), expected);

  Future<void> stop() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 5));
    await lines.cancel();
    await process.stdin.close();
    await stderrDone;
  }
}

final class _CountingAllocator implements Allocator {
  int allocations = 0;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    allocations++;
    return calloc.allocate<T>(byteCount, alignment: alignment);
  }

  @override
  void free(Pointer<NativeType> pointer) => calloc.free(pointer);
}
