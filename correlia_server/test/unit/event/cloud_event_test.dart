import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:test/test.dart';

import 'fixture.dart';

Uint8List _bytes(Map<String, Object?> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  test('Publish a canonical alert', () {
    final event = CanonicalEvent.fromJson(
      eventFixture()['data']! as Map<String, Object?>,
    );
    final envelope = CloudEvent(event: event);
    expect(envelope.mediaType, 'application/cloudevents+json');
    final decoded =
        jsonDecode(utf8.decode(envelope.toJsonBytes())) as Map<String, Object?>;
    expect(decoded['datacontenttype'], 'application/json');
    expect(decoded['type'], 'io.correlia.alert.v1');
    expect(decoded['data'], isA<Map<String, Object?>>());
    expect(decoded['id'], event.eventId);
    expect(decoded['subject'], event.fingerprint);
    expect(decoded['partitionkey'], event.fingerprint);
    expect(decoded['correliatenant'], 'default');
    expect(
      CloudEvent.decode(envelope.toJsonBytes()).event.toJson(),
      event.toJson(),
    );
    final payload = eventFixture()['data']! as Map<String, Object?>;
    payload.remove('source_time');
    payload.remove('reported_source_time');
    final noTime =
        jsonDecode(
              utf8.decode(
                CloudEvent(
                  event: CanonicalEvent.fromJson(payload),
                ).toJsonBytes(),
              ),
            )
            as Map<String, Object?>;
    expect(noTime.containsKey('time'), isFalse);
  });

  test('Conflicting or unsupported envelope', () {
    for (final entry in <String, Object?>{
      'subject': '0' * 64,
      'partitionkey': '0' * 64,
      'correliatenant': 'another',
      'id': '00000000-0000-5000-8000-000000000000',
      'source': 'urn:correlia:source:22222222-2222-4222-8222-222222222222',
      'type': 'io.correlia.state.v1',
      'specversion': '0.3',
      'datacontenttype': 'text/plain',
      'dataschema': 'urn:correlia:schema:event:2.0',
      'traceparent': '00-${'0' * 32}-${'1' * 16}-01',
      'time': '2026-11-11T00:00:00Z',
    }.entries) {
      expect(
        () => CloudEvent.decode(
          _bytes(eventFixture()..[entry.key] = entry.value),
        ),
        throwsA(isA<EventFieldError>()),
        reason: entry.key,
      );
    }
    expect(
      () => CloudEvent.decode(
        _bytes(
          eventFixture()
            ..remove('data')
            ..['data_base64'] = 'e30=',
        ),
      ),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => CloudEvent.decode(_bytes(eventFixture()..['data'] = '{}')),
      throwsA(isA<EventFieldError>()),
    );
  });

  test('Intermediary adds a valid extension', () {
    for (final value in <Object?>[
      'trace-7',
      true,
      2147483647,
      -2147483648,
      null,
    ]) {
      final decoded = CloudEvent.decode(
        _bytes(eventFixture()..['brokertrace'] = value),
      );
      expect(decoded.event.eventId, '86fe3b73-ec2d-5dd3-b104-11f2ec79469c');
      final projection =
          jsonDecode(utf8.decode(decoded.toJsonBytes()))
              as Map<String, Object?>;
      expect(projection.containsKey('brokertrace'), isFalse);
    }
  });

  test('Invalid extension attribute', () {
    for (final name in [
      'BrokerTrace',
      'example.org/context',
      'bad_name',
      'a' * 129,
    ]) {
      expect(
        () => CloudEvent.decode(_bytes(eventFixture()..[name] = 'value')),
        throwsA(isA<EventFieldError>()),
      );
    }
    for (final value in <Object?>[
      {},
      [],
      1.5,
      2147483648,
      'bad\u0001text',
      '\ufdd0',
      'x' * 1025,
    ]) {
      expect(
        () =>
            CloudEvent.decode(_bytes(eventFixture()..['brokertrace'] = value)),
        throwsA(isA<EventFieldError>()),
      );
    }
    final excess = eventFixture()
      ..addAll({for (var i = 0; i < 33; i++) 'extra$i': i});
    expect(
      () => CloudEvent.decode(_bytes(excess)),
      throwsA(isA<EventFieldError>()),
    );
  });

  test('Namespaced extension retained', () {
    final parsed = CloudEvent.decode(_bytes(eventFixture()));
    expect(parsed.event.extensions['example.org/context'], 'rack-7');
    expect(
      CanonicalEvent.fromBuffer(parsed.event.toBuffer()).extensions,
      parsed.event.extensions,
    );
  });

  test('Unsupported field or major version', () {
    final unknown = eventFixture();
    (unknown['data']! as Map<String, Object?>)['producer_note'] = 'new';
    expect(
      () => CloudEvent.decode(_bytes(unknown)),
      throwsA(
        isA<EventFieldError>().having((e) => e.path, 'field', 'producer_note'),
      ),
    );
    expect(
      () => CloudEvent.decode(
        _bytes(
          eventFixture()..['dataschema'] = 'urn:correlia:schema:event:2.0',
        ),
      ),
      throwsA(isA<EventFieldError>()),
    );
    final extension = eventFixture();
    (extension['data']! as Map<String, Object?>)['extensions'] = {
      'context': 'invalid',
    };
    expect(
      () => CloudEvent.decode(_bytes(extension)),
      throwsA(isA<EventFieldError>()),
    );
  });

  test('UPG-3 older consumers parse a newer minor', () {
    final future = eventFixture()
      ..['dataschema'] = 'urn:correlia:schema:event:1.1';
    final payload = future['data']! as Map<String, Object?>;
    payload['producer_note'] = 'new optional';
    (payload['observer']! as Map<String, Object?>)['producer_note'] =
        'nested new';
    final parsed = CloudEvent.decode(_bytes(future));
    expect(parsed.event.validationScope, ValidationScope.knownCoreOnly);
    final projection =
        jsonDecode(utf8.decode(parsed.toJsonBytes())) as Map<String, Object?>;
    expect(projection['dataschema'], 'urn:correlia:schema:event:1.0');
    expect(
      (projection['data']! as Map<String, Object?>).containsKey(
        'producer_note',
      ),
      isFalse,
    );
    expect(
      ((projection['data']! as Map<String, Object?>)['observer']!
              as Map<String, Object?>)
          .containsKey('producer_note'),
      isFalse,
    );
    payload['severity'] = 3;
    expect(
      () => CloudEvent.decode(_bytes(future)),
      throwsA(
        isA<EventFieldError>().having((e) => e.path, 'field', 'severity'),
      ),
    );

    // Synthetic optional field 100 is absent from the published v1.0 descriptor.
    // Its exact tag, length and UTF-8 wire value are independently constructed.
    final original = CanonicalEvent.fromJson(
      eventFixture()['data']! as Map<String, Object?>,
    ).toBuffer();
    const added = [0xa2, 0x06, 0x03, 0x6e, 0x65, 0x77];
    final binary = CanonicalEvent.fromBuffer(
      Uint8List.fromList([...original, ...added]),
      sourceDataschema: 'urn:correlia:schema:event:1.1',
    );
    expect(_unknownStringField100(binary.toBuffer()), 'new');
    expect(binary.validationScope, ValidationScope.knownCoreOnly);
    expect(binary.toJson().containsKey('producer_note'), isFalse);
  });

  test('Extensions have one location', () {
    final original = eventFixture();
    final parsed = CloudEvent.decode(_bytes(original));
    final projected =
        jsonDecode(utf8.decode(parsed.toJsonBytes())) as Map<String, Object?>;
    expect(projected['partitionkey'], original['partitionkey']);
    expect(parsed.event.extensions['example.org/context'], 'rack-7');
    expect(
      () => CloudEvent.decode(
        _bytes(original..['example.org/context'] = 'rack-7'),
      ),
      throwsA(isA<EventFieldError>()),
    );
  });

  test('Bounded input, trace context and nested known-field validation', () {
    expect(
      () => CloudEvent.decode(Uint8List(262145)),
      throwsA(
        isA<EventFieldError>().having((e) => e.code, 'code', 'event_too_large'),
      ),
    );
    Object? boundary = 'leaf';
    for (var n = 0; n < 14; n++) {
      boundary = {'nested': boundary};
    }
    final atLimit = eventFixture()
      ..['dataschema'] = 'urn:correlia:schema:event:1.1';
    (atLimit['data']! as Map<String, Object?>)['future'] = boundary;
    expect(
      CloudEvent.decode(_bytes(atLimit)).event.validationScope,
      ValidationScope.knownCoreOnly,
    );
    Object? nested = 'leaf';
    for (var n = 0; n < 18; n++) {
      nested = {'nested': nested};
    }
    final future = eventFixture()
      ..['dataschema'] = 'urn:correlia:schema:event:1.1';
    (future['data']! as Map<String, Object?>)['future'] = nested;
    expect(
      () => CloudEvent.decode(_bytes(future)),
      throwsA(isA<EventFieldError>().having((e) => e.code, 'code', 'too_deep')),
    );
    const trace = '00-11111111111111111111111111111111-2222222222222222-01';
    final valid = CloudEvent.decode(
      _bytes(eventFixture()..['traceparent'] = trace),
    );
    expect(valid.traceparent, trace);
    expect(
      (jsonDecode(utf8.decode(valid.toJsonBytes()))
          as Map<String, Object?>)['traceparent'],
      trace,
    );
    final malformed = eventFixture()
      ..['dataschema'] = 'urn:correlia:schema:event:1.1';
    ((malformed['data']! as Map<String, Object?>)['observer']!
            as Map<String, Object?>)['sourceKind'] =
        'alias';
    expect(
      () => CloudEvent.decode(_bytes(malformed)),
      throwsA(isA<EventFieldError>()),
    );
  });
}

// A small independent protobuf wire reader proves recovery by a newer consumer,
// without inspecting the implementation's generated backing or private state.
String? _unknownStringField100(Uint8List bytes) {
  var offset = 0;
  int varint() {
    var result = 0;
    var shift = 0;
    while (offset < bytes.length && shift < 70) {
      final byte = bytes[offset++];
      result |= (byte & 127) << shift;
      if (byte < 128) return result;
      shift += 7;
    }
    throw const FormatException('Malformed wire integer');
  }

  while (offset < bytes.length) {
    final tag = varint();
    switch (tag & 7) {
      case 0:
        varint();
      case 1:
        offset += 8;
      case 2:
        final length = varint();
        if (tag >> 3 == 100) {
          return utf8.decode(bytes.sublist(offset, offset + length));
        }
        offset += length;
      case 5:
        offset += 4;
      default:
        throw const FormatException('Unsupported wire type');
    }
  }
  return null;
}
