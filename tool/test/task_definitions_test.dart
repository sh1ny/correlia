import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('mise.toml and tool sources have no Windows or WSL references', () {
    final root = Directory.current.parent;
    // Built from parts so this test file never contains the needles itself.
    final needles = ['/${'mnt'}/', 'wsl${'path'}', '.${'ex'}e', 'cmd.${'ex'}e'];
    final files = <File>[
      File('${root.path}/mise.toml'),
      ...Directory(
        '${root.path}/.github/workflows',
      ).listSync(recursive: true).whereType<File>(),
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

  test('test:all runs every sender test, compiled-binary e2e included', () {
    final text = File(
      '${Directory.current.parent.path}/mise.toml',
    ).readAsStringSync();
    final start = text.indexOf('[tasks."test:all"]');
    expect(start, isNot(-1));
    final end = text.indexOf('\n[', start + 1);
    final task = text.substring(start, end == -1 ? text.length : end);
    // The CI job runs `mise run test:all`; the sender's `e2e` tag is not in
    // the fast preset that `check` runs, so test:all must run it unfiltered.
    expect(task, contains('"cd correlia_icinga2_notify && dart test"'));
  });
}
