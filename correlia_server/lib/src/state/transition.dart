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
