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
  Directory repo, {
  bool compatibilityOnly = false,
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  if (compatibilityOnly) {
    final command = ProtoCommand(
      repoRoot: repo,
      dartExecutable: Platform.resolvedExecutable,
      launch: runBoundedProcess,
      out: out,
      err: err,
      write: false,
      compatibilityOnly: true,
    );
    final code = await command.run();
    return (exit: code, out: '$out', err: '$err');
  }
  final runner = buildRunner(repoRoot: repo, out: out, err: err);
  final code = await runner.run(['proto:check']);
  return (exit: code ?? 0, out: '$out', err: '$err');
}

String _mutateProto(String source, String from, String to) {
  final index = source.indexOf(from);
  if (index < 0) throw StateError('Mutation target not found: $from');
  return source.replaceRange(index, index + from.length, to);
}

String _mutateFieldRule(
  String source,
  String fieldDeclaration,
  String ruleFrom,
  String ruleTo,
) {
  final declaration = source.indexOf(fieldDeclaration);
  if (declaration < 0) {
    throw StateError('Field declaration not found: $fieldDeclaration');
  }
  final end = source.indexOf('];', declaration);
  if (end < 0) throw StateError('Field declaration has no end');
  final region = source.substring(declaration, end);
  if (!region.contains(ruleFrom)) {
    throw StateError('Rule target not found: $ruleFrom');
  }
  return source.replaceRange(
    declaration,
    end,
    region.replaceFirst(ruleFrom, ruleTo),
  );
}

void main() {
  late Directory scratch;
  late Directory repo;
  late File proto;

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('correlia_proto_compat_');
    repo = await _copyRepository(scratch);
    await _installValidator(repo);
    proto = File('${repo.path}/proto/correlia/event/v1/event.proto');
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  const timeout = Timeout(Duration(minutes: 5));

  test(
    'Add optional bounded field',
    () async {
      final before = File(
        '${repo.path}/contracts/baselines/event-v1.0.binpb',
      ).readAsBytesSync();
      final text = proto.readAsStringSync();
      final insertion = text.indexOf(
        '\n}',
        text.indexOf('message CanonicalEvent'),
      );
      expect(insertion, isNot(-1));
      proto.writeAsStringSync(
        text.replaceRange(
          insertion,
          insertion,
          '\n  optional string producer_note = 100 [\n'
          '    json_name = "producer_note",\n'
          '    (buf.validate.field).string = {min_len: 1, max_len: 256}\n'
          '  ];',
        ),
      );

      final result = await _runTool(repo, compatibilityOnly: true);

      expect(result.exit, 0, reason: '${result.out}${result.err}');
      expect(result.err, isNot(contains('validation rule changed')));
      expect(result.err, isNot(contains('buf breaking')));
      expect(
        File(
          '${repo.path}/contracts/baselines/event-v1.0.binpb',
        ).readAsBytesSync(),
        before,
      );
    },
    timeout: timeout,
  );

  test(
    'Existing value domains cannot widen in a minor',
    () async {
      final text = proto.readAsStringSync();
      final declaration = text.indexOf('string summary = 11 [');
      expect(declaration, isNot(-1));
      final nextDeclaration = text.indexOf(
        '\n  ',
        text.indexOf('];', declaration),
      );
      expect(nextDeclaration, isNot(-1));
      final region = text.substring(declaration, nextDeclaration);
      expect(region, contains('max_len: 256'));
      proto.writeAsStringSync(
        text.replaceRange(
          declaration,
          nextDeclaration,
          region.replaceFirst('max_len: 256', 'max_len: 512'),
        ),
      );

      final result = await _runTool(repo, compatibilityOnly: true);

      expect(result.exit, 1);
      expect(result.err, contains('CanonicalEvent.summary'));
      expect(result.err, contains('validation rule changed'));
    },
    timeout: timeout,
  );

  test(
    'Break existing consumers',
    () async {
      final original = proto.readAsStringSync();
      final mutations = <({String name, String Function(String) mutate})>[
        (
          name: 'field removal',
          mutate: (source) {
            final start = source.indexOf('  string summary = 11 [');
            final end = source.indexOf('];', start) + 2;
            return source.replaceRange(start, end, '');
          },
        ),
        (
          name: 'field number reuse',
          mutate: (source) => _mutateProto(
            source,
            'string summary = 11 [',
            'string summary = 10 [',
          ),
        ),
        (
          name: 'JSON name change',
          mutate: (source) => _mutateProto(
            source,
            'json_name = "summary"',
            'json_name = "headline"',
          ),
        ),
        (
          name: 'field presence change',
          mutate: (source) => _mutateProto(
            source,
            'optional string severity_original = 9 [',
            'string severity_original = 9 [',
          ),
        ),
        (
          name: 'summary cap narrowing',
          mutate: (source) => _mutateFieldRule(
            source,
            'string summary = 11 [',
            'max_len: 256',
            'max_len: 128',
          ),
        ),
        (
          name: 'map cap narrowing',
          mutate: (source) => _mutateFieldRule(
            source,
            'map<string, string> labels = 15 [',
            'max_pairs: 128',
            'max_pairs: 64',
          ),
        ),
        (
          name: 'numeric cap narrowing',
          mutate: (source) => _mutateFieldRule(
            source,
            'uint32 size = 3 [',
            'lte: 4294967295',
            'lte: 1024',
          ),
        ),
        (
          name: 'new required field',
          mutate: (source) {
            final insertion = source.indexOf(
              '\n}',
              source.indexOf('message CanonicalEvent'),
            );
            return source.replaceRange(
              insertion,
              insertion,
              '\n  string newly_required = 101 [\n'
              '    json_name = "newly_required",\n'
              '    (buf.validate.field).required = true\n'
              '  ];',
            );
          },
        ),
        (
          name: 'new required oneof',
          mutate: (source) {
            final insertion = source.indexOf(
              '\n}',
              source.indexOf('message CanonicalEvent'),
            );
            return source.replaceRange(
              insertion,
              insertion,
              '\n  oneof newly_required_oneof {\n'
              '    option (buf.validate.oneof).required = true;\n'
              '    string required_choice = 102;\n'
              '  }',
            );
          },
        ),
        (
          name: 'enum value addition',
          mutate: (source) => _mutateProto(
            source,
            'EVENT_KIND_HEARTBEAT = 6;',
            'EVENT_KIND_HEARTBEAT = 6;\n  EVENT_KIND_NEW = 7;',
          ),
        ),
        (
          name: 'enum domain change',
          mutate: (source) => _mutateProto(
            source,
            'EVENT_KIND_HEARTBEAT = 6;',
            'EVENT_KIND_HEARTBEAT = 7;',
          ),
        ),
      ];

      for (final mutation in mutations) {
        proto.writeAsStringSync(mutation.mutate(original));
        final result = await _runTool(repo, compatibilityOnly: true);
        expect(
          result.exit,
          isNot(0),
          reason: '${mutation.name} unexpectedly passed',
        );
        expect(result.err, isNotEmpty, reason: mutation.name);
        proto.writeAsStringSync(original);
      }
    },
    timeout: timeout,
  );

  test(
    'Missing compatibility baseline',
    () async {
      File(
        '${repo.path}/contracts/baselines/event-v1.0.binpb',
      ).deleteSync();

      final result = await _runTool(repo, compatibilityOnly: true);

      expect(result.exit, 1);
      expect(result.err, contains('compatibility baseline is missing'));
      expect(result.err, contains('never rebuilt automatically'));
    },
    timeout: timeout,
  );
}
