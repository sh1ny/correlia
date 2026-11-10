import 'dart:convert';
import 'dart:typed_data';

import 'canonical_event.dart';
import 'identity.dart';

/// The media type of a structured CloudEvents JSON envelope.
const _envelopeMediaType = 'application/cloudevents+json';

/// The media type of the canonical payload carried in the envelope's data.
const _dataMediaType = 'application/json';

/// The CloudEvents specification version implemented by this codec.
const _specVersion = '1.0';

/// The prefix of the Correlia source URI reference.
const _sourcePrefix = 'urn:correlia:source:';

/// The prefix of the Correlia CloudEvents type attribute.
const _typePrefix = 'io.correlia.';

/// The suffix of the Correlia CloudEvents type attribute.
const _typeSuffix = '.v1';

/// The maximum size of a serialized structured envelope.
const _maxEnvelopeBytes = 262144;

/// The maximum container nesting depth of a decoded envelope.
const _maxJsonDepth = 16;

/// The maximum number of unknown envelope attributes.
const _maxExtensionAttributes = 32;

/// The maximum length of an unknown attribute name.
const _maxExtensionNameScalars = 128;

/// The maximum length of an unknown attribute's string value.
const _maxExtensionValueScalars = 1024;

/// The smallest signed 32-bit integer.
const _minInt32 = -2147483648;

/// The largest signed 32-bit integer.
const _maxInt32 = 2147483647;

/// The envelope attributes this codec derives or checks.
const _knownAttributes = <String>{
  'specversion',
  'id',
  'source',
  'type',
  'datacontenttype',
  'dataschema',
  'subject',
  'time',
  'partitionkey',
  'traceparent',
  'correliatenant',
  'data',
};

/// The CloudEvents attributes this codec refuses instead of ignoring.
const _refusedAttributes = <String>{'data_base64'};

/// A CloudEvents 1.0.2 structured JSON envelope around a canonical event.
///
/// The codec derives every standard attribute from the validated payload and
/// checks a decoded envelope against the payload it carries. Unknown
/// CloudEvents extension attributes are validated and then ignored: they never
/// reach the payload, never change its validation scope and are never
/// re-emitted.
final class CloudEvent {
  /// Wraps a validated canonical event in a derived structured envelope.
  ///
  /// The supplied [traceparent] is validated as a W3C trace context before the
  /// envelope is returned.
  factory CloudEvent({required CanonicalEvent event, String? traceparent}) {
    if (traceparent != null) _validateTraceparent(traceparent, 'traceparent');
    final bytes = _encode(event, traceparent);
    return CloudEvent._(event, traceparent, bytes);
  }

  const CloudEvent._(this.event, this.traceparent, this._bytes);

  /// Reads and validates a structured CloudEvents JSON envelope.
  ///
  /// Throws an [EventFieldError] when the document exceeds the size or depth
  /// bounds, carries a malformed known attribute, disagrees with the payload
  /// it carries or contains an invalid unknown extension attribute.
  factory CloudEvent.decode(Uint8List bytes) {
    if (bytes.length > _maxEnvelopeBytes) {
      throw const EventFieldError('event', 'event_too_large');
    }
    final document = _decodeJson(_decodeUtf8(bytes));
    if (document is! Map<String, Object?>) {
      throw const EventFieldError('event', 'invalid_envelope');
    }
    _checkDepth(document, 1);

    final specversion = _requireString(document, 'specversion');
    if (specversion != _specVersion) {
      throw const EventFieldError('specversion', 'unsupported_specversion');
    }
    final datacontenttype = _requireString(document, 'datacontenttype');
    if (datacontenttype != _dataMediaType) {
      throw const EventFieldError(
        'datacontenttype',
        'unsupported_content_type',
      );
    }
    final dataschema = _requireString(document, 'dataschema');
    parseDataschema(dataschema, path: 'dataschema');
    final id = _requireString(document, 'id');
    final source = _requireString(document, 'source');
    final type = _requireString(document, 'type');
    final subject = _optionalString(document, 'subject');
    final partitionkey = _optionalString(document, 'partitionkey');
    final correliatenant = _optionalString(document, 'correliatenant');
    final time = _optionalString(document, 'time');
    final traceparent = _optionalString(document, 'traceparent');
    _checkUnknownAttributes(document);

    final rawData = document['data'];
    if (rawData == null) throw const EventFieldError('data', 'required');
    if (rawData is! Map<String, Object?>) {
      throw const EventFieldError('data', 'invalid_type');
    }

    final event = CanonicalEvent.fromJson(
      rawData,
      sourceDataschema: dataschema,
    );
    _checkAgreement(
      event,
      id: id,
      source: source,
      type: type,
      subject: subject,
      partitionkey: partitionkey,
      correliatenant: correliatenant,
      time: time,
    );
    return CloudEvent(event: event, traceparent: traceparent);
  }

  /// The validated canonical event carried by this envelope.
  final CanonicalEvent event;

  /// The optional W3C trace context of this envelope.
  final String? traceparent;

  final Uint8List _bytes;

  /// The media type of this structured envelope.
  String get mediaType => _envelopeMediaType;

  /// Returns the immutable current-version structured JSON representation.
  ///
  /// Size validation and encoding occur before the envelope is accepted.
  Uint8List toJsonBytes() => _bytes;

  static Uint8List _encode(CanonicalEvent event, String? traceparent) {
    if (traceparent == null) return defaultStructuredEventBytes(event);
    final bytes = utf8.encode(
      jsonEncode(projectStructuredEvent(event, traceparent: traceparent)),
    );
    if (bytes.length > _maxEnvelopeBytes) {
      throw const EventFieldError('event', 'event_too_large');
    }
    return bytes.asUnmodifiableView();
  }

