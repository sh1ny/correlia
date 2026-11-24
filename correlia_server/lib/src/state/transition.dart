import '../event/canonical_event.dart';
import '../event/event_timestamp.dart';
import 'ordering_key.dart';

/// The visible change recorded in the append-only ledger.
enum ActivityKind {
  created,
  resolved,
  refired,
  severityChanged,
  displayChanged,
}

/// An eligible observation's state and display projection.
final class Observation {
  const Observation({
    required this.status,
    required this.severity,
    required this.summary,
    required this.orderingKey,
    this.sourceInstance = '',
    this.firingSince,
    this.generatorUrl,
  });

  final EventStatus status;
  final EventSeverity severity;
  final String summary;
  final String sourceInstance;
  final DateTime? firingSince;
  final String? generatorUrl;
  final OrderingKey orderingKey;
}

/// The authoritative values compared by the pure transition function.
final class AlertState {
  const AlertState({
    required this.status,
    required this.severity,
    required this.summary,
    required this.sourceInstance,
    required this.firingSince,
    required this.generatorUrl,
    required this.fence,
    required this.version,
    required this.lastObservedAt,
  });

  final EventStatus status;
  final EventSeverity severity;
  final String summary;
  final String sourceInstance;
  final DateTime? firingSince;
  final String? generatorUrl;
  final OrderingKey fence;
  final int version;
  final EventTimestamp lastObservedAt;
}

/// A fenced observation's state effect and optional activity entry.
sealed class TransitionResult {
  const TransitionResult(this.state, this.activityKind);
  final AlertState? state;
  final ActivityKind? activityKind;
}

/// The first state for a fingerprint.
final class Created extends TransitionResult {
  const Created(AlertState state) : super(state, ActivityKind.created);
}

/// A newer observation, with activity only for a visible change.
final class Applied extends TransitionResult {
  const Applied(
    AlertState state, {
    required this.visibleChange,
    ActivityKind? activityKind,
  }) : super(state, activityKind);
  final bool visibleChange;
}

/// An observation that advances freshness but cannot pass the fence.
final class Stale extends TransitionResult {
  const Stale(AlertState state) : super(state, null);
}

/// An informational observation with no state effect.
final class Ignored extends TransitionResult {
  const Ignored(AlertState? state) : super(state, null);
}

/// Evaluates an eligible observation without database or clock dependencies.
TransitionResult decideTransition(AlertState? state, Observation observation) {
  if (observation.status == EventStatus.info) return Ignored(state);
  final observed = observation.orderingKey.observedAt;
  final lastObserved =
      state == null || compareTimestamps(observed, state.lastObservedAt) > 0
      ? observed
      : state.lastObservedAt;
  if (state != null && observation.orderingKey.compareTo(state.fence) <= 0) {
    return Stale(
      AlertState(
        status: state.status,
        severity: state.severity,
        summary: state.summary,
        sourceInstance: state.sourceInstance,
        firingSince: state.firingSince,
        generatorUrl: state.generatorUrl,
        fence: state.fence,
        version: state.version,
        lastObservedAt: lastObserved,
      ),
    );
  }
  final ActivityKind? kind;
  if (state == null) {
    kind = ActivityKind.created;
  } else if (state.status != observation.status) {
    kind = observation.status == EventStatus.resolved
        ? ActivityKind.resolved
        : ActivityKind.refired;
  } else if (state.severity != observation.severity) {
    kind = ActivityKind.severityChanged;
  } else if (state.summary != observation.summary ||
      state.sourceInstance != observation.sourceInstance ||
      state.firingSince != observation.firingSince ||
      state.generatorUrl != observation.generatorUrl) {
    kind = ActivityKind.displayChanged;
  } else {
    kind = null;
  }
  final next = AlertState(
    status: observation.status,
    severity: observation.severity,
    summary: observation.summary,
    sourceInstance: observation.sourceInstance,
    firingSince: observation.firingSince,
    generatorUrl: observation.generatorUrl,
    fence: observation.orderingKey,
    version: (state?.version ?? 0) + (kind == null ? 0 : 1),
    lastObservedAt: lastObserved,
  );
  return state == null
      ? Created(next)
      : Applied(next, visibleChange: kind != null, activityKind: kind);
}

