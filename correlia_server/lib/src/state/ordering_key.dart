import '../event/event_timestamp.dart';

/// Compares canonical instants without losing sub-microsecond precision.
int compareTimestamps(EventTimestamp a, EventTimestamp b) {
  final seconds = a.seconds.compareTo(b.seconds);
  return seconds == 0 ? a.nanos.compareTo(b.nanos) : seconds;
}

/// A deterministic fence over effective source time, receipt time and event id.
final class OrderingKey implements Comparable<OrderingKey> {
  OrderingKey({
    required this.effectiveAt,
    required this.observedAt,
    required String eventId,
  }) : eventId = eventId.toLowerCase();

  /// Clamps source clock skew without changing the source's reported instant.
  factory OrderingKey.fromSource({
    required EventTimestamp sourceTime,
    required EventTimestamp observedAt,
    required String eventId,
    required Duration skewAllowance,
  }) {
    final micros = skewAllowance.inMicroseconds;
    final nanos = observedAt.nanos + (micros % 1000000) * 1000;
    final seconds =
        observedAt.seconds + micros ~/ 1000000 + nanos ~/ 1000000000;
    // The clamp can extend past the canonical range, but the source cannot.
    final effective = seconds > 253402300799
        ? sourceTime
        : EventTimestamp.fromParts(seconds, nanos % 1000000000);
    return OrderingKey(
      effectiveAt: compareTimestamps(sourceTime, effective) <= 0
          ? sourceTime
          : effective,
      observedAt: observedAt,
      eventId: eventId,
    );
  }

  final EventTimestamp effectiveAt;
  final EventTimestamp observedAt;
  final String eventId;

  @override
  int compareTo(OrderingKey other) {
    final effective = compareTimestamps(effectiveAt, other.effectiveAt);
    if (effective != 0) return effective;
    final observed = compareTimestamps(observedAt, other.observedAt);
    return observed == 0 ? eventId.compareTo(other.eventId) : observed;
  }
}
