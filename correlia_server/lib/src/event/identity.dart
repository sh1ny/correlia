import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/data.dart';
import 'package:uuid/uuid.dart';

import '../event_generated/correlia/event/v1/event_bounds.dart';

import 'event_timestamp.dart';
import 'validation.dart';

export 'event_timestamp.dart';
export 'validation.dart';

/// The frozen v1 observation UUID namespace, distinct from alert namespaces.
const observationUuidNamespace = 'f36aac0f-16fa-46db-951b-bb578b323aed';

const _maxOriginalIdentityBytes = 1048576;
const _observationLength =
    CanonicalEventBounds.CanonicalEventObservationKeyLength;
const _identityCount = CanonicalEventBounds.CanonicalEventIdentityFieldsLength;
const _identityKeyLength =
    CanonicalEventBounds.CanonicalEventIdentityFieldsKeyLength;
const _inlineLength = CanonicalEventBounds.IdentityComponentRawByteLength;
const _rawLength = CanonicalEventBounds.IdentityComponentRawLength;
const _digestLength = CanonicalEventBounds.IdentityComponentSha256Length;
const _statuses = {'firing', 'resolved', 'info'};
const _severities = {'critical', 'error', 'warning', 'info', 'unknown'};

/// Validated source scope used by pure identity operations.
final class SourceContext {
  /// Constructs source scope, defaulting the alert namespace to source instance.
  factory SourceContext({
    required String sourceInstance,
    required String sourceKind,
    String? namespace,
    String tenant = 'default',
  }) {
    validateUuid(sourceInstance, 'source_instance');
    const kindLength = CanonicalEventBounds.ObserverSourceKindLength;
    validateText(
      sourceKind,
      'source_kind',
      min: kindLength.min!,
      max: kindLength.max!,
      pattern: CanonicalEventBounds.ObserverSourceKindPattern,
    );
    final effectiveNamespace = namespace ?? sourceInstance;
    const namespaceLength = CanonicalEventBounds.CanonicalEventNamespaceLength;
    validateText(
      effectiveNamespace,
      'namespace',
      min: namespaceLength.min!,
      max: namespaceLength.max!,
    );
    if (tenant != CanonicalEventBounds.CanonicalEventTenantConst) {
      throw const EventFieldError('tenant', 'unsupported_tenant');
    }
    return SourceContext._(
      sourceInstance,
      sourceKind,
      effectiveNamespace,
      tenant,
    );
  }

  const SourceContext._(
    this.sourceInstance,
    this.sourceKind,
    this.namespace,
    this.tenant,
  );

  /// The canonical registered source UUID.
  final String sourceInstance;

  /// The integration's stable lowercase kind token.
  final String sourceKind;

  /// The operator-controlled alert namespace.
  final String namespace;

  /// The v1 single-tenant identifier.
  final String tenant;
}

/// A tagged inline value or full-original-value SHA-256 digest.
final class IdentityComponent {
  IdentityComponent._(this.raw, this.digest);

  /// Preserves a small original value or hashes its full UTF-8 representation.
  factory IdentityComponent.fromText(String value) {
    validateText(
      value,
      'identity_component',
      min: _rawLength.min!,
      max: _maxOriginalIdentityBytes,
    );
    if (value.length > _maxOriginalIdentityBytes) {
      throw const EventFieldError('identity_component', 'too_large');
    }
    final encoded = utf8.encode(value);
    if (encoded.length > _maxOriginalIdentityBytes) {
      throw const EventFieldError('identity_component', 'too_large');
    }
    return encoded.length <= _inlineLength.max!
        ? IdentityComponent._(value, null)
        : IdentityComponent._(
            null,
            Uint8List.fromList(
              sha256.convert(encoded).bytes,
            ).asUnmodifiableView(),
          );
  }

  /// Constructs the digest form from exactly 32 bytes without retaining aliases.
  factory IdentityComponent.fromDigest(Uint8List digest) {
    if (digest.length != _digestLength.max!) {
      throw const EventFieldError(
        'identity_component.sha256',
        'invalid_length',
      );
    }
    return IdentityComponent._(
      null,
      Uint8List.fromList(digest).asUnmodifiableView(),
    );
  }

  /// The original inline text, absent for digest components.
  final String? raw;

  /// The unmodifiable original-value digest, absent for inline components.
  final Uint8List? digest;

  /// Encodes the component with its unambiguous raw or hash tag.
  Uint8List encode() {
    final data = raw == null ? digest! : utf8.encode(raw!);
    final bytes = Uint8List(data.length + 1);
    bytes[0] = raw == null ? 1 : 0;
    bytes.setRange(1, bytes.length, data);
    return bytes;
  }
}

