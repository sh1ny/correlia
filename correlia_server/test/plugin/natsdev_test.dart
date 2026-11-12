import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/plugin_process_identity.dart';

void main() {
  const driver = 'test/plugin/support/natsdev_test_driver.dart';

  test('test_owned_server', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      driver,
      'owned',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final output = jsonDecode(result.stdout as String) as Map<String, Object?>;
    final uri = Uri.parse(output['url']! as String);
    expect(uri.host, '127.0.0.1');
    expect(uri.port, greaterThan(0));
    expect(Directory(output['storage']! as String).existsSync(), isFalse);
    final identity = PluginProcessIdentity(
      pid: output['pid']! as int,
      startTime: output['startTime']! as int,
    );
    expect(identity.isLive, isFalse);
  }, tags: ['plugin']);

  test('server_fails_to_start', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      driver,
      'failure',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('NATS startup'));
  }, tags: ['plugin']);
}
