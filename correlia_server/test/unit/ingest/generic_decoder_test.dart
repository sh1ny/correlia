import 'dart:convert';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/generic_decoder.dart';
import 'package:correlia_server/src/ingest/source_decoder.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../support/generic_webhook_fixture.dart';

const _time = '2026-11-24T05:20:00Z';
const _uuid = '11111111-1111-4111-8111-111111111111';

Map<String, Object?> _alert([String host = 'api']) => {
  'host': host,
  'time': _time,
  'state': 'PROBLEM',
  'summary': 'Unavailable',
};

DecodeRequest _request(String body) {
  final bytes = utf8.encode(body);
  return DecodeRequest(
    bytes: bytes,
    sourceInstance: _uuid,
    namespace: _uuid,
    excludedLabels: const [],
    rawRef: 'raw:2026-11-24T05:21:00.000Z/$_uuid',
    rawSha256: sha256.convert(bytes).toString(),
    observedAt: EventTimestamp.parse('2026-11-24T05:21:00Z'),
    processedAt: EventTimestamp.parse('2026-11-24T05:21:01Z'),
    configVersion: 'revision',
  );
}

DecodedBatch _decode(
  Object? payload, [
  Map<String, Object?> fields = const {},
]) => decodeGeneric(
  _request(jsonEncode(payload)),
  GenericMapping.parse({...checkMapping(), ...fields}),
);

Matcher _error(String code, List<String> tokens) => throwsA(
  isA<EventPointerError>()
      .having((error) => error.code, 'code', code)
      .having(
        (error) => error.segments.map((part) => part.token),
        'tokens',
        tokens,
      ),
);

