import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:test/test.dart';

import '../../support/generic_webhook_fixture.dart';

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

  test('accepts config-only input and never reflects paths', () async {
    expect(await IngestBootstrap.load({}, runMode: 'test'), isNull);
    expect(
      (await IngestBootstrap.load({
        'CORRELIA_INGEST_CONFIG': config.path,
      }, runMode: 'test'))!.revision,
      1,
    );
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
      await secrets.writeAsString('canary-secret' * 41000);
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
  test('mappings_over_the_file_cap', () async {
    await config.writeAsString(
      jsonEncode({
        'format_version': 2,
        'revision': 1,
        'sources': <Object?>[],
        'outputs': <Object?>[],
        'mappings': [
          for (var i = 0; i < 20; i++)
            {
              ...checkMapping(name: 'mapping-$i'),
              'description': {'constant': 'x' * 4096},
            },
        ],
      }),
    );
    await expectLater(
      IngestBootstrap.load(environment(), runMode: 'test'),
      throwsA(
        isA<BootstrapError>()
            .having((e) => e.fileKind, 'file kind', 'config')
            .having((e) => e.code, 'code', 'bound'),
      ),
    );
  });
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
  test('secret_file_sizes', () async {
    final encoded = base64Url
        .encode(List<int>.filled(16384, 7))
        .replaceAll('=', '');
    await secrets.writeAsString(
      jsonEncode({
        for (var i = 0; i < 15; i++) 'secret-$i': {'bytes': encoded},
      }),
    );
    expect((await secrets.length()), greaterThan(300 * 1024));
    expect(
      (await IngestBootstrap.load(environment(), runMode: 'test'))!.revision,
      1,
    );

    await secrets.writeAsString(
      jsonEncode({
        for (var i = 0; i < 17; i++) 'secret-$i': {'bytes': encoded},
      }),
    );
    await expectLater(
      IngestBootstrap.load(environment(), runMode: 'test'),
      throwsA(isA<BootstrapError>().having((e) => e.code, 'code', 'bound')),
    );
    await secrets.writeAsString(' ' * (512 * 1024 + 1));
    await expectLater(
      IngestBootstrap.load(environment(), runMode: 'test'),
      throwsA(isA<BootstrapError>().having((e) => e.code, 'code', 'bound')),
    );
    await config.writeAsString(' ' * (64 * 1024 + 1));
    await expectLater(
      IngestBootstrap.load(environment(), runMode: 'test'),
      throwsA(isA<BootstrapError>().having((e) => e.code, 'code', 'bound')),
    );
  });
  test(
    'plugin directory is required only for workers and must be safe',
    () async {
      await config.writeAsString(
        jsonEncode({
          'format_version': 1,
          'revision': 1,
          'sources': <Object?>[],
          'outputs': [
            {
              'id': '22222222-2222-4222-8222-222222222222',
              'kind': 'plugin',
              'plugin': 'output-nats',
              'sha256': 'a' * 64,
              'config': <String, Object?>{},
              'secret_refs': <String, Object?>{},
            },
          ],
        }),
      );
      expect(
        await IngestBootstrap.load(
          environment(),
          runMode: 'test',
          requirePluginDirectory: false,
        ),
        isNotNull,
      );
      await expectLater(
        IngestBootstrap.load(environment(), runMode: 'test'),
        throwsA(
          isA<BootstrapError>().having(
            (e) => e.field,
            'field',
            'CORRELIA_PLUGIN_DIR',
          ),
        ),
      );
      final directory = await Directory('${root.path}/plugins').create();
      final safe = await Process.run('/usr/bin/chmod', ['700', directory.path]);
      expect(safe.exitCode, 0);
      final env = {...environment(), 'CORRELIA_PLUGIN_DIR': directory.path};
      expect(await IngestBootstrap.load(env, runMode: 'test'), isNotNull);
      final result = await Process.run('/usr/bin/chmod', [
        '777',
        directory.path,
      ]);
      expect(result.exitCode, 0);
      await expectLater(
        IngestBootstrap.load(env, runMode: 'test'),
        throwsA(
          isA<BootstrapError>().having((e) => e.code, 'code', 'permissions'),
        ),
      );
    },
  );
}
