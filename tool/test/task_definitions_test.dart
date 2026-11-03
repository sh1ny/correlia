import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('mise.toml and tool sources have no Windows or WSL references', () {
    final root = Directory.current.parent;
    // Built from parts so this test file never contains the needles itself.
    final needles = ['/${'mnt'}/', 'wsl${'path'}', '.${'ex'}e', 'cmd.${'ex'}e'];
    final files = <File>[
      File('${root.path}/mise.toml'),
      for (final dir in ['tool/bin', 'tool/lib'])
        ...Directory(
          '${root.path}/$dir',
        ).listSync(recursive: true).whereType<File>(),
    ];
    expect(files.length, greaterThan(1));

    final hits = <String>[];
    for (final file in files) {
      final text = file.readAsStringSync();
      for (final needle in needles) {
        if (text.contains(needle)) hits.add('${file.path}: $needle');
      }
    }

    expect(hits, isEmpty);
  });
}
