import 'dart:io';

import 'package:test/test.dart';

/// The one-line entries of the `run` list of the mise task [name].
List<String> _runEntries(String miseToml, String name) {
  final section = RegExp(
    '^\\[tasks\\.$name\\]\\n((?:(?!\\[).*\\n?)*)',
    multiLine: true,
  ).firstMatch(miseToml);
  expect(section, isNotNull, reason: 'no [tasks.$name] in mise.toml');
  final run = RegExp(
    r'^run = \[\n((?:\s+".*",\n)+)\]',
    multiLine: true,
  ).firstMatch(section!.group(1)!);
  expect(run, isNotNull, reason: 'tasks.$name.run is not a list of strings');
  return [
    for (final line in run!.group(1)!.trim().split('\n'))
      line
          .trim()
          .replaceFirst(RegExp(r'^"'), '')
          .replaceFirst(RegExp(r'",$'), ''),
  ];
}

void main() {
  test('an analysis warning fails the analyze step naming file and issue', () {
    final root = Directory.current.parent;
    final entries = _runEntries(
      File('${root.path}/mise.toml').readAsStringSync(),
      'check',
    );
    final analyze = entries.firstWhere(
      (entry) => entry.startsWith('dart analyze'),
      orElse: () => fail('the check has no `dart analyze` step: $entries'),
    );
    expect(analyze, 'dart analyze --fatal-infos');

    // A standalone package with the workspace's analysis options and a warning.
    final scratch = Directory.systemTemp.createTempSync('correlia_check_');
    addTearDown(() => scratch.deleteSync(recursive: true));
    File('${scratch.path}/pubspec.yaml').writeAsStringSync('''
name: fixture
publish_to: none
environment:
  sdk: ^3.12.2
dev_dependencies:
  lints: ">=3.0.0 <7.0.0"
''');
    File(
      '${root.path}/analysis_options.yaml',
    ).copySync('${scratch.path}/analysis_options.yaml');
    File('${scratch.path}/lib/unused.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('void f() {\n  final unused = 1;\n}\n');
    final dart = Platform.resolvedExecutable;
    final get = Process.runSync(dart, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: scratch.path);
    expect(get.exitCode, 0, reason: '${get.stderr}');

    final result = Process.runSync(dart, [
      'analyze',
      '--fatal-infos',
    ], workingDirectory: scratch.path);

    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('lib/unused.dart'));
    expect(result.stdout, contains('unused_local_variable'));
  });

  test('the check runs its steps in order and stops at the first failure', () {
    final entries = _runEntries(
      File('${Directory.current.parent.path}/mise.toml').readAsStringSync(),
      'check',
    );
    expect(entries, [
      'openspec validate --all --strict',
      'dart run tool/bin/tool.dart doctor',
      'dart analyze --fatal-infos',
      'flutter analyze --fatal-infos correlia_flutter',
      'dart format --output=none --set-exit-if-changed .',
      'dart run tool/bin/tool.dart generated',
      'dart run tool/bin/tool.dart test',
      'cd tool && dart test',
      'cd correlia_flutter && flutter test',
    ]);
  });
}
