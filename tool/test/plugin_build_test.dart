import 'dart:io';

import 'package:test/test.dart';

Future<Directory> _copyRepository(Directory scratch) async {
  final root = Directory.current.parent;
  final files = await Process.run('git', [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ], workingDirectory: root.path);
  expect(files.exitCode, 0, reason: '${files.stderr}');
  final copy = Directory('${scratch.path}/repo')..createSync();
  for (final relative in (files.stdout as String).split('\u0000')) {
    if (relative.isEmpty) continue;
    final source = File('${root.path}/$relative');
    if (!source.existsSync()) continue;
    final target = File('${copy.path}/$relative')
      ..parent.createSync(recursive: true);
    source.copySync(target.path);
  }
  return copy;
}

void _writeSentinel(Directory repo) {
  File(
    '${repo.path}/correlia_server/test/plugin/build_sentinel_test.dart',
  ).writeAsStringSync('''
import 'dart:io';
import 'package:test/test.dart';
void main() {
  test('tier sentinel', () {
    File('build_sentinel_ran').writeAsStringSync('ran');
  }, tags: ['plugin']);
}
''');
}

Future<ProcessResult> _runTier(Directory repo) => Process.run(
  'mise',
  [
    'run',
    'test',
    '--',
    '--tags',
    'plugin',
    'test/plugin/build_sentinel_test.dart',
  ],
  workingDirectory: repo.path,
  environment: {'MISE_TRUSTED_CONFIG_PATHS': repo.path},
);

void main() {
  late Directory scratch;
  late Directory repo;
  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('correlia_plugin_build_');
    repo = await _copyRepository(scratch);
  });
  tearDown(() => scratch.deleteSync(recursive: true));
  test('plugin_tier_on_clean_clone', () async {
    _writeSentinel(repo);
    final result = await _runTier(repo);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(File('${repo.path}/build/plugins/output-nats').existsSync(), isTrue);
    expect(File('${repo.path}/build/plugins/natsdev').existsSync(), isTrue);
    expect(
      File('${repo.path}/correlia_server/build_sentinel_ran').existsSync(),
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('module_checksum_mismatch', () async {
    final build = await Process.run(
      'mise',
      ['run', 'plugins:build'],
      workingDirectory: repo.path,
      environment: {'MISE_TRUSTED_CONFIG_PATHS': repo.path},
    );
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    _writeSentinel(repo);
    final sum = File('${repo.path}/plugins/go.sum');
    final original = sum.readAsStringSync();
    final line = RegExp(
      r'^github\.com/hashicorp/go-plugin v1\.8\.0 h1:[^\n]+',
      multiLine: true,
    ).firstMatch(original);
    expect(line, isNotNull);
    sum.writeAsStringSync(
      original.replaceRange(
        line!.start,
        line.end,
        'github.com/hashicorp/go-plugin v1.8.0 h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      ),
    );
    final result = await _runTier(repo);
    expect(result.exitCode, isNot(0));
    expect('${result.stdout}${result.stderr}', contains('plugins'));
    expect(
      '${result.stdout}${result.stderr}'.toLowerCase(),
      contains('checksum'),
    );
    expect(
      File('${repo.path}/correlia_server/build_sentinel_ran').existsSync(),
      isFalse,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
