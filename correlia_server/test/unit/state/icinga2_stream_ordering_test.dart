import 'package:correlia_server/src/event/canonical_event.dart';
import 'package:correlia_server/src/state/transition.dart';
import 'package:test/test.dart';

import 'icinga2_reconcile_test.dart' show observation;

void main() {
  test('sync_of_an_already_streamed_change', () {
    final first = decideStreamTransition(null, observation(600));
    final copy = decideStreamTransition(
      first.state,
      observation(600, receipt: 660),
      reconcile: true,
      duplicate: true,
    );
    expect(copy.outcome, StreamOutcome.duplicateObservation);
    expect(copy.keepsEvent, isFalse);
    expect(copy.state?.fence, first.state?.fence);
    expect(copy.state?.lastObservedAt.seconds, 660);
    expect(copy.diverged, isFalse);
  });

  test('regressing_execution_end', () {
    final critical = decideStreamTransition(
      null,
      observation(600, id: 'end-840'),
    );
    final ok = decideStreamTransition(
      critical.state,
      observation(660, status: EventStatus.resolved, id: 'end-720'),
      reconcile: true,
    );
    expect(ok.outcome, StreamOutcome.repaired);
    expect(ok.state?.status, EventStatus.resolved);
    expect(ok.state?.fence.effectiveAt.seconds, 660);
  });

  test('three_observations_in_every_order', () {
    final inputs = [
      observation(600, id: 'critical'),
      observation(660, status: EventStatus.resolved, id: 'ok'),
      observation(720, severity: EventSeverity.warning, id: 'warning'),
    ];
    for (final order in [
      [0, 1, 2],
      [0, 2, 1],
      [1, 0, 2],
      [1, 2, 0],
      [2, 0, 1],
      [2, 1, 0],
    ]) {
      AlertState? state;
      for (final n in order) {
        state = decideStreamTransition(
          state,
          inputs[n],
          reconcile: n == 1,
        ).state;
      }
      expect(state?.status, EventStatus.firing, reason: '$order');
      expect(state?.severity, EventSeverity.warning);
      expect(state?.fence.effectiveAt.seconds, 720);
    }
  });

  test('icinga_2_clock_ahead_beyond_the_skew', () {
    final critical = observation(2400, receipt: 720, id: 'critical');
    final ok = observation(
      2460,
      receipt: 660,
      status: EventStatus.resolved,
      id: 'ok',
    );
    for (final order in [
      [critical, ok],
      [ok, critical],
    ]) {
      AlertState? state;
      for (final item in order) {
        state = decideStreamTransition(state, item).state;
      }
      expect(state?.fence.effectiveAt.seconds, 1020);
      final sync = decideStreamTransition(state, ok, reconcile: true);
      expect(sync.outcome, StreamOutcome.stale);
      expect(sync.diverged, isTrue);
      expect(sync.state?.status, EventStatus.firing);
    }
  });

  test('later_soft_result_under_hard_only', () {
    final resolved = decideStreamTransition(
      null,
      observation(600, status: EventStatus.resolved),
    ).state;
    final soft = decideStreamTransition(resolved, null, reconcile: true);
    expect(soft.outcome, StreamOutcome.softInfo);
    expect(soft.state, same(resolved));
    expect(soft.diverged, isFalse);
    expect(soft.keepsEvent, isFalse);
  });

  test('another_source_writes_the_same_alert', () {
    final older = decideStreamTransition(null, observation(600)).state;
    final newer = decideTransition(
      older,
      observation(660, source: 'webhook', status: EventStatus.resolved),
    ).state;
    final sync = decideStreamTransition(
      newer,
      observation(600, receipt: 720),
      reconcile: true,
    );
    expect(sync.diverged, isTrue);
    expect(sync.state?.sourceInstance, 'webhook');
    expect(sync.state?.fence.effectiveAt.seconds, 660);
  });

  test('sync_copy_among_equal_starts', () {
    final ok = observation(
      600,
      receipt: 660,
      status: EventStatus.resolved,
      id: 'ok',
    );
    final critical = observation(600, receipt: 720, id: 'critical');
    final first = decideStreamTransition(null, ok);
    final second = decideStreamTransition(first.state, critical);
    final copy = decideStreamTransition(
      second.state,
      observation(600, receipt: 780, status: EventStatus.resolved, id: 'ok'),
      reconcile: true,
      duplicate: true,
    );
    expect(second.state?.status, EventStatus.firing);
    expect(copy.diverged, isTrue);
    expect(copy.state?.fence, second.state?.fence);
    expect(copy.state?.version, second.state?.version);
  });

  for (final name in [
    'late_stream_copy_after_the_prompt_copy',
    'late_stream_copy_is_not_a_first_delivery',
    'late_copy_processed_before_the_prompt_copy',
    'prompt_copy_processed_first',
  ]) {
    test(name, () {
      final promptFirst =
          name == 'late_stream_copy_after_the_prompt_copy' ||
          name == 'prompt_copy_processed_first';
      final firing = decideStreamTransition(
        null,
        observation(540, id: 'problem'),
      ).state;
      final recovery = observation(600, status: EventStatus.resolved, id: 'ok');
      final initial = promptFirst
          ? decideStreamTransition(firing, recovery).state
          : firing;
      final old = decideStreamTransition(
        initial,
        observation(
          600,
          receipt: 700000,
          status: EventStatus.resolved,
          id: 'ok',
        ),
        duplicate: promptFirst,
        eligibility: StreamEligibility.late,
      );
      expect(old.outcome, StreamOutcome.late);
      expect(old.keepsEvent, isFalse);
      expect(old.state, same(initial));
      if (!promptFirst) {
        final eligible = decideStreamTransition(old.state, recovery);
        expect(eligible.keepsEvent, isTrue);
        expect(eligible.state?.status, EventStatus.resolved);
      }
    });
  }
}
