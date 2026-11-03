import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:correlia_tool/correlia_tool.dart';
import 'package:test/test.dart';

/// Hand-written resolver: answers from a fixed table, no process is run.
class FakeResolver implements ToolResolver {
  FakeResolver(this.tools);

  final Map<String, ResolvedTool> tools;

  @override
  Future<ResolvedTool?> resolve(String tool) async => tools[tool];
}

const _pins = {
  'dart': '3.13.7',
  'flutter': '3.47.9',
  'go': '1.27.3',
  'buf': '1.75.0',
  'openspec': '1.16.0',
  'serverpod_cli': '4.1.0',
};

Map<String, ResolvedTool> _linuxTools() => {
  for (final MapEntry(:key, :value) in _pins.entries)
    key: ResolvedTool(
      path: '/home/dev/.local/share/mise/bin/$key',
      version: value,
    ),
};

Future<({int? code, String out, String err})> _runDoctor(
  Map<String, ResolvedTool> tools,
) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final runner = CommandRunner<int>('tool', 'test')
    ..addCommand(
      DoctorCommand(
        resolver: FakeResolver(tools),
        pins: _pins,
        out: out,
        err: err,
      ),
    );
  final code = await runner.run(['doctor']);
  return (code: code, out: out.toString(), err: err.toString());
}

void main() {
  group('doctor', () {
    test(
      'reports a Linux path and the pinned version for every tool',
      () async {
        final result = await _runDoctor(_linuxTools());

        expect(result.code, 0, reason: result.err);
        for (final MapEntry(:key, :value) in _pins.entries) {
          expect(result.out, contains(key));
          expect(result.out, contains('/home/dev/.local/share/mise/bin/$key'));
          expect(result.out, contains(value));
        }
        expect(result.err, isEmpty);
      },
    );

    test(
      'a wrong serverpod_cli version fails naming tool, pinned and found',
      () async {
        final tools = _linuxTools()
          ..['serverpod_cli'] = const ResolvedTool(
            path: '/home/dev/.pub-cache/serverpod_cli-4.0.0',
            version: '4.0.0',
          );

        final result = await _runDoctor(tools);

        expect(result.code, isNot(0));
        expect(result.err, contains('serverpod_cli'));
        expect(result.err, contains('4.1.0'));
        expect(result.err, contains('4.0.0'));
      },
    );

    test(
      'a missing tool fails naming the tool and its pinned version',
      () async {
        final tools = _linuxTools()..remove('buf');

        final result = await _runDoctor(tools);

        expect(result.code, isNot(0));
        expect(result.err, contains('buf'));
        expect(result.err, contains('1.75.0'));
      },
    );

    test('a tool resolved to a Windows path fails naming the tool', () async {
      final tools = _linuxTools()
        ..['dart'] = const ResolvedTool(
          path: '/mnt/c/tools/dart-sdk/bin/dart.exe',
          version: '3.13.7',
        );

      final result = await _runDoctor(tools);

      expect(result.code, isNot(0));
      expect(result.err, contains('dart'));
      expect(result.err, contains('/mnt/c/tools/dart-sdk/bin/dart.exe'));
    });

    test(
      'a Windows dart earlier on PATH does not win over the pinned one',
      () async {
        final repoRoot = Directory.current.parent;
        final pinned = Pins.load(repoRoot);
        final fake = Directory.systemTemp.createTempSync('fake-windows-dart');
        addTearDown(() => fake.deleteSync(recursive: true));
        for (final name in ['dart', 'dart.exe']) {
          final file = File('${fake.path}/$name')
            ..writeAsStringSync('#!/bin/sh\necho "Dart SDK version: 0.0.1"\n');
          Process.runSync('chmod', ['+x', file.path]);
        }

        final result = Process.runSync(
          'mise',
          ['exec', '--', 'which', 'dart'],
          workingDirectory: repoRoot.path,
          environment: {
            'PATH': '${fake.path}:${Platform.environment['PATH']}',
          },
        );

        expect(result.exitCode, 0, reason: '${result.stderr}');
        final resolved = (result.stdout as String).trim();
        expect(resolved, isNot(startsWith(fake.path)));
        expect(resolved, contains('flutter/${pinned.versionOf('flutter')}/'));
      },
    );
  });
}
