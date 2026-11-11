import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/alertmanager_decoder.dart';
import 'package:test/test.dart';

// Correlia-authored examples based on the documented Alertmanager v4 format;
// these are not captures from a real Alertmanager installation.
Map<String, Object?> alert({
  String status = 'firing',
  Map<String, String>? labels,
  Map<String, String>? annotations,
  String startsAt = '2026-11-10T01:00:00.123456789+01:00',
  String? endsAt = '0001-01-01T00:00:00Z',
  String? fingerprint,
  String? generatorUrl,
}) => {
  'status': status,
  'labels': labels ?? {'alertname': 'Example', 'severity': 'warning'},
  'annotations': annotations ?? {'summary': 'Example alert'},
  'startsAt': startsAt,
  'endsAt': ?endsAt,
  'fingerprint': ?fingerprint,
  'generatorURL': ?generatorUrl,
};

Map<String, Object?> groupOf(List<Object?> alerts, {int truncated = 0}) => {
  'version': '4',
  'status': 'firing',
  'alerts': alerts,
  'receiver': 'test',
  'groupKey': '{}',
  'groupLabels': <String, String>{},
  'commonLabels': <String, String>{},
  'commonAnnotations': <String, String>{},
  'externalURL': 'https://alerts.example/',
  'notification_reason': 'test',
  'truncatedAlerts': truncated,
};

AlertmanagerBatch decode(
  Map<String, Object?> payload, {
  List<String> excluded = const [],
}) => decodeAlertmanager(
  bytes: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
  sourceInstance: '11111111-1111-4111-8111-111111111111',
  excludedLabels: excluded,
  rawRef: 'raw:fixture',
  rawSha256: '0' * 64,
  observedAt: EventTimestamp.parse('2026-11-10T00:01:00Z'),
  processedAt: EventTimestamp.parse('2026-11-10T00:02:00Z'),
  configVersion: 'snapshot-1',
);

