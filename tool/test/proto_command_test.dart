import 'dart:io';

import 'package:correlia_tool/correlia_tool.dart';
import 'package:test/test.dart';

/// Copies the repository into a disposable directory owned by this test.
Future<Directory> _copyRepository(Directory parent) async {
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
        ...Platform.environment,
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

Future<void> _installValidator(Directory repo) async {
  final result = await Process.run(
    'npm',
    [
      'ci',
      '--prefix',
      'tool/schema_validation',
      '--prefer-offline',
      '--ignore-scripts',
      '--no-audit',
      '--no-fund',
    ],
    workingDirectory: repo.path,
  );
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
}

Future<({int exit, String out, String err})> _runTool(
  Directory repo,
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final command = ProtoCommand(
    repoRoot: repo,
    dartExecutable: Platform.resolvedExecutable,
    launch: (executable, args, workingDirectory) => runBoundedProcess(
      executable,
      args,
      workingDirectory,
      environment: environment,
    ),
    out: out,
    err: err,
    write: arguments.length == 1 && arguments.single == 'proto',
  );
  final code = await command.run();
  return (exit: code, out: '$out', err: '$err');
}

Future<ProcessResult> _validateFixtureCase(
  Directory repo,
  String caseName,
) async {
  return Process.run(
    'node',
    [
      '${repo.path}/tool/schema_validation/validate.mjs',
      '${repo.path}/contracts/schemas/'
          'correlia.event.v1.CanonicalEvent.jsonschema.strict.bundle.json',
      '${repo.path}/tool/schema_validation/fixtures',
      caseName,
    ],
    workingDirectory: repo.path,
  );
}

Map<String, List<int>> _snapshotFiles(Directory root) {
  final snapshot = <String, List<int>>{};
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = entity.path.substring(root.path.length + 1);
    snapshot[relative] = entity.readAsBytesSync();
  }
  return snapshot;
}

Future<String> _status(Directory repo) async {
  final result = await Process.run(
    'git',
    ['status', '--porcelain'],
    workingDirectory: repo.path,
  );
  return result.stdout as String;
}

