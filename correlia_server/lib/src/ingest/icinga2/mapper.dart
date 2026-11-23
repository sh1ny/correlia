import 'dart:convert';

import '../../event/canonical_event.dart';
import '../../event/identity.dart';
import '../../event_generated/correlia/event/v1/event_bounds.dart';
import 'facts.dart';

/// The canonical JSON array an observation of [fact] is keyed by.
///
/// A state notification is keyed by the object's state, state type and last
/// state change in microseconds, so re-notifications of one state are one
/// observation and SOFT and HARD are two. Every other notification is one
/// command execution: type, notification time and the delivered author. All
/// elements are strings and the domain is versioned.
String icinga2KeyText(Icinga2Fact fact) => jsonEncode(switch (fact) {
  StateFact() => [
    'icinga2.notify.v1',
    fact.state.wire,
    fact.stateType.wire,
    '${fact.lastStateChange.microseconds}',
  ],
  NotificationFact() => [
    'icinga2.notify.${fact.notificationType.wire}.v1',
    fact.notificationType.wire,
    '${fact.notificationTime.microseconds}',
    fact.author ?? '',
  ],
});

/// The kind, status and severity a fact projects to.
typedef _Classification = (EventKind, EventStatus, EventSeverity);

_Classification _classify(Icinga2Fact fact) => switch (fact) {
  // The state fields decide, never the notification type (a delayed RECOVERY
  // finds the object's state at the time the command ran).
  StateFact(:final state, :final stateType) =>
    state.isRecovered
        ? (EventKind.alert, EventStatus.resolved, EventSeverity.info)
        // No notification follows a SOFT problem, so it cannot alert.
        : stateType == Icinga2StateType.soft
        ? (EventKind.state, EventStatus.info, EventSeverity.info)
        : (EventKind.alert, EventStatus.firing, _severity(state)),
  AckFact() => (EventKind.ack, EventStatus.info, EventSeverity.info),
  DowntimeFact() => (EventKind.downtime, EventStatus.info, EventSeverity.info),
  FlappingFact() => (EventKind.state, EventStatus.info, EventSeverity.info),
  CommentFact() => (EventKind.comment, EventStatus.info, EventSeverity.info),
};

EventSeverity _severity(Icinga2State state) => switch (state) {
  Icinga2State.down ||
  Icinga2State.unreachable ||
  Icinga2State.critical => EventSeverity.critical,
  Icinga2State.warning => EventSeverity.warning,
  Icinga2State.unknown => EventSeverity.unknown,
  Icinga2State.up || Icinga2State.ok => EventSeverity.info,
};

/// Maps one fact to one canonical event.
///
/// The summary comes from the object and its state only (UNREACHABLE shown as
/// DOWN), and there is no `starts_at` and no generator link, so a new
/// observation of an unchanged state is no visible change to the alert. Check
/// output is the description of a state event only; a notification event's
/// description is its comment. Identity uses the complete names.
CanonicalEvent mapIcinga2Fact(
  Icinga2Fact fact, {
  required SourceContext source,
  required EventRawReference raw,
  required EventPipeline pipeline,
  required EventTimestamp observedAt,
  required EventTimestamp processedAt,
}) {
  final (kind, status, severity) = _classify(fact);
  final object = fact.object;
  final name = switch (object.service) {
    final service? => '${object.host}!$service',
    null => object.host,
  };
  final shown = fact.state == Icinga2State.unreachable
      ? Icinga2State.down
      : fact.state;
  final sourceTime = switch (fact) {
    StateFact() => fact.lastStateChange,
    NotificationFact() => fact.notificationTime,
  }.toTimestamp();
  final description = switch (fact) {
    StateFact(:final output) => output,
    NotificationFact(:final comment) => comment,
  };
  final author = switch (fact) {
    StateFact() => null,
    NotificationFact(:final author) => author,
  };
  return CanonicalEvent.create(
    source: source,
    kind: kind,
    status: status,
    severity: severity,
    summary: normalizeDisplayText(
      '$name ${shown.wire}',
      maxScalars: CanonicalEventBounds.CanonicalEventSummaryLength.max!,
      singleLine: true,
    ),
    description: description == null || description.isEmpty
        ? null
        : normalizeDisplayText(
            description,
            maxScalars:
                CanonicalEventBounds.CanonicalEventDescriptionLength.max!,
          ),
    severityOriginal: fact.state.wire,
    identityFields: identityComponents({
      'host': object.host,
      'service': ?object.service,
    }),
    observationKey: ObservationKey.native(icinga2KeyText(fact)),
    observedAt: observedAt,
    processedAt: processedAt,
    raw: raw,
    pipeline: pipeline,
    annotations: {
      'icinga2.notification_type': fact.notificationType.wire,
      if (author != null && author.isNotEmpty)
        'icinga2.notification_author': normalizeDisplayText(
          author,
          maxScalars:
              CanonicalEventBounds.CanonicalEventAnnotationsValueLength.max!,
        ),
    },
    sourceTime: sourceTime,
    reportedSourceTime: sourceTime.toRfc3339(),
  );
}
