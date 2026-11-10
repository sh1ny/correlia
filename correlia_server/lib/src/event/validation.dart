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
