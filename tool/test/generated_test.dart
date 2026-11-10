import 'dart:io';

import 'package:correlia_tool/correlia_tool.dart';
import 'package:test/test.dart';

/// Copies the repository (tracked and unignored files, so no `.dart_tool`,
/// `build` or passwords) into a fresh git repository under [parent] and
/// commits it, so `git status` of the copy shows what a run changed.
Future<Directory> _copyOfRepository(Directory parent) async {
  final root = Directory.current.parent;
  final files = await Process.run('git', [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ], workingDirectory: root.path);
  expect(files.exitCode, 0, reason: '${files.stderr}');
  final copy = Directory('${parent.path}/repo')..createSync();
  for (final relative in (files.stdout as String).split('\u0000')) {
    if (relative.isEmpty) continue;
    final source = File('${root.path}/$relative');
    if (!source.existsSync()) continue;
    final target = File('${copy.path}/$relative')
      ..parent.createSync(recursive: true);
    source.copySync(target.path);
  }
  for (final args in [
    ['init', '-q'],
    ['add', '-A'],
    [
      '-c',
      'user.name=Nikolay Bochev',
      '-c',
      'user.email=309868+sh1ny@users.noreply.github.com',
      'commit',
      '-q',
      '-m',
      'copy\n\nCo-authored-by: KintsugiBot <296966193+KintsugiBot@users.noreply.github.com>',
    ],
  ]) {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: copy.path,
      environment: {
        'GIT_AUTHOR_NAME': 'Nikolay Bochev',
        'GIT_AUTHOR_EMAIL': '309868+sh1ny@users.noreply.github.com',
        'GIT_COMMITTER_NAME': 'Nikolay Bochev',
        'GIT_COMMITTER_EMAIL': '309868+sh1ny@users.noreply.github.com',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }
  return copy;
}

Future<String> _status(Directory repo) async {
  final result = await Process.run('git', [
    'status',
    '--porcelain',
  ], workingDirectory: repo.path);
  return result.stdout as String;
}

Future<({int exit, String out, String err})> _generated(Directory repo) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final runner = buildRunner(repoRoot: repo, out: out, err: err);
  final code = await runner.run(['generated']);
  return (exit: code ?? 0, out: '$out', err: '$err');
}

void main() {
  late Directory scratch;
  late Directory repo;

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('correlia_generated_');
    repo = await _copyOfRepository(scratch);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  const timeout = Timeout(Duration(minutes: 3));

  test(
    'current code passes and the checkout is unchanged',
    () async {
      expect(await _status(repo), isEmpty);

      final result = await _generated(repo);

      expect(result.exit, 0, reason: '${result.out}${result.err}');
      expect(await _status(repo), isEmpty);
      expect(Directory('${repo.path}/.dart_tool').existsSync(), isFalse);
    },
    timeout: timeout,
  );

  test(
    'a stale generated file fails naming it',
    () async {
      const stale = 'correlia_server/lib/src/generated/endpoints.dart';
      final file = File('${repo.path}/$stale');
      file.writeAsStringSync('// edited by hand\n${file.readAsStringSync()}');
      final before = await _status(repo);

      final result = await _generated(repo);

      expect(result.exit, 1);
      expect(result.err, contains(stale));
      expect(await _status(repo), before);
      expect(file.readAsStringSync(), startsWith('// edited by hand'));
    },
    timeout: timeout,
  );
}
