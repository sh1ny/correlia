import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:test/test.dart';

const source = '11111111-1111-4111-8111-111111111111';
final now = DateTime.utc(2026, 11, 18);
final material = {
  for (var i = 1; i <= 5; i++)
    'key$i': base64Url.encode(List<int>.filled(32, i)).substring(0, 43),
};

Map<String, Object?> credential(int i, {String? before, String? after}) => {
  'type': 'bearer',
  'ref': 'key$i',
  'not_before': ?before,
  'not_after': ?after,
};

IngestBootstrap parse({
  Map<String, Object?> fields = const {},
  List<String>? namespaces,
}) => IngestBootstrap.parse(
  {
    'format_version': 2,
    'revision': 1,
    'namespaces': ?namespaces,
    'sources': [
      {
        'id': source,
        'enabled': true,
        'kind': 'alertmanager',
        'credentials': [credential(1)],
        'output_ids': <String>[],
        ...fields,
      },
    ],
    'outputs': <Object?>[],
  },
  material,
  runMode: 'test',
  clock: () => now,
);

Matcher field(String path) =>
    throwsA(isA<BootstrapError>().having((e) => e.field, 'field', path));

void main() {
  test('webhook_mode_by_default', () {
    final webhook = parse(fields: {'kind': 'icinga2'}).sources.single;
    expect(webhook.toJson(), isNot(contains('api')));
    expect(webhook.credentials.single.reference, 'key1');
    expect(webhook.rateLimit!.burst, 40);
  });

  test('mode_on_another_kind_or_unknown_mode', () {
    expect(
      () => parse(fields: {'mode': 'event_streams'}),
      field('sources[0].mode'),
    );
    expect(
      () => parse(fields: {'kind': 'icinga2', 'mode': 'poll'}),
      field('sources[0].mode'),
    );
  });

  test('existing_snapshot_republished_after_the_upgrade', () {
    const previousSnapshot =
        '9609c9e2f4cffe145a2d4bba19ffdd2d7b153d6b4cf7542d97f5a204cea0e92e';
    expect(parse(fields: {'kind': 'icinga2'}).snapshotId, previousSnapshot);
    expect(
      parse(fields: {'kind': 'icinga2', 'mode': 'webhook'}).snapshotId,
      previousSnapshot,
    );
  });

  test('unsupported_kind_or_field', () {
    expect(() => parse(fields: {'kind': 'zabbix'}), field('sources[0].kind'));
    expect(() => parse(fields: {'foreign': true}), field('sources[0].foreign'));
  });

  test('thanos_source_kind', () {
    expect(
      () => parse(fields: {'kind': 'thanos'}),
      field('sources[0].kind'),
    );
  });

  test('icinga2_source_declares_a_path_token', () {
    expect(
      parse(fields: {'kind': 'icinga2'}).sources.single.toJson()['kind'],
      'icinga2',
    );
    expect(
      () => parse(fields: {'kind': 'icinga2', 'path_token_enabled': true}),
      field('sources[0].path_token_enabled'),
    );
    expect(
      parse(
        fields: {'kind': 'alertmanager', 'path_token_enabled': true},
      ).sources.single.pathTokenEnabled,
      isTrue,
    );
  });

  test('icinga2_source_declares_excluded_identity_labels', () {
    expect(
      () => parse(
        fields: {
          'kind': 'icinga2',
          'excluded_identity_labels': ['service'],
        },
      ),
      field('sources[0].excluded_identity_labels'),
    );
    expect(
      parse(
        fields: {
          'kind': 'alertmanager',
          'excluded_identity_labels': ['service'],
        },
      ).sources.single.excludedIdentityLabels,
      {'service'},
    );
  });

  test('activation_without_a_usable_credential', () {
    for (final invalid in [
      [for (var i = 1; i <= 5; i++) credential(i)],
      [credential(1), credential(1)],
      [credential(1, after: '2026-11-17T00:00:00Z')],
      [
        credential(
          1,
          before: '2026-11-20T00:00:00Z',
          after: '2026-11-20T00:00:00Z',
        ),
      ],
    ]) {
      expect(
        () => parse(fields: {'credentials': invalid}),
        throwsA(isA<BootstrapError>()),
      );
    }
    expect(
      parse(
        fields: {
          'credentials': [credential(1, before: '2026-11-19T00:00:00Z')],
        },
      ).sources.single.credentials.single.notBefore,
      DateTime.utc(2026, 11, 19),
    );
  });

  test('undeclared_or_uuid_shaped_namespace', () {
    expect(
      () => parse(fields: {'namespace': 'shared'}),
      field('sources[0].namespace'),
    );
    expect(() => parse(namespaces: [source]), field('namespaces[0]'));
    expect(parse().sources.single.namespace, source);
    expect(
      parse(
        fields: {'namespace': 'shared'},
        namespaces: ['shared'],
      ).sources.single.namespace,
      'shared',
    );
  });

  test(
    'v1 maps to one bearer credential and preserves its legacy namespace',
    () {
      final legacy = IngestBootstrap.parse(
        {
          'format_version': 1,
          'revision': 1,
          'outputs': <Object?>[],
          'sources': [
            {
              'id': source,
              'enabled': true,
              'token_ref': 'key1',
              'namespace': 'legacy',
              'output_ids': <String>[],
            },
          ],
        },
        material,
        runMode: 'test',
      );
      final mapped = legacy.sources.single;
      expect(mapped.kind.name, 'alertmanager');
      expect(mapped.namespace, 'legacy');
      expect(mapped.credentials.single.type.name, 'bearer');
      expect(mapped.credentials.single.reference, 'key1');
      expect(mapped.rateLimit!.perSecond, 20);
      expect(mapped.rateLimit!.burst, 40);
      final snapshot = jsonDecode(legacy.publicJson) as Map<String, Object?>;
      expect(snapshot['format_version'], 2);
      expect(legacy.publicJson, isNot(contains(material['key1']!)));
    },
  );

  test('rate limits accept endpoints and reject out-of-range parameters', () {
    final rate = parse(
      fields: {
        'rate_limit': {'per_second': 1000, 'burst': 10000},
      },
    ).sources.single.rateLimit!;
    expect((rate.perSecond, rate.burst), (1000, 10000));
    for (final (perSecond, burst, path) in [
      (0, 1, 'per_second'),
      (1001, 1, 'per_second'),
      (1, 0, 'burst'),
      (1, 10001, 'burst'),
    ]) {
      expect(
        () => parse(
          fields: {
            'rate_limit': {'per_second': perSecond, 'burst': burst},
          },
        ),
        field('sources[0].rate_limit.$path'),
      );
    }
  });
}