void main() {
  test('key_containing_dots_and_slashes', () {
    final event = _decode(
      {
        ..._alert()..remove('host'),
        'labels': {'kubernetes.io/name': 'api', '~rack': 'r1'},
      },
      {
        'identity': {
          'host': '/labels/kubernetes.io~1name',
          'rack': '/labels/~0rack',
        },
      },
    ).events.single;
    expect(event.identityFields['host']!.raw, 'api');
    expect(event.identityFields['rack']!.raw, 'r1');
  });

  test('duplicate_member_name', () {
    final payload = jsonEncode({..._alert()..remove('host')});
    final wire =
        '{"labels":{"host":"a","h\\u006fst":"b"},${payload.substring(1)}';
    final mapping = GenericMapping.parse({
      ...checkMapping(),
      'identity': {'host': '/labels/host'},
    });
    expect(
      () => decodeGeneric(_request(wire), mapping),
      _error('duplicate_field', ['labels', 'host']),
    );
    final preview = previewGeneric(_request(wire), mapping);
    expect(preview.events, isEmpty);
    expect(preview.diagnostics.single.path, '/labels/host');
    expect(preview.diagnostics.single.code, 'duplicate_field');
  });

  test('three_alerts_in_one_delivery', () {
    final batch = _decode(
      {
        'items': [_alert('a'), _alert('b'), _alert('c')],
      },
      {'items': '/items'},
    );
    expect(batch.events, hasLength(3));
    expect(batch.events.map((e) => e.fingerprint).toSet(), hasLength(3));
  });

  test('more_than_1000_items', () {
    expect(
      () => _decode(List.filled(1001, _alert()), {'items': ''}),
      _error('items_bound', []),
    );
  });

  test('items_pointer_selects_an_object', () {
    expect(
      () => _decode({'items': _alert()}, {'items': '/items'}),
      _error('invalid_type', ['items']),
    );
  });

  test('copies_that_expand_past_the_decode_budget', () {
    final payload = [
      ...List.filled(899, {..._alert(), 'copy': '\u0000' * 150}),
      {'host': false}, // Must not reach this alert after the budget is spent.
    ];
    expect(
      () => _decode(payload, {
        'items': '',
        'labels': {
          for (var i = 0; i < 128; i++) 'k$i': {'copy': '/copy'},
        },
      }),
      _error('decode_bound', []),
    );
  });

  test('id_6_re_batched_generic_alerts', () {
    final a = _alert('a');
    final b = _alert('b');
    final first = _decode([a, b], {'items': ''}).events;
    final singles = [_decode(b).events.single, _decode(a).events.single];
    expect(
      singles.map((e) => (e.fingerprint, e.eventId)),
      first.reversed.map((e) => (e.fingerprint, e.eventId)),
    );
  });

  test('missing_identity_value', () {
    expect(
      () => _decode(_alert()..remove('host')),
      _error('required', ['host']),
    );
  });

  test('identity_value_that_is_not_a_string', () {
    expect(
      () => _decode({..._alert(), 'host': 1}),
      _error('identity_type', ['host']),
    );
  });

  test('observation_id_absent_in_one_alert', () {
    expect(
      () => _decode(
        [
          {..._alert(), 'changeId': 'one'},
          _alert('b'),
        ],
        {'items': '', 'observation_id': '/changeId'},
      ),
      _error('required', ['1', 'changeId']),
    );
  });

  test('mapped_status_and_severity', () {
    final event = _decode(
      {..._alert(), 'state': 'OK', 'level': 2},
      {
        'severity': {
          'pointer': '/level',
          'values': {'2': 'critical'},
        },
      },
    ).events.single;
    expect(event.status, EventStatus.resolved);
    expect(event.severity, EventSeverity.critical);
  });

  test('unlisted_value_with_a_default', () {
    final event = _decode(
      {..._alert(), 'level': 'OTHER'},
      {
        'severity': {
          'pointer': '/level',
          'values': {'CRIT': 'critical'},
          'default': 'warning',
        },
      },
    ).events.single;
    expect(event.severity, EventSeverity.warning);
  });

  test('status_value_absent', () {
    expect(
      () => _decode(_alert()..remove('state'), {
        'status': {
          'pointer': '/state',
          'values': <String, Object?>{},
          'default': 'info',
        },
      }),
      _error('required', ['state']),
    );
  });

  test('unlisted_value_without_a_default', () {
    expect(
      () => _decode({..._alert(), 'state': 'other'}),
      _error('unlisted_value', ['state']),
    );
  });

  test('epoch_milliseconds', () {
    final event = _decode(
      {..._alert(), 'time': 1795497600123},
      {
        'source_time': {'pointer': '/time', 'format': 'epoch_millis'},
      },
    ).events.single;
    expect(event.reportedSourceTime, '2026-11-24T05:20:00.123Z');
    expect(event.sourceTime, EventTimestamp.parse('2026-11-24T05:20:00.123Z'));
    final changedDisplay = _decode(
      {..._alert(), 'time': 1795497600123, 'summary': 'changed'},
      {
        'source_time': {'pointer': '/time', 'format': 'epoch_millis'},
      },
    ).events.single;
    expect(changedDisplay.eventId, event.eventId);
  });

  test('fractional_exponent_or_negative_epoch_value', () {
    final mapping = GenericMapping.parse({
      ...checkMapping(),
      'source_time': {'pointer': '/time', 'format': 'epoch_seconds'},
    });
    for (final number in ['1795497600.5', '1.7954976e9', '-1']) {
      final wire = jsonEncode(_alert()).replaceFirst('"$_time"', number);
      expect(
        () => decodeGeneric(_request(wire), mapping),
        _error('invalid_timestamp', ['time']),
      );
    }
  });

  for (final (name, format, bound, expected) in [
    (
      'epoch_range_boundary',
      'epoch_millis',
      253402300799999,
      '9999-12-31T23:59:59.999Z',
    ),
    (
      'epoch_seconds_range_boundary',
      'epoch_seconds',
      253402300799,
      '9999-12-31T23:59:59Z',
    ),
  ]) {
    test(name, () {
      final fields = {
        'source_time': {'pointer': '/time', 'format': format},
      };
      expect(
        _decode({
          ..._alert(),
          'time': bound,
        }, fields).events.single.reportedSourceTime,
        expected,
      );
      expect(
        () => _decode({..._alert(), 'time': bound + 1}, fields),
        _error('invalid_timestamp', ['time']),
      );
    });
  }

  test('rfc_3339_without_an_offset', () {
    expect(
      () => _decode({..._alert(), 'time': '2026-11-24T05:20:00'}),
      _error('invalid_timestamp', ['time']),
    );
  });

  test('nul_in_copied_label_and_description_is_preserved', () {
    const text = 'before\u0000after';
    final event = _decode(
      {..._alert(), 'output': text},
      {
        'description': {'copy': '/output'},
        'labels': {
          'output': {'copy': '/output'},
        },
      },
    ).events.single;
    expect(event.description, text);
    expect(event.labels['output'], text);
  });

  test('copied_and_constant_display_fields', () {
    final event = _decode(
      {
        ..._alert(),
        'check': {'output': '  chars\n"quoted"  '},
      },
      {
        'description': {'copy': '/check/output'},
        'labels': {
          'team': {'constant': 'ops'},
        },
      },
    ).events.single;
    expect(event.description, '  chars\n"quoted"  ');
    expect(event.labels, {'team': 'ops'});
  });

  test('id_3_long_display_text', () {
    final fields = {
      'description': {'copy': '/description'},
    };
    final longText = _decode({
      ..._alert(),
      'description': '🚨' * 5000,
    }, fields).events.single;
    final short = _decode({
      ..._alert(),
      'description': 'short',
    }, fields).events.single;
    expect(longText.description, '${'🚨' * 4095}…');
    expect(longText.fingerprint, short.fingerprint);
  });

  test('null_and_absent_optional_fields', () {
    final fields = {
      'labels': {
        'env': {'copy': '/env'},
      },
    };
    for (final sender in [
      {..._alert(), 'summary': 42},
      {..._alert(), 'summary': 42, 'env': null},
    ]) {
      final event = _decode(sender, fields).events.single;
      expect(event.summary, '42');
      expect(event.labels, isEmpty);
    }
  });

  test('null_summary', () {
    expect(
      () => _decode({..._alert(), 'summary': null}),
      _error('required', ['summary']),
    );
  });

  test('link_that_is_not_a_url', () {
    expect(
      () => _decode(
        {..._alert(), 'runbook': 'see wiki'},
        {
          'links': {
            'check': {'copy': '/runbook'},
          },
        },
      ),
      _error('invalid_format', ['runbook']),
    );
  });

  test('object_copied_into_a_display_field', () {
    expect(
      () => _decode({
        ..._alert(),
        'summary': {'secret': true},
      }),
      _error('invalid_type', ['summary']),
    );
  });

  test('extra_field_rejected_by_default', () {
    expect(
      () => _decode({..._alert(), 'token': 'unknown'}),
      _error('unmapped_field', ['token']),
    );
  });

  test('metadata_beside_the_items_array', () {
    final batch = _decode(
      {
        'data': {
          'results': [_alert()],
          'page': 1,
        },
      },
      {
        'items': '/data/results',
        'unmapped_fields': 'count',
      },
    );
    expect(batch.events, hasLength(1));
    expect(batch.unmappedFields, 1);
  });

  test('extra_fields_counted', () {
    final batch = _decode(
      {..._alert(), 'a': 1, 'b': <String, Object?>{}},
      {'unmapped_fields': 'count'},
    );
    expect(batch.events, hasLength(1));
    expect(batch.unmappedFields, 2);
  });
}
