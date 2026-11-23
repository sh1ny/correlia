import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/icinga2_capture/staging.dart';

void main() {
  late Directory root;
  late Directory target;

  setUp(() {
    root = Directory.systemTemp.createTempSync('capture-staging-');
    target = Directory('${root.path}/2.16.6/linux-x64');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('second_capture_of_a_pair_is_refused', () async {
    // A capture holding the pair lock keeps a second process out; the lock
    // is per process, so the second one is a real child.
    final held = lockPair(target);
    expect(held, isNotNull);
    addTearDown(held!.closeSync);
    final script = File('${root.path}/lock.dart')
      ..writeAsStringSync('''
import 'dart:io';
import '${File('tool/icinga2_capture/staging.dart').absolute.uri}';
void main() => stdout.write(
  lockPair(Directory('${target.path}')) == null ? 'refused' : 'locked',
);
''');
    final child = await Process.run(Platform.resolvedExecutable, [
      'run',
      script.path,
    ]);
    expect(child.exitCode, 0, reason: '${child.stderr}');
    expect(child.stdout, 'refused');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('published_run_replaces_the_pair_directory', () {
    // An interrupted earlier run leaves its staging behind; a new one starts
    // clean, and publishing leaves only the new run's files.
    target.createSync(recursive: true);
    File('${target.path}/manifest.json').writeAsStringSync('{"run":1}');
    File('${target.path}/kept.json').writeAsStringSync('run 1');
    File('${target.path}/dropped.json').writeAsStringSync('run 1');
    Directory('${target.path}.staging').createSync();
    File('${target.path}.staging/stray.json').writeAsStringSync('stray');

    final partial = openStaging(target, keep: true);
    expect(_names(partial), ['dropped.json', 'kept.json', 'manifest.json']);
    final full = openStaging(target, keep: false);
    expect(full.listSync(), isEmpty);
    File('${full.path}/kept.json').writeAsStringSync('run 2');
    File('${full.path}/manifest.json').writeAsStringSync('{"run":2}');
    // Until it is published, the pair still holds the earlier run whole.
    expect(_names(target), ['dropped.json', 'kept.json', 'manifest.json']);

    publishStaging(full, target);
    expect(_names(target), ['kept.json', 'manifest.json']);
    expect(
      jsonDecode(File('${target.path}/manifest.json').readAsStringSync()),
      {'run': 2},
    );
    expect(Directory('${target.path}.staging').existsSync(), isFalse);
    expect(Directory('${target.path}.old').existsSync(), isFalse);
  });

  test('interrupted_publication_restores_the_last_run', () {
    // Interrupted after the pair moved to .old and before staging moved in:
    // the next run starts from that last complete run.
    Directory('${target.path}.old').createSync(recursive: true);
    File('${target.path}.old/manifest.json').writeAsStringSync('{"run":1}');
    Directory('${target.path}.staging').createSync();
    File('${target.path}.staging/half.json').writeAsStringSync('run 2');

    final partial = openStaging(target, keep: true);
    expect(_names(partial), ['manifest.json']);
    expect(_names(target), ['manifest.json']);
    expect(Directory('${target.path}.old').existsSync(), isFalse);
  });
}

List<String> _names(Directory d) => [
  for (final f in d.listSync().whereType<File>()) f.uri.pathSegments.last,
]..sort();
