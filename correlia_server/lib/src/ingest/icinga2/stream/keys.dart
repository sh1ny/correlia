/// Key encodings `icinga2.check.v1` and `icinga2.stream.<type>.v1` freeze the
/// field order and shortest round-trip double text. Changing either changes
/// published event ids and requires a new domain version.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../../event/event_timestamp.dart';
import '../../../event/validation.dart';
import '../facts.dart';

/// A parsed Icinga time and its exact microsecond ordering time.
final class StreamKeyTime {
  const StreamKeyTime._(this.value);

  /// Reads a required JSON number in the accepted time interval [1, 2^33).
  factory StreamKeyTime.read(
    Map<String, Object?> object,
    String key,
    String path,
  ) {
    if (!object.containsKey(key)) throw EventFieldError(path, 'missing_field');
    final raw = object[key];
    if (raw is! num) throw EventFieldError(path, 'invalid_type');
    final value = raw.toDouble();
    if (!(value >= 1 && value < 8589934592)) {
      throw EventFieldError(path, 'out_of_range');
    }
    return StreamKeyTime._(value);
  }

  /// The parsed binary value; `toString()` yields the frozen wire text.
  final double value;

  /// Floors the exact binary value, not the rounded double product by 10^6.
  EventTimestamp toTimestamp() {
    final bits = (ByteData(8)..setFloat64(0, value)).getUint64(0);
    final shift = 1075 - (bits >> 52);
    final fractionalBits = bits & ((1 << shift) - 1);
    // Every accepted value has at least 20 fractional significand bits. Split
    // before multiplying so neither partial product can overflow a VM int.
    const limb = 20;
    final scaled =
        ((fractionalBits >> limb) * 1000000) +
        (((fractionalBits & ((1 << limb) - 1)) * 1000000) >> limb);
    return EventTimestamp.fromParts(
      value.toInt(),
      (scaled >> (shift - limb)) * 1000,
    );
  }
}

/// Returns the shared StateChange/sync key of a check result.
String icingaCheckKey(
  Icinga2State state,
  Icinga2StateType type,
  StreamKeyTime start,
  StreamKeyTime end,
) => jsonEncode([
  'icinga2.check.v1',
  state.wire,
  type.wire,
  '${start.value}',
  '${end.value}',
]);

/// Returns the key of one acknowledgement, downtime, or flap event.
String icingaStreamEventKey(
  String type,
  StreamKeyTime timestamp,
  Object? detail,
) => jsonEncode([
  'icinga2.stream.${type.toLowerCase()}.v1',
  type,
  '${timestamp.value}',
  detail,
]);
