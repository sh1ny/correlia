import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:correlia_tool/correlia_tool.dart';
import 'package:test/test.dart';

/// Runs the real `dart test` in [directory] and captures its stdout.
class _CapturingLauncher {
  final stdoutText = StringBuffer();
  int? exitCode;

  Future<int> call(List<String> args, Directory directory) async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['test', ...args],
      workingDirectory: directory.path,
    );
    stdoutText.write(result.stdout);
    return exitCode = result.exitCode;
  }
}

/// The names of the tests that actually ran (not skipped, not the runner's
/// hidden "loading ..." entries) in a `--reporter json` event stream.
List<String> _ranTests(String jsonLines) {
  final names = <int, String>{};
  final ran = <String>[];
  for (final line in const LineSplitter().convert(jsonLines)) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    switch (event) {
      case {'type': 'testStart', 'test': {'id': int id, 'name': String name}}:
        names[id] = name;
      case {
        'type': 'testDone',
        'testID': int id,
        'hidden': false,
        'skipped': false,
      }:
        final name = names[id];
        if (name != null) ran.add(name);
    }
  }
  return ran;
}

Directory _fixture() =>
    Directory('${Directory.current.path}/test/fixtures/tiers');

Future<({int exit, List<String> ran})> _tool(List<String> args) async {
  final launcher = _CapturingLauncher();
  final runner = CommandRunner<int>('tool', 'test')
    ..addCommand(
      TestCommand(
        packageDirectory: _fixture(),
        launch: launcher.call,
        err: StringBuffer(),
      ),
    );
  final code = await runner.run([
    'test',
    ...args,
    '--reporter',
    'json',
  ]);
  return (exit: code ?? 0, ran: _ranTests(launcher.stdoutText.toString()));
}

void main() {
  group('buildDartTestArguments', () {
    test('no arguments selects the fast preset', () {
      expect(buildDartTestArguments([]), ['-P', 'fast']);
    });

    test('arguments selecting no tag add the fast preset and -x load', () {
      expect(buildDartTestArguments(['--reporter', 'expanded']), [
        '-P',
        'fast',
        '-x',
        'load',
        '--reporter',
        'expanded',
      ]);
    });

    test('exclusion alone does not count as selecting a tag', () {
      expect(buildDartTestArguments(['-x', 'db']), [
        '-P',
        'fast',
        '-x',
        'load',
        '-x',
        'db',
      ]);
    });

    for (final selector in [
      ['--tags', 'db'],
      ['--tags=db'],
      ['-t', 'db'],
      ['-tdb'],
      ['--tags', 'db || e2e'],
    ]) {
      test('${selector.join(' ')} adds only -x load', () {
        expect(buildDartTestArguments(selector), ['-x', 'load', ...selector]);
      });
    }

    for (final selector in [
      ['--tags', 'load'],
      ['--tags=load'],
      ['-t', 'load'],
      ['-tload'],
      ['--tags', 'db || load'],
    ]) {
      test('${selector.join(' ')} passes the arguments through only', () {
        expect(buildDartTestArguments(selector), selector);
      });
    }

    test('a tag that merely contains load does not select load', () {
      expect(buildDartTestArguments(['--tags', 'payload']), [
        '-x',
        'load',
        '--tags',
        'payload',
      ]);
    });

    test('all excludes only load', () {
      expect(buildDartTestArguments([], all: true), ['-x', 'load']);
    });

    test('all with a load selection does not exclude load', () {
      expect(buildDartTestArguments(['-t', 'load'], all: true), [
        '-t',
        'load',
      ]);
    });
  });

  group('fixture tiers', () {
    test('no arguments runs only fast tests', () async {
      final result = await _tool([]);

      expect(result.exit, 0);
      expect(result.ran, ['fast tier case']);
    });

    test('--tags db runs every db test and nothing untagged', () async {
      final result = await _tool(['--tags', 'db']);

      expect(result.exit, 0);
      expect(result.ran, isNotEmpty);
      expect(result.ran, everyElement(startsWith('db')));
    });

    test('--reporter expanded runs only fast tests', () async {
      final launcher = _CapturingLauncher();
      final runner = CommandRunner<int>('tool', 'test')
        ..addCommand(
          TestCommand(
            packageDirectory: _fixture(),
            launch: launcher.call,
            err: StringBuffer(),
          ),
        );

      final code = await runner.run(['test', '--reporter', 'expanded']);

      expect(code, 0);
      expect(launcher.stdoutText.toString(), contains('fast tier case'));
      for (final tier in ['db', 'e2e', 'plugin', 'load']) {
        expect(launcher.stdoutText.toString(), isNot(contains('$tier tier')));
      }
    });

    test('--tags load runs only load tests', () async {
      final result = await _tool(['--tags', 'load']);

      expect(result.exit, 0);
      expect(result.ran, ['load tier case']);
    });

    test('test:all runs fast db e2e plugin and no load', () async {
      final result = await _tool(['--all']);

      expect(result.exit, 0);
      expect(
        result.ran,
        unorderedEquals([
          'fast tier case',
          'db tier case',
          'e2e tier case',
          'plugin tier case',
        ]),
      );
    });

    test('--tags dbb exits non-zero', () async {
      final result = await _tool(['--tags', 'dbb']);

      expect(result.exit, isNot(0));
      expect(result.ran, isEmpty);
    });
  });

  test('the fast preset also excludes the integration guard tag', () {
    final server = File(
      '${Directory.current.parent.path}/correlia_server/dart_test.yaml',
    ).readAsStringSync();

    expect(server, contains('  integration: {}'));
    expect(
      server,
      contains(
        'exclude_tags: "db || e2e || plugin || load || integration"',
      ),
    );
  });

  test('the fixture declares the same tiers as correlia_server', () {
    final server = File(
      '${Directory.current.parent.path}/correlia_server/dart_test.yaml',
    ).readAsStringSync();
    final fixture = File(
      '${_fixture().path}/dart_test.yaml',
    ).readAsStringSync();
    String body(String text) => text
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'))
        .join('\n');
    expect(body(fixture), contains(body(server)));
  });
}