void main() {
  late Directory scratch;
  late Directory repo;

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('correlia_proto_test_');
    repo = await _copyRepository(scratch);
    await _installValidator(repo);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  const timeout = Timeout(Duration(minutes: 5));

  test(
    'Generate in a fresh clone',
    () async {
      final first = await _runTool(repo, ['proto']);
      expect(first.exit, 0, reason: '${first.out}${first.err}');
      expect(await _status(repo), isEmpty);
      final firstBytes = _snapshotFiles(
        Directory('${repo.path}/correlia_server/lib/src/event_generated'),
      );
      final firstSchema = File(
        '${repo.path}/contracts/schemas/'
        'correlia.event.v1.CanonicalEvent.jsonschema.strict.bundle.json',
      ).readAsBytesSync();

      final second = await _runTool(repo, ['proto']);
      expect(second.exit, 0, reason: '${second.out}${second.err}');
      expect(await _status(repo), isEmpty);
      final secondBytes = _snapshotFiles(
        Directory('${repo.path}/correlia_server/lib/src/event_generated'),
      );
      final secondSchema = File(
        '${repo.path}/contracts/schemas/'
        'correlia.event.v1.CanonicalEvent.jsonschema.strict.bundle.json',
      ).readAsBytesSync();
      expect(secondBytes.keys, firstBytes.keys);
      for (final path in firstBytes.keys) {
        expect(secondBytes[path], firstBytes[path], reason: path);
      }
      expect(secondSchema, firstSchema);
    },
    timeout: timeout,
  );

  test(
    'Generator cannot run',
    () async {
      final proto = File(
        '${repo.path}/proto/correlia/event/v1/event.proto',
      );
      proto.writeAsStringSync('${proto.readAsStringSync()}\nnot valid proto\n');

      final result = await _runTool(repo, ['proto']);

      expect(result.exit, isNot(0));
      expect(result.err, contains('buf lint'));
      expect(result.err, isNot(contains('generated canonical event contract')));
    },
    timeout: timeout,
  );

  test(
    'Generator cannot run when the required plugin is unavailable',
    () async {
      final tools = Directory('${scratch.path}/tools')..createSync();
      for (final tool in ['buf', 'node']) {
        final located = await Process.run('which', [tool]);
        expect(located.exitCode, 0, reason: '${located.stderr}');
        final path = (located.stdout as String).trim();
        Link('${tools.path}/$tool').createSync(path);
      }

      final result = await _runTool(
        repo,
        ['proto'],
        environment: {...Platform.environment, 'PATH': tools.path},
      );

      expect(result.exit, isNot(0));
      expect(result.err, contains('buf generate'));
      expect(result.err, isNot(contains('generated canonical event contract')));
    },
    timeout: timeout,
  );

  test(
    'Current contract outputs',
    () async {
      final result = await _runTool(repo, ['proto:check']);
      expect(result.exit, 0, reason: '${result.out}${result.err}');
      expect(await _status(repo), isEmpty);
    },
    timeout: timeout,
  );

  test(
    'Stale generated content',
    () async {
      final generated = File(
        '${repo.path}/correlia_server/lib/src/event_generated/'
        'correlia/event/v1/event_bounds.dart',
      );
      final original = generated.readAsBytesSync();
      generated.writeAsStringSync(
        '${generated.readAsStringSync()}\n// stale content\n',
      );
      final before = await _status(repo);

      final result = await _runTool(repo, ['proto:check']);

      expect(result.exit, 1);
      expect(result.err, contains('event_bounds.dart'));
      expect(result.err, contains('content differs'));
      expect(result.err, contains('mise run proto'));
      expect(await _status(repo), before);

      final repair = await _runTool(repo, ['proto']);
      expect(repair.exit, 0, reason: '${repair.out}${repair.err}');
      expect(generated.readAsBytesSync(), original);
    },
    timeout: timeout,
  );

  test(
    'Deleted or obsolete output',
    () async {
      final schema = File(
        '${repo.path}/contracts/schemas/'
        'correlia.event.v1.CanonicalEvent.jsonschema.strict.bundle.json',
      );
      schema.deleteSync();
      final obsolete =
          File(
              '${repo.path}/correlia_server/lib/src/event_generated/old/obsolete.pb.dart',
            )
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('// obsolete\n');
      final before = await _status(repo);

      final result = await _runTool(repo, ['proto:check']);

      expect(result.exit, 1);
      expect(result.err, contains('contracts/schemas/'));
      expect(result.err, contains('obsolete.pb.dart'));
      expect(result.err, contains('mise run proto'));
      expect(await _status(repo), before);

      final repair = await _runTool(repo, ['proto']);
      expect(repair.exit, 0, reason: '${repair.out}${repair.err}');
      expect(obsolete.existsSync(), isFalse);
      expect(schema.existsSync(), isTrue);
    },
    timeout: timeout,
  );

  test(
    'Plugin generated drift includes changed missing and obsolete files',
    () async {
      final dartRoot = '${repo.path}/correlia_server/lib/src/plugin_generated';
      final goRoot = '${repo.path}/correlia_server/test/plugin/fixtures/go/gen';
      final changed = File(
        '$dartRoot/correlia/plugin/spike/v1/output.pb.dart',
      );
      changed.writeAsStringSync('${changed.readAsStringSync()}\n// stale\n');
      File('$goRoot/correlia/plugin/spike/v1/output.pb.go').deleteSync();
      final obsolete = File('$goRoot/obsolete.go')
        ..writeAsStringSync('package obsolete\n');
      final before = await _status(repo);

      final result = await _runTool(repo, ['proto:check']);
      expect(result.exit, 1);
      expect(result.err, contains('output.pb.dart (content differs)'));
      expect(
        result.err,
        contains('output.pb.go (generated but not committed)'),
      );
      expect(
        result.err,
        contains('obsolete.go (committed but no longer generated)'),
      );
      expect(await _status(repo), before);

      final repair = await _runTool(repo, ['proto']);
      expect(repair.exit, 0, reason: '${repair.out}${repair.err}');
      expect(obsolete.existsSync(), isFalse);
      expect(await _status(repo), isEmpty);
    },
    timeout: timeout,
  );

  test(
    'Payload schema covers key value numeric timestamp and base64 bounds',
    () async {
      for (final caseName in [
        'map key cap',
        'map value cap',
        'map entry cap',
        'invalid timestamp',
        'base64 data',
      ]) {
        final result = await _validateFixtureCase(repo, caseName);
        expect(
          result.exitCode,
          0,
          reason: '$caseName: ${result.stdout}${result.stderr}',
        );
      }
      final positive = File(
        '${repo.path}/tool/schema_validation/fixtures/valid/source-kind.json',
      ).readAsStringSync();
      expect(positive, contains('2026-11-10T00:00:00.123456789Z'));
      expect(positive, contains('4294967295'));
      expect(positive, contains('observation_key'));
    },
    timeout: timeout,
  );

  test(
    'Canonical payload is schema valid',
    () async {
      final result = await _validateFixtureCase(
        repo,
        'canonical payload is schema valid',
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('1 schema fixture case(s) passed'));
    },
    timeout: timeout,
  );

  test(
    'Payload constraints reject invalid values',
    () async {
      final result = await _validateFixtureCase(
        repo,
        'payload constraints reject invalid values',
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('1 schema fixture case(s) passed'));
    },
    timeout: timeout,
  );

  test(
    'Valid source-kind token',
    () async {
      final result = await _validateFixtureCase(
        repo,
        'valid source-kind token',
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('1 schema fixture case(s) passed'));
    },
    timeout: timeout,
  );

  test(
    'Valid substring does not validate the whole token',
    () async {
      final result = await _validateFixtureCase(
        repo,
        'valid substring does not validate the whole token',
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('1 schema fixture case(s) passed'));
    },
    timeout: timeout,
  );
}
