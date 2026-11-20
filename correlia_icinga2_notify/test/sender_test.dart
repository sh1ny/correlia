import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_icinga2_notify/correlia_icinga2_notify.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

const _source = '0a1b2c3d-0000-4000-8000-0123456789ab';
const _token = 'tok-ABC_123';
const _key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

/// An in-memory file system with call recording.
final class FakeFiles implements SenderFiles {
  final infos = <String, FileInfo>{};
  final streams = <String, Stream<List<int>> Function(int maxBytes)>{};
  final statted = <String>[];
  final opened = <String>[];
  final maxBytesSeen = <int>[];

  void regular(String path, List<int> content, {int mode = 0x180}) {
    infos[path] = FileInfo(
      type: FileSystemEntityType.file,
      mode: mode,
      size: content.length,
    );
    streams[path] = (max) => Stream.value(content.take(max).toList());
  }

  @override
  Future<FileInfo> stat(String path) async {
    statted.add(path);
    return infos[path] ??
        const FileInfo(
          type: FileSystemEntityType.notFound,
          mode: 0,
          size: 0,
        );
  }

  @override
  Stream<List<int>> open(String path, int maxBytes) {
    opened.add(path);
    maxBytesSeen.add(maxBytes);
    return streams[path]!(maxBytes);
  }
}

final class Outcome {
  Outcome(this.code, this.lines);
  final int code;
  final List<String> lines;
  String get text => lines.join('\n');
}

String _lit(String value) => jsonEncode(value);

/// The argument list of a valid service notification, with [over] applied:
/// a `null` value removes the argument.
List<String> argv({
  required String baseUrl,
  Map<String, String?> over = const {},
  bool hmac = false,
}) {
  final values = <String, String?>{
    '--base-url': baseUrl,
    '--source': _source,
    if (hmac)
      '--hmac-key-file': '/creds/key'
    else
      '--token-file': '/creds/token',
    '--object-type': 'service',
    '--host': 'db1',
    '--service': 'disk',
    '--state': 'CRITICAL',
    '--state-type': 'HARD',
    '--last-state-change': '1700000000.123456',
    '--output': 'CRITICAL: disk full',
    '--notification-type': 'PROBLEM',
    '--notification-time': '1700000001.654321',
  };
  for (final MapEntry(:key, :value) in over.entries) {
    values[key] = value;
  }
  return [
    for (final MapEntry(:key, :value) in values.entries)
      if (value != null) ...[key, _lit(value)],
  ];
}

FakeFiles creds({int tokenMode = 0x180, int keyMode = 0x180}) => FakeFiles()
  ..regular('/creds/token', utf8.encode('$_token\n'), mode: tokenMode)
  ..regular('/creds/key', utf8.encode('$_key\n'), mode: keyMode);

Future<Outcome> run(
  List<String> args, {
  SenderFiles? files,
  Duration deadline = const Duration(seconds: 5),
  bool environmentEmpty = true,
  DateTime? now,
  List<String> bundles = const [],
}) async {
  final lines = <String>[];
  final code = await runSender(
    args,
    files: files ?? creds(),
    deadline: deadline,
    environmentIsEmpty: () => environmentEmpty,
    clock: () => now ?? DateTime.fromMillisecondsSinceEpoch(1700000000000),
    bundlePaths: bundles,
    writeError: lines.add,
  );
  return Outcome(code, lines);
}

final class Recorded {
  Recorded(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final HttpHeaders headers;
  final Uint8List body;
}

final class Receiver {
  Receiver._(this.server, this.scheme);
  final HttpServer server;
  final String scheme;
  final requests = <Recorded>[];
  int status = 202;
  String? location;
  String responseBody = '';

  static Future<Receiver> start({String? certPrefix}) async {
    final HttpServer server;
    if (certPrefix == null) {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } else {
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/server_$certPrefix.pem')
        ..usePrivateKey('test/fixtures/server_$certPrefix.key');
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
    }
    final receiver = Receiver._(server, certPrefix == null ? 'http' : 'https');
    server.listen((request) async {
      final body = await request.fold<BytesBuilder>(
        BytesBuilder(),
        (builder, chunk) => builder..add(chunk),
      );
      receiver.requests.add(
        Recorded(
          request.method,
          request.uri.path,
          request.headers,
          body.takeBytes(),
        ),
      );
      request.response.statusCode = receiver.status;
      if (receiver.location case final location?) {
        request.response.headers.set('location', location);
      }
      request.response.write(receiver.responseBody);
      await request.response.close();
    });
    return receiver;
  }

