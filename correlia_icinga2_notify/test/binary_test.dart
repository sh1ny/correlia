@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

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
}
