import '../event_generated/correlia/event/v1/event_bounds.dart';

import 'validation.dart';

/// A protobuf-range UTC instant with nanosecond precision.
final class EventTimestamp {
  const EventTimestamp._(this.seconds, this.nanos);

  /// Parses strict offset-bearing RFC3339 without calendar normalization.
  factory EventTimestamp.parse(String value, {String path = 'timestamp'}) {
    const length = CanonicalEventBounds.CanonicalEventReportedSourceTimeLength;
    validateText(value, path, min: length.min ?? 0, max: length.max!);
    final match = _rfc3339.firstMatch(value);
    if (match == null || match.end != value.length) {
      throw EventFieldError(path, 'invalid_timestamp');
    }
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final hour = int.parse(match[4]!);
    final minute = int.parse(match[5]!);
    final second = int.parse(match[6]!);
    if (year < 1 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31 ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      throw EventFieldError(path, 'invalid_timestamp');
    }
    final local = DateTime.utc(year, month, day, hour, minute, second);
    if (local.year != year || local.month != month || local.day != day) {
      throw EventFieldError(path, 'invalid_timestamp');
    }
    var offset = 0;
    if (match[8] != 'Z') {
      final zoneHour = int.parse(match[10]!);
      final zoneMinute = int.parse(match[11]!);
      if (zoneHour > 23 || zoneMinute > 59) {
        throw EventFieldError(path, 'invalid_timestamp');
      }
      offset = (zoneHour * 60 + zoneMinute) * 60 * (match[9] == '+' ? 1 : -1);
    }
    return EventTimestamp.fromParts(
      local.millisecondsSinceEpoch ~/ 1000 - offset,
      int.parse((match[7] ?? '').padRight(9, '0')),
      path: path,
    );
  }

  /// Validates UTC seconds and nonnegative nanoseconds in the protobuf domain.
  factory EventTimestamp.fromParts(
    int seconds,
    int nanos, {
    String path = 'timestamp',
  }) {
    if (seconds < -62135596800 ||
        seconds > 253402300799 ||
        nanos < 0 ||
        nanos > 999999999) {
      throw EventFieldError(path, 'invalid_timestamp');
    }
    return EventTimestamp._(seconds, nanos);
  }

  static final _rfc3339 = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|([+-])(\d{2}):(\d{2}))$',
  );

  /// Whole UTC seconds since the Unix epoch.
  final int seconds;

  /// Nanoseconds after the beginning of the second.
  final int nanos;

  /// Encodes the instant as canonical UTC RFC3339.
  String toRfc3339() {
    final date = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    );
    final base =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}T${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
    if (nanos == 0) return '${base}Z';
    final digits = nanos % 1000000 == 0
        ? 3
        : nanos % 1000 == 0
        ? 6
        : 9;
    return '$base.${nanos.toString().padLeft(9, '0').substring(0, digits)}Z';
  }

  @override
  bool operator ==(Object other) =>
      other is EventTimestamp &&
      seconds == other.seconds &&
      nanos == other.nanos;

  @override
  int get hashCode => Object.hash(seconds, nanos);
}