/// Validates original inputs before hashing, preserving every selected identity field.
Map<String, IdentityComponent> identityComponents(Map<String, String> values) {
  if (values.length < _identityCount.min! ||
      values.length > _identityCount.max!) {
    throw const EventFieldError('identity_fields', 'invalid_count');
  }
  final fields = IdentityFieldsBuilder();
  for (final MapEntry(:key, :value) in values.entries) {
    fields.add(key, value);
  }
  return fields.finish();
}

/// Validates and budgets original identity values before hashing them.
final class IdentityFieldsBuilder {
  var _total = 0;
  final _encoded = <(String, String, Uint8List)>[];

  /// Validates one pair before retaining its original bytes.
  void add(String key, String value) {
    validateText(
      key,
      'identity_fields.key',
      min: _identityKeyLength.min!,
      max: _identityKeyLength.max!,
    );
    // Bound work before allocating UTF-8, and validate the whole collection
    // before hashing any original value.
    if (value.length > _maxOriginalIdentityBytes) {
      throw EventFieldError('identity_fields.$key', 'too_large');
    }
    validateText(
      value,
      'identity_fields.$key',
      min: _rawLength.min!,
      max: _maxOriginalIdentityBytes,
    );
    final bytes = utf8.encode(value);
    final nextTotal = _total + utf8.encode(key).length + bytes.length;
    if (nextTotal > _maxOriginalIdentityBytes) {
      throw const EventFieldError('identity_fields', 'too_large');
    }
    _total = nextTotal;
    _encoded.add((key, value, bytes));
  }

  /// Returns the canonical components for the validated pairs.
  Map<String, IdentityComponent> finish() => Map.unmodifiable({
    for (final (key, value, bytes) in _encoded)
      key: bytes.length <= _inlineLength.max!
          ? IdentityComponent._(value, null)
          : IdentityComponent._(
              null,
              Uint8List.fromList(
                sha256.convert(bytes).bytes,
              ).asUnmodifiableView(),
            ),
  });
}

/// Selects Alertmanager labels after validating all labels and explicit exclusions.
Map<String, IdentityComponent> selectAlertmanagerIdentity(
  Map<String, String> labels, {
  List<String> excludedLabels = const [],
}) {
  if (labels.length > CanonicalEventBounds.CanonicalEventLabelsLength.max! ||
      excludedLabels.length > _identityCount.max!) {
    throw const EventFieldError('labels', 'invalid_count');
  }
  final excluded = <String>{};
  for (final key in excludedLabels) {
    validateText(
      key,
      'excluded_labels',
      min: _identityKeyLength.min!,
      max: _identityKeyLength.max!,
    );
    if (!excluded.add(key)) {
      throw const EventFieldError('excluded_labels', 'duplicate');
    }
  }
  for (final MapEntry(:key, :value) in labels.entries) {
    const keyLength = CanonicalEventBounds.CanonicalEventLabelsKeyLength;
    validateText(key, 'labels.key', min: keyLength.min!, max: keyLength.max!);
    // Identity helpers allow long originals for hashing; the normalized payload's
    // separate labels map must still obey its display/evidence value bound.
    validateText(
      value,
      'labels.$key',
      min: _rawLength.min!,
      max: _maxOriginalIdentityBytes,
    );
  }
  return identityComponents({
    for (final MapEntry(:key, :value) in labels.entries)
      if (!excluded.contains(key)) key: value,
  });
}

/// Encodes ordered tuples using unsigned big-endian counts and UTF-8 byte lengths.
Uint8List canonicalTuple(List<(String, Uint8List)> pairs) {
  final names = <String>{};
  final encodedNames = <Uint8List>[];
  var length = 4;
  for (final (name, value) in pairs) {
    validateText(
      name,
      'tuple.name',
      min: _identityKeyLength.min!,
      max: _identityKeyLength.max!,
    );
    if (!names.add(name)) {
      throw const EventFieldError('tuple.name', 'duplicate');
    }
    final encoded = utf8.encode(name);
    encodedNames.add(encoded);
    length += 8 + encoded.length + value.length;
    if (length > _maxOriginalIdentityBytes) {
      throw const EventFieldError('tuple', 'too_large');
    }
  }
  final bytes = Uint8List(length);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, pairs.length);
  var offset = 4;
  for (var i = 0; i < pairs.length; i++) {
    final name = encodedNames[i];
    final value = pairs[i].$2;
    view.setUint32(offset, name.length);
    offset += 4;
    bytes.setRange(offset, offset + name.length, name);
    offset += name.length;
    view.setUint32(offset, value.length);
    offset += 4;
    bytes.setRange(offset, offset + value.length, value);
    offset += value.length;
  }
  return bytes;
}

