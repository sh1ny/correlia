import 'package:correlia_server/src/event/canonical_event.dart';
import 'package:correlia_server/src/event/event_timestamp.dart';
import 'package:correlia_server/src/state/ordering_key.dart';
import 'package:correlia_server/src/state/transition.dart';
import 'package:test/test.dart';

const _lowId = '00000000-0000-4000-8000-000000000001';
const _highId = '00000000-0000-4000-8000-000000000002';

EventTimestamp _time(int seconds, [int nanos = 0]) =>
    EventTimestamp.fromParts(seconds, nanos);

Observation _observation({
  required EventStatus status,
  required int source,
  int sourceNanos = 0,
  int observed = 1000,
  String id = _lowId,
  EventSeverity severity = EventSeverity.warning,
  String summary = 'Disk full',
  String? generatorUrl = 'https://monitor.example/alert',
}) => Observation(
  status: status,
  severity: severity,
  summary: summary,
  generatorUrl: generatorUrl,
  orderingKey: OrderingKey(
    effectiveAt: _time(source, sourceNanos),
    observedAt: _time(observed),
    eventId: id,
  ),
);

AlertState _created(Observation observation) {
  final result = decideTransition(null, observation);
  expect(result, isA<Created>());
  expect(result.activityKind, ActivityKind.created);
  return result.state!;
}

