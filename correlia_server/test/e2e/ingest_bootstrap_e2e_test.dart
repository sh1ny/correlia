@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/shared_cluster.dart';

void main() {
  test('malformed_secret_or_credential_bearing_input_is_not_echoed', () async {
    final serverDir = Directory.current;
    final database = await SharedClusterDatabase.create(serverDir);
    final files = await Directory.systemTemp.createTemp(
      'correlia-bootstrap-e2e-',
    );
    final children = <ChildServer>[];
    try {
      final config = File('${files.path}/config.json');
      final secrets = File('${files.path}/secrets.json');
      const canary = 'STARTUP_PRIVATE_CANARY';
      final token = base64Url
          .encode(List<int>.filled(32, 9))
          .replaceAll('=', '');
      for (final variant in [
        'malformed_json',
        'invalid_secret',
        'userinfo',
        'query',
      ]) {
        final outputs = <Object?>[];
        if (variant == 'userinfo' || variant == 'query') {
          outputs.add({
            'id': '22222222-2222-4222-8222-222222222222',
            'kind': 'webhook',
            'url': variant == 'userinfo'
                ? 'https://user:$canary@example.com/events'
                : 'https://example.com/events?secret=$canary',
            'signing_key_ref': 'key-v1',
          });
        }
        await config.writeAsString(
          jsonEncode({
            'format_version': 1,
            'revision': 1,
            'sources': <Object?>[],
            'outputs': outputs,
          }),
        );
        await secrets.writeAsString(switch (variant) {
          'malformed_json' => '{"key-v1":"$canary",',
          'invalid_secret' => jsonEncode({'key-v1': canary}),
          _ => jsonEncode({'key-v1': token}),
        });
        await Process.run('/usr/bin/chmod', ['600', secrets.path]);
        final child = await ChildServer.startOnSharedCluster(
          serverDir: serverDir,
          database: database,
          environment: {
            'CORRELIA_INGEST_CONFIG': config.path,
            'CORRELIA_INGEST_SECRETS': secrets.path,
          },
        );
        children.add(child);
        final result = await Future.any<int>([
          child.exitCode,
          child.waitUntilReady().then(
            (_) => -999,
            onError: (_) => child.exitCode,
          ),
        ]);
        expect(
          result,
          1,
          reason: '$variant must fail startup, not become ready',
        );
        expect(child.output, contains('ingest bootstrap'));
        expect(child.output, isNot(contains(canary)));
        expect(child.output, isNot(contains(token)));
        expect(child.output, isNot(contains('https://user:')));
      }
    } finally {
      await tearDownChildren(children);
      await database.drop();
      await files.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
