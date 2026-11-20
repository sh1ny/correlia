import 'dart:convert';
import 'dart:typed_data';

import '../../event/validation.dart';
import '../body_depth.dart';
import 'facts.dart';

/// The only document format this parser reads.
const icinga2WebhookFormat = 'correlia.icinga2.v1';

/// The first instant outside the canonical timestamp domain (year 10000).
const _secondsLimit = 253402300800;

const _knownFields = {
  'format',
  'object_type',
  'host',
  'service',
  'state',
  'state_type',
  'last_state_change',
  'output',
  'notification_type',
  'notification_author',
  'notification_comment',
  'notification_time',
};

final _timeForm = RegExp(r'^[1-9][0-9]{0,11}\.[0-9]{6}$');

/// Parses one Icinga2 webhook document v1 into a typed fact.
///
/// Throws [EventFieldError] for every malformed body. Failure paths name only
/// documented fields: an unknown key is reported as the structural path `*`,
/// never by its name, so sender-chosen text cannot reach stored diagnostics.
Icinga2Fact parseIcinga2Webhook(Uint8List bytes) {
  checkBodyDepth(bytes);
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw const EventFieldError('body', 'invalid_json');
  }
  if (decoded is! Map<String, Object?>) {
    throw const EventFieldError('body', 'invalid_type');
  }
  final document = decoded;
  // The format comes first: a document of another version may carry fields
  // this version does not know, and "unsupported version" is the useful answer.
  if (_string(document, 'format') != icinga2WebhookFormat) {
    throw const EventFieldError('format', 'unsupported_version');
  }
  if (document.keys.any((key) => !_knownFields.contains(key))) {
    throw const EventFieldError('*', 'unknown_field');
  }
  final objectType = switch (_string(document, 'object_type')) {
    'host' => false,
    'service' => true,
    _ => throw const EventFieldError('object_type', 'invalid_object_type'),
  };
  final host = _name(_string(document, 'host'), 'host');
  final service = objectType
      ? _name(_string(document, 'service'), 'service')
      : document.containsKey('service')
      ? throw const EventFieldError('service', 'unexpected_field')
      : null;
  final stateText = _string(document, 'state');
  final state = Icinga2State.values
      .where((value) => value.wire == stateText)
      .where((value) => value.isHostState != objectType)
      .firstOrNull;
  if (state == null) throw const EventFieldError('state', 'invalid_state');
  final stateTypeText = _string(document, 'state_type');
  final stateType = Icinga2StateType.values
      .where((value) => value.wire == stateTypeText)
      .firstOrNull;
  if (stateType == null) {
    throw const EventFieldError('state_type', 'invalid_state_type');
  }
  final lastStateChange = _time(document, 'last_state_change');
  final typeText = _string(document, 'notification_type');
  final type = Icinga2NotificationType.values
      .where((value) => value.wire == typeText)
      .firstOrNull;
  if (type == null) {
    throw const EventFieldError('notification_type', 'unsupported_type');
  }
  final notificationTime = _time(document, 'notification_time');
  final output = _optionalText(document, 'output');
  final author = _optionalText(document, 'notification_author');
  final comment = _optionalText(document, 'notification_comment');
  final object = Icinga2Object(host: host, service: service);
  return switch (type) {
    Icinga2NotificationType.problem ||
    Icinga2NotificationType.recovery => StateFact(
      object: object,
      state: state,
      stateType: stateType,
      lastStateChange: lastStateChange,
      notificationType: type,
      notificationTime: notificationTime,
      output: output,
    ),
    Icinga2NotificationType.acknowledgement => AckFact(
      object: object,
      state: state,
      stateType: stateType,
      lastStateChange: lastStateChange,
      notificationType: type,
      notificationTime: notificationTime,
      author: author,
      comment: comment,
    ),
    Icinga2NotificationType.downtimeStart ||
    Icinga2NotificationType.downtimeEnd ||
    Icinga2NotificationType.downtimeCancelled => DowntimeFact(
      object: object,
      state: state,
      stateType: stateType,
      lastStateChange: lastStateChange,
      notificationType: type,
      notificationTime: notificationTime,
      author: author,
      comment: comment,
    ),
    Icinga2NotificationType.flappingStart ||
    Icinga2NotificationType.flappingEnd => FlappingFact(
      object: object,
      state: state,
      stateType: stateType,
      lastStateChange: lastStateChange,
      notificationType: type,
      notificationTime: notificationTime,
      author: author,
      comment: comment,
    ),
    Icinga2NotificationType.custom => CommentFact(
      object: object,
      state: state,
      stateType: stateType,
      lastStateChange: lastStateChange,
      notificationType: type,
      notificationTime: notificationTime,
      author: author,
      comment: comment,
    ),
  };
}

/// A present string field, or `missing_field` / `invalid_type` on [key].
String _string(Map<String, Object?> document, String key) {
  if (!document.containsKey(key)) throw EventFieldError(key, 'missing_field');
  return switch (document[key]) {
    final String value => value,
    _ => throw EventFieldError(key, 'invalid_type'),
  };
}

String? _optionalText(Map<String, Object?> document, String key) {
  if (!document.containsKey(key)) return null;
  final value = _string(document, key);
  _requireStorable(value, key, controls: false);
  return value;
}

/// A host or service name: no control character, and never empty.
String _name(String value, String path) {
  if (value.isEmpty) throw EventFieldError(path, 'invalid_text');
  _requireStorable(value, path, controls: true);
  return value;
}

/// Rejects text PostgreSQL cannot store: U+0000 and unpaired surrogates, and,
/// for names, every control character (U+0000-U+001F, U+007F).
void _requireStorable(String value, String path, {required bool controls}) {
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    final bad =
        unit == 0 ||
        (controls && (unit < 0x20 || unit == 0x7f)) ||
        (unit >= 0xdc00 && unit <= 0xdfff) ||
        (unit >= 0xd800 &&
            unit <= 0xdbff &&
            !(i + 1 < units.length &&
                units[i + 1] >= 0xdc00 &&
                units[i + 1] <= 0xdfff));
    if (bad) throw EventFieldError(path, 'invalid_text');
    if (unit >= 0xd800 && unit <= 0xdbff) i++;
  }
}

/// A time string in the fixed six-decimal form, exact to the microsecond.
///
/// The two digit groups are converted by integer arithmetic; no floating-point
/// value is ever involved, so distinct texts stay distinct microseconds.
Icinga2Time _time(Map<String, Object?> document, String key) {
  final text = _string(document, key);
  if (!_timeForm.hasMatch(text)) throw EventFieldError(key, 'invalid_time');
  final dot = text.indexOf('.');
  final seconds = int.parse(text.substring(0, dot));
  if (seconds >= _secondsLimit) throw EventFieldError(key, 'out_of_range');
  return Icinga2Time(seconds * 1000000 + int.parse(text.substring(dot + 1)));
}