void main() {
  test('mixed_group_and_upstream_truncation', () {
    final batch = decode(
      groupOf([
        alert(),
        alert(status: 'resolved', endsAt: '2026-11-10T00:05:00Z'),
      ], truncated: 3),
    );
    expect(batch.upstreamOmissions, 3);
    expect(batch.events.map((e) => e.status), [
      EventStatus.firing,
      EventStatus.resolved,
    ]);
    for (final event in batch.events) {
      final envelope = CloudEvent(event: event);
      final decoded = CloudEvent.decode(envelope.toJsonBytes());
      expect(decoded.event.toJson(), event.toJson());
      final binary = CanonicalEvent.fromBuffer(event.toBuffer());
      expect(binary.eventId, event.eventId);
      expect(binary.fingerprint, event.fingerprint);
      expect(binary.status, event.status);
      expect(binary.observationKey.bytes, event.observationKey.bytes);
      expect(binary.labels, event.labels);
      expect(binary.annotations, event.annotations);
    }
  });
  test('unsupported_version_or_malformed_member', () {
    final cases = <Map<String, Object?>>[
      {
        ...groupOf([alert()]),
        'version': '3',
      },
      {
        ...groupOf([alert()]),
        'unexpected': true,
      },
      groupOf([
        {...alert(), 'unexpected': true},
      ]),
      groupOf([
        {...alert(), 'status': 'other'},
      ]),
      groupOf([
        {
          ...alert(),
          'labels': {'a': 1},
        },
      ]),
      groupOf([
        {
          ...alert(),
          'annotations': {'a': false},
        },
      ]),
      groupOf([alert(), 4]),
    ];
    for (final payload in cases) {
      expect(() => decode(payload), throwsA(isA<EventFieldError>()));
    }
  });
  test('recognized_fields_require_their_documented_types', () {
    for (final key in [
      'version',
      'status',
      'receiver',
      'groupKey',
      'externalURL',
      'notification_reason',
      'groupLabels',
      'commonLabels',
      'commonAnnotations',
      'truncatedAlerts',
      'alerts',
    ]) {
      for (final invalid in <Object?>[
        null,
        if (key == 'truncatedAlerts') ...[-1, 1.5] else 42,
        false,
        if (key != 'alerts') [],
      ]) {
        expect(
          () => decode({
            ...groupOf([alert()]),
            key: invalid,
          }),
          throwsA(isA<EventFieldError>()),
          reason: '$key must reject $invalid',
        );
      }
    }
    for (final key in [
      'status',
      'labels',
      'annotations',
      'startsAt',
      'endsAt',
      'generatorURL',
      'fingerprint',
    ]) {
      for (final invalid in <Object?>[null, 42, false, []]) {
        expect(
          () => decode(
            groupOf([
              {...alert(), key: invalid},
            ]),
          ),
          throwsA(isA<EventFieldError>()),
          reason: '$key must reject $invalid',
        );
      }
    }
    for (final key in ['groupLabels', 'commonLabels', 'commonAnnotations']) {
      expect(
        () => decode({
          ...groupOf([alert()]),
          key: {'x': false},
        }),
        throwsA(isA<EventFieldError>()),
      );
    }
  });
  test('json_depth_and_batch_boundaries', () {
    Map<String, Object?> nested(int depth) {
      Object? value = 0;
      for (var i = 0; i < depth - 1; i++) {
        value = [value];
      }
      return {...groupOf([]), 'unknown': value};
    }

    expect(
      () => decode(nested(32)),
      throwsA(
        isA<EventFieldError>().having((e) => e.code, 'code', 'unknown_field'),
      ),
    );
    expect(
      () => decode(nested(33)),
      throwsA(
        isA<EventFieldError>().having((e) => e.code, 'code', 'depth_bound'),
      ),
    );
    expect(
      decode(groupOf(List.generate(1000, (_) => alert()))).events,
      hasLength(1000),
    );
    expect(
      () => decode(groupOf(List.generate(1001, (_) => alert()))),
      throwsA(
        isA<EventFieldError>().having((e) => e.code, 'code', 'batch_bound'),
      ),
    );
  });
  test('optional_metadata_and_display_fallbacks', () {
    final minimal = <String, Object?>{
      'version': '4',
      'status': 'resolved',
      'alerts': [
        alert(labels: {'alertname': 'Name'}, annotations: {}),
        alert(labels: {'other': 'value'}, annotations: {'summary': ''}),
      ],
    };
    final events = decode(minimal).events;
    expect(events.map((e) => e.summary), ['Name', 'Alertmanager alert']);
    expect(events.every((e) => e.status == EventStatus.firing), isTrue);
    expect(events.every((e) => e.links.isEmpty), isTrue);
    for (final field in ['generatorURL', 'fingerprint']) {
      expect(
        () => decode(
          groupOf([
            {
              ...alert(),
              field: {'bad': 'type'},
            },
          ]),
        ),
        throwsA(isA<EventFieldError>()),
      );
    }
    expect(
      () => decode({
        ...groupOf([alert()]),
        'externalURL': 'ftp://example.org',
      }),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => decode(groupOf([alert(generatorUrl: 'not a URL')])),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      decode(groupOf([alert(generatorUrl: '')])).events.single.links,
      hasLength(1),
    );
  });
  test('empty_group', () {
    final batch = decode(groupOf([], truncated: 2));
    expect(batch.events, isEmpty);
    expect(batch.upstreamOmissions, 2);
  });
  test('id_6_rebatching_and_fingerprint_independence', () {
    final one = alert(fingerprint: 'one');
    final two = alert(labels: {'alertname': 'Other'});
    final a = decode(groupOf([one, two])).events;
    final b = decode(
      groupOf([
        two,
        {...one, 'fingerprint': 'changed'},
      ]),
    ).events;
    expect(a[0].fingerprint, b[1].fingerprint);
    expect(a[0].eventId, b[1].eventId);
    expect(a[1].eventId, b[0].eventId);
    expect(b[1].extensions['correlia.io/alertmanager_fingerprint'], 'changed');
    expect(b[1].labelsOrigin, isEmpty);
  });
  test('id_7b_and_id_7c_severity_labels', () {
    final warning = alert();
    final critical = alert(
      labels: {'alertname': 'Example', 'severity': 'critical'},
    );
    final a = decode(groupOf([warning, critical])).events;
    expect(a[0].fingerprint, isNot(a[1].fingerprint));
    final b = decode(
      groupOf([warning, critical]),
      excluded: ['severity'],
    ).events;
    expect(b[0].fingerprint, b[1].fingerprint);
    final resolved = decode(
      groupOf([
        alert(
          status: 'resolved',
          labels: {'alertname': 'Example', 'severity': 'critical'},
          endsAt: '2026-11-10T00:05:00Z',
        ),
      ]),
    ).events.single;
    expect(resolved.fingerprint, isNot(a[0].fingerprint));
  });
  test('firing_zero_end_and_resolved_end', () {
    const start = '2026-11-10T01:00:00.123456789+01:00';
    const end = '2026-11-10T00:05:00.123456789Z';
    final events = decode(
      groupOf([alert(), alert(status: 'resolved', endsAt: end)]),
    ).events;
    expect(events[0].endsAt, isNull);
    expect(events[0].sourceTime, EventTimestamp.parse(start));
    expect(events[1].sourceTime, EventTimestamp.parse(end));
    expect(
      events[0].observationKey.bytes,
      ObservationKey.alertmanager(
        status: 'firing',
        startsAt: start,
        endsAt: '0001-01-01T00:00:00Z',
      ).bytes,
    );
    expect(
      events[1].observationKey.bytes,
      ObservationKey.alertmanager(
        status: 'resolved',
        startsAt: start,
        endsAt: end,
      ).bytes,
    );
  });
  test('firing_zero_end_preserves_exact_supplied_evidence', () {
    const start = '2026-11-10T01:00:00.123456789+01:00';
    const zero = '0001-01-01T00:00:00.000000000Z';
    final event = decode(groupOf([alert(endsAt: zero)])).events.single;
    expect(event.endsAt, isNull);
    expect(
      event.observationKey.bytes,
      ObservationKey.alertmanager(
        status: 'firing',
        startsAt: start,
        endsAt: zero,
      ).bytes,
    );
    expect(
      event.eventId,
      isNot(decode(groupOf([alert()])).events.single.eventId),
    );
  });
  test('invalid_source_evidence', () {
    for (final value in [
      {...alert()}..remove('startsAt'),
      alert(startsAt: '0001-01-01T00:00:00Z'),
      alert(startsAt: '2026-11-10T00:00:00'),
      alert(status: 'resolved', endsAt: null),
      alert(status: 'resolved'),
      alert(endsAt: '2026-11-09T00:00:00Z'),
    ]) {
      expect(() => decode(groupOf([value])), throwsA(isA<EventFieldError>()));
    }
  });
  test('display_and_provenance_mapping', () {
    final event = decode(
      groupOf([
        alert(
          labels: {'alertname': 'Example', 'severity': 'notice'},
          annotations: {'summary': 'x' * 500, 'description': 'detail'},
          generatorUrl: 'https://example.org/graph',
        ),
      ]),
    ).events.single;
    expect(event.severity, EventSeverity.unknown);
    expect(event.severityOriginal, 'notice');
    expect(event.summary.runes.length, 256);
    expect(event.summary, contains('…'));
    expect(event.description, 'detail');
    expect(event.links.any((link) => link.relation == 'generator'), isTrue);
    expect(event.raw.ref, 'raw:fixture');
    expect(event.pipeline.version, 'snapshot-1');
    expect(
      CloudEvent.decode(CloudEvent(event: event).toJsonBytes()).event.eventId,
      event.eventId,
    );
  });
  test('map_or_aggregate_event_overflow', () {
    final tooMany = {for (var i = 0; i < 2000; i++) 'key$i': 'x'};
    expect(
      () => decode(groupOf([alert(labels: tooMany)])),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => decode(groupOf([alert(annotations: tooMany)])),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => decode(
        groupOf([
          alert(labels: {'x' * 5000: 'x'}),
        ]),
      ),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => decode(
        groupOf([
          alert(annotations: {'x' * 5000: 'x'}),
        ]),
      ),
      throwsA(isA<EventFieldError>()),
    );
    final largeAnnotations = {
      for (var i = 0; i < 128; i++) 'key$i': 'é' * 1024,
    };
    expect(
      () => decode(groupOf([alert(), alert(annotations: largeAnnotations)])),
      throwsA(
        isA<EventFieldError>()
            .having((e) => e.path, 'path', 'alerts[1].event')
            .having((e) => e.code, 'code', 'event_too_large'),
      ),
    );
    expect(
      () => decode(
        groupOf([
          alert(labels: {'alertname': 'x' * 1048576}),
        ]),
      ),
      throwsA(
        isA<EventFieldError>().having((e) => e.code, 'code', 'too_large'),
      ),
    );
    expect(
      () => decode(groupOf(List.generate(1001, (_) => alert()))),
      throwsA(isA<EventFieldError>()),
    );
  });
  test('empty_selected_identity', () {
    expect(
      () => decode(
        groupOf([
          alert(labels: {'severity': 'warning'}),
        ]),
        excluded: ['severity'],
      ),
      throwsA(isA<EventFieldError>()),
    );
  });
  test('oversize_identity_label_projection', () {
    final prefix = 'x' * 1100;
    final events = decode(
      groupOf([
        alert(labels: {'alertname': '${prefix}a'}),
        alert(labels: {'alertname': '${prefix}b'}),
      ]),
    ).events;
    expect(events[0].labels['alertname'], events[1].labels['alertname']);
    expect(events[0].labels['alertname'], contains('…'));
    expect(events[0].fingerprint, isNot(events[1].fingerprint));
  });
  test('oversize_annotation_value', () {
    final original = alert(annotations: {'description': 'x'});
    final long = alert(annotations: {'description': 'x' * 5000});
    final events = decode(groupOf([original, long])).events;
    expect(events[0].fingerprint, events[1].fingerprint);
    expect(events[0].eventId, events[1].eventId);
    expect(events[1].annotations['description'], contains('…'));
    expect(events[1].description, contains('…'));
  });
}
