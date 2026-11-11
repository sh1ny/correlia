import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File config;
  late File secrets;
  Map<String, String> environment() => {
    'CORRELIA_INGEST_CONFIG': config.path,
    'CORRELIA_INGEST_SECRETS': secrets.path,
  };
  setUp(() async {
    root = await Directory.systemTemp.createTemp('correlia-ingest-bootstrap-');
    config = File('${root.path}/config.json');
    secrets = File('${root.path}/secrets.json');
    await config.writeAsString(
      jsonEncode({
        'format_version': 1,
        'revision': 1,
        'sources': <Object?>[],
        'outputs': <Object?>[],
      }),
    );
    await secrets.writeAsString('{}');
    final result = await Process.run('/usr/bin/chmod', ['600', secrets.path]);
    expect(result.exitCode, 0);
  });
  tearDown(() => root.delete(recursive: true));

  test('requires paired files without reflecting paths', () async {
    expect(await IngestBootstrap.load({}, runMode: 'test'), isNull);
    await expectLater(
      IngestBootstrap.load({
        'CORRELIA_INGEST_CONFIG': '/canary-secret-path',
      }, runMode: 'test'),
      throwsA(
        isA<BootstrapError>().having(
          (e) => e.toString(),
          'sanitized',
          isNot(contains('canary')),
        ),
      ),
    );
  });
  test('rejects world-readable secrets and accepts owner-only file', () async {
    expect(
      (await IngestBootstrap.load(environment(), runMode: 'test'))!.revision,
      1,
    );
    await Process.run('/usr/bin/chmod', ['644', secrets.path]);
    await expectLater(
      IngestBootstrap.load(environment(), runMode: 'test'),
      throwsA(
        isA<BootstrapError>().having((e) => e.code, 'code', 'permissions'),
      ),
    );
  });
  test(
    'rejects oversized files before parsing and never echoes bytes',
    () async {
      await secrets.writeAsString('canary-secret' * 6000);
      await expectLater(
        IngestBootstrap.load(environment(), runMode: 'test'),
        throwsA(
          isA<BootstrapError>()
              .having((e) => e.code, 'code', 'bound')
              .having(
                (e) => e.toString(),
                'sanitized',
                isNot(contains('canary')),
              ),
        ),
      );
    },
  );
  test('sanitizes malformed secret JSON and URI parser errors', () async {
    await secrets.writeAsString('{"private":"canary-secret",');
    await expectLater(
      IngestBootstrap.load(environment(), runMode: 'test'),
      throwsA(
        isA<BootstrapError>().having(
          (e) => e.toString(),
          'sanitized',
          allOf(isNot(contains('canary')), isNot(contains(root.path))),
        ),
      ),
    );
  });
  test('rejects symlink secret input rather than following it', () async {
    final link = Link('${root.path}/secret-link');
    await link.create(secrets.path);
    await expectLater(
      IngestBootstrap.load({
        ...environment(),
        'CORRELIA_INGEST_SECRETS': link.path,
      }, runMode: 'test'),
      throwsA(
        isA<BootstrapError>().having((e) => e.code, 'code', 'regular_file'),
      ),
    );
  });
}
