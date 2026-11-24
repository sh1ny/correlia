import 'dart:convert';

import 'package:correlia_server/src/event/canonical_event.dart';
import 'package:correlia_server/src/event/identity.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:test/test.dart';

import '../../support/icinga2_stream_decode_fixture.dart';

IcingaStreamLineResult _decode(
  Object? document, {
  StreamStateTypePolicy policy = StreamStateTypePolicy.hardOnly,
  IcingaStreamOrigin origin = IcingaStreamOrigin.stream,
}) {
  final text = document is String ? document : jsonEncode(document);
  final request = streamDecodeRequest(text);
  return decodeIcingaStreamLine(
    text,
    request: request,
    receivedAt: request.observedAt,
    policy: policy,
    origin: origin,
  );
}

CanonicalEvent _event(
  Map<String, Object?> document, {
  StreamStateTypePolicy policy = StreamStateTypePolicy.hardOnly,
}) => (_decode(document, policy: policy) as IcingaStreamEvent).event;

Matcher _error(String code, String path) => throwsA(
  isA<EventFieldError>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.path, 'path', path),
);

Map<String, Object?> _check(Map<String, Object?> event) =>
    event['check_result']! as Map<String, Object?>;

Map<String, Object?> _withState(
  Map<String, Object?> event,
  Map<String, Object?> state,
) => {
  ...event,
  'check_result': {
    ..._check(event),
    'vars_after': {
      ..._check(event)['vars_after']! as Map<String, Object?>,
      ...state,
    },
  },
};

void main() {
  final events = {
    for (final release in streamCaptures)
      release: capturedStreamEvents(release),
  };
  final latest = events[streamCaptures.last]!;
  Map<String, Object?> state(String output) => latest.firstWhere(
    (item) => item['type'] == 'StateChange' && _check(item)['output'] == output,
  );

  test('host_raw_warning', () {
    final input = _withState(state('host HARD problem'), {'state': 1});
    final event = _event(input);
    expect(event.status, EventStatus.resolved);
    expect(event.kind, EventKind.alert);
    expect(event.severityOriginal, 'UP');
    expect(event.summary, 'stream-host UP');
  });

  test('unreachable_host', () {
    final event = _event(
      _withState(state('host HARD problem'), {'reachable': false}),
    );
    expect(event.status, EventStatus.firing);
    expect(event.severity, EventSeverity.critical);
    expect(event.severityOriginal, 'UNREACHABLE');
  });

  test('unknown_raw_state', () {
    for (final raw in [99, 7]) {
      expect(
        () => _decode(_withState(state('host HARD problem'), {'state': raw})),
        _error('invalid_state', 'check_result.vars_after.state'),
      );
    }
  });

  test('missed_recovery_superseded_by_a_soft_result', () {
    final sync = capturedStreamSync(streamCaptures.last, 'services');
    final attrs = sync['attrs']! as Map<String, Object?>;
    final result = _decode({
      ...sync,
      'attrs': {
        ...attrs,
        'last_check_result': _check(state('service SOFT problem')),
      },
    }, origin: IcingaStreamOrigin.sync);
    expect(result, isA<IcingaStreamSoftInfo>());
  });

  test('soft_problem_under_hard_only', () {
    expect(_decode(state('service SOFT problem')), isA<IcingaStreamSoftInfo>());
    expect(_event(state('service recovery')).status, EventStatus.resolved);
  });

  test('soft_problem_under_soft_and_hard', () {
    final problem = _event(
      state('service SOFT problem'),
      policy: StreamStateTypePolicy.softAndHard,
    );
    final recovery = _event(
      state('service recovery'),
      policy: StreamStateTypePolicy.softAndHard,
    );
    expect(problem.status, EventStatus.firing);
    expect(problem.severity, EventSeverity.critical);
    expect(recovery.status, EventStatus.resolved);
    expect(recovery.fingerprint, problem.fingerprint);
  });

  test('acknowledgement_set', () {
    final event = _event(
      latest.firstWhere((item) => item['type'] == 'AcknowledgementSet'),
    );
    expect(event.kind, EventKind.ack);
    expect(event.status, EventStatus.info);
    expect(event.description, 'checking');
    expect(event.annotations['icinga2.notification_author'], 'operator');
    expect(
      event.fingerprint,
      _event(state('service HARD problem')).fingerprint,
    );
  });

  test('two_acknowledgements_by_different_authors_at_one_instant', () {
    final input = latest.firstWhere(
      (item) => item['type'] == 'AcknowledgementSet',
    );
    final time = (input['timestamp']! as num).toDouble().toString();
    final first = _event(input);
    final next = _event({...input, 'author': 'second operator'});
    expect(next.eventId, isNot(first.eventId));
    for (final (author, event) in [
      ('operator', first),
      ('second operator', next),
    ]) {
      expect(
        event.observationKey.bytes,
        ObservationKey.native(
          jsonEncode([
            'icinga2.stream.acknowledgementset.v1',
            'AcknowledgementSet',
            time,
            author,
          ]),
        ).bytes,
      );
    }
  });

  test('acknowledgement_clear_uses_null_author', () {
    for (final release in streamCaptures) {
      final input = events[release]!.firstWhere(
        (item) => item['type'] == 'AcknowledgementCleared',
      );
      final event = _event(input);
      expect(event.kind, EventKind.ack, reason: release);
      expect(event.status, EventStatus.info);
      expect(event.description, isNull);
      expect(event.annotations, isNot(contains('icinga2.notification_author')));
      expect(
        event.observationKey.bytes,
        ObservationKey.native(
          jsonEncode([
            'icinga2.stream.acknowledgementcleared.v1',
            'AcknowledgementCleared',
            (input['timestamp']! as num).toDouble().toString(),
            null,
          ]),
        ).bytes,
      );
    }
  });

  test('downtime_and_flapping_use_native_evidence', () {
    for (final release in streamCaptures) {
      for (final (type, kind) in [
        ('DowntimeStarted', EventKind.downtime),
        ('DowntimeRemoved', EventKind.downtime),
        ('Flapping', EventKind.state),
      ]) {
        for (final item in events[release]!.where(
          (item) => item['type'] == type,
        )) {
          final event = _event(item);
          expect(event.kind, kind, reason: '$release $type');
          expect(event.status, EventStatus.info);
          expect(
            event.observationKey.bytes,
            ObservationKey.native(
              jsonEncode([
                'icinga2.stream.${type.toLowerCase()}.v1',
                type,
                (item['timestamp']! as num).toDouble().toString(),
                if (type == 'Flapping')
                  item['is_flapping']
                else
                  (item['downtime']! as Map<String, Object?>)['name'],
              ]),
            ).bytes,
          );
        }
      }
    }
  });

  test('event_type_not_subscribed', () {
    final item = state('service HARD problem');
    expect(
      () => _decode({...item, 'type': 'CheckResult'}),
      _error('unsupported_type', 'type'),
    );
  });

  test('structural_field_paths', () {
    final item = state('service HARD problem');
    expect(
      () => _decode({...item, 'check_result.vars_after.state': 1}),
      _error('unknown_field', '*'),
    );
    expect(
      () => _decode(_withState(item, {'secret_hint': 1})),
      _error('unknown_field', 'check_result.vars_after.*'),
    );
    final text = jsonEncode(
      item,
    ).replaceFirst('"vars_after":{', '"vars_after":{"state":1,');
    expect(
      () => _decode(text),
      _error('duplicate_field', 'check_result.vars_after.state'),
    );
  });
}