void main() {
  group('decideTransition', () {
    test('ord_1_delayed_recovery_does_not_clear_newer_problem', () {
      final older = _observation(status: EventStatus.resolved, source: 100);
      final newer = _observation(status: EventStatus.firing, source: 200);
      final firstNew = _created(newer);
      final stale = decideTransition(firstNew, older);
      expect(stale, isA<Stale>());
      expect(stale.activityKind, isNull);
      expect(stale.state!.status, EventStatus.firing);
      expect(stale.state!.fence.compareTo(newer.orderingKey), 0);
      expect(stale.state!.version, 1);

      final firstOld = _created(older);
      final applied = decideTransition(firstOld, newer);
      expect(applied, isA<Applied>());
      expect((applied as Applied).visibleChange, isTrue);
      expect(applied.activityKind, ActivityKind.refired);
      expect(applied.state!.status, EventStatus.firing);
      expect(applied.state!.fence.compareTo(newer.orderingKey), 0);
      expect(applied.state!.version, 2);
    });

    test('ord_2_stale_problem_does_not_resurrect_resolved_alert', () {
      final older = _observation(status: EventStatus.firing, source: 100);
      final newer = _observation(status: EventStatus.resolved, source: 200);
      final firstNew = _created(newer);
      expect(firstNew.status, EventStatus.resolved);
      final stale = decideTransition(firstNew, older);
      expect(stale, isA<Stale>());
      expect(stale.activityKind, isNull);
      expect(stale.state!.status, EventStatus.resolved);
      expect(stale.state!.fence.compareTo(newer.orderingKey), 0);
      expect(stale.state!.version, 1);

      final applied = decideTransition(_created(older), newer);
      expect(applied, isA<Applied>());
      expect((applied as Applied).visibleChange, isTrue);
      expect(applied.activityKind, ActivityKind.resolved);
      expect(applied.state!.status, EventStatus.resolved);
      expect(applied.state!.fence.compareTo(newer.orderingKey), 0);
      expect(applied.state!.version, 2);
    });

    test('ord_3_equal_source_times_ordered_deterministically', () {
      for (final byId in [false, true]) {
        final earlier = _observation(
          status: EventStatus.firing,
          source: 100,
          observed: 200,
          id: byId ? _lowId : _highId,
          severity: EventSeverity.warning,
          summary: 'Old summary',
        );
        final later = _observation(
          status: EventStatus.resolved,
          source: 100,
          observed: byId ? 200 : 201,
          id: byId ? _highId : _lowId,
          severity: EventSeverity.critical,
          summary: 'New summary',
        );
        final forward = decideTransition(_created(earlier), later);
        final reverse = decideTransition(_created(later), earlier);
        expect(forward, isA<Applied>());
        expect(reverse, isA<Stale>());
        for (final result in [forward, reverse]) {
          expect(result.state!.status, EventStatus.resolved);
          expect(result.state!.severity, EventSeverity.critical);
          expect(result.state!.summary, 'New summary');
          expect(result.state!.fence.compareTo(later.orderingKey), 0);
        }
        expect(forward.state!.version, 2);
        expect(reverse.state!.version, 1);
      }
    });

    test(
      'nanosecond fence rejects an older source despite later observation',
      () {
        final newer = _observation(
          status: EventStatus.firing,
          source: 100,
          sourceNanos: 900,
          observed: 200,
        );
        final older = _observation(
          status: EventStatus.resolved,
          source: 100,
          sourceNanos: 800,
          observed: 201,
        );
        final result = decideTransition(_created(newer), older);
        expect(result, isA<Stale>());
        expect(result.state!.status, EventStatus.firing);
        expect(result.state!.fence.compareTo(newer.orderingKey), 0);
        expect(result.state!.version, 1);
        expect(result.state!.lastObservedAt, _time(201));
      },
    );

    test('newer_repeat_with_no_visible_change', () {
      final initial = _observation(status: EventStatus.firing, source: 100);
      final repeat = _observation(
        status: EventStatus.firing,
        source: 200,
        observed: 1001,
      );
      final result = decideTransition(_created(initial), repeat);
      expect(result, isA<Applied>());
      expect((result as Applied).visibleChange, isFalse);
      expect(result.activityKind, isNull);
      expect(result.state!.fence.compareTo(repeat.orderingKey), 0);
      expect(result.state!.lastObservedAt, _time(1001));
      expect(result.state!.version, 1);
    });

    test('informational_observation', () {
      final info = _observation(status: EventStatus.info, source: 200);
      final empty = decideTransition(null, info);
      expect(empty, isA<Ignored>());
      expect(empty.state, isNull);
      expect(empty.activityKind, isNull);

      final state = _created(
        _observation(status: EventStatus.firing, source: 100),
      );
      final existing = decideTransition(state, info);
      expect(existing, isA<Ignored>());
      expect(existing.state, same(state));
      expect(existing.activityKind, isNull);
    });

    test('severity and display changes each advance version and activity', () {
      final initial = _created(
        _observation(status: EventStatus.firing, source: 100),
      );
      final severity = decideTransition(
        initial,
        _observation(
          status: EventStatus.firing,
          source: 200,
          severity: EventSeverity.critical,
        ),
      );
      expect(severity, isA<Applied>());
      expect((severity as Applied).visibleChange, isTrue);
      expect(severity.activityKind, ActivityKind.severityChanged);
      expect(severity.state!.severity, EventSeverity.critical);
      expect(severity.state!.version, 2);

      final display = decideTransition(
        severity.state,
        _observation(
          status: EventStatus.firing,
          source: 300,
          severity: EventSeverity.critical,
          summary: 'Disk critically full',
          generatorUrl: null,
        ),
      );
      expect(display, isA<Applied>());
      expect((display as Applied).visibleChange, isTrue);
      expect(display.activityKind, ActivityKind.displayChanged);
      expect(display.state!.summary, 'Disk critically full');
      expect(display.state!.generatorUrl, isNull);
      expect(display.state!.version, 3);
    });

    test('equal fence is stale and observed time never moves backward', () {
      final observation = _observation(
        status: EventStatus.firing,
        source: 100,
        observed: 200,
      );
      final state = _created(observation);
      final equal = decideTransition(state, observation);
      expect(equal, isA<Stale>());
      expect(equal.state!.version, 1);
      expect(equal.state!.lastObservedAt, _time(200));
      final newer = _observation(
        status: EventStatus.firing,
        source: 101,
        observed: 199,
      );
      final applied = decideTransition(equal.state, newer);
      expect(applied, isA<Applied>());
      expect(applied.state!.lastObservedAt, _time(200));
    });
  });
}
