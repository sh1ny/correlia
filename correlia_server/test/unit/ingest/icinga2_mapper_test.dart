import 'package:correlia_server/event.dart';
import 'package:test/test.dart';

import '../../support/icinga2_delivery.dart';

void main() {
  test('service_problem_notification', () {
    final event = decodeOne(delivery());
    expect(event.kind, EventKind.alert);
    expect(event.status, EventStatus.firing);
    expect(event.severity, EventSeverity.critical);
    expect(event.severityOriginal, 'CRITICAL');
    expect(event.observer.sourceKind, 'icinga2');
    expect(event.summary, 'db1!disk CRITICAL');
    expect(event.description, 'DISK CRITICAL - free space: / 100 MB');
    expect(event.annotations, {'icinga2.notification_type': 'PROBLEM'});
    expect(event.startsAt, isNull);
    expect(event.endsAt, isNull);
    expect(event.links, isEmpty);
    expect(
      event.sourceTime,
      EventTimestamp.parse('2025-11-19T16:53:54.123456Z'),
    );
    expect(event.reportedSourceTime, '2025-11-19T16:53:54.123456Z');
  });

  test('informational_delivery_carrying_a_problem_state', () {
    final event = decodeOne(
      delivery(set: {'notification_type': 'ACKNOWLEDGEMENT'}),
    );
    expect(event.kind, EventKind.ack);
    expect(event.status, EventStatus.info);
    expect(event.severity, EventSeverity.info);
    expect(event.severityOriginal, 'CRITICAL');
    // Check output is published only on state observations.
    expect(event.description, isNull);
  });

  test('unreachable_host', () {
    final event = decodeOne(hostDelivery(state: 'UNREACHABLE'));
    expect(event.kind, EventKind.alert);
    expect(event.status, EventStatus.firing);
    expect(event.severity, EventSeverity.critical);
    expect(event.severityOriginal, 'UNREACHABLE');
    expect(event.summary, 'web1 DOWN');
  });

  test('missing_check_output', () {
    final event = decodeOne(delivery(set: {'output': null}));
    expect(event.description, isNull);
    expect(event.summary, 'db1!disk CRITICAL');
    expect(decodeOne(delivery(set: {'output': ''})).description, isNull);
  });

  test('host_and_service_are_distinct_alerts', () {
    final host = decodeOne(hostDelivery(set: {'host': 'web1'}));
    final service = decodeOne(
      delivery(set: {'host': 'web1', 'service': 'http'}),
    );
    expect(host.fingerprint, isNot(service.fingerprint));
    expect(
      decodeOne(delivery(set: {'host': 'web1', 'service': 'http'})).fingerprint,
      service.fingerprint,
    );
  });

  test('same_names_on_another_source', () {
    final document = delivery(set: {'host': 'web1', 'service': 'http'});
    final one = decodeOne(document, namespace: 'site-a');
    final two = decodeOne(document, namespace: 'site-b');
    expect(one.fingerprint, isNot(two.fingerprint));
  });

  test('oversize_identity_value', () {
    final host = 'h' * 2000;
    final event = decodeOne(delivery(set: {'host': host}));
    final component = event.identityFields['host']!;
    expect(component.raw, isNull);
    expect(component.digest, isNotNull);
    final source = SourceContext(
      sourceInstance: icinga2SourceInstance,
      sourceKind: 'icinga2',
    );
    expect(
      event.fingerprint,
      alertFingerprint(
        source,
        identityComponents({'host': host, 'service': 'disk'}),
      ),
    );
    final truncated = decodeOne(delivery(set: {'host': 'h' * 1999}));
    expect(truncated.fingerprint, isNot(event.fingerprint));
    expect(event.summary.runes.length, lessThanOrEqualTo(256));
    expect(event.summary, contains('…'));
  });

  test('published_author_and_comment_fields', () {
    final comment = 'c' * 6000;
    final author = 'a' * 2000;
    final event = decodeOne(
      delivery(
        set: {
          'notification_type': 'CUSTOM',
          'notification_comment': comment,
          'notification_author': author,
        },
      ),
    );
    expect(event.kind, EventKind.comment);
    expect(event.description, '${'c' * 4095}…');
    expect(event.annotations['icinga2.notification_author'], '${'a' * 1023}…');
    expect(event.annotations['icinga2.notification_type'], 'CUSTOM');

    final bare = decodeOne(delivery(set: {'notification_type': 'CUSTOM'}));
    expect(bare.description, isNull);
    expect(
      bare.annotations.containsKey('icinga2.notification_author'),
      isFalse,
    );
    final empty = decodeOne(
      delivery(
        set: {
          'notification_type': 'CUSTOM',
          'notification_comment': '',
          'notification_author': '',
        },
      ),
    );
    expect(empty.description, isNull);
    expect(
      empty.annotations.containsKey('icinga2.notification_author'),
      isFalse,
    );
  });

  group('beyond the named scenarios', () {
    test('every_notification_type_has_its_kind_and_no_alert_effect', () {
      const kinds = {
        'ACKNOWLEDGEMENT': EventKind.ack,
        'DOWNTIMESTART': EventKind.downtime,
        'DOWNTIMEEND': EventKind.downtime,
        'DOWNTIMECANCELLED': EventKind.downtime,
        'FLAPPINGSTART': EventKind.state,
        'FLAPPINGEND': EventKind.state,
        'CUSTOM': EventKind.comment,
      };
      for (final MapEntry(:key, :value) in kinds.entries) {
        final event = decodeOne(delivery(set: {'notification_type': key}));
        expect(event.kind, value, reason: key);
        expect(event.status, EventStatus.info, reason: key);
        expect(event.severity, EventSeverity.info, reason: key);
        expect(event.annotations['icinga2.notification_type'], key);
      }
    });

    test('state_and_state_type_decide_the_status_never_the_type', () {
      const table = [
        ('PROBLEM', 'OK', 'HARD', EventStatus.resolved, EventSeverity.info),
        ('RECOVERY', 'OK', 'SOFT', EventStatus.resolved, EventSeverity.info),
        // A delayed RECOVERY that finds the service refired is firing.
        (
          'RECOVERY',
          'CRITICAL',
          'HARD',
          EventStatus.firing,
          EventSeverity.critical,
        ),
        (
          'PROBLEM',
          'WARNING',
          'HARD',
          EventStatus.firing,
          EventSeverity.warning,
        ),
        (
          'PROBLEM',
          'UNKNOWN',
          'HARD',
          EventStatus.firing,
          EventSeverity.unknown,
        ),
        ('PROBLEM', 'CRITICAL', 'SOFT', EventStatus.info, EventSeverity.info),
      ];
      for (final (type, state, stateType, status, severity) in table) {
        final event = decodeOne(
          delivery(
            set: {
              'notification_type': type,
              'state': state,
              'state_type': stateType,
            },
          ),
        );
        expect((event.status, event.severity), (status, severity));
        expect(event.severityOriginal, state);
        expect(
          event.kind,
          status == EventStatus.info ? EventKind.state : EventKind.alert,
        );
      }
    });
  });
}
