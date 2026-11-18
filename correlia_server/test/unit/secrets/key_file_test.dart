import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/secrets/key_file.dart';
import 'package:test/test.dart';

void main() {
  group('key_file_rejected', () {
    late Directory directory;
    late File file;
    final key = base64Url.encode(Uint8List(32)).substring(0, 43);

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('correlia-key-test-');
      addTearDown(() => directory.delete(recursive: true));
      file = File('${directory.path}/key');
    });

    Future<void> writeKey(String data, {String mode = '0600'}) async {
      await file.writeAsString(data);
      final result = await Process.run('/usr/bin/chmod', [mode, file.path]);
      expect(result.exitCode, 0, reason: 'Fixture permission setup');
    }

    Matcher rejects(String code, String input) => isA<BootstrapError>()
        .having((error) => error.fileKind, 'file kind', 'secret_key')
        .having((error) => error.code, 'code', code)
        .having(
          (error) => error.toString(),
          'diagnostic',
          isNot(contains(input)),
        );

    test('absent file', () async {
      await expectLater(
        loadSecretKey(file.path),
        throwsA(rejects('regular_file', file.path)),
      );
    });

    test('group-readable file', () async {
      await writeKey(key, mode: '0640');
      await expectLater(
        loadSecretKey(file.path),
        throwsA(rejects('permissions', key)),
      );
    });

    test('symlink to a valid file', () async {
      await writeKey(key);
      final link = await Link('${directory.path}/key-link').create(file.path);
      await expectLater(
        loadSecretKey(link.path),
        throwsA(rejects('regular_file', key)),
      );
    });

    test('file owned by a different UID', () async {
      await writeKey(key);
      final uid = await Process.run('/usr/bin/id', ['-u']);
      expect(uid.exitCode, 0);
      final otherUid = int.parse((uid.stdout as String).trim()) == 0 ? 1 : 0;
      await expectLater(
        loadSecretKey(file.path, effectiveUid: otherUid),
        throwsA(rejects('owner', key)),
      );
    });

    for (final (label, input) in [
      ('wrong length', 'text-not-a-valid-key'),
      ('padding', '$key='),
      ('noncanonical trailing bits', '${key.substring(0, 42)}B'),
    ]) {
      test(label, () async {
        await writeKey(input);
        await expectLater(
          loadSecretKey(file.path),
          throwsA(rejects('format', input)),
        );
      });
    }

    test('accepts a canonical key followed by one LF', () async {
      await writeKey('$key\n');
      expect(await loadSecretKey(file.path), orderedEquals(Uint8List(32)));
    });
  });
}