  String get url => '$scheme://127.0.0.1:${server.port}';
  Future<void> close() => server.close(force: true);
}

/// A listener that must never be contacted.
final class Tripwire {
  Tripwire._(this.socket);
  final ServerSocket socket;
  final _accepted = <int>[];
  Completer<void>? _waiting;

  static Future<Tripwire> start() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tripwire = Tripwire._(socket);
    socket.listen((client) {
      tripwire._accepted.add(client.remotePort);
      client.destroy();
      tripwire._waiting?.complete();
    });
    return tripwire;
  }

  int get port => socket.port;

  /// How many connections other than the probe reached the listener.
  ///
  /// The probe connects last and the kernel hands connections to `accept` in
  /// order, so once the probe is accepted every earlier one has been counted.
  Future<int> contacted() async {
    final probe = await Socket.connect(InternetAddress.loopbackIPv4, port);
    while (!_accepted.contains(probe.port)) {
      await (_waiting = Completer<void>()).future;
    }
    probe.destroy();
    return _accepted.length - 1;
  }

  Future<void> close() => socket.close();
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('notify-test'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// Copies a fixture into the temp directory with an explicit mode, so the
  /// checkout's umask cannot change what the mode check sees.
  Future<String> staged(String name, String mode, {String? content}) async {
    final file = File('${temp.path}/$name');
    if (content != null) {
      file.writeAsStringSync(content);
    } else {
      File('test/fixtures/$name').copySync(file.path);
    }
    final result = await Process.run('chmod', [mode, file.path]);
    expect(result.exitCode, 0);
    return file.path;
  }

  test('configured_ca_is_the_only_trust', () async {
    final one = await Receiver.start(certPrefix: 'one');
    final two = await Receiver.start(certPrefix: 'two');
    addTearDown(one.close);
    addTearDown(two.close);
    final token = await staged('token', '600', content: _token);
    final caOne = await staged('ca_one.pem', '644');
    final caTwo = await staged('ca_two.pem', '644');
    List<String> withCa(Receiver r, String? ca) => argv(
      baseUrl: r.url,
      over: {'--token-file': token, '--ca-file': ca},
    );

    final trusted = await run(
      withCa(one, caOne),
      files: const DiskFiles(),
    );
    expect(trusted.code, 0, reason: trusted.text);
    expect(one.requests, hasLength(1));

    // The server the configured CA did not sign is refused, even when the
    // distribution bundle would trust it.
    final untrusted = await run(
      withCa(two, caOne),
      files: const DiskFiles(),
      bundles: [caTwo],
    );
    expect(untrusted.code, 3, reason: untrusted.text);
    expect(two.requests, isEmpty);

    // Without --ca-file the first existing bundle is the trust.
    final bundled = await run(
      withCa(two, null),
      files: const DiskFiles(),
      bundles: ['${temp.path}/missing.pem', caTwo],
    );
    expect(bundled.code, 0, reason: bundled.text);
    expect(two.requests, hasLength(1));

    // No file, no trust: nothing falls back to the runtime's roots.
    final none = await run(
      withCa(two, null),
      files: const DiskFiles(),
      bundles: ['${temp.path}/missing.pem'],
    );
    expect(none.code, 2, reason: none.text);
  });

  test('url_without_a_scheme_or_with_a_loopback_name', () async {
    final tripwire = await Tripwire.start();
    addTearDown(tripwire.close);
    for (final url in [
      'correlia.example:8080',
      'http://localhost:${tripwire.port}',
      '//127.0.0.1:${tripwire.port}',
    ]) {
      final files = creds();
      final result = await run(argv(baseUrl: url), files: files);
      expect(result.code, 2, reason: url);
      expect(result.text, contains('--base-url'), reason: url);
      expect(files.statted, isEmpty, reason: 'no credential read for $url');
    }
    expect(await tripwire.contacted(), 0);
  });

  test('plain_http_to_a_remote_host', () async {
    for (final url in [
      'http://correlia.example:8080',
      'http://10.0.0.5:8080',
      'http://[::ffff:127.0.0.1]:8080',
      'http://128.0.0.1:8080',
    ]) {
      final files = creds();
      final result = await run(argv(baseUrl: url), files: files);
      expect(result.code, 2, reason: url);
      expect(result.text, contains('--base-url'), reason: url);
      expect(files.statted, isEmpty, reason: url);
    }
    // Literal loopback over plain http is the one allowed form.
    final receiver = await Receiver.start();
    addTearDown(receiver.close);
    final ok = await run(argv(baseUrl: receiver.url));
    expect(ok.code, 0, reason: ok.text);
  });

  test('non_regular_credential_file', () async {
    final tripwire = await Tripwire.start();
    addTearDown(tripwire.close);
    final files = FakeFiles()
      ..infos['/creds/key'] = const FileInfo(
        type: FileSystemEntityType.pipe,
        mode: 0x180,
        size: 0,
      );
    final result = await run(
      argv(baseUrl: 'http://127.0.0.1:${tripwire.port}', hmac: true),
      files: files,
    );
    expect(result.code, 2);
    expect(result.text, contains('--hmac-key-file'));
    expect(files.statted, ['/creds/key']);
    expect(files.opened, isEmpty, reason: 'a FIFO is never opened');
    expect(await tripwire.contacted(), 0);
  });

  test('credential_file_larger_than_its_check', () async {
    final tripwire = await Tripwire.start();
    addTearDown(tripwire.close);
    final files = FakeFiles()
      ..infos['/creds/token'] = const FileInfo(
        type: FileSystemEntityType.file,
        mode: 0x180,
        size: 10,
      )
      // The file grew after the check: far more than the cap arrives, and a
      // sender that trusted the stat would accept it.
      ..streams['/creds/token'] = (max) => Stream.fromIterable([
        List.filled(4096, 0x61),
        List.filled(4096, 0x62),
      ]);
    final result = await run(
      argv(baseUrl: 'http://127.0.0.1:${tripwire.port}'),
      files: files,
    );
    expect(result.code, 2);
    expect(result.text, contains('--token-file'));
    expect(result.text, isNot(contains('aaaa')));
    expect(files.maxBytesSeen, [4097], reason: 'reads the cap plus one byte');
    expect(await tripwire.contacted(), 0);

    // A file whose stat already exceeds the cap is refused without a read.
    final big = FakeFiles()
      ..infos['/creds/token'] = const FileInfo(
        type: FileSystemEntityType.file,
        mode: 0x180,
        size: 4097,
      );
    final refused = await run(
      argv(baseUrl: 'http://127.0.0.1:${tripwire.port}'),
      files: big,
    );
    expect(refused.code, 2);
    expect(big.opened, isEmpty);
  });

  test('blocking_file_after_the_check', () async {
    final receiver = await Receiver.start(certPrefix: 'one');
    addTearDown(receiver.close);
    final files = creds()
      ..infos['/creds/ca'] = const FileInfo(
        type: FileSystemEntityType.file,
        mode: 0x1a4,
        size: 100,
      )
      // The open never completes, as for a FIFO swapped in after the check.
      ..streams['/creds/ca'] = (max) => StreamController<List<int>>().stream;
    final watch = Stopwatch()..start();
    final result = await run(
      argv(baseUrl: receiver.url, over: {'--ca-file': '/creds/ca'}),
      files: files,
      deadline: const Duration(milliseconds: 300),
    );
    expect(result.code, 3);
    expect(result.lines, ['deadline']);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(receiver.requests, isEmpty);
  });

  test('credential_file_readable_by_others', () async {
    final tripwire = await Tripwire.start();
    addTearDown(tripwire.close);
    final url = 'http://127.0.0.1:${tripwire.port}';

    final token = await run(
      argv(baseUrl: url),
      files: creds(tokenMode: 0x1a4), // 0644
    );
    expect(token.code, 2);
    expect(token.text, contains('credential_mode'));
    expect(token.text, contains('--token-file'));
    expect(token.text, isNot(contains(_token)));

    final key = await run(
      argv(baseUrl: url, hmac: true),
      files: creds(keyMode: 0x1a0), // 0640
    );
    expect(key.code, 2);
    expect(key.text, contains('credential_mode'));
    expect(key.text, contains('--hmac-key-file'));

    final files = creds()
      ..regular('/creds/ca', utf8.encode('x'), mode: 0x1b6); // 0666
    final ca = await run(
      argv(
        baseUrl: 'https://127.0.0.1:${tripwire.port}',
        over: {
          '--ca-file': '/creds/ca',
        },
      ),
      files: files,
    );
    expect(ca.code, 2);
    expect(ca.text, contains('ca_mode'));
    expect(ca.text, contains('--ca-file'));
    expect(files.opened, ['/creds/token'], reason: 'the CA was never opened');
    expect(await tripwire.contacted(), 0);
  });

  test('peer_never_answers', () async {
    final accepted = <Socket>[];
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    socket.listen(accepted.add);
    addTearDown(() async {
      for (final client in accepted) {
        client.destroy();
      }
      await socket.close();
    });
    final watch = Stopwatch()..start();
    final result = await run(
      argv(baseUrl: 'http://127.0.0.1:${socket.port}'),
      deadline: const Duration(milliseconds: 300),
    );
    expect(result.code, 3);
    expect(result.lines, ['deadline']);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(accepted, isNotEmpty, reason: 'the connection was made');
  });

  test('only_202_counts_as_delivered', () async {
    final receiver = await Receiver.start();
    addTearDown(receiver.close);
    receiver.responseBody = '<html>MARKER-BODY</html>';
    for (final (status, code) in [
      (202, 0),
      (200, 1),
      (204, 1),
      (401, 1),
      (503, 1),
    ]) {
      receiver.status = status;
      final result = await run(argv(baseUrl: receiver.url));
      expect(result.code, code, reason: '$status');
      if (code == 1) {
        expect(result.lines, ['status $status']);
      } else {
        expect(result.lines, isEmpty);
      }
    }
  });

  test('redirect_is_not_followed', () async {
    final target = await Receiver.start();
    final first = await Receiver.start();
    addTearDown(target.close);
    addTearDown(first.close);
    first
      ..status = 307
      ..location = '${target.url}/hooks/icinga2/$_source';
    final result = await run(argv(baseUrl: first.url));
    expect(result.code, 1);
    expect(result.lines, ['status 307']);
    expect(first.requests, hasLength(1));
    expect(target.requests, isEmpty);
  });

  test('hmac_vectors', () {
    Uint8List bytes(int value, int count) =>
        Uint8List.fromList(List.filled(count, value));
    // RFC 4231, section 4, HMAC-SHA-256 (test cases 1 to 4, 6 and 7).
    final cases = <(List<int>, List<int>, String)>[
      (
        bytes(0x0b, 20),
        ascii.encode('Hi There'),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      ),
      (
        ascii.encode('Jefe'),
        ascii.encode('what do ya want for nothing?'),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      ),
      (
        bytes(0xaa, 20),
        bytes(0xdd, 50),
        '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe',
      ),
      (
        [for (var i = 1; i <= 25; i++) i],
        bytes(0xcd, 50),
        '82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b',
      ),
      (
        bytes(0xaa, 131),
        ascii.encode(
          'Test Using Larger Than Block-Size Key - Hash Key First',
        ),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
      ),
      (
        bytes(0xaa, 131),
        ascii.encode(
          'This is a test using a larger than block-size key and a larger '
          'than block-size data. The key needs to be hashed before being '
          'used by the HMAC algorithm.',
        ),
        '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2',
      ),
    ];
    for (final (key, data, expected) in cases) {
      expect(hmacSha256Hex(key, data), expected);
    }

    // ADR 0029: the signed input is ASCII(timestamp) 0x2e '-' 0x2e body, with
    // '-' standing for an absent Idempotency-Key, over the exact body bytes.
    final key = List<int>.generate(32, (i) => i);
    final body = utf8.encode('{"a":"é\u0000"}');
    final input = [...ascii.encode('1700000000.-.'), ...body];
    expect(
      ingressSignature(key, '1700000000', body),
      Hmac(sha256, key).convert(input).toString(),
    );
  });

  group('delivery', () {
    test('bearer_request_carries_the_document_and_the_token', () async {
      final receiver = await Receiver.start();
      addTearDown(receiver.close);
      final result = await run(
        argv(
          baseUrl: receiver.url,
          over: {
            '--notification-author': 'ann\u0000x',
            '--notification-comment': 'c',
            '--notification-type': 'CUSTOM',
          },
        ),
      );
      expect(result.code, 0, reason: result.text);
      final request = receiver.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/hooks/icinga2/$_source');
      expect(request.headers.value('authorization'), 'Bearer $_token');
      expect(request.headers.value('x-correlia-signature'), isNull);
      expect(request.headers.contentType?.mimeType, 'application/json');
      final document = jsonDecode(utf8.decode(request.body));
      expect(document, {
        'format': 'correlia.icinga2.v1',
        'object_type': 'service',
        'host': 'db1',
        'service': 'disk',
        'state': 'CRITICAL',
        'state_type': 'HARD',
        'last_state_change': '1700000000.123456',
        'output': 'CRITICAL: disk full',
        'notification_type': 'CUSTOM',
        'notification_author': 'ann\u{fffd}x',
        'notification_comment': 'c',
        'notification_time': '1700000001.654321',
      });
    });

    test('hmac_request_is_signed_over_the_exact_body', () async {
      final receiver = await Receiver.start();
      addTearDown(receiver.close);
      final result = await run(
        argv(baseUrl: receiver.url, hmac: true),
        now: DateTime.fromMillisecondsSinceEpoch(1700000042999),
      );
      expect(result.code, 0, reason: result.text);
      final request = receiver.requests.single;
      expect(request.headers.value('authorization'), isNull);
      expect(request.headers.value('x-correlia-timestamp'), '1700000042');
      final keyBytes = base64Url.decode('$_key=');
      final expected = Hmac(
        sha256,
        keyBytes,
      ).convert([...ascii.encode('1700000042.-.'), ...request.body]);
      expect(request.headers.value('x-correlia-signature'), 'sha256=$expected');
      expect(result.text, isNot(contains(_key)));
    });

    test('non_state_notification_without_a_state_change_time', () async {
      for (final type in [
        'CUSTOM',
        'ACKNOWLEDGEMENT',
        'DOWNTIMESTART',
        'FLAPPINGSTART',
      ]) {
        final receiver = await Receiver.start();
        addTearDown(receiver.close);
        final result = await run(
          argv(
            baseUrl: receiver.url,
            over: {
              '--notification-type': type,
              '--last-state-change': null,
              '--output': null,
            },
          ),
        );
        expect(result.code, 0, reason: '$type ${result.text}');
        final document =
            jsonDecode(utf8.decode(receiver.requests.single.body))
                as Map<String, Object?>;
        expect(
          document.containsKey('last_state_change'),
          isFalse,
          reason: type,
        );
        expect(document.containsKey('output'), isFalse, reason: type);
        expect(document['notification_type'], type);
        expect(document['notification_time'], '1700000001.654321');
      }
    });

    test('host_notification_omits_the_service', () async {
      final receiver = await Receiver.start();
      addTearDown(receiver.close);
      final result = await run(
        argv(
          baseUrl: receiver.url,
          over: {
            '--object-type': 'host',
            '--service': null,
            '--state': 'DOWN',
            '--output': null,
          },
        ),
      );
      expect(result.code, 0, reason: result.text);
      final document =
          jsonDecode(utf8.decode(receiver.requests.single.body))
              as Map<String, Object?>;
      expect(document.containsKey('service'), isFalse);
      expect(document.containsKey('output'), isFalse);
      expect(document['object_type'], 'host');
    });
  });

  group('configuration', () {
    Future<void> rejects(
      Map<String, String?> over,
      String expected, {
      bool hmac = false,
      List<String>? raw,
    }) async {
      final tripwire = await Tripwire.start();
      addTearDown(tripwire.close);
      final files = creds();
      final result = await run(
        raw ??
            argv(
              baseUrl: 'http://127.0.0.1:${tripwire.port}',
              over: over,
              hmac: hmac,
            ),
        files: files,
      );
      expect(result.code, 2, reason: result.text);
      expect(result.text, contains(expected));
      expect(files.statted, isEmpty, reason: 'no file touched');
      expect(await tripwire.contacted(), 0);
    }

    test('state_notification_without_a_state_change_time', () async {
      for (final type in ['PROBLEM', 'RECOVERY']) {
        await rejects({
          '--notification-type': type,
          '--last-state-change': null,
        }, 'missing_argument --last-state-change');
        await rejects({
          '--notification-type': type,
          '--last-state-change': '',
        }, 'invalid_argument --last-state-change');
      }
      await rejects({
        '--notification-type': 'CUSTOM',
        '--last-state-change': '',
      }, 'invalid_argument --last-state-change');
    });

    test('non_empty_environment', () async {
      final files = creds();
      final result = await run(
        argv(baseUrl: 'http://127.0.0.1:1'),
        files: files,
        environmentEmpty: false,
      );
      expect(result.code, 2);
      expect(result.lines, ['environment']);
      expect(files.statted, isEmpty);
    });

    test('names_and_settings', () async {
      await rejects({'--host': 'db1\u0000x'}, 'invalid_name');
      await rejects({'--service': 'a\nb'}, 'invalid_name');
      await rejects({'--host': ''}, 'invalid_name');
      await rejects({'--host': 'a\u007fb'}, 'invalid_name');
      await rejects({'--host': 'x' * 1025}, 'invalid_name');
      await rejects({'--ca-file': '/etc/ca.pem\u0000-next'}, '--ca-file');
      await rejects({'--ca-file': ''}, '--ca-file');
      await rejects({'--token-file': 'x' * 4097}, '--token-file');
      await rejects({'--source': 'not-a-uuid'}, '--source');
      await rejects({'--source': '$_source\nSECRET-MARKER'}, '--source');
      await rejects({'--source': _key}, '--source');
    });

    test('base_url_forms', () async {
      for (final url in [
        'https://user:secret@correlia.example',
        'https://correlia.example?token=secret',
        'https://correlia.example/hooks/icinga2/$_source/secret',
        'https://correlia.example\nhttps://x/SECRET-MARKER',
        'https://correlia.example/',
        'https://',
        'https://:8080',
      ]) {
        final files = creds();
        final result = await run(argv(baseUrl: url), files: files);
        expect(result.code, 2, reason: url);
        expect(result.text, contains('--base-url'), reason: url);
        expect(result.text, isNot(contains('secret')), reason: url);
        expect(files.statted, isEmpty, reason: url);
      }
    });

    test('arguments_are_exact', () async {
      final base = argv(baseUrl: 'http://127.0.0.1:1');
      await rejects({}, 'repeated', raw: [...base, '--host', '"again"']);
      await rejects({}, 'unknown', raw: [...base, '--extra', '"x"']);
      await rejects({}, 'missing', raw: [...base, '--output']);
      await rejects({}, 'unknown', raw: ['stray', ...base]);
      await rejects({'--token-file': null}, 'credential');
      await rejects({'--hmac-key-file': '"/creds/key"'}, 'credential');
      await rejects({'--host': null}, '--host');
      await rejects({'--service': null}, '--service');
      await rejects({'--object-type': 'host'}, '--service');
    });

    test('values_are_single_json_string_literals', () async {
      final base = argv(baseUrl: 'http://127.0.0.1:1');
      List<String> replaced(String name, String raw) {
        final copy = [...base];
        copy[copy.indexOf(name) + 1] = raw;
        return copy;
      }

      await rejects({}, '--host', raw: replaced('--host', 'db1'));
      await rejects({}, '--host', raw: replaced('--host', '"a" "b"'));
      await rejects({}, '--host', raw: replaced('--host', '5'));
      await rejects({}, '--host', raw: replaced('--host', '"a'));
      await rejects({}, '--output', raw: replaced('--output', 'null'));
    });

    test('times_and_enumerations_are_checked', () async {
      await rejects({
        '--last-state-change': '1700000000',
      }, '--last-state-change');
      await rejects(
        {'--notification-time': '0.123456'},
        '--notification-time'
        '',
      );
      await rejects({
        '--notification-time': '01700000000.123456',
      }, '--notification-time');
      await rejects({'--state': 'DOWN'}, '--state');
      await rejects({'--state': 'BOGUS'}, '--state');
      await rejects({'--state-type': 'MEDIUM'}, '--state-type');
      await rejects({'--notification-type': 'problem'}, '--notification-type');
      await rejects({'--object-type': 'Service'}, '--object-type');
    });

    test('key_file_must_be_the_canonical_form', () async {
      for (final content in [
        '${_key}A\n', // 44 characters
        '${_key.substring(0, 42)}\n', // 42 characters
        '${_key.substring(0, 42)}B\n', // 43 characters, non-canonical tail
        '$_key=\n',
        '$_key\n\n',
        '  $_key',
      ]) {
        final tripwire = await Tripwire.start();
        addTearDown(tripwire.close);
        final files = FakeFiles()..regular('/creds/key', utf8.encode(content));
        final result = await run(
          argv(baseUrl: 'http://127.0.0.1:${tripwire.port}', hmac: true),
          files: files,
        );
        expect(result.code, 2, reason: content);
        expect(result.text, contains('--hmac-key-file'), reason: content);
        expect(await tripwire.contacted(), 0);
      }
    });
  });
}
