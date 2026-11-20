import '../../event/event_timestamp.dart';

/// An instant read from the webhook's fixed time text, exact to the microsecond.
final class Icinga2Time {
  /// Wraps whole [microseconds] since the Unix epoch.
  const Icinga2Time(this.microseconds);

  /// Whole microseconds since the Unix epoch.
  final int microseconds;

  /// The same instant as a canonical timestamp.
  EventTimestamp toTimestamp({String path = 'timestamp'}) =>
      EventTimestamp.fromParts(
        microseconds ~/ 1000000,
        microseconds % 1000000 * 1000,
        path: path,
      );

  @override
  bool operator ==(Object other) =>
      other is Icinga2Time && other.microseconds == microseconds;

  @override
  int get hashCode => microseconds.hashCode;
}

/// The Icinga 2 object a fact describes: a host, or a service of a host.
final class Icinga2Object {
  /// Creates a host object, or a service object when [service] is given.
  const Icinga2Object({required this.host, this.service});

  /// The host name, complete and unaltered.
  final String host;

  /// The service name, absent for a host object.
  final String? service;
}

/// A host or service state name as Icinga 2 reports it.
enum Icinga2State {
  up('UP'),
  down('DOWN'),
  unreachable('UNREACHABLE'),
  ok('OK'),
  warning('WARNING'),
  critical('CRITICAL'),
  unknown('UNKNOWN');

  const Icinga2State(this.wire);

  /// The name in the webhook document.
  final String wire;

  /// Whether the state is a host state.
  bool get isHostState => switch (this) {
    up || down || unreachable => true,
    ok || warning || critical || unknown => false,
  };

  /// The state when it is a recovery (host UP or service OK).
  bool get isRecovered => this == up || this == ok;
}

/// Whether the object's problem state is confirmed.
enum Icinga2StateType {
  soft('SOFT'),
  hard('HARD');

  const Icinga2StateType(this.wire);

  /// The name in the webhook document.
  final String wire;
}

/// Icinga 2's own notification type strings, unchanged.
enum Icinga2NotificationType {
  problem('PROBLEM'),
  recovery('RECOVERY'),
  acknowledgement('ACKNOWLEDGEMENT'),
  downtimeStart('DOWNTIMESTART'),
  downtimeEnd('DOWNTIMEEND'),
  downtimeCancelled('DOWNTIMECANCELLED'),
  flappingStart('FLAPPINGSTART'),
  flappingEnd('FLAPPINGEND'),
  custom('CUSTOM');

  const Icinga2NotificationType(this.wire);

  /// The name in the webhook document.
  final String wire;
}

/// One delivery's evidence, before it becomes a canonical event.
sealed class Icinga2Fact {
  const Icinga2Fact({
    required this.object,
    required this.state,
    required this.stateType,
    required this.lastStateChange,
    required this.notificationType,
    required this.notificationTime,
  });

  /// The host or service the delivery is about.
  final Icinga2Object object;

  /// The object's state when the command ran.
  final Icinga2State state;

  /// Whether that state is HARD or SOFT.
  final Icinga2StateType stateType;

  /// The object's last state change time.
  final Icinga2Time lastStateChange;

  /// Icinga 2's notification type.
  final Icinga2NotificationType notificationType;

  /// The time the command read its clock.
  final Icinga2Time notificationTime;
}

/// A `PROBLEM` or `RECOVERY` delivery: an observation of the object's state.
final class StateFact extends Icinga2Fact {
  /// Creates a state observation carrying the live check [output].
  const StateFact({
    required super.object,
    required super.state,
    required super.stateType,
    required super.lastStateChange,
    required super.notificationType,
    required super.notificationTime,
    this.output,
  });

  /// The live check output, absent when the object has none.
  final String? output;
}

/// A delivery that is informational whatever state it carries.
sealed class NotificationFact extends Icinga2Fact {
  const NotificationFact({
    required super.object,
    required super.state,
    required super.stateType,
    required super.lastStateChange,
    required super.notificationType,
    required super.notificationTime,
    this.author,
    this.comment,
  });

  /// The delivered author, absent when the delivery carries none.
  final String? author;

  /// The delivered comment, absent when the delivery carries none.
  final String? comment;
}

/// An acknowledgement.
final class AckFact extends NotificationFact {
  /// Creates an acknowledgement fact.
  const AckFact({
    required super.object,
    required super.state,
    required super.stateType,
    required super.lastStateChange,
    required super.notificationType,
    required super.notificationTime,
    super.author,
    super.comment,
  });
}

/// A downtime start, end or cancellation.
final class DowntimeFact extends NotificationFact {
  /// Creates a downtime fact.
  const DowntimeFact({
    required super.object,
    required super.state,
    required super.stateType,
    required super.lastStateChange,
    required super.notificationType,
    required super.notificationTime,
    super.author,
    super.comment,
  });
}

/// A flapping start or end.
final class FlappingFact extends NotificationFact {
  /// Creates a flapping fact.
  const FlappingFact({
    required super.object,
    required super.state,
    required super.stateType,
    required super.lastStateChange,
    required super.notificationType,
    required super.notificationTime,
    super.author,
    super.comment,
  });
}

/// A `CUSTOM` notification.
final class CommentFact extends NotificationFact {
  /// Creates a comment fact.
  const CommentFact({
    required super.object,
    required super.state,
    required super.stateType,
    required super.lastStateChange,
    required super.notificationType,
    required super.notificationTime,
    super.author,
    super.comment,
  });
}
