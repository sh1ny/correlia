import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/alertmanager_decoder.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/generic_decoder.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:correlia_server/src/ingest/source_decoder.dart';
import 'package:correlia_server/src/matcher/matcher_document.dart';
import 'package:correlia_server/src/matcher/matcher_evaluation.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../support/generic_webhook_fixture.dart';
import '../../support/icinga2_delivery.dart';
import '../../support/icinga2_stream_decode_fixture.dart';

const _source = '11111111-1111-4111-8111-111111111111';
const _alertmanagerRoot = 'test/unit/ingest/fixtures/alertmanager';
const _thanosRoot = 'test/unit/ingest/fixtures/thanos';

List<CanonicalEvent> _alertmanager(String path) {
  final bytes = File(path).readAsBytesSync();
  return decodeAlertmanager(
    bytes: bytes,
    sourceInstance: _source,
    rawRef: 'raw:$path',
    rawSha256: sha256.convert(bytes).toString(),
    observedAt: EventTimestamp.parse('2026-11-24T20:00:00Z'),
    processedAt: EventTimestamp.parse('2026-11-24T20:01:00Z'),
    configVersion: 'compatibility',
  ).events;
}

CanonicalEvent _generic() {
  final bytes = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'host': 'api',
        'time': '2026-11-24T05:20:00Z',
        'state': 'PROBLEM',
        'summary': 'Unavailable',
      }),
    ),
  );
  return decodeGeneric(
    DecodeRequest(
      bytes: bytes,
      sourceInstance: _source,
      namespace: _source,
      excludedLabels: const [],
      rawRef: 'raw:generic',
      rawSha256: sha256.convert(bytes).toString(),
      observedAt: EventTimestamp.parse('2026-11-24T05:21:00Z'),
      processedAt: EventTimestamp.parse('2026-11-24T05:21:01Z'),
      configVersion: 'revision',
    ),
    GenericMapping.parse(checkMapping()),
  ).events.single;
}

IcingaStreamLineResult _stream(
  Map<String, Object?> document,
  StreamStateTypePolicy policy,
) {
  final text = jsonEncode(document);
  final request = streamDecodeRequest(text);
  return decodeIcingaStreamLine(
    text,
    request: request,
    receivedAt: request.observedAt,
    policy: policy,
    origin: IcingaStreamOrigin.stream,
  );
}

EventKind? _streamKind(
  Map<String, Object?> document,
  StreamStateTypePolicy policy,
) => switch (_stream(document, policy)) {
  IcingaStreamEvent(:final event) => event.kind,
  _ => null,
};

void main() {
  test('alertmanager_protocol_and_generic_kinds', () {
    final alertmanager = [
      for (final name in ['v0.35.0-firing.json', 'v0.35.0-resolved.json'])
        ..._alertmanager('$_alertmanagerRoot/$name'),
    ];
    // Thanos Ruler fixtures reach an Alertmanager-protocol source.
    final thanos = [
      for (final name in [
        'v0.42.5-kept-0001.json',
        'v0.42.5-dropped-0001.json',
      ])
        ..._alertmanager('$_thanosRoot/$name'),
    ];
    expect(alertmanager, isNotEmpty);
    expect(thanos, isNotEmpty);
    for (final event in [...alertmanager, ...thanos, _generic()]) {
      expect(event.kind, EventKind.alert);
    }
  });

  test('icinga2_webhook_kinds', () {
    CanonicalEvent decode(Map<String, Object?> set) =>
        decodeOne(delivery(set: set));
    final table = <(Map<String, Object?>, EventKind)>[
      ({'notification_type': 'PROBLEM'}, EventKind.alert),
      (
        {'notification_type': 'RECOVERY', 'state': 'OK'},
        EventKind.alert,
      ),
      (
        {'notification_type': 'PROBLEM', 'state_type': 'SOFT'},
        EventKind.state,
      ),
      ({'notification_type': 'FLAPPINGSTART'}, EventKind.state),
      ({'notification_type': 'FLAPPINGEND'}, EventKind.state),
      ({'notification_type': 'ACKNOWLEDGEMENT'}, EventKind.ack),
      ({'notification_type': 'DOWNTIMESTART'}, EventKind.downtime),
      ({'notification_type': 'DOWNTIMEEND'}, EventKind.downtime),
      ({'notification_type': 'DOWNTIMECANCELLED'}, EventKind.downtime),
      ({'notification_type': 'CUSTOM'}, EventKind.comment),
    ];
    for (final (set, kind) in table) {
      expect(decode(set).kind, kind, reason: '$set');
    }
  });

  test('icinga2_event_streams_kinds_under_each_state_policy', () {
    final events = capturedStreamEvents(streamCaptures.last);
    Map<String, Object?> state(String output) => events.firstWhere(
      (item) =>
          item['type'] == 'StateChange' &&
          (item['check_result']! as Map<String, Object?>)['output'] == output,
    );
    Map<String, Object?> typed(String type) =>
        events.firstWhere((item) => item['type'] == type);
    for (final policy in StreamStateTypePolicy.values) {
      expect(
        _streamKind(state('service HARD problem'), policy),
        EventKind.alert,
        reason: '$policy hard problem',
      );
      expect(
        _streamKind(state('service recovery'), policy),
        EventKind.alert,
        reason: '$policy recovery',
      );
      for (final (type, kind) in [
        ('AcknowledgementSet', EventKind.ack),
        ('AcknowledgementCleared', EventKind.ack),
        ('DowntimeStarted', EventKind.downtime),
        ('DowntimeRemoved', EventKind.downtime),
        ('Flapping', EventKind.state),
      ]) {
        expect(_streamKind(typed(type), policy), kind, reason: '$policy $type');
      }
      // A comment type is not subscribed and is rejected.
      expect(
        () => _stream({...typed('Flapping'), 'type': 'CommentAdded'}, policy),
        throwsA(
          isA<EventFieldError>().having(
            (e) => e.code,
            'code',
            'unsupported_type',
          ),
        ),
        reason: '$policy comment',
      );
    }
    final soft = state('service SOFT problem');
    expect(
      _stream(soft, StreamStateTypePolicy.hardOnly),
      isA<IcingaStreamSoftInfo>(),
    );
    expect(
      _streamKind(soft, StreamStateTypePolicy.softAndHard),
      EventKind.alert,
    );
  });

  test('a_label_named_kind_does_not_change_kind', () async {
    final event = _alertmanager(
      '$_alertmanagerRoot/v0.35.0-firing.json',
    ).single;
    final matcher = MatcherDocument.parse({
      'language': 'matcher',
      'version': 1,
      'rules': [
        {
          'id': 'kind-label',
          'when': {'field': 'summary', 'op': 'exists'},
          'actions': [
            {'type': 'set_label', 'key': 'kind', 'value': 'heartbeat'},
          ],
        },
      ],
    }, const {});
    final patched = await applyMatcherRule(
      matcher.rules.single,
      original: event,
      current: event,
      capture: (_, _, _) async => null,
    );
    expect(patched!.event.labels, containsPair('kind', 'heartbeat'));
    expect(patched.event.kind, EventKind.alert);
    expect(patched.event.fingerprint, event.fingerprint);
  });
}
