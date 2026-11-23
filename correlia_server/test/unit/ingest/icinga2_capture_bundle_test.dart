import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../../tool/icinga2_capture/bundle.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('capture-bundle-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('rebuild_during_a_capture_does_not_change_the_bundle', () {
    // The manifest hashes, the installed files and the rendered settings come
    // from one read: inputs replaced afterwards change none of them.
    final sender = File('${root.path}/correlia-icinga2-notify')
      ..writeAsStringSync('sender A');
    final contrib = Directory('${root.path}/contrib')..createSync();
    File('${contrib.path}/correlia.conf').writeAsStringSync('settings A');
    File('${contrib.path}/correlia-commands.conf').writeAsStringSync('cmd A');
    File('${contrib.path}/README.md').writeAsStringSync('readme A');

    final bundle = CaptureBundle.read(sender, contrib);
    sender.writeAsStringSync('sender B');
    File('${contrib.path}/correlia.conf').writeAsStringSync('settings B');
    File('${contrib.path}/correlia-commands.conf').writeAsStringSync('cmd B');

    String hash(String text) => sha256.convert(utf8.encode(text)).toString();
    expect(utf8.decode(bundle.sender), 'sender A');
    expect(bundle.senderSha256, hash('sender A'));
    expect(bundle.contribSha256, {
      'README.md': hash('readme A'),
      'correlia-commands.conf': hash('cmd A'),
      'correlia.conf': hash('settings A'),
    });
    expect(
      {
        for (final MapEntry(:key, :value) in bundle.definitions.entries)
          key: utf8.decode(value),
      },
      {'correlia-commands.conf': 'cmd A', 'correlia.conf': 'settings A'},
    );
    expect(bundle.shippedSettings, 'settings A');
  });
}
