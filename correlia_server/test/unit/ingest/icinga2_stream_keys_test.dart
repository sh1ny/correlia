import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/event/canonical_event.dart';
import 'package:correlia_server/src/event/validation.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/keys.dart';
import 'package:test/test.dart';

import '../../support/icinga2_stream_decode_fixture.dart';

const _vectors = [
  (
    '1763571234.123456',
    '1763571234.123456',
    1763571234123456,
    '26c87fc0-798e-51e8-8dd7-71c82f840e3f',
    'AAAAAgAAAAZkb21haW4AAAASY29ycmVsaWEubmF0aXZlLnYxAAAAA2tleQAAAE8AWyJpY2luZ2EyLmNoZWNrLnYxIiwiQ1JJVElDQUwiLCJIQVJEIiwiMTc2MzU3MTIzNC4xMjM0NTYiLCIxNzYzNTcxMjM0LjEyMzQ1NiJd',
  ),
  (
    '4294967296.000011',
    '4294967296.000011',
    4294967296000011,
    '8e0f3f49-4a48-5010-b817-c7b09666ba29',
    'AAAAAgAAAAZkb21haW4AAAASY29ycmVsaWEubmF0aXZlLnYxAAAAA2tleQAAAE8AWyJpY2luZ2EyLmNoZWNrLnYxIiwiQ1JJVElDQUwiLCJIQVJEIiwiNDI5NDk2NzI5Ni4wMDAwMTEiLCI0Mjk0OTY3Mjk2LjAwMDAxMSJd',
  ),
  (
    '8589934591.999999',
    '8589934591.999999',
    8589934591999999,
    '2213a4e0-c658-58a5-ba6e-2cc93edc641d',
    'AAAAAgAAAAZkb21haW4AAAASY29ycmVsaWEubmF0aXZlLnYxAAAAA2tleQAAAE8AWyJpY2luZ2EyLmNoZWNrLnYxIiwiQ1JJVElDQUwiLCJIQVJEIiwiODU4OTkzNDU5MS45OTk5OTkiLCI4NTg5OTM0NTkxLjk5OTk5OSJd',
  ),
  (
    '4294967296.000001',
    '4294967296.000001',
    4294967296000000,
    'e9d414eb-53ae-5d37-80d3-193200dc4115',
    'AAAAAgAAAAZkb21haW4AAAASY29ycmVsaWEubmF0aXZlLnYxAAAAA2tleQAAAE8AWyJpY2luZ2EyLmNoZWNrLnYxIiwiQ1JJVElDQUwiLCJIQVJEIiwiNDI5NDk2NzI5Ni4wMDAwMDEiLCI0Mjk0OTY3Mjk2LjAwMDAwMSJd',
  ),
  (
    '1763571234',
    '1763571234.0',
    1763571234000000,
    '03f72b23-bce4-52fe-85de-c1702240a827',
    'AAAAAgAAAAZkb21haW4AAAASY29ycmVsaWEubmF0aXZlLnYxAAAAA2tleQAAAEUAWyJpY2luZ2EyLmNoZWNrLnYxIiwiQ1JJVElDQUwiLCJIQVJEIiwiMTc2MzU3MTIzNC4wIiwiMTc2MzU3MTIzNC4wIl0=',
  ),
];

CanonicalEvent _decode(String line) {
  final request = streamDecodeRequest(line);
  final result = decodeIcingaStreamLine(
    line,
    request: request,
    receivedAt: request.observedAt,
    policy: StreamStateTypePolicy.hardOnly,
  );
  return (result as IcingaStreamEvent).event;
}

String _case(Map<String, Object?> fixture, {String? start, String? end}) {
  final check = {...fixture['check_result']! as Map<String, Object?>}
    ..remove('execution_start')
    ..remove('execution_end');
  final envelope = jsonEncode({...fixture, 'check_result': check});
  // Substitute the original JSON number spelling without first reformatting it.
  final fields = [
    if (start != null) '"execution_start":$start,',
    if (end != null) '"execution_end":$end,',
  ];
  return envelope.replaceFirst(
    '"check_result":{',
    '"check_result":{${fields.join()}',
  );
}

void main() {
  final fixture = capturedStreamEvents('2.16.6').firstWhere(
    (event) =>
        (event['check_result'] as Map<String, Object?>?)?['output'] ==
        'service HARD problem',
  );

  test('key_times', () {
    for (final (wire, text, micros, id, bytes) in _vectors) {
      final event = _decode(_case(fixture, start: wire, end: wire));
      expect(event.eventId, id);
      expect(base64.encode(event.observationKey.bytes), bytes);
      expect(
        utf8.decode(event.observationKey.bytes.sublist(48)),
        '["icinga2.check.v1","CRITICAL","HARD","$text","$text"]',
      );
      final time = event.sourceTime!;
      expect(time.seconds * 1000000 + time.nanos ~/ 1000, micros);
    }
  });

  test('captured_times_use_exact_microsecond_floors', () {
    for (final release in streamCaptures) {
      for (final row in capturedStreamEvents(release)) {
        final check = row['check_result'] as Map<String, Object?>?;
        for (final (object, key) in [
          (row, 'timestamp'),
          if (check != null) ...[
            (check, 'execution_start'),
            (check, 'execution_end'),
          ],
        ]) {
          final value = (object[key]! as num).toDouble();
          final bits = (ByteData(8)..setFloat64(0, value)).getUint64(0);
          final significand = (1 << 52) | (bits & ((1 << 52) - 1));
          final exact =
              (BigInt.from(significand) * BigInt.from(1000000)) >>
              (1075 - (bits >> 52));
          final timestamp = StreamKeyTime.read(object, key, key).toTimestamp();
          expect(
            timestamp.seconds * 1000000 + timestamp.nanos ~/ 1000,
            exact.toInt(),
            reason: '$release $key $value',
          );
        }
      }
    }
  });

  test('captured_stream_and_sync_share_the_same_key', () {
    for (final release in streamCaptures) {
      final lines = capturedStreamEvents(release);
      for (final collection in ['hosts', 'services']) {
        final sync = capturedStreamSync(release, collection);
        final attrs = sync['attrs']! as Map<String, Object?>;
        final result = attrs['last_check_result']! as Map<String, Object?>;
        final wire = lines.singleWhere(
          (line) =>
              (line['check_result'] as Map<String, Object?>?)?['output'] ==
              result['output'],
        );
        final streamEvent = _decode(jsonEncode(wire));
        final text = jsonEncode(sync);
        final request = streamDecodeRequest(text);
        final syncEvent =
            decodeIcingaStreamLine(
                  text,
                  request: request,
                  receivedAt: request.observedAt,
                  policy: StreamStateTypePolicy.hardOnly,
                  origin: IcingaStreamOrigin.sync,
                )
                as IcingaStreamEvent;
        expect(
          syncEvent.event.eventId,
          streamEvent.eventId,
          reason: '$release $collection',
        );
        expect(
          syncEvent.event.observationKey.bytes,
          streamEvent.observationKey.bytes,
        );
      }
    }
  });

  test('invalid_time', () {
    for (final (value, code) in [
      (null, 'missing_field'),
      ('"4294967296"', 'invalid_type'),
      ('0.9999', 'out_of_range'),
      ('8589934592', 'out_of_range'),
    ]) {
      expect(
        () => _decode(_case(fixture, start: value, end: '1763571234')),
        throwsA(
          isA<EventFieldError>()
              .having((e) => e.path, 'path', 'check_result.execution_start')
              .having((e) => e.code, 'code', code),
        ),
      );
    }
  });
}
