import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:test/test.dart';

void main() {
  final token = base64Url.encode(List<int>.filled(32, 7)).replaceAll('=', '');
  const sourceId = '11111111-1111-4111-8111-111111111111';
  const outputId = '22222222-2222-4222-8222-222222222222';
  Map<String, Object?> config() => {
    'format_version': 1,
    'revision': 1,
    'sources': [
      {
        'id': sourceId,
        'enabled': true,
        'token_ref': 'source-v1',
        'output_ids': [outputId],
      },
    ],
    'outputs': [
      {
        'id': outputId,
        'kind': 'webhook',
        'url': 'http://127.0.0.1:9099/events',
        'signing_key_ref': 'output-v1',
      },
    ],
  };
  Map<String, Object?> secrets() => {'source-v1': token, 'output-v1': token};

  test('public snapshot contains digests but no credential bytes', () {
    final input = IngestBootstrap.parse(config(), secrets(), runMode: 'test');
    expect(input.sources.single.id, sourceId);
    expect(input.sources.single.namespace, sourceId);
    expect(input.publicJson, isNot(contains(token)));
    expect(input.snapshotId, matches(RegExp(r'^[a-f0-9]{64}$')));
    final reordered = config();
    expect(
      IngestBootstrap.parse(reordered, secrets(), runMode: 'test').snapshotId,
      input.snapshotId,
    );
    reordered['revision'] = 2;
    expect(
      IngestBootstrap.parse(reordered, secrets(), runMode: 'test').snapshotId,
      isNot(input.snapshotId),
    );
  });
  test('rejects missing outputs even with an empty registry', () {
    final input = config()..['outputs'] = <Object?>[];
    expect(
      () => IngestBootstrap.parse(input, secrets(), runMode: 'test'),
      throwsA(isA<BootstrapError>()),
    );
  });
  test('rejects noncanonical credential encodings', () {
    for (final invalid in [
      '$token=',
      token.substring(1),
      '${token.substring(0, 42)}+',
      '${token.substring(0, 42)}/',
      '${token.substring(0, 42)}B',
    ]) {
      expect(
        () => IngestBootstrap.parse(
          config(),
          secrets()..['source-v1'] = invalid,
          runMode: 'test',
        ),
        throwsA(isA<BootstrapError>()),
      );
    }
  });
  test('rejects unsafe URLs without reflecting input', () {
    for (final url in [
      'http://user:password@example.com/hooks?secret=canary',
      'https://example.com/hooks?secret=canary',
      'http://example.com/hooks',
      'https://example.com/#canary',
    ]) {
      final input = config();
      (input['outputs']! as List<Map<String, Object?>>).single['url'] = url;
      try {
        IngestBootstrap.parse(input, secrets(), runMode: 'production');
        fail('unsafe URL accepted');
      } on BootstrapError catch (error) {
        expect(error.toString(), isNot(contains('canary')));
        expect(error.toString(), isNot(contains('password')));
        expect(error.toString(), isNot(contains(url)));
      }
    }
  });
  test('rejects unknown fields and invalid revision bounds', () {
    for (final revision in [0, -1, 2147483648, 1.0, '1']) {
      expect(
        () => IngestBootstrap.parse(
          config()..['revision'] = revision,
          secrets(),
          runMode: 'test',
        ),
        throwsA(isA<BootstrapError>()),
      );
    }
    expect(
      () => IngestBootstrap.parse(
        config()..['extra'] = true,
        secrets(),
        runMode: 'test',
      ),
      throwsA(isA<BootstrapError>()),
    );
  });
  test('invalid_plugin_output', () {
    Map<String, Object?> plugin() => {
      'id': outputId,
      'kind': 'plugin',
      'plugin': 'output-nats',
      'sha256': 'a' * 64,
      'config': <String, Object?>{},
      'secret_refs': {'token': 'output-v1'},
    };
    for (final (field, value) in <(String, Object?)>[
      ('kind', 'unknown'),
      ('plugin', '../escape'),
      ('sha256', 'A' * 64),
      ('config', {'large': 'x' * 16384}),
      ('secret_refs', {'token': 'missing'}),
    ]) {
      final input = config()..['outputs'] = [plugin()..[field] = value];
      expect(
        () => IngestBootstrap.parse(input, secrets(), runMode: 'test'),
        throwsA(
          isA<BootstrapError>().having(
            (error) => error.field,
            'field',
            contains(field),
          ),
        ),
      );
    }
  });

  test('long_plugin_secret', () {
    final bytes = List<int>.generate(3072, (i) => i % 256);
    final encoded = base64Url.encode(bytes).replaceAll('=', '');
    final input = config()
      ..['outputs'] = [
        {
          'id': outputId,
          'kind': 'plugin',
          'plugin': 'output-nats',
          'sha256': 'a' * 64,
          'config': <String, Object?>{},
          'secret_refs': {'credentials': 'long'},
        },
      ];
    final values = secrets()..['long'] = {'bytes': encoded};
    final parsed = IngestBootstrap.parse(input, values, runMode: 'test');
    expect(parsed.secret('long'), orderedEquals(bytes));
    expect(parsed.publicJson, isNot(contains(encoded)));
    for (final ref in ['source-v1', 'output-v1']) {
      expect(
        () => IngestBootstrap.parse(
          config(),
          secrets()..[ref] = {'bytes': encoded},
          runMode: 'test',
        ),
        throwsA(isA<BootstrapError>()),
      );
    }
  });
}
