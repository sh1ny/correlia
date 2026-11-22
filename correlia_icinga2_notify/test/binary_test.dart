@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// Compiles the sender into [into] and returns the binary's path.
Future<String> _compile(Directory into) async {
  final output = '${into.path}/correlia-icinga2-notify';
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    'bin/main.dart',
    '-o',
    output,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  return output;
}

void main() {
  late Directory temp;
  late String binary;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('notify-binary');
    binary = await _compile(temp);
  });
  tearDownAll(() => temp.deleteSync(recursive: true));

  test('command_definition_without_env_i', () async {
    // The sender must stop before it opens a connection: count what reaches
    // this listener, then probe it so the count is settled (connections are
    // accepted in order, so an earlier one is counted before the probe).
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <int>[];
    listener.listen((client) {
      accepted.add(client.remotePort);
      client.destroy();
    });
    addTearDown(listener.close);

    final token = File('${temp.path}/token')..writeAsStringSync('t');
    expect((await Process.run('chmod', ['600', token.path])).exitCode, 0);
    String lit(String value) => jsonEncode(value);
    final process = await Process.run(
      binary,
      [
        '--base-url',
        lit('http://127.0.0.1:${listener.port}'),
        '--source',
        lit('0a1b2c3d-0000-4000-8000-0123456789ab'),
        '--token-file',
        lit(token.path),
        '--object-type',
        lit('host'),
        '--host',
        lit('db1'),
        '--state',
        lit('DOWN'),
        '--state-type',
        lit('HARD'),
        '--last-state-change',
        lit('1700000000.000001'),
        '--notification-type',
        lit('PROBLEM'),
        '--notification-time',
        lit('1700000001.000001'),
      ],
      // The single inert variable of the spec scenario; nothing else.
      environment: {'CORRELIA_PROBE': '1'},
      includeParentEnvironment: false,
    );
    expect(process.exitCode, 2);
    expect(process.stderr, 'environment\n');
    expect(process.stdout, isEmpty);

    final probe = await Socket.connect(
      InternetAddress.loopbackIPv4,
      listener.port,
    );
    while (!accepted.contains(probe.port)) {
      await Future<void>.delayed(Duration.zero);
    }
    probe.destroy();
    expect(accepted, hasLength(1), reason: 'only the probe connected');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('build_is_independent_of_the_checkout_path', () async {
    // The release task publishes a rebuild only when its hash is the one the
    // captures ran, so two checkouts at different paths must build the same
    // bytes. Each copy holds the sender package next to the workspace lock.
    final root = Directory.systemTemp.createTempSync('notify-checkouts');
    addTearDown(() => root.deleteSync(recursive: true));
    final hashes = <String>[];
    for (final checkout in ['one', 'another/place/deeper']) {
      final package = Directory(
        '${root.path}/$checkout/correlia_icinga2_notify',
      )..createSync(recursive: true);
      for (final entry in ['bin', 'lib', 'pubspec.yaml']) {
        final copied = await Process.run('cp', ['-R', entry, package.path]);
        expect(copied.exitCode, 0, reason: '${copied.stderr}');
      }
      File('../pubspec.lock').copySync('${package.parent.path}/pubspec.lock');
      final output = '${root.path}/$checkout.bin';
      final built = await Process.run('../tool/build_icinga2_notify.sh', [
        package.path,
        'x64',
        output,
      ]);
      expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');
      hashes.add(sha256.convert(File(output).readAsBytesSync()).toString());
    }
    expect(hashes[1], hashes[0]);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('failed_rebuild_leaves_no_earlier_publication', () async {
    // The installation guide calls the release directory qualified, so an
    // earlier publication must not outlive a rebuild that fails.
    final root = Directory.systemTemp.createTempSync('notify-release');
    addTearDown(() => root.deleteSync(recursive: true));
    final release = Directory('${root.path}/build/icinga2-notify/release');
    File('${release.path}/linux-x64/correlia-icinga2-notify')
      ..createSync(recursive: true)
      ..writeAsStringSync('an earlier build');
    // A sender package without its sources: the build refuses it.
    Directory('${root.path}/correlia_icinga2_notify').createSync();
    final run = await Process.run('../tool/release_icinga2_notify.sh', [
      root.path,
    ]);
    expect(run.exitCode, isNot(0), reason: '${run.stdout}${run.stderr}');
    expect(run.stderr, contains('not the sender package'));
    expect(release.existsSync(), isFalse);
  });
}
