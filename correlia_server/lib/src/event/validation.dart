import 'dart:convert';

import '../event_generated/correlia/event/v1/event_bounds.dart';

/// A rejected canonical-event boundary input.
sealed class EventValidationError implements Exception {
  const EventValidationError(this.path, this.code);

  /// The rejected field's path.
  final String path;

  /// The stable machine-readable rejection code.
  final String code;

  @override
  String toString() => '$path: $code';
}

/// A field whose value violates the event contract.
final class EventFieldError extends EventValidationError {
  const EventFieldError(super.path, super.code);
}

/// A sender pointer token and whether the decoder traversed an array at it.
typedef EventPointerSegment = ({String token, bool arrayIndex});

/// A sender-field rejection whose raw pointer is never put in error text.
final class EventPointerError extends EventValidationError {
  EventPointerError(Iterable<EventPointerSegment> segments, String code)
    : segments = List.unmodifiable(segments),
      super('', code);

  /// The structured sender path; redact it before persisting any part of it.
  final List<EventPointerSegment> segments;
}

/// Renders an RFC 6901 path without splitting a token or exceeding 256 bytes.
String boundedEventPointer(Iterable<EventPointerSegment> segments) {
  final pointer = StringBuffer();
  var remaining = 256;
  for (final segment in segments) {
    final token = segment.token;
    if (token.length >= remaining)
      return pointer.isEmpty ? '/*' : pointer.toString();
    final escaped = token.replaceAll('~', '~0').replaceAll('/', '~1');
    final size = utf8.encode(escaped).length + 1;
    if (size > remaining) return pointer.isEmpty ? '/*' : pointer.toString();
    pointer.write('/');
    pointer.write(escaped);
    remaining -= size;
  }
  return pointer.toString();
}

/// Rejects malformed Unicode and strings outside their scalar bounds.
void validateText(
  String value,
  String path, {
  int min = 0,
  required int max,
  String? pattern,
}) {
  if (value.length > max * 2) throw EventFieldError(path, 'too_long');
  var count = 0;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length) throw EventFieldError(path, 'invalid_unicode');
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) {
        throw EventFieldError(path, 'invalid_unicode');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw EventFieldError(path, 'invalid_unicode');
    }
    if (++count > max) throw EventFieldError(path, 'too_long');
  }
  if (count < min) throw EventFieldError(path, 'required');
  if (pattern != null) {
    final match = RegExp(pattern).firstMatch(value);
    if (match == null || match.start != 0 || match.end != value.length) {
      throw EventFieldError(path, 'invalid_format');
    }
  }
}

/// Validates canonical lowercase UUID text without silently normalizing it.
void validateUuid(String value, String path, {bool version5 = false}) {
  const length = CanonicalEventBounds.ObserverSourceInstanceLength;
  validateText(
    value,
    path,
    min: length.min!,
    max: length.max!,
    pattern: CanonicalEventBounds.ObserverSourceInstancePattern,
  );
  if (version5 && (value[14] != '5' || !'89ab'.contains(value[19]))) {
    throw EventFieldError(path, 'invalid_format');
  }
}

/// Validates a lowercase SHA-256 hexadecimal digest.
void validateSha256(String value, String path) {
  const length = CanonicalEventBounds.CanonicalEventFingerprintLength;
  validateText(
    value,
    path,
    min: length.min!,
    max: length.max!,
    pattern: CanonicalEventBounds.CanonicalEventFingerprintPattern,
  );
}