/// Computes the alert fingerprint independently of arrival or normalized state.
String alertFingerprint(
  SourceContext source,
  Map<String, IdentityComponent> fields,
) {
  if (fields.length < _identityCount.min! ||
      fields.length > _identityCount.max!) {
    throw const EventFieldError('identity_fields', 'invalid_count');
  }
  final encoded = <(String, Uint8List, Uint8List)>[];
  for (final MapEntry(:key, :value) in fields.entries) {
    validateText(
      key,
      'identity_fields.key',
      min: _identityKeyLength.min!,
      max: _identityKeyLength.max!,
    );
    encoded.add((key, utf8.encode(key), value.encode()));
  }
  encoded.sort((a, b) => _compareBytes(a.$2, b.$2));
  return sha256
      .convert(
        canonicalTuple([
          ('domain', utf8.encode('correlia.alert.v1')),
          ('tenant', utf8.encode(source.tenant)),
          ('namespace', utf8.encode(source.namespace)),
          ('source_kind', utf8.encode(source.sourceKind)),
          (
            'identity_fields',
            canonicalTuple([
              for (final (key, _, value) in encoded) (key, value),
            ]),
          ),
        ]),
      )
      .toString();
}

/// A bounded, domain-checked, delivery-independent observation key.
final class ObservationKey {
  ObservationKey._(Uint8List bytes, {this.reportedSourceTime})
    : bytes = bytes.asUnmodifiableView();

  /// Constructs a source-native key from original evidence, never a body digest.
  factory ObservationKey.native(String key) {
    if (key.isEmpty) {
      throw const EventFieldError('observation_key.key', 'required');
    }
    return ObservationKey._(
      canonicalTuple([
        ('domain', utf8.encode('correlia.native.v1')),
        ('key', IdentityComponent.fromText(key).encode()),
      ]),
    );
  }

  /// Constructs a key from status and original Alertmanager timestamp evidence.
  factory ObservationKey.alertmanager({
    required String status,
    String? startsAt,
    String? endsAt,
  }) {
    _validateStatus(status);
    if (startsAt == null && endsAt == null) {
      throw const EventFieldError('observation_key', 'missing_evidence');
    }
    Uint8List presence(String? value, String path) {
      if (value == null) return Uint8List(1);
      EventTimestamp.parse(value, path: path);
      return Uint8List.fromList([1, ...utf8.encode(value)]);
    }

    return ObservationKey._(
      canonicalTuple([
        ('domain', utf8.encode('correlia.alertmanager.v1')),
        ('status', utf8.encode(status)),
        ('starts_at', presence(startsAt, 'observation_key.starts_at')),
        ('ends_at', presence(endsAt, 'observation_key.ends_at')),
      ]),
    );
  }

  /// Constructs fallback identity only when reported source-time evidence exists.
  factory ObservationKey.fallback({
    required String status,
    required String severity,
    required String? reportedSourceTime,
  }) {
    _validateStatus(status);
    if (!_severities.contains(severity)) {
      throw const EventFieldError('observation_key.severity', 'invalid_enum');
    }
    if (reportedSourceTime == null) {
      throw const EventFieldError(
        'observation_key.reported_source_time',
        'missing_evidence',
      );
    }
    EventTimestamp.parse(
      reportedSourceTime,
      path: 'observation_key.reported_source_time',
    );
    return ObservationKey._(
      canonicalTuple([
        ('domain', utf8.encode('correlia.fallback.v1')),
        ('status', utf8.encode(status)),
        ('severity', utf8.encode(severity)),
        ('reported_source_time', utf8.encode(reportedSourceTime)),
      ]),
      reportedSourceTime: reportedSourceTime,
    );
  }