  /// Checks the envelope's identities against the payload it carries.
  static void _checkAgreement(
    CanonicalEvent event, {
    required String id,
    required String source,
    required String type,
    String? subject,
    String? partitionkey,
    String? correliatenant,
    String? time,
  }) {
    if (id != event.eventId) {
      throw const EventFieldError('id', 'identity_mismatch');
    }
    if (source != '$_sourcePrefix${event.source.sourceInstance}') {
      throw const EventFieldError('source', 'identity_mismatch');
    }
    if (type != '$_typePrefix${event.kind.name}$_typeSuffix') {
      throw const EventFieldError('type', 'identity_mismatch');
    }
    if (subject != null && subject != event.fingerprint) {
      throw const EventFieldError('subject', 'identity_mismatch');
    }
    if (partitionkey != null && partitionkey != event.fingerprint) {
      throw const EventFieldError('partitionkey', 'identity_mismatch');
    }
    if (correliatenant != null && correliatenant != event.tenant) {
      throw const EventFieldError('correliatenant', 'identity_mismatch');
    }
    if (time == null) return;
    final sourceTime = event.sourceTime;
    if (sourceTime == null) {
      throw const EventFieldError('time', 'identity_mismatch');
    }
    if (EventTimestamp.parse(time, path: 'time') != sourceTime) {
      throw const EventFieldError('time', 'identity_mismatch');
    }
  }

  /// Validates the unknown envelope attributes and then ignores them.
  static void _checkUnknownAttributes(Map<String, Object?> document) {
    var unknown = 0;
    for (final MapEntry(:key, :value) in document.entries) {
      if (_knownAttributes.contains(key)) continue;
      if (_refusedAttributes.contains(key)) {
        throw EventFieldError(key, 'unsupported_attribute');
      }
      validateText(
        key,
        key,
        min: 1,
        max: _maxExtensionNameScalars,
        pattern: r'^[a-z0-9]+$',
      );
      if (value == null) continue;
      unknown++;
      if (unknown > _maxExtensionAttributes) {
        throw const EventFieldError('event', 'invalid_count');
      }
      _validateExtensionValue(key, value);
    }
  }

  /// Accepts only the CloudEvents scalar types an extension attribute may carry.
  static void _validateExtensionValue(String name, Object value) {
    if (value is bool) return;
    if (value is int) {
      if (value < _minInt32 || value > _maxInt32) {
        throw EventFieldError(name, 'out_of_range');
      }
      return;
    }
    if (value is double) {
      if (!value.isFinite || value != value.truncateToDouble()) {
        throw EventFieldError(name, 'invalid_number');
      }
      if (value < _minInt32 || value > _maxInt32) {
        throw EventFieldError(name, 'out_of_range');
      }
      return;
    }
    if (value is String) {
      validateText(value, name, max: _maxExtensionValueScalars);
      _rejectControlCharacters(value, name);
      return;
    }
    throw EventFieldError(name, 'invalid_type');
  }

  /// Rejects the characters a CloudEvents string value may not carry.
  static void _rejectControlCharacters(String value, String path) {
    for (final rune in value.runes) {
      if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) {
        throw EventFieldError(path, 'invalid_character');
      }
      if (rune >= 0xfdd0 && rune <= 0xfdef) {
        throw EventFieldError(path, 'invalid_character');
      }
      if ((rune & 0xfffe) == 0xfffe) {
        throw EventFieldError(path, 'invalid_character');
      }
    }
  }

  /// Validates a W3C trace context with nonzero trace and span identifiers.
  static void _validateTraceparent(String value, String path) {
    final match = _traceparent.firstMatch(value);
    if (match == null || match.end != value.length) {
      throw EventFieldError(path, 'invalid_format');
    }
    if (_isAllZeros(match[1]!) || _isAllZeros(match[2]!)) {
      throw EventFieldError(path, 'invalid_trace_id');
    }
  }

  /// Whether every character of a hexadecimal identifier is a zero digit.
  static bool _isAllZeros(String value) {
    for (final unit in value.codeUnits) {
      if (unit != 0x30) return false;
    }
    return true;
  }

  /// Rejects a document whose containers nest deeper than the bound.
  static void _checkDepth(Object? value, int depth) {
    final children = switch (value) {
      final Map<Object?, Object?> map => map.values,
      final List<Object?> list => list,
      _ => null,
    };
    if (children == null) return;
    if (depth > _maxJsonDepth) throw const EventFieldError('event', 'too_deep');
    for (final nested in children) {
      _checkDepth(nested, depth + 1);
    }
  }

  /// Reads a required string attribute.
  static String _requireString(Map<String, Object?> document, String name) {
    final value = document[name];
    if (value == null) throw EventFieldError(name, 'required');
    if (value is! String) throw EventFieldError(name, 'invalid_type');
    return value;
  }

  /// Reads an optional string attribute, rejecting an explicit null value.
  static String? _optionalString(Map<String, Object?> document, String name) {
    if (!document.containsKey(name)) return null;
    final value = document[name];
    if (value is! String) throw EventFieldError(name, 'invalid_type');
    return value;
  }

  /// Decodes UTF-8 bytes without accepting malformed sequences.
  static String _decodeUtf8(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const EventFieldError('event', 'invalid_utf8');
    }
  }

  /// Decodes a JSON document without accepting trailing content.
  static Object? _decodeJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      throw const EventFieldError('event', 'invalid_json');
    }
  }

  static final _traceparent = RegExp(
    r'^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$',
  );
}