/// Whether stream evidence can reserve a key and pass the alert fence.
enum StreamEligibility { ready, late, futureDated }

/// The single primary outcome of one stream or sync item.
enum StreamOutcome {
  applied,
  stale,
  duplicateObservation,
  late,
  futureDated,
  confirmed,
  repaired,
  tombstoned,
  softInfo,
  informational,
}

/// A state decision and the evidence the caller must retain atomically.
final class StreamDecision {
  const StreamDecision._(
    this.outcome,
    this.state, {
    this.transition,
    this.keepsEvent = false,
    this.diverged = false,
  });

  final StreamOutcome outcome;
  final AlertState? state;

  /// Null when the item must not write any alert state.
  final TransitionResult? transition;
  final bool keepsEvent;
  final bool diverged;
}

/// Evaluates an observation against locked state and its key reservation.
///
/// A null observation represents a SOFT problem already excluded by policy.
/// Ineligible evidence takes precedence over an existing key and cannot
/// refresh state. Divergence compares against the result after this item.
StreamDecision decideStreamTransition(
  AlertState? state,
  Observation? observation, {
  bool reconcile = false,
  bool duplicate = false,
  StreamEligibility eligibility = StreamEligibility.ready,
}) {
  if (observation == null) {
    return StreamDecision._(StreamOutcome.softInfo, state);
  }
  final diverged =
      reconcile &&
      (state?.status != observation.status ||
          state?.severity != observation.severity);
  if (eligibility != StreamEligibility.ready) {
    return StreamDecision._(
      eligibility == StreamEligibility.late
          ? StreamOutcome.late
          : StreamOutcome.futureDated,
      state,
      diverged: diverged,
    );
  }
  if (duplicate) {
    final next = state == null || observation.status == EventStatus.info
        ? state
        : _advanceFreshness(state, observation.orderingKey);
    return StreamDecision._(
      StreamOutcome.duplicateObservation,
      next,
      transition: next == null || identical(next, state) ? null : Stale(next),
      diverged: diverged,
    );
  }
  final transition = decideTransition(state, observation);
  if (transition is Stale) {
    return StreamDecision._(
      StreamOutcome.stale,
      transition.state,
      transition: transition,
      keepsEvent: !reconcile,
      diverged: diverged,
    );
  }
  if (transition is Ignored) {
    return StreamDecision._(
      StreamOutcome.informational,
      state,
      keepsEvent: true,
    );
  }
  if (reconcile &&
      state == null &&
      observation.status == EventStatus.resolved) {
    final tombstone = transition.state!;
    return StreamDecision._(
      StreamOutcome.tombstoned,
      tombstone,
      transition: Applied(tombstone, visibleChange: false),
    );
  }
  if (reconcile && state != null && !diverged) {
    final confirmed = _advanceFreshness(
      state,
      observation.orderingKey,
      advanceFence: true,
    );
    return StreamDecision._(
      StreamOutcome.confirmed,
      confirmed,
      transition: Applied(confirmed, visibleChange: false),
    );
  }
  return StreamDecision._(
    reconcile && state != null ? StreamOutcome.repaired : StreamOutcome.applied,
    transition.state,
    transition: transition,
    keepsEvent: true,
  );
}

AlertState _advanceFreshness(
  AlertState state,
  OrderingKey key, {
  bool advanceFence = false,
}) {
  final fresher = compareTimestamps(key.observedAt, state.lastObservedAt) > 0;
  if (!fresher && !advanceFence) return state;
  return AlertState(
    status: state.status,
    severity: state.severity,
    summary: state.summary,
    sourceInstance: state.sourceInstance,
    firingSince: state.firingSince,
    generatorUrl: state.generatorUrl,
    fence: advanceFence ? key : state.fence,
    version: state.version,
    lastObservedAt: fresher ? key.observedAt : state.lastObservedAt,
  );
}