  /// Reads and validates a canonical key's exact domain, order and component shape.
  factory ObservationKey.fromBytes(Uint8List input) {
    if (input.length > _observationLength.max!) {
      throw const EventFieldError('observation_key', 'too_large');
    }
    final pairs = _readTuple(input);
    String text(int index) {
      try {
        return utf8.decode(pairs[index].$2);
      } on FormatException {
        throw const EventFieldError('observation_key', 'invalid_utf8');
      }
    }

    ObservationKey reconstructed;
    switch (pairs.map((pair) => pair.$1).toList()) {
      case ['domain', 'key'] when text(0) == 'correlia.native.v1':
        final value = pairs[1].$2;
        if (value.isEmpty) {
          throw const EventFieldError('observation_key.key', 'required');
        }
        if (value[0] == 0 &&
            value.length > 1 &&
            value.length <= _inlineLength.max! + 1) {
          String original;
          try {
            original = utf8.decode(value.sublist(1));
          } on FormatException {
            throw const EventFieldError('observation_key.key', 'invalid_utf8');
          }
          reconstructed = ObservationKey.native(original);
        } else if (value[0] == 1 && value.length == _digestLength.max! + 1) {
          reconstructed = ObservationKey._(
            canonicalTuple([pairs[0], ('key', Uint8List.fromList(value))]),
          );
        } else {
          throw const EventFieldError(
            'observation_key.key',
            'invalid_component',
          );
        }
      case ['domain', 'status', 'starts_at', 'ends_at']
          when text(0) == 'correlia.alertmanager.v1':
        String? presence(int index) {
          final value = pairs[index].$2;
          if (value.length == 1 && value[0] == 0) return null;
          if (value.length > 1 && value[0] == 1) {
            try {
              return utf8.decode(value.sublist(1));
            } on FormatException {
              throw const EventFieldError('observation_key', 'invalid_utf8');
            }
          }
          throw const EventFieldError('observation_key', 'invalid_presence');
        }
        reconstructed = ObservationKey.alertmanager(
          status: text(1),
          startsAt: presence(2),
          endsAt: presence(3),
        );
      case ['domain', 'status', 'severity', 'reported_source_time']
          when text(0) == 'correlia.fallback.v1':
        reconstructed = ObservationKey.fallback(
          status: text(1),
          severity: text(2),
          reportedSourceTime: text(3),
        );
      default:
        throw const EventFieldError('observation_key', 'invalid_domain');
    }
    return reconstructed;
  }

  /// The immutable complete canonical key bytes.
  final Uint8List bytes;

  /// Original reported text for fallback evidence, never normalized for hashing.
  final String? reportedSourceTime;
}

/// Computes an observation UUID without allocating generations or applying effects.
String observationId({
  required SourceContext source,
  required String fingerprint,
  required ObservationKey key,
  int generation = 0,
}) {
  validateSha256(fingerprint, 'fingerprint');
  const generationRange = CanonicalEventBounds.PipelineGenerationUint32;
  if (generation < generationRange.min! || generation > generationRange.max!) {
    throw const EventFieldError('pipeline.generation', 'out_of_range');
  }
  final name = canonicalTuple([
    ('domain', utf8.encode('correlia.observation.v1')),
    ('source_instance', utf8.encode(source.sourceInstance)),
    ('fingerprint', utf8.encode(fingerprint)),
    ('observation_key', key.bytes),
    ('generation', utf8.encode('$generation')),
  ]);
  return const Uuid().v5FromBytes(
    observationUuidNamespace,
    name,
    config: const V5Options(false, null),
  );
}

/// Computes a source-scoped transport retry key, preferring valid supplied headers.
String transportKey({
  required String sourceInstance,
  String? idempotencyKey,
  Uint8List? bodySha256,
}) {
  validateUuid(sourceInstance, 'source_instance');
  final List<(String, Uint8List)> pairs;
  if (idempotencyKey != null) {
    validateText(idempotencyKey, 'idempotency_key', min: 1, max: 256);
    pairs = [
      ('domain', utf8.encode('correlia.transport.header.v1')),
      ('source_instance', utf8.encode(sourceInstance)),
      ('key', utf8.encode(idempotencyKey)),
    ];
  } else {
    if (bodySha256 == null || bodySha256.length != 32) {
      throw const EventFieldError('body_sha256', 'invalid_length');
    }
    pairs = [
      ('domain', utf8.encode('correlia.transport.body.v1')),
      ('source_instance', utf8.encode(sourceInstance)),
      ('body_sha256', bodySha256),
    ];
  }
  return sha256.convert(canonicalTuple(pairs)).toString();
}

void _validateStatus(String status) {
  if (!_statuses.contains(status)) {
    throw const EventFieldError('observation_key.status', 'invalid_enum');
  }
}

int _compareBytes(Uint8List a, Uint8List b) {
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

List<(String, Uint8List)> _readTuple(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  var offset = 0;
  int length() {
    if (offset + 4 > bytes.length) {
      throw const EventFieldError('observation_key', 'invalid_tuple');
    }
    final value = view.getUint32(offset);
    offset += 4;
    return value;
  }

  Uint8List value() {
    final count = length();
    if (count > bytes.length - offset) {
      throw const EventFieldError('observation_key', 'invalid_tuple');
    }
    final result = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return result;
  }

  final count = length();
  if (count > 4) {
    throw const EventFieldError('observation_key', 'invalid_tuple');
  }
  final result = <(String, Uint8List)>[];
  for (var i = 0; i < count; i++) {
    String name;
    try {
      name = utf8.decode(value());
    } on FormatException {
      throw const EventFieldError('observation_key', 'invalid_utf8');
    }
    result.add((name, value()));
  }
  if (offset != bytes.length) {
    throw const EventFieldError('observation_key', 'invalid_tuple');
  }
  return result;
}
