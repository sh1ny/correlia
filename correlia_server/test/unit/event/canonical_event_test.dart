import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:test/test.dart';

import 'fixture.dart';

Map<String, Object?> _payload() =>
    eventFixture()['data']! as Map<String, Object?>;

void main() {
  test('Complete event survives both representations', () {
    final payload = _payload()
      ..['severity_number'] = 13
      ..['severity_original'] = 'WARNING'
      ..['dedup_key'] = 'source-hint'
      ..['description'] = 'Detail 🦋'
      ..['resource'] = {'host.name': 'host-7'}
      ..['labels_origin'] = {'severity': 'source label'}
      ..['annotations'] = {'runbook': 'Check upstream'}
      ..['links'] = [
        {
          'href': 'https://example.org/runbook',
          'relation': 'runbook',
          'text': 'Help',
        },
      ]
      ..['ends_at'] = '0001-01-01T00:00:00Z'
      ..['observed_at'] = '2026-11-10T00:00:00.123456789Z';
    (payload['observer']! as Map<String, Object?>).addAll({
      'name': 'production',
      'version': '1.0',
    });
    (payload['pipeline']! as Map<String, Object?>).addAll({
      'stages_applied': ['decode', 'normalize'],
      'enrichment_errors': [
        {'stage': 'enrich', 'code': 'unavailable', 'message': 'Not reached'},
      ],
    });
    final event = CanonicalEvent.fromJson(payload);
    final jsonRoundtrip = CanonicalEvent.fromJson(event.toJson());
    final binaryRoundtrip = CanonicalEvent.fromBuffer(
      event.toBuffer(),
      sourceDataschema: 'urn:correlia:schema:event:1.0',
    );
    expect(jsonRoundtrip.toJson(), event.toJson());
    expect(binaryRoundtrip.toJson(), event.toJson());
    expect(event.observedAt.nanos, 123456789);
    expect(binaryRoundtrip.observedAt.nanos, 123456789);
    expect(event.toJson()['observed_at'], '2026-11-10T00:00:00.123456789Z');
    expect(event.toJson()['ends_at'], '0001-01-01T00:00:00Z');
    expect(event.eventId, '86fe3b73-ec2d-5dd3-b104-11f2ec79469c');
    expect(event.kind, EventKind.alert);
  });

  test('Present empty optional values survive both representations', () {
    final payload = _payload()
      ..['description'] = ''
      ..['dedup_key'] = ''
      ..['severity_original'] = ''
      ..['annotations'] = {'empty': ''}
      ..['extensions'] = {'example.org/empty': ''}
      ..['labels'] = {'empty': ''}
      ..['identity_fields'] = {
        'empty': {'raw': ''},
      }
      ..['fingerprint'] =
          '637da8a0af1e2d3a838d56316d14f8b178db6785f9c6baf2df9b1daa4b6617dc'
      ..['event_id'] = '7adbba8a-7fbe-5666-ac2e-90b33457dab7';
    (payload['observer']! as Map<String, Object?>).addAll({
      'name': '',
      'version': '',
    });
    final event = CanonicalEvent.fromJson(payload);
    expect(event.toJson()['description'], '');
    expect(event.labels['empty'], '');
    expect(CanonicalEvent.fromJson(event.toJson()).toJson(), event.toJson());
    expect(
      CanonicalEvent.fromBuffer(event.toBuffer()).toJson(),
      event.toJson(),
    );
  });

  test('Invalid enum or absent required metadata', () {
    for (final field in [
      'event_id',
      'fingerprint',
      'summary',
      'observed_at',
      'processed_at',
      'raw',
      'pipeline',
    ]) {
      final payload = _payload()..remove(field);
      expect(
        () => CanonicalEvent.fromJson(payload),
        throwsA(
          isA<EventFieldError>().having(
            (e) => e.path,
            'field',
            startsWith(field),
          ),
        ),
      );
    }
    for (final field in ['kind', 'status', 'severity']) {
      for (final value in <Object?>['UNRECOGNIZED', 1, null]) {
        expect(
          () => CanonicalEvent.fromJson(_payload()..[field] = value),
          throwsA(isA<EventFieldError>().having((e) => e.path, 'field', field)),
        );
      }
    }
    final observer = _payload();
    (observer['observer']! as Map<String, Object?>).remove('source_instance');
    expect(
      () => CanonicalEvent.fromJson(observer),
      throwsA(
        isA<EventFieldError>().having(
          (e) => e.path,
          'field',
          'observer.source_instance',
        ),
      ),
    );
  });

  test('Display truncation and long identity', () {
    final description = normalizeDisplayText('🦋' * 4097, maxScalars: 4096);
    expect(description.runes.length, 4096);
    expect(description.endsWith('…'), isTrue);
    expect(
      normalizeDisplayText(
        'first\r\nsecond',
        maxScalars: 256,
        singleLine: true,
      ),
      'first  second',
    );
    expect(IdentityComponent.fromText('x' * 1025).digest, isNotNull);
    final valid = CanonicalEvent.fromJson(
      _payload()..['description'] = description,
    );
    expect(valid.toJson()['description'], description);
    expect(
      () => CanonicalEvent.fromJson(_payload()..['summary'] = '🦋' * 257),
      throwsA(isA<EventFieldError>().having((e) => e.path, 'field', 'summary')),
    );
    expect(
      CanonicalEvent.fromJson(_payload()..['summary'] = '🦋' * 256).summary,
      '🦋' * 256,
    );
  });

  test('Collection or encoded size overflow', () {
    expect(
      () => CanonicalEvent.fromJson(
        _payload()..['labels'] = {for (var n = 0; n < 129; n++) 'k$n': 'v'},
      ),
      throwsA(isA<EventFieldError>().having((e) => e.path, 'field', 'labels')),
    );
    expect(
      () => CanonicalEvent.fromJson(
        _payload()..['annotations'] = {'note': 'x' * 1025},
      ),
      throwsA(
        isA<EventFieldError>().having(
          (e) => e.path,
          'field',
          'annotations.note',
        ),
      ),
    );
    final huge = _payload()
      ..['annotations'] = {for (var n = 0; n < 128; n++) 'k$n': '🦋' * 1024};
    expect(
      () => CanonicalEvent.fromJson(huge),
      throwsA(
        isA<EventFieldError>().having((e) => e.code, 'code', 'event_too_large'),
      ),
    );
    expect(
      () => CanonicalEvent.fromBuffer(Uint8List(262145)),
      throwsA(
        isA<EventFieldError>().having((e) => e.code, 'code', 'event_too_large'),
      ),
    );
  });

  test('Raw metadata is independent of the default ingress limit', () {
    for (final size in [1048577, 4294967295]) {
      final payload = _payload();
      (payload['raw']! as Map<String, Object?>)['size'] = size;
      final event = CanonicalEvent.fromJson(payload);
      expect((event.toJson()['raw']! as Map<String, Object?>)['size'], size);
      expect(
        CanonicalEvent.fromBuffer(event.toBuffer()).toJson(),
        event.toJson(),
      );
    }
    for (final size in <Object>[-1, 4294967296, '4294967295', 1.5]) {
      final payload = _payload();
      (payload['raw']! as Map<String, Object?>)['size'] = size;
      expect(
        () => CanonicalEvent.fromJson(payload),
        throwsA(
          isA<EventFieldError>().having((e) => e.path, 'field', 'raw.size'),
        ),
      );
    }
  });

  test('Newer binary minor omits its optional addition', () {
    final event = CanonicalEvent.fromJson(_payload());
    expect(
      CanonicalEvent.fromBuffer(
        event.toBuffer(),
        sourceDataschema: 'urn:correlia:schema:event:1.1',
      ).validationScope,
      ValidationScope.knownCoreOnly,
    );
  });

  test('Binary input has no provenance', () {
    final event = CanonicalEvent.fromBuffer(
      CanonicalEvent.fromJson(_payload()).toBuffer(),
    );
    expect(event.validationScope, ValidationScope.unknown);
    expect(event.toJson()['event_id'], '86fe3b73-ec2d-5dd3-b104-11f2ec79469c');
  });

  test('Supplied binary provenance is invalid', () {
    final bytes = CanonicalEvent.fromJson(_payload()).toBuffer();
    for (final schema in [
      '',
      'invalid',
      'urn:correlia:schema:event:2.0',
      'urn:correlia:schema:event:1.01',
    ]) {
      expect(
        () => CanonicalEvent.fromBuffer(bytes, sourceDataschema: schema),
        throwsA(
          isA<EventFieldError>().having(
            (e) => e.path,
            'field',
            'source_dataschema',
          ),
        ),
      );
    }
  });

  test('Valid source-kind token', () {
    expect(
      CanonicalEvent.fromJson(_payload()).source.sourceKind,
      'alertmanager',
    );
  });

  test('Valid substring does not validate the whole token', () {
    for (final token in ['Bad-Kind!alertmanager', 'alertmanager\n']) {
      final payload = _payload();
      (payload['observer']! as Map<String, Object?>)['source_kind'] = token;
      expect(
        () => CanonicalEvent.fromJson(payload),
        throwsA(
          isA<EventFieldError>().having(
            (e) => e.path,
            'field',
            'observer.source_kind',
          ),
        ),
      );
    }
  });

  test('Known keys, timestamps, identities and immutable aliases', () {
    final payload = _payload();
    final event = CanonicalEvent.fromJson(payload);
    (payload['labels']! as Map<String, Object?>)['severity'] = 'mutated';
    expect(event.labels['severity'], 'warning');
    expect(() => event.labels['severity'] = 'mutated', throwsUnsupportedError);
    final json = event.toJson();
    (json['labels']! as Map<String, Object?>)['severity'] = 'mutated';
    expect(event.toJson(), isNot(json));
    for (final replacement in [
      '2026-02-30T00:00:00Z',
      '2026-11-10T00:00:00',
      '2026-11-10T00:00:00+24:00',
    ]) {
      expect(
        () =>
            CanonicalEvent.fromJson(_payload()..['observed_at'] = replacement),
        throwsA(
          isA<EventFieldError>().having((e) => e.path, 'field', 'observed_at'),
        ),
      );
    }
    expect(
      () => CanonicalEvent.fromJson(_payload()..['eventId'] = 'alias'),
      throwsA(isA<EventFieldError>().having((e) => e.path, 'field', 'eventId')),
    );
    expect(
      () => CanonicalEvent.fromJson(_payload()..['fingerprint'] = '0' * 64),
      throwsA(
        isA<EventFieldError>().having((e) => e.path, 'field', 'fingerprint'),
      ),
    );
    final reported = _payload()
      ..['reported_source_time'] = '2026-11-10T01:00:00Z';
    expect(
      () => CanonicalEvent.fromJson(reported),
      throwsA(
        isA<EventFieldError>().having(
          (e) => e.path,
          'field',
          'reported_source_time',
        ),
      ),
    );
    final badLineage = _payload();
    (badLineage['pipeline']! as Map<String, Object?>)['generation'] = 1;
    expect(
      () => CanonicalEvent.fromJson(badLineage),
      throwsA(
        isA<EventFieldError>().having(
          (e) => e.path,
          'field',
          'pipeline.original_event_id',
        ),
      ),
    );
    final reprocessed = _payload()
      ..['event_id'] = '8e5f9d59-ab9d-503d-a931-9be2e90a75a8';
    (reprocessed['pipeline']! as Map<String, Object?>).addAll({
      'generation': 1,
      'original_event_id': '86fe3b73-ec2d-5dd3-b104-11f2ec79469c',
    });
    final reprocessedEvent = CanonicalEvent.fromJson(reprocessed);
    expect(reprocessedEvent.eventId, '8e5f9d59-ab9d-503d-a931-9be2e90a75a8');
    expect(
      (reprocessedEvent.toJson()['pipeline']!
          as Map<String, Object?>)['original_event_id'],
      '86fe3b73-ec2d-5dd3-b104-11f2ec79469c',
    );
    final badBytes = _payload()..['observation_key'] = base64Encode([0]);
    expect(
      () => CanonicalEvent.fromJson(badBytes),
      throwsA(
        isA<EventFieldError>().having(
          (e) => e.path,
          'field',
          'observation_key',
        ),
      ),
    );
  });
  test('Acceptance includes envelope overhead and immutable trace output', () {
    Map<String, Object?> largePayload() => _payload()
      ..['annotations'] = {for (var n = 0; n < 128; n++) 'a$n': 'x' * 1024}
      ..['resource'] = {for (var n = 0; n < 128; n++) 'r$n': 'x' * 980}
      ..['description'] = '';
    final input = largePayload();
    input['description'] =
        'x' * (262044 - utf8.encode(jsonEncode(input)).length);
    expect(
      () => CanonicalEvent.fromJson(input),
      throwsA(
        isA<EventFieldError>().having((e) => e.code, 'code', 'event_too_large'),
      ),
    );

    final nearCap = largePayload();
    final base = CanonicalEvent.fromJson(nearCap);
    final baseSize = CloudEvent(event: base).toJsonBytes().length;
    nearCap['description'] = 'x' * (262136 - baseSize);
    final accepted = CanonicalEvent.fromJson(nearCap);
    final envelope = CloudEvent(event: accepted);
    expect(() => envelope.toJsonBytes()[0] = 0, throwsUnsupportedError);
    const trace = '00-11111111111111111111111111111111-2222222222222222-01';
    expect(
      () => CloudEvent(event: accepted, traceparent: trace),
      throwsA(
        isA<EventFieldError>().having((e) => e.code, 'code', 'event_too_large'),
      ),
    );
  });

  test('Binary integer widths are checked before narrowing', () {
    List<int> varint(int value) {
      final bytes = <int>[];
      do {
        final byte = value & 0x7f;
        value >>= 7;
        bytes.add(value == 0 ? byte : byte | 0x80);
      } while (value != 0);
      return bytes;
    }

    List<int> field(int number, int value) => [
      ...varint(number << 3),
      ...varint(value),
    ];

    List<int> nested(int number, int child, int value) {
      final body = field(child, value);
      return [...varint((number << 3) | 2), ...varint(body.length), ...body];
    }

    final original = CanonicalEvent.fromJson(_payload()).toBuffer();
    final accepted = <String>[];
    for (final (name, wire) in [
      ('raw.size', nested(25, 3, 4294967296)),
      ('pipeline.generation', nested(26, 2, 4294967296)),
      ('kind', field(5, 4294967297)),
      ('status', field(6, 4294967297)),
      ('severity', field(7, 4294967299)),
      ('observed_at.nanos', nested(23, 2, 4294967297)),
    ]) {
      try {
        CanonicalEvent.fromBuffer(Uint8List.fromList([...original, ...wire]));
        accepted.add(name);
      } on EventFieldError catch (error) {
        expect(error.path, 'event', reason: name);
        expect(error.code, 'out_of_range', reason: name);
      }
    }
    expect(
      accepted,
      isEmpty,
      reason: 'No wire integer may wrap into a valid value',
    );
  });

  test('Malformed known protobuf fields fail with field errors', () {
    final original = CanonicalEvent.fromJson(_payload()).toBuffer();
    for (final (path, tag) in [
      ('kind', 0x28),
      ('status', 0x30),
      ('severity', 0x38),
    ]) {
      expect(
        () => CanonicalEvent.fromBuffer(
          Uint8List.fromList([...original, tag, 99]),
        ),
        throwsA(isA<EventFieldError>().having((e) => e.path, 'field', path)),
      );
    }
    // observed_at field23: Timestamp.nanos = 1000000000 (outside its domain).
    const invalidTime = [0xba, 0x01, 0x06, 0x10, 0x80, 0x94, 0xeb, 0xdc, 0x03];
    expect(
      () => CanonicalEvent.fromBuffer(
        Uint8List.fromList([...original, ...invalidTime]),
      ),
      throwsA(
        isA<EventFieldError>().having((e) => e.path, 'field', 'observed_at'),
      ),
    );
    // A summary string may not replacement-normalize malformed UTF-8.
    expect(
      () => CanonicalEvent.fromBuffer(
        Uint8List.fromList([...original, 0x5a, 0x01, 0xff]),
      ),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => CanonicalEvent.fromBuffer(Uint8List.fromList([255])),
      throwsA(isA<EventFieldError>()),
    );
  });
}
