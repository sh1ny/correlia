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
    // Each fixture holds one alert, and each is emitted as one event. Thanos
    // Ruler fixtures reach an Alertmanager-protocol source.
    for (final path in [
      '$_alertmanagerRoot/v0.35.0-firing.json',
      '$_alertmanagerRoot/v0.35.0-resolved.json',
      '$_thanosRoot/v0.42.5-kept-0001.json',
      '$_thanosRoot/v0.42.5-dropped-0001.json',
    ]) {
      expect(
        [for (final event in _alertmanager(path)) event.kind],
        [EventKind.alert],
        reason: path,
      );
    }
    expect(_generic().kind, EventKind.alert);
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
      // A delayed recovery that samples a SOFT problem state.
      (
        {
          'notification_type': 'RECOVERY',
          'state': 'CRITICAL',
          'state_type': 'SOFT',
        },
        EventKind.state,
      ),
      (
        {
          'notification_type': 'RECOVERY',
          'state': 'CRITICAL',
          'state_type': 'HARD',
        },
        EventKind.alert,
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

  test('icinga2_webhook_kinds_on_the_golden_captures', () {
    // Every delivery Correlia admitted in the committed captures of each
    // Icinga2 release, decoded as the pipeline decodes it.
    final seen = <String>{};
    var deliveries = 0;
    for (final file in Directory(
      'test/unit/ingest/fixtures/icinga2',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.contains('/linux-x64/') ||
          file.path.endsWith('manifest.json')) {
        continue;
      }
      final capture =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      for (final record in capture['records']! as List<Object?>) {
        if (record case {
          'kind': 'admitted',
          'response_status': 202,
          'request': {'body': final String text},
        }) {
          final document = jsonDecode(text) as Map<String, Object?>;
          final type = document['notification_type']! as String;
          final stateType = document['state_type'];
          final state = document['state'];
          final expected = switch (type) {
            // The sampled state decides, never the notification type: a
            // recovered state resolves the alert, a SOFT problem state is
            // only a state change, and a HARD one alerts.
            'PROBLEM' ||
            'RECOVERY' when state == 'OK' || state == 'UP' => EventKind.alert,
            'PROBLEM' || 'RECOVERY' when stateType == 'SOFT' => EventKind.state,
            'PROBLEM' || 'RECOVERY' => EventKind.alert,
            'FLAPPINGSTART' || 'FLAPPINGEND' => EventKind.state,
            'ACKNOWLEDGEMENT' => EventKind.ack,
            'DOWNTIMESTART' ||
            'DOWNTIMEEND' ||
            'DOWNTIMECANCELLED' => EventKind.downtime,
            'CUSTOM' => EventKind.comment,
            _ => fail('${file.path}: unexpected type $type'),
          };
          expect(
            decodeOne(document).kind,
            expected,
            reason: '${file.path} ${record['id']}: $type $stateType',
          );
          seen.add(type);
          deliveries++;
        }
      }
    }
    expect(deliveries, greaterThan(0));
    // The synthetic table above covers the cases the captures lack: a SOFT
    // problem, a recovery that samples a problem state and a cancelled
    // downtime.
    expect(seen, {
      'PROBLEM',
      'RECOVERY',
      'FLAPPINGSTART',
      'FLAPPINGEND',
      'ACKNOWLEDGEMENT',
      'DOWNTIMESTART',
      'DOWNTIMEEND',
      'CUSTOM',
    });
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
    // A SOFT recovery is still a resolved alert under hard_only.
    final recovery =
        jsonDecode(jsonEncode(state('service recovery')))
            as Map<String, Object?>;
    final check = recovery['check_result']! as Map<String, Object?>;
    (check['vars_after']! as Map<String, Object?>)['state_type'] = 0;
    recovery['state_type'] = 0;
    expect(
      _stream(recovery, StreamStateTypePolicy.hardOnly),
      isA<IcingaStreamEvent>()
          .having((e) => e.event.kind, 'kind', EventKind.alert)
          .having((e) => e.event.status, 'status', EventStatus.resolved),
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
