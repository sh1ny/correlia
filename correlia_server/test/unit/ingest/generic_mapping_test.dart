import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:test/test.dart';

import '../../support/generic_webhook_fixture.dart';

IngestBootstrap _parse(List<Object?> mappings) => IngestBootstrap.parse(
  {
    'format_version': 2,
    'revision': 7,
    'mappings': mappings,
    'sources': <Object?>[],
    'outputs': <Object?>[],
  },
  const <String, Object?>{},
  runMode: 'test',
);

Matcher _error(String field, [String? code]) {
  final match = isA<BootstrapError>().having((e) => e.field, 'field', field);
  return throwsA(
    code == null ? match : match.having((e) => e.code, 'code', code),
  );
}

List<Object?> _publicMappings(IngestBootstrap bootstrap) =>
    (jsonDecode(bootstrap.publicJson) as Map<String, Object?>)['mappings']!
        as List<Object?>;

void main() {
  test('runbook_covers_format_1_keys_and_its_example_activates', () {
    final text = File('../docs/runbooks/generic-webhook.md').readAsStringSync();
    final keys = RegExp(
      r'^\| `([a-z_]+)` \|',
      multiLine: true,
    ).allMatches(text).map((match) => match[1]!);
    expect(keys, unorderedEquals(GenericMapping.keys));
    final example = RegExp(r'```json\n([\s\S]*?)\n```').firstMatch(text)![1]!;
    final parsed = _parse(jsonDecode(example) as List<Object?>);
    expect(parsed.mappings.keys, ['checks']);
  });

  test('snapshot_without_mappings_keeps_its_bytes_and_id', () {
    const prior = '{"format_version":2,"revision":7,"sources":[],"outputs":[]}';
    const priorId =
        '4fbe3bfcfe5f5ae08cb528bbe7ebe1dcf63f955f22e45ab2af94b3bc78c207b7';
    final without = IngestBootstrap.parse(
      jsonDecode(prior),
      const <String, Object?>{},
      runMode: 'test',
    );
    for (final bootstrap in [without, _parse([])]) {
      expect(bootstrap.publicJson, prior);
      expect(bootstrap.snapshotId, priorId);
    }
  });

  test('unsupported_mapping_format', () {
    expect(
      () => _parse([
        {...checkMapping(), 'mapping_format': 2},
      ]),
      _error('mappings[0].mapping_format'),
    );
  });

  test('duplicate_mapping_name', () {
    expect(
      () => _parse([checkMapping(), checkMapping()]),
      _error('mappings[1].name'),
    );
  });

  test('invalid_pointer', () {
    for (final pointer in ['labels/host', '/labels/~2', '/labels/~']) {
      expect(
        () => _parse([
          {
            ...checkMapping(),
            'identity': {'host': pointer},
          },
        ]),
        _error('mappings[0].identity.host'),
      );
    }
  });

  test('postgres_unsafe_mapping_text_is_refused_before_activation', () {
    for (final (fields, path) in [
      (
        {
          'identity': {'host': '/labels/ho\u0000st'},
        },
        'identity.host',
      ),
      (
        {
          'summary': {'constant': 'not\u0000text'},
        },
        'summary',
      ),
      (
        {
          'status': {
            'pointer': '/state',
            'values': {'PRO\u0000BLEM': 'firing'},
          },
        },
        'status.values',
      ),
    ]) {
      expect(
        () => _parse([
          {...checkMapping(), ...fields},
        ]),
        _error('mappings[0].$path', 'invalid_text'),
      );
    }
  });

  test('mapping_with_a_source_time_only', () {
    final mapping = checkMapping();
    final bootstrap = _parse([mapping]);
    expect(_publicMappings(bootstrap).single, mapping);
  });

  test('rul_8_neither_observation_id_nor_source_time', () {
    expect(
      () => _parse([checkMapping()..remove('source_time')]),
      _error('mappings[0].source_time'),
    );
  });

  test('observation_id_without_a_source_time', () {
    expect(
      () => _parse([
        {...checkMapping()..remove('source_time'), 'observation_id': '/id'},
      ]),
      _error('mappings[0].source_time'),
    );
  });

  test('no_identity_field', () {
    for (final identity in [null, <String, Object?>{}]) {
      expect(
        () => _parse([
          {...checkMapping(), 'identity': identity, 'observation_id': '/id'},
        ]),
        _error('mappings[0].identity'),
      );
    }
  });

  test('empty_summary_constant', () {
    expect(
      () => _parse([
        {
          ...checkMapping(),
          'summary': {'constant': ''},
        },
      ]),
      _error('mappings[0].summary'),
    );
  });

  test('mapping_without_a_summary', () {
    expect(
      () => _parse([checkMapping()..remove('summary')]),
      _error('mappings[0].summary'),
    );
  });

  test('mappings_are_canonical_and_sorted', () {
    final a = checkMapping(name: 'a');
    final b = checkMapping(name: 'b');
    final first = _parse([b, a]);
    final reordered = _parse([
      Map.fromEntries(a.entries.toList().reversed),
      b,
    ]);
    expect(_publicMappings(first), [a, b]);
    expect(first.publicJson, reordered.publicJson);
    expect(first.snapshotId, reordered.snapshotId);
    expect(first.withoutImport().publicJson, first.publicJson);
  });

  test('mapping_count_limit', () {
    final mappings = [for (var i = 0; i < 64; i++) checkMapping(name: 'm-$i')];
    expect(_publicMappings(_parse(mappings)), hasLength(64));
    expect(() => _parse([...mappings, checkMapping()]), _error('mappings'));
  });

  test('mapping_and_serialized_mappings_byte_limits', () {
    Map<String, Object?> large(String name, int count, int bytes) => {
      ...checkMapping(name: name),
      'labels': {
        for (var i = 0; i < count; i++) 'z$i': {'constant': 'é' * (bytes ~/ 2)},
      },
    };
    final near = large('one', 30, 1024);
    expect(
      _publicMappings(_parse([near, large('two', 30, 1024)])),
      hasLength(2),
    );
    expect(() => _parse([large('one', 32, 1024)]), _error('mappings[0]'));
    expect(
      () => _parse([near, large('two', 30, 1024), large('three', 30, 1024)]),
      _error('mappings', 'mappings_bound'),
    );
  });

  test('mapping_named_fields_bounds', () {
    for (final (field, limit, value) in [
      ('identity', 128, '/host'),
      ('labels', 128, const {'copy': '/value'}),
      ('links', 16, const {'copy': '/runbook'}),
    ]) {
      final fields = {for (var i = 0; i < limit; i++) 'k$i': value};
      expect(
        _publicMappings(
          _parse([
            {...checkMapping(), field: fields},
          ]),
        ),
        hasLength(1),
      );
      expect(
        () => _parse([
          {
            ...checkMapping(),
            field: {...fields, 'overflow': value},
          },
        ]),
        _error('mappings[0].$field'),
      );
    }
  });

  test('mapping_value_table_and_pointer_byte_bounds', () {
    final values = {
      for (var i = 0; i < 255; i++) '$i': 'firing',
      'é' * 128: 'resolved',
    };
    final pointer = '/a${'é' * 255}';
    Map<String, Object?> withStatus(Map<String, String> values) => {
      ...checkMapping(),
      'status': {'pointer': pointer, 'values': values},
    };
    expect(_publicMappings(_parse([withStatus(values)])), hasLength(1));
    expect(
      () => _parse([
        withStatus({...values, 'overflow': 'info'}),
      ]),
      _error('mappings[0].status.values'),
    );
    expect(
      () => _parse([
        withStatus({'x${'é' * 128}': 'info'}),
      ]),
      _error('mappings[0].status.values'),
    );
    expect(
      () => _parse([
        {...checkMapping(), 'items': '$pointer!'},
      ]),
      _error('mappings[0].items'),
    );
  });

  test('out_of_contract_constants_and_enum_outputs', () {
    for (final (key, value, path) in [
      ('description', {'constant': 'x' * 4097}, 'description'),
      (
        'links',
        {
          'runbook': {'constant': 'javascript:bad'},
        },
        'links.runbook',
      ),
      (
        'status',
        {
          'pointer': '/state',
          'values': {'OK': 'closed'},
        },
        'status.values',
      ),
      ('severity', {'constant': 'emergency'}, 'severity.constant'),
      (
        'severity',
        {
          'pointer': '/severity',
          'values': {'0': 'info'},
          'default': 'panic',
        },
        'severity.default',
      ),
    ]) {
      expect(
        () => _parse([
          {...checkMapping(), key: value},
        ]),
        _error('mappings[0].$path'),
      );
    }
  });
}
