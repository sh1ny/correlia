import 'package:correlia_server/src/event/canonical_event.dart';
import 'package:correlia_server/src/event/event_timestamp.dart';
import 'package:correlia_server/src/state/ordering_key.dart';
import 'package:correlia_server/src/state/transition.dart';
import 'package:test/test.dart';

EventTimestamp instant(int seconds) => EventTimestamp.fromParts(seconds, 0);

Observation observation(
  int start, {
  int? receipt,
  EventStatus status = EventStatus.firing,
  EventSeverity? severity,
  String source = 'stream',
  String id = 'check',
}) => Observation(
  status: status,
  severity:
      severity ??
      (status == EventStatus.firing
          ? EventSeverity.critical
          : EventSeverity.info),
  summary: 'reported by $source',
  sourceInstance: source,
  orderingKey: OrderingKey.fromSource(
    sourceTime: instant(start),
    observedAt: instant(receipt ?? start),
    eventId: id,
    skewAllowance: const Duration(minutes: 5),
  ),
);

void main() {
  final firing = decideTransition(
    null,
    observation(600, source: 'webhook'),
  ).state!;

  test('sync_agrees_with_the_alert', () {
    final result = decideStreamTransition(
      firing,
      observation(660),
      reconcile: true,
    );
    expect(result.outcome, StreamOutcome.confirmed);
    expect(result.keepsEvent, isFalse);
    expect(result.transition?.activityKind, isNull);
    expect(result.state?.version, firing.version);
    expect(result.state?.summary, firing.summary);
    expect(result.state?.sourceInstance, 'webhook');
    expect(result.state?.fence.effectiveAt.seconds, 660);
    expect(result.state?.lastObservedAt.seconds, 660);
    expect(result.diverged, isFalse);
  });

  test('sync_repairs_a_missed_recovery', () {
    final result = decideStreamTransition(
      firing,
      observation(660, status: EventStatus.resolved),
      reconcile: true,
    );
    expect(result.outcome, StreamOutcome.repaired);
    expect(result.keepsEvent, isTrue);
    expect(result.transition?.activityKind, ActivityKind.resolved);
    expect(result.state?.status, EventStatus.resolved);
    expect(result.state?.version, firing.version + 1);
    expect(result.diverged, isFalse);
  });

  test('recovered_object_with_no_alert', () {
    final result = decideStreamTransition(
      null,
      observation(660, status: EventStatus.resolved),
      reconcile: true,
    );
    expect(result.outcome, StreamOutcome.tombstoned);
    expect(result.keepsEvent, isFalse);
    expect(result.transition?.activityKind, isNull);
    expect(result.state?.status, EventStatus.resolved);
    expect(result.state?.fence.effectiveAt.seconds, 660);
    final older = decideStreamTransition(
      result.state,
      observation(600, receipt: 720),
    );
    expect(older.outcome, StreamOutcome.stale);
    expect(older.state?.status, EventStatus.resolved);
  });

  test('stale_reconcile_observation_that_disagrees', () {
    final result = decideStreamTransition(
      firing,
      observation(540, receipt: 660, status: EventStatus.resolved),
      reconcile: true,
    );
    expect(result.outcome, StreamOutcome.stale);
    expect(result.keepsEvent, isFalse);
    expect(result.diverged, isTrue);
    expect(result.state?.status, EventStatus.firing);
    expect(result.state?.fence, firing.fence);
    expect(result.state?.lastObservedAt.seconds, 660);
  });

  test('late_reconcile_observation', () {
    final late = decideStreamTransition(
      firing,
      observation(540, status: EventStatus.resolved),
      reconcile: true,
      eligibility: StreamEligibility.late,
    );
    expect(late.outcome, StreamOutcome.late);
    expect(late.diverged, isTrue);
    expect(late.state, same(firing));
    expect(late.keepsEvent, isFalse);
    final future = decideStreamTransition(
      firing,
      observation(660, severity: EventSeverity.warning),
      reconcile: true,
      eligibility: StreamEligibility.futureDated,
    );
    expect(future.outcome, StreamOutcome.futureDated);
    expect(future.diverged, isTrue);
    expect(future.state, same(firing));
    expect(future.keepsEvent, isFalse);
  });
}
