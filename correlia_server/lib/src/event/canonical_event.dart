import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart' as protobuf;

import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as time_pb;
import '../event_generated/correlia/event/v1/event.pb.dart' as pb;
import '../event_generated/correlia/event/v1/event_bounds.dart';
import 'identity.dart';

const _maxEventBytes = 262144;
const _currentSchema = 'urn:correlia:schema:event:1.0';
typedef _Length = ({int? min, int? max});

/// The part of a versioned input this reader could validate.
enum ValidationScope { exact, knownCoreOnly, unknown }

/// The semantic kind of a canonical event.
enum EventKind { alert, state, ack, downtime, comment, heartbeat }

/// The source observation's normalized status.
enum EventStatus { firing, resolved, info }

/// The source observation's normalized severity.
enum EventSeverity { critical, error, warning, info, unknown }

/// Validates schema metadata without inferring versions from payload contents.
ValidationScope parseDataschema(
  String value, {
  String path = 'source_dataschema',
}) {
  final match = _schemaPattern.firstMatch(value);
  if (match == null || match.end != value.length) {
    throw EventFieldError(path, 'invalid_format');
  }
  if (match[1] != '1') throw EventFieldError(path, 'unsupported_major');
  return match[2] == '0'
      ? ValidationScope.exact
      : ValidationScope.knownCoreOnly;
}

final _schemaPattern = RegExp(
  r'^urn:correlia:schema:event:(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
);

/// Immutable reporting-system metadata.
final class EventObserver {
  EventObserver({
    required this.sourceInstance,
    required this.sourceKind,
    this.name,
    this.version,
  }) {
    validateUuid(sourceInstance, 'observer.source_instance');
    _bounded(
      sourceKind,
      'observer.source_kind',
      CanonicalEventBounds.ObserverSourceKindLength,
      pattern: CanonicalEventBounds.ObserverSourceKindPattern,
    );
    if (name != null) {
      _bounded(name!, 'observer.name', CanonicalEventBounds.ObserverNameLength);
    }
    if (version != null) {
      _bounded(
        version!,
        'observer.version',
        CanonicalEventBounds.ObserverVersionLength,
      );
    }
  }

  /// The canonical source UUID.
  final String sourceInstance;

  /// The source's stable kind token.
  final String sourceKind;

  /// The optional reporting-system display name.
  final String? name;

  /// The optional reporting-system version.
  final String? version;
}

/// Immutable metadata referencing a raw body rather than embedding it.
final class EventRawReference {
  EventRawReference({
    required this.ref,
    required this.sha256,
    required this.size,
  }) {
    _bounded(ref, 'raw.ref', CanonicalEventBounds.RawReferenceRefLength);
    validateSha256(sha256, 'raw.sha256');
    _integer(size, 'raw.size', CanonicalEventBounds.RawReferenceSizeUint32);
  }

  /// The opaque non-secret raw-body reference.
  final String ref;

  /// The lowercase full-body SHA-256 digest.
  final String sha256;

  /// The referenced body's byte length, independent of the default ingress cap.
  final int size;
}

/// A bounded external HTTP or HTTPS reference.
final class EventLink {
  EventLink({required this.href, required this.relation, this.text}) {
    _bounded(
      href,
      'links.href',
      CanonicalEventBounds.LinkHrefLength,
      pattern: CanonicalEventBounds.LinkHrefPattern,
    );
    final uri = Uri.tryParse(href);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const EventFieldError('links.href', 'invalid_uri');
    }
    _bounded(
      relation,
      'links.relation',
      CanonicalEventBounds.LinkRelationLength,
    );
    if (text != null) {
      _bounded(text!, 'links.text', CanonicalEventBounds.LinkTextLength);
    }
  }

  /// The bounded HTTP or HTTPS URI.
  final String href;

  /// The relation of the target to this event.
  final String relation;

  /// The optional display text.
  final String? text;
}

/// A bounded, typed enrichment failure rather than an exception dump.
final class EventEnrichmentError {
  EventEnrichmentError({
    required this.stage,
    required this.code,
    required this.message,
  }) {
    _bounded(
      stage,
      'enrichment_error.stage',
      CanonicalEventBounds.EnrichmentErrorStageLength,
    );
    _bounded(
      code,
      'enrichment_error.code',
      CanonicalEventBounds.EnrichmentErrorCodeLength,
    );
    _bounded(
      message,
      'enrichment_error.message',
      CanonicalEventBounds.EnrichmentErrorMessageLength,
    );
  }

  /// The failing pipeline stage.
  final String stage;

  /// The stable machine-readable failure code.
  final String code;

  /// The bounded operator-facing explanation.
  final String message;
}

/// Immutable processing provenance and reprocess lineage.
final class EventPipeline {
  factory EventPipeline({
    required String version,
    int generation = 0,
    List<String> stagesApplied = const [],
    List<EventEnrichmentError> enrichmentErrors = const [],
    String? originalEventId,
  }) {
    _bounded(
      version,
      'pipeline.version',
      CanonicalEventBounds.PipelineVersionLength,
    );
    _integer(
      generation,
      'pipeline.generation',
      CanonicalEventBounds.PipelineGenerationUint32,
    );
    _length(
      stagesApplied.length,
      'pipeline.stages_applied',
      CanonicalEventBounds.PipelineStagesAppliedLength,
    );
    _length(
      enrichmentErrors.length,
      'pipeline.enrichment_errors',
      CanonicalEventBounds.PipelineEnrichmentErrorsLength,
    );
    for (var i = 0; i < stagesApplied.length; i++) {
      _bounded(
        stagesApplied[i],
        'pipeline.stages_applied[$i]',
        CanonicalEventBounds.PipelineStagesAppliedItemLength,
      );
    }
    if (generation > 0 && originalEventId == null) {
      throw const EventFieldError('pipeline.original_event_id', 'required');
    }
    if (generation == 0 && originalEventId != null) {
      throw const EventFieldError(
        'pipeline.original_event_id',
        'unexpected_lineage',
      );
    }
    if (originalEventId != null) {
      validateUuid(
        originalEventId,
        'pipeline.original_event_id',
        version5: true,
      );
    }
    return EventPipeline._(
      version,
      generation,
      List.unmodifiable(stagesApplied),
      List.unmodifiable(enrichmentErrors),
      originalEventId,
    );
  }
  const EventPipeline._(
    this.version,
    this.generation,
    this.stagesApplied,
    this.enrichmentErrors,
    this.originalEventId,
  );

  /// The immutable configuration version identifier.
  final String version;

  /// The uint32 processing generation; zero denotes initial processing or replay.
  final int generation;

  /// The immutable ordered list of applied stages.
  final List<String> stagesApplied;

  /// The immutable list of bounded enrichment failures.
  final List<EventEnrichmentError> enrichmentErrors;

  /// The original observation UUID for a positive reprocess generation.
  final String? originalEventId;
}

/// A fully validated immutable event backed by a frozen generated message.
final class CanonicalEvent {
  CanonicalEvent._(this._message, this._values, this.validationScope);

  /// Constructs an event from typed source evidence and immutable metadata.
  factory CanonicalEvent.create({
    required SourceContext source,
    required EventKind kind,
    required EventStatus status,
    required EventSeverity severity,
    required String summary,
    required Map<String, IdentityComponent> identityFields,
    required ObservationKey observationKey,
    required EventTimestamp observedAt,
    required EventTimestamp processedAt,
    required EventRawReference raw,
    required EventPipeline pipeline,
    EventObserver? observer,
    int? severityNumber,
    String? severityOriginal,
    String? dedupKey,
    String? description,
    Map<String, String> resource = const {},
    Map<String, String> labels = const {},
    Map<String, String> labelsOrigin = const {},
    Map<String, String> annotations = const {},
    List<EventLink> links = const [],
    EventTimestamp? startsAt,
    EventTimestamp? endsAt,
    EventTimestamp? sourceTime,
    String? reportedSourceTime,
    Map<String, String> extensions = const {},
  }) {
    _bounded(
      summary,
      'summary',
      CanonicalEventBounds.CanonicalEventSummaryLength,
    );
    if (description != null) {
      _bounded(
        description,
        'description',
        CanonicalEventBounds.CanonicalEventDescriptionLength,
      );
    }
    if (severityOriginal != null) {
      _bounded(
        severityOriginal,
        'severity_original',
        CanonicalEventBounds.CanonicalEventSeverityOriginalLength,
      );
    }
    if (dedupKey != null) {
      _bounded(
        dedupKey,
        'dedup_key',
        CanonicalEventBounds.CanonicalEventDedupKeyLength,
      );
    }
    if (severityNumber != null) {
      _integer(
        severityNumber,
        'severity_number',
        CanonicalEventBounds.CanonicalEventSeverityNumberUint32,
      );
    }
    _stringMap(
      resource,
      'resource',
      CanonicalEventBounds.CanonicalEventResourceLength,
      CanonicalEventBounds.CanonicalEventResourceKeyLength,
      CanonicalEventBounds.CanonicalEventResourceValueLength,
      present: true,
    );
    _stringMap(
      labels,
      'labels',
      CanonicalEventBounds.CanonicalEventLabelsLength,
      CanonicalEventBounds.CanonicalEventLabelsKeyLength,
      CanonicalEventBounds.CanonicalEventLabelsValueLength,
      present: true,
    );
    _stringMap(
      labelsOrigin,
      'labels_origin',
      CanonicalEventBounds.CanonicalEventLabelsOriginLength,
      CanonicalEventBounds.CanonicalEventLabelsOriginKeyLength,
      CanonicalEventBounds.CanonicalEventLabelsOriginValueLength,
      present: true,
    );
    for (final key in labelsOrigin.keys) {
      if (!labels.containsKey(key)) {
        throw EventFieldError('labels_origin.$key', 'unknown_label');
      }
    }
    _stringMap(
      annotations,
      'annotations',
      CanonicalEventBounds.CanonicalEventAnnotationsLength,
      CanonicalEventBounds.CanonicalEventAnnotationsKeyLength,
      CanonicalEventBounds.CanonicalEventAnnotationsValueLength,
      present: true,
    );
    _stringMap(
      extensions,
      'extensions',
      CanonicalEventBounds.CanonicalEventExtensionsLength,
      CanonicalEventBounds.CanonicalEventExtensionsKeyLength,
      CanonicalEventBounds.CanonicalEventExtensionsValueLength,
      present: true,
      keyPattern: CanonicalEventBounds.CanonicalEventExtensionsKeyPattern,
    );
    _length(
      links.length,
      'links',
      CanonicalEventBounds.CanonicalEventLinksLength,
    );
    if ((sourceTime == null) != (reportedSourceTime == null)) {
      throw const EventFieldError('reported_source_time', 'paired_presence');
    }
    if (reportedSourceTime != null &&
        EventTimestamp.parse(
              reportedSourceTime,
              path: 'reported_source_time',
            ) !=
            sourceTime) {
      throw const EventFieldError('reported_source_time', 'time_mismatch');
    }
    final fingerprint = alertFingerprint(source, identityFields);
    final eventId = observationId(
      source: source,
      fingerprint: fingerprint,
      key: observationKey,
      generation: pipeline.generation,
    );
    final effectiveObserver =
        observer ??
        EventObserver(
          sourceInstance: source.sourceInstance,
          sourceKind: source.sourceKind,
        );
    if (effectiveObserver.sourceInstance != source.sourceInstance ||
        effectiveObserver.sourceKind != source.sourceKind) {
      throw const EventFieldError('observer', 'identity_mismatch');
    }
    final message = pb.CanonicalEvent()
      ..eventId = eventId
      ..fingerprint = fingerprint
      ..tenant = source.tenant
      ..namespace = source.namespace
      ..kind = pb.EventKind.valueOf(kind.index + 1)!
      ..status = pb.EventStatus.valueOf(status.index + 1)!
      ..severity = pb.EventSeverity.valueOf(severity.index + 1)!
      ..summary = summary
      ..observer = pb.Observer(
        sourceInstance: effectiveObserver.sourceInstance,
        sourceKind: effectiveObserver.sourceKind,
        name: effectiveObserver.name,
        version: effectiveObserver.version,
      )
      ..raw = pb.RawReference(ref: raw.ref, sha256: raw.sha256, size: raw.size)
      ..pipeline = pb.Pipeline(
        version: pipeline.version,
        generation: pipeline.generation,
        stagesApplied: pipeline.stagesApplied,
        enrichmentErrors: [
          for (final error in pipeline.enrichmentErrors)
            pb.EnrichmentError(
              stage: error.stage,
              code: error.code,
              message: error.message,
            ),
        ],
        originalEventId: pipeline.originalEventId,
      )
      ..observationKey = observationKey.bytes;
    if (severityNumber != null) message.severityNumber = severityNumber;
    if (severityOriginal != null) message.severityOriginal = severityOriginal;
    if (dedupKey != null) message.dedupKey = dedupKey;
    if (description != null) message.description = description;
    if (reportedSourceTime != null) {
      message.reportedSourceTime = reportedSourceTime;
    }
    message.resource.addAll(resource);
    message.labels.addAll(labels);
    message.labelsOrigin.addAll(labelsOrigin);
    message.annotations.addAll(annotations);
    message.extensions.addAll(extensions);
    message.links.addAll([
      for (final link in links)
        pb.Link(href: link.href, relation: link.relation, text: link.text),
    ]);
    for (final entry in identityFields.entries) {
      message.identityFields[entry.key] = entry.value.raw != null
          ? (pb.IdentityComponent()..raw = entry.value.raw!)
          : (pb.IdentityComponent()..sha256 = entry.value.digest!);
    }
    message.observedAt = _wireTime(observedAt);
    message.processedAt = _wireTime(processedAt);
    if (startsAt != null) message.startsAt = _wireTime(startsAt);
    if (endsAt != null) message.endsAt = _wireTime(endsAt);
    if (sourceTime != null) message.sourceTime = _wireTime(sourceTime);
    final values = _Values(
      source: source,
      kind: kind,
      status: status,
      severity: severity,
      observer: effectiveObserver,
      raw: raw,
      pipeline: pipeline,
      links: List.unmodifiable(links),
      observedAt: observedAt,
      processedAt: processedAt,
      startsAt: startsAt,
      endsAt: endsAt,
      sourceTime: sourceTime,
      identityFields: Map.unmodifiable(identityFields),
      observationKey: observationKey,
    );
    return _accept(message, values, ValidationScope.exact);
  }

  /// Reads the strict known-field ProtoJSON boundary for the supplied schema.
  factory CanonicalEvent.fromJson(
    Map<String, Object?> payload, {
    String sourceDataschema = _currentSchema,
  }) {
    final scope = parseDataschema(sourceDataschema);
    checkJsonBoundary(payload);
    final values = _validatePayload(
      payload,
      allowUnknown: scope == ValidationScope.knownCoreOnly,
    );
    final message = pb.CanonicalEvent();
    try {
      message.mergeFromProto3Json(
        payload,
        ignoreUnknownFields: scope == ValidationScope.knownCoreOnly,
      );
    } on FormatException {
      throw const EventFieldError('event', 'invalid_protojson');
    } on ArgumentError {
      throw const EventFieldError('event', 'invalid_protojson');
    }
    return _accept(message, values, scope);
  }

  /// Reads bounded protobuf, retaining native unknown fields for binary output.
  factory CanonicalEvent.fromBuffer(
    Uint8List bytes, {
    String? sourceDataschema,
  }) {
    if (bytes.length > _maxEventBytes) {
      throw const EventFieldError('event', 'event_too_large');
    }
    final scope = sourceDataschema == null
        ? ValidationScope.unknown
        : parseDataschema(sourceDataschema);
    final pb.CanonicalEvent message;
    try {
      final reader = _StrictEventReader(bytes);
      message = pb.CanonicalEvent()..mergeFromCodedBufferReader(reader);
      reader.checkLastTagWas(0);
    } on protobuf.InvalidProtocolBufferException {
      throw const EventFieldError('event', 'invalid_protobuf');
    } on ArgumentError {
      throw const EventFieldError('event', 'invalid_protobuf');
    }
    // Closed enums are stored as native unknown varints by protobuf. Do not
    // accidentally accept an earlier known value when a later occurrence is
    // unknown: existing enum domains are frozen throughout v1.
    final unknown = message.unknownFields;
    for (final (tag, path) in const [
      (5, 'kind'),
      (6, 'status'),
      (7, 'severity'),
    ]) {
      if (unknown.hasField(tag)) throw EventFieldError(path, 'invalid_enum');
    }
    _validateBinaryTimestamps(message);
    final values = _validatePayload(_project(message), allowUnknown: false);
    return _accept(message, values, scope);
  }

  static CanonicalEvent _accept(
    pb.CanonicalEvent message,
    _Values values,
    ValidationScope scope,
  ) {
    message.freeze();
    final event = CanonicalEvent._(message, values, scope);
    final bytes = utf8.encode(jsonEncode(projectStructuredEvent(event)));
    if (bytes.length > _maxEventBytes) {
      throw const EventFieldError('event', 'event_too_large');
    }
    event._structuredBytes = bytes.asUnmodifiableView();
    return event;
  }

  final pb.CanonicalEvent _message;
  final _Values _values;
  late final Uint8List _structuredBytes;

  /// The extent of version-aware validation, never inferred from absent fields.
  final ValidationScope validationScope;

  /// The deterministic observation UUIDv5.
  String get eventId => _message.eventId;

  /// The namespace-scoped alert SHA-256 fingerprint.
  String get fingerprint => _message.fingerprint;

  /// The v1 single-tenant identifier.
  String get tenant => _message.tenant;

  /// The operator-controlled alert namespace.
  String get namespace => _message.namespace;

  /// The validated registered source scope.
  SourceContext get source => _values.source;

  /// The semantic event kind.
  EventKind get kind => _values.kind;

  /// The normalized observation status.
  EventStatus get status => _values.status;

  /// The normalized observation severity.
  EventSeverity get severity => _values.severity;

  /// The optional OTel severity number.
  int? get severityNumber =>
      _message.hasSeverityNumber() ? _message.severityNumber : null;

  /// The optional original source severity text.
  String? get severityOriginal =>
      _message.hasSeverityOriginal() ? _message.severityOriginal : null;

  /// The optional source hint, never an identity override.
  String? get dedupKey => _message.hasDedupKey() ? _message.dedupKey : null;

  /// The bounded display summary.
  String get summary => _message.summary;

  /// The optional bounded display description.
  String? get description =>
      _message.hasDescription() ? _message.description : null;

  /// The frozen resource attributes.
  Map<String, String> get resource => _message.resource;

  /// The frozen normalized labels.
  Map<String, String> get labels => _message.labels;

  /// The frozen origin evidence for existing labels.
  Map<String, String> get labelsOrigin => _message.labelsOrigin;

  /// The frozen annotations.
  Map<String, String> get annotations => _message.annotations;

  /// The immutable typed external references.
  List<EventLink> get links => _values.links;

  /// The reporting-system metadata.
  EventObserver get observer => _values.observer;

  /// The original start instant, including nanoseconds.
  EventTimestamp? get startsAt => _values.startsAt;

  /// The optional end instant, including nanoseconds.
  EventTimestamp? get endsAt => _values.endsAt;

  /// The normalized source instant, paired with original reported text.
  EventTimestamp? get sourceTime => _values.sourceTime;

  /// The original source timestamp spelling, unchanged by normalization.
  String? get reportedSourceTime =>
      _message.hasReportedSourceTime() ? _message.reportedSourceTime : null;

  /// The local observation instant.
  EventTimestamp get observedAt => _values.observedAt;

  /// The local processing instant.
  EventTimestamp get processedAt => _values.processedAt;

  /// The immutable raw-body metadata.
  EventRawReference get raw => _values.raw;

  /// The immutable processing provenance.
  EventPipeline get pipeline => _values.pipeline;

  /// The frozen namespaced payload extensions.
  Map<String, String> get extensions => _message.extensions;

  /// The immutable selected identity evidence.
  Map<String, IdentityComponent> get identityFields => _values.identityFields;

  /// The validated complete canonical observation key.
  ObservationKey get observationKey => _values.observationKey;

  /// Emits a fresh current-v1.0 known-field ProtoJSON projection.
  Map<String, Object?> toJson() => _project(_message);

  /// Encodes known and native unknown protobuf fields without exposing backing state.
  Uint8List toBuffer() => _message.writeToBuffer();
}

/// Builds the one authoritative current-version structured projection.
Map<String, Object?> projectStructuredEvent(
  CanonicalEvent event, {
  String? traceparent,
}) => {
  'specversion': '1.0',
  'id': event.eventId,
  'source': 'urn:correlia:source:${event.source.sourceInstance}',
  'type': 'io.correlia.${event.kind.name}.v1',
  'datacontenttype': 'application/json',
  'dataschema': _currentSchema,
  'subject': event.fingerprint,
  'partitionkey': event.fingerprint,
  'correliatenant': event.tenant,
  if (event.sourceTime case final EventTimestamp time) 'time': time.toRfc3339(),
  'traceparent': ?traceparent,
  'data': event.toJson(),
};

/// Returns the immutable default envelope representation validated at acceptance.
Uint8List defaultStructuredEventBytes(CanonicalEvent event) =>
    event._structuredBytes;

/// Truncates display text by Unicode scalar, with a marker included in the cap.
String normalizeDisplayText(
  String value, {
  required int maxScalars,
  bool singleLine = false,
}) {
  if (maxScalars < 1) {
    throw ArgumentError.value(maxScalars, 'maxScalars', 'must be positive');
  }
  validateText(value, 'display_text', max: value.length);
  final text = singleLine
      ? value.replaceAll('\r', ' ').replaceAll('\n', ' ')
      : value;
  final runes = text.runes;
  if (runes.length <= maxScalars) return text;
  return '${String.fromCharCodes(runes.take(maxScalars - 1))}…';
}

Map<String, Object?> _project(pb.CanonicalEvent message) {
  final result = _typedJson(message.toProto3Json()) as Map<String, Object?>;
  if (message.hasRaw()) {
    (result['raw']! as Map<String, Object?>)['size'] = message.raw.size;
  }
  if (message.hasPipeline()) {
    (result['pipeline']! as Map<String, Object?>)['generation'] =
        message.pipeline.generation;
  }
  return result;
}

time_pb.Timestamp _wireTime(EventTimestamp value) {
  final result = time_pb.Timestamp();
  result.seconds = result.seconds + value.seconds;
  result.nanos = value.nanos;
  return result;
}

Object? _typedJson(Object? value) {
  if (value is Map<Object?, Object?>) {
    // protobuf's map-field projection uses nullable key type arguments even
    // though every actual key is a string. Adapt the fresh serialization tree
    // with checked views; never retain or expose generated-message collections.
    final map = value is Map<String, Object?>
        ? value
        : value.cast<String, Object?>();
    for (final entry in map.entries) {
      map[entry.key] = _typedJson(entry.value);
    }
    return map;
  }
  if (value is List<Object?>) {
    for (var i = 0; i < value.length; i++) {
      value[i] = _typedJson(value[i]);
    }
  }
  return value;
}

final class _StrictEventReader extends protobuf.CodedBufferReader {
  _StrictEventReader(Uint8List super.bytes)
    : _wire = bytes,
      super(sizeLimit: _maxEventBytes);

  final Uint8List _wire;
  int _position = 0;
  int _lastInt32 = 0;

  int _varintLength() {
    for (var n = 0; n < 10; n++) {
      if (_position + n >= _wire.length) {
        throw const EventFieldError('event', 'invalid_protobuf');
      }
      final byte = _wire[_position + n];
      if (n == 9 && (byte & 0xfe) != 0) {
        throw const EventFieldError('event', 'out_of_range');
      }
      if ((byte & 0x80) == 0) return n + 1;
    }
    throw const EventFieldError('event', 'invalid_protobuf');
  }

  @override
  Int64 readInt64() {
    final length = _varintLength();
    final value = super.readInt64();
    _position += length;
    return value;
  }

  @override
  Int64 readUint64() {
    final length = _varintLength();
    final value = super.readUint64();
    _position += length;
    return value;
  }

  // The standard 32-bit readers mask overflowing varints. Decode the wire's
  // full 64-bit value first so enums, nanos, and uint32 fields cannot wrap.
  @override
  int readInt32() {
    final value = readInt64().toInt();
    if (value < -2147483648 || value > 2147483647) {
      throw const EventFieldError('event', 'out_of_range');
    }
    _lastInt32 = value;
    return value;
  }

  @override
  int readUint32() {
    final value = readUint64().toInt();
    if (value < 0 || value > 4294967295) {
      throw const EventFieldError('event', 'out_of_range');
    }
    return value;
  }

  @override
  bool readBool() {
    final length = _varintLength();
    final value = super.readBool();
    _position += length;
    return value;
  }

  @override
  Uint8List readBytesAsView() {
    final value = super.readBytesAsView();
    _position += value.length;
    return value;
  }

  @override
  int readFixed32() {
    final value = super.readFixed32();
    _position += 4;
    return value;
  }

  @override
  int readSfixed32() {
    final value = super.readSfixed32();
    _position += 4;
    return value;
  }

  @override
  Int64 readSfixed64() {
    final value = super.readSfixed64();
    _position += 8;
    return value;
  }

  @override
  double readFloat() {
    final value = super.readFloat();
    _position += 4;
    return value;
  }

  @override
  double readDouble() {
    final value = super.readDouble();
    _position += 8;
    return value;
  }

  @override
  bool skipField(int tag) {
    final skipped = super.skipField(tag);
    // This branch skips bytes internally rather than through a public read.
    if (skipped && (tag & 7) == 2) {
      if (_lastInt32 < 0) {
        throw const EventFieldError('event', 'invalid_protobuf');
      }
      _position += _lastInt32;
    }
    return skipped;
  }

  @override
  String readString() {
    try {
      return utf8.decode(readBytesAsView());
    } on FormatException {
      throw const EventFieldError('event', 'invalid_utf8');
    }
  }
}

void _validateBinaryTimestamps(pb.CanonicalEvent message) {
  if (message.hasStartsAt()) {
    EventTimestamp.fromParts(
      message.startsAt.seconds.toInt(),
      message.startsAt.nanos,
      path: 'starts_at',
    );
  }
  if (message.hasEndsAt()) {
    EventTimestamp.fromParts(
      message.endsAt.seconds.toInt(),
      message.endsAt.nanos,
      path: 'ends_at',
    );
  }
  if (message.hasSourceTime()) {
    EventTimestamp.fromParts(
      message.sourceTime.seconds.toInt(),
      message.sourceTime.nanos,
      path: 'source_time',
    );
  }
  if (message.hasObservedAt()) {
    EventTimestamp.fromParts(
      message.observedAt.seconds.toInt(),
      message.observedAt.nanos,
      path: 'observed_at',
    );
  }
  if (message.hasProcessedAt()) {
    EventTimestamp.fromParts(
      message.processedAt.seconds.toInt(),
      message.processedAt.nanos,
      path: 'processed_at',
    );
  }
}

final class _Values {
  _Values({
    required this.source,
    required this.kind,
    required this.status,
    required this.severity,
    required this.observer,
    required this.raw,
    required this.pipeline,
    required this.links,
    required this.observedAt,
    required this.processedAt,
    required this.identityFields,
    required this.observationKey,
    this.startsAt,
    this.endsAt,
    this.sourceTime,
  });
  final SourceContext source;
  final EventKind kind;
  final EventStatus status;
  final EventSeverity severity;
  final EventObserver observer;
  final EventRawReference raw;
  final EventPipeline pipeline;
  final List<EventLink> links;
  final EventTimestamp? startsAt, endsAt, sourceTime;
  final EventTimestamp observedAt, processedAt;
  final Map<String, IdentityComponent> identityFields;
  final ObservationKey observationKey;
}

const _eventKeys = {
  'event_id',
  'fingerprint',
  'tenant',
  'namespace',
  'kind',
  'status',
  'severity',
  'severity_number',
  'severity_original',
  'dedup_key',
  'summary',
  'description',
  'resource',
  'observer',
  'labels',
  'labels_origin',
  'annotations',
  'links',
  'starts_at',
  'ends_at',
  'source_time',
  'reported_source_time',
  'observed_at',
  'processed_at',
  'raw',
  'pipeline',
  'extensions',
  'identity_fields',
  'observation_key',
};
const _observerKeys = {'source_instance', 'source_kind', 'name', 'version'};
const _rawKeys = {'ref', 'sha256', 'size'};
const _pipelineKeys = {
  'version',
  'generation',
  'stages_applied',
  'enrichment_errors',
  'original_event_id',
};
const _linkKeys = {'href', 'relation', 'text'};
const _errorKeys = {'stage', 'code', 'message'};
const _componentKeys = {'raw', 'sha256'};

_Values _validatePayload(
  Map<String, Object?> map, {
  required bool allowUnknown,
}) {
  _keys(map, _eventKeys, '', allowUnknown);
  final eventId = _requiredString(map, 'event_id');
  validateUuid(eventId, 'event_id', version5: true);
  final fingerprint = _requiredString(map, 'fingerprint');
  validateSha256(fingerprint, 'fingerprint');
  final tenant = _requiredString(map, 'tenant');
  if (tenant != CanonicalEventBounds.CanonicalEventTenantConst) {
    throw const EventFieldError('tenant', 'unsupported_tenant');
  }
  final namespace = _text(
    map,
    'namespace',
    CanonicalEventBounds.CanonicalEventNamespaceLength,
    required: true,
  )!;
  final kind = _enumValue(map['kind'], 'kind', _kindNames);
  final status = _enumValue(map['status'], 'status', _statusNames);
  final severity = _enumValue(map['severity'], 'severity', _severityNames);
  _text(
    map,
    'summary',
    CanonicalEventBounds.CanonicalEventSummaryLength,
    required: true,
  );
  _text(
    map,
    'description',
    CanonicalEventBounds.CanonicalEventDescriptionLength,
  );
  _text(
    map,
    'severity_original',
    CanonicalEventBounds.CanonicalEventSeverityOriginalLength,
  );
  _text(map, 'dedup_key', CanonicalEventBounds.CanonicalEventDedupKeyLength);
  if (map.containsKey('severity_number')) {
    _readInteger(
      map['severity_number'],
      'severity_number',
      CanonicalEventBounds.CanonicalEventSeverityNumberUint32,
    );
  }

  final observerMap = _object(map['observer'], 'observer');
  _keys(observerMap, _observerKeys, 'observer', allowUnknown);
  final observer = EventObserver(
    sourceInstance: _requiredString(observerMap, 'source_instance', 'observer'),
    sourceKind: _requiredString(observerMap, 'source_kind', 'observer'),
    name: _optionalString(observerMap, 'name', 'observer'),
    version: _optionalString(observerMap, 'version', 'observer'),
  );
  final source = SourceContext(
    sourceInstance: observer.sourceInstance,
    sourceKind: observer.sourceKind,
    namespace: namespace,
    tenant: tenant,
  );

  _stringMap(
    map['resource'],
    'resource',
    CanonicalEventBounds.CanonicalEventResourceLength,
    CanonicalEventBounds.CanonicalEventResourceKeyLength,
    CanonicalEventBounds.CanonicalEventResourceValueLength,
    present: map.containsKey('resource'),
  );
  final labels = _stringMap(
    map['labels'],
    'labels',
    CanonicalEventBounds.CanonicalEventLabelsLength,
    CanonicalEventBounds.CanonicalEventLabelsKeyLength,
    CanonicalEventBounds.CanonicalEventLabelsValueLength,
    present: map.containsKey('labels'),
  );
  final origin = _stringMap(
    map['labels_origin'],
    'labels_origin',
    CanonicalEventBounds.CanonicalEventLabelsOriginLength,
    CanonicalEventBounds.CanonicalEventLabelsOriginKeyLength,
    CanonicalEventBounds.CanonicalEventLabelsOriginValueLength,
    present: map.containsKey('labels_origin'),
  );
  for (final key in origin.keys) {
    if (!labels.containsKey(key)) {
      throw EventFieldError('labels_origin.$key', 'unknown_label');
    }
  }
  _stringMap(
    map['annotations'],
    'annotations',
    CanonicalEventBounds.CanonicalEventAnnotationsLength,
    CanonicalEventBounds.CanonicalEventAnnotationsKeyLength,
    CanonicalEventBounds.CanonicalEventAnnotationsValueLength,
    present: map.containsKey('annotations'),
  );
  _stringMap(
    map['extensions'],
    'extensions',
    CanonicalEventBounds.CanonicalEventExtensionsLength,
    CanonicalEventBounds.CanonicalEventExtensionsKeyLength,
    CanonicalEventBounds.CanonicalEventExtensionsValueLength,
    present: map.containsKey('extensions'),
    keyPattern: CanonicalEventBounds.CanonicalEventExtensionsKeyPattern,
  );

  final linkValues = _list(
    map,
    'links',
    CanonicalEventBounds.CanonicalEventLinksLength,
  );
  final links = <EventLink>[];
  for (var i = 0; i < linkValues.length; i++) {
    final path = 'links[$i]';
    final value = _object(linkValues[i], path);
    _keys(value, _linkKeys, path, allowUnknown);
    try {
      links.add(
        EventLink(
          href: _requiredString(value, 'href', path),
          relation: _requiredString(value, 'relation', path),
          text: _optionalString(value, 'text', path),
        ),
      );
    } on EventFieldError catch (error) {
      throw EventFieldError(
        error.path.replaceFirst('links.', '$path.'),
        error.code,
      );
    }
  }

  final rawMap = _object(map['raw'], 'raw');
  _keys(rawMap, _rawKeys, 'raw', allowUnknown);
  final raw = EventRawReference(
    ref: _requiredString(rawMap, 'ref', 'raw'),
    sha256: _requiredString(rawMap, 'sha256', 'raw'),
    size: rawMap.containsKey('size')
        ? _readInteger(
            rawMap['size'],
            'raw.size',
            CanonicalEventBounds.RawReferenceSizeUint32,
          )
        : 0,
  );
  final pipelineMap = _object(map['pipeline'], 'pipeline');
  _keys(pipelineMap, _pipelineKeys, 'pipeline', allowUnknown);
  final stages = _list(
    pipelineMap,
    'stages_applied',
    CanonicalEventBounds.PipelineStagesAppliedLength,
    prefix: 'pipeline',
  );
  final stageNames = <String>[];
  for (var i = 0; i < stages.length; i++) {
    final value = stages[i];
    if (value is! String) {
      throw EventFieldError('pipeline.stages_applied[$i]', 'invalid_type');
    }
    stageNames.add(value);
  }
  final errors = <EventEnrichmentError>[];
  final errorValues = _list(
    pipelineMap,
    'enrichment_errors',
    CanonicalEventBounds.PipelineEnrichmentErrorsLength,
    prefix: 'pipeline',
  );
  for (var i = 0; i < errorValues.length; i++) {
    final path = 'pipeline.enrichment_errors[$i]';
    final value = _object(errorValues[i], path);
    _keys(value, _errorKeys, path, allowUnknown);
    try {
      errors.add(
        EventEnrichmentError(
          stage: _requiredString(value, 'stage', path),
          code: _requiredString(value, 'code', path),
          message: _requiredString(value, 'message', path),
        ),
      );
    } on EventFieldError catch (error) {
      throw EventFieldError(
        error.path.replaceFirst('enrichment_error.', '$path.'),
        error.code,
      );
    }
  }
  final pipeline = EventPipeline(
    version: _requiredString(pipelineMap, 'version', 'pipeline'),
    generation: pipelineMap.containsKey('generation')
        ? _readInteger(
            pipelineMap['generation'],
            'pipeline.generation',
            CanonicalEventBounds.PipelineGenerationUint32,
          )
        : 0,
    stagesApplied: stageNames,
    enrichmentErrors: errors,
    originalEventId: _optionalString(
      pipelineMap,
      'original_event_id',
      'pipeline',
    ),
  );

  EventTimestamp? time(String key, {bool required = false}) {
    final value = _optionalString(map, key);
    if (value == null) {
      if (required) throw EventFieldError(key, 'required');
      return null;
    }
    return EventTimestamp.parse(value, path: key);
  }

  final startsAt = time('starts_at'),
      endsAt = time('ends_at'),
      sourceTime = time('source_time');
  final observedAt = time('observed_at', required: true)!,
      processedAt = time('processed_at', required: true)!;
  final reported = _text(
    map,
    'reported_source_time',
    CanonicalEventBounds.CanonicalEventReportedSourceTimeLength,
  );
  if ((sourceTime == null) != (reported == null)) {
    throw const EventFieldError('reported_source_time', 'paired_presence');
  }
  if (reported != null &&
      EventTimestamp.parse(reported, path: 'reported_source_time') !=
          sourceTime) {
    throw const EventFieldError('reported_source_time', 'time_mismatch');
  }

  final fieldMap = _object(map['identity_fields'], 'identity_fields');
  _length(
    fieldMap.length,
    'identity_fields',
    CanonicalEventBounds.CanonicalEventIdentityFieldsLength,
  );
  final fields = <String, IdentityComponent>{};
  for (final MapEntry(:key, :value) in fieldMap.entries) {
    _bounded(
      key,
      'identity_fields.key',
      CanonicalEventBounds.CanonicalEventIdentityFieldsKeyLength,
    );
    final path = 'identity_fields.$key';
    final component = _object(value, path);
    _keys(component, _componentKeys, path, allowUnknown);
    if (component.containsKey('raw') == component.containsKey('sha256')) {
      throw EventFieldError(path, 'oneof_required');
    }
    if (component.containsKey('raw')) {
      final raw = _requiredString(component, 'raw', path);
      _bounded(
        raw,
        '$path.raw',
        CanonicalEventBounds.IdentityComponentRawLength,
      );
      _length(
        utf8.encode(raw).length,
        '$path.raw',
        CanonicalEventBounds.IdentityComponentRawByteLength,
      );
      fields[key] = IdentityComponent.fromText(raw);
    } else {
      fields[key] = IdentityComponent.fromDigest(
        _bytes(
          component['sha256'],
          '$path.sha256',
          CanonicalEventBounds.IdentityComponentSha256Length,
        ),
      );
    }
  }
  final observationKey = ObservationKey.fromBytes(
    _bytes(
      map['observation_key'],
      'observation_key',
      CanonicalEventBounds.CanonicalEventObservationKeyLength,
    ),
  );
  if (alertFingerprint(source, fields) != fingerprint) {
    throw const EventFieldError('fingerprint', 'identity_mismatch');
  }
  if (observationId(
        source: source,
        fingerprint: fingerprint,
        key: observationKey,
        generation: pipeline.generation,
      ) !=
      eventId) {
    throw const EventFieldError('event_id', 'identity_mismatch');
  }
  return _Values(
    source: source,
    kind: kind,
    status: status,
    severity: severity,
    observer: observer,
    raw: raw,
    pipeline: pipeline,
    links: List.unmodifiable(links),
    startsAt: startsAt,
    endsAt: endsAt,
    sourceTime: sourceTime,
    observedAt: observedAt,
    processedAt: processedAt,
    identityFields: Map.unmodifiable(fields),
    observationKey: observationKey,
  );
}

void _keys(
  Map<String, Object?> map,
  Set<String> known,
  String prefix,
  bool allowUnknown,
) {
  for (final key in map.keys) {
    if (known.contains(key)) continue;
    final path = prefix.isEmpty ? key : '$prefix.$key';
    if (!allowUnknown) throw EventFieldError(path, 'undeclared_field');
    for (final name in known) {
      final words = name.split('_');
      final alias =
          words.first +
          words
              .skip(1)
              .map((part) => part[0].toUpperCase() + part.substring(1))
              .join();
      if (alias == key) throw EventFieldError(path, 'alias_not_allowed');
    }
  }
}

Map<String, Object?> _object(Object? value, String path) {
  if (value == null) throw EventFieldError(path, 'required');
  if (value is! Map<String, Object?>) {
    throw EventFieldError(path, 'invalid_type');
  }
  return value;
}

String _requiredString(
  Map<String, Object?> map,
  String key, [
  String prefix = '',
]) {
  final path = prefix.isEmpty ? key : '$prefix.$key';
  final value = map[key];
  if (value == null && !map.containsKey(key)) {
    throw EventFieldError(path, 'required');
  }
  if (value is! String) throw EventFieldError(path, 'invalid_type');
  return value;
}

String? _optionalString(
  Map<String, Object?> map,
  String key, [
  String prefix = '',
]) => map.containsKey(key) ? _requiredString(map, key, prefix) : null;
String? _text(
  Map<String, Object?> map,
  String key,
  _Length length, {
  bool required = false,
}) {
  final value = required
      ? _requiredString(map, key)
      : _optionalString(map, key);
  if (value != null) _bounded(value, key, length);
  return value;
}

void _bounded(String value, String path, _Length length, {String? pattern}) =>
    validateText(
      value,
      path,
      min: length.min ?? 0,
      max: length.max ?? _maxEventBytes,
      pattern: pattern,
    );
void _length(int value, String path, _Length length) {
  if (value < (length.min ?? 0) || length.max != null && value > length.max!) {
    throw EventFieldError(path, 'invalid_count');
  }
}

void _integer(int value, String path, _Length range) {
  if (value < (range.min ?? 0) || range.max != null && value > range.max!) {
    throw EventFieldError(path, 'out_of_range');
  }
}

int _readInteger(Object? value, String path, _Length range) {
  if (value is! int) throw EventFieldError(path, 'invalid_type');
  _integer(value, path, range);
  return value;
}

T _enumValue<T extends Enum>(
  Object? value,
  String path,
  Map<String, T> values,
) {
  if (value is! String) throw EventFieldError(path, 'invalid_enum');
  return values[value] ?? (throw EventFieldError(path, 'invalid_enum'));
}

const _kindNames = <String, EventKind>{
  'EVENT_KIND_ALERT': EventKind.alert,
  'EVENT_KIND_STATE': EventKind.state,
  'EVENT_KIND_ACK': EventKind.ack,
  'EVENT_KIND_DOWNTIME': EventKind.downtime,
  'EVENT_KIND_COMMENT': EventKind.comment,
  'EVENT_KIND_HEARTBEAT': EventKind.heartbeat,
};
const _statusNames = <String, EventStatus>{
  'EVENT_STATUS_FIRING': EventStatus.firing,
  'EVENT_STATUS_RESOLVED': EventStatus.resolved,
  'EVENT_STATUS_INFO': EventStatus.info,
};
const _severityNames = <String, EventSeverity>{
  'EVENT_SEVERITY_CRITICAL': EventSeverity.critical,
  'EVENT_SEVERITY_ERROR': EventSeverity.error,
  'EVENT_SEVERITY_WARNING': EventSeverity.warning,
  'EVENT_SEVERITY_INFO': EventSeverity.info,
  'EVENT_SEVERITY_UNKNOWN': EventSeverity.unknown,
};

List<Object?> _list(
  Map<String, Object?> map,
  String key,
  _Length length, {
  String prefix = '',
}) {
  if (!map.containsKey(key)) return const [];
  final path = prefix.isEmpty ? key : '$prefix.$key';
  final value = map[key];
  if (value is! List<Object?>) throw EventFieldError(path, 'invalid_type');
  _length(value.length, path, length);
  return value;
}

Map<String, Object?> _stringMap(
  Object? value,
  String path,
  _Length count,
  _Length keys,
  _Length values, {
  required bool present,
  String? keyPattern,
}) {
  if (!present) return const {};
  final map = _object(value, path);
  _length(map.length, path, count);
  for (final MapEntry(:key, :value) in map.entries) {
    _bounded(key, '$path.key', keys, pattern: keyPattern);
    if (value is! String) throw EventFieldError('$path.$key', 'invalid_type');
    _bounded(value, '$path.$key', values);
  }
  return map;
}

Uint8List _bytes(Object? value, String path, _Length length) {
  if (value is! String) throw EventFieldError(path, 'invalid_type');
  if (length.max != null && value.length > ((length.max! + 2) ~/ 3) * 4) {
    throw EventFieldError(path, 'invalid_length');
  }
  final Uint8List result;
  try {
    result = base64Decode(value);
  } on FormatException {
    throw EventFieldError(path, 'invalid_base64');
  }
  if (result.length < (length.min ?? 0) ||
      length.max != null && result.length > length.max!) {
    throw EventFieldError(path, 'invalid_length');
  }
  return result;
}

/// Checks whole-input work bounds before recursive domain conversion.
void checkJsonBoundary(Object? value) {
  var nodes = 0, stringBytes = 0;
  void visit(Object? value, int depth) {
    if (++nodes > _maxEventBytes) {
      throw const EventFieldError('event', 'event_too_large');
    }
    if (value is String) {
      validateText(value, 'event', max: _maxEventBytes);
      for (final rune in value.runes) {
        stringBytes += rune < 128
            ? 1
            : rune < 2048
            ? 2
            : rune < 65536
            ? 3
            : 4;
      }
      if (stringBytes > _maxEventBytes) {
        throw const EventFieldError('event', 'event_too_large');
      }
    } else if (value is Map<String, Object?>) {
      if (depth > 16) throw const EventFieldError('event', 'too_deep');
      if (value.length > _maxEventBytes) {
        throw const EventFieldError('event', 'event_too_large');
      }
      for (final MapEntry(:key, :value) in value.entries) {
        visit(key, depth + 1);
        visit(value, depth + 1);
      }
    } else if (value is List<Object?>) {
      if (depth > 16) throw const EventFieldError('event', 'too_deep');
      if (value.length > _maxEventBytes) {
        throw const EventFieldError('event', 'event_too_large');
      }
      for (final item in value) {
        visit(item, depth + 1);
      }
    } else if (value != null &&
        value is! bool &&
        value is! int &&
        (value is! double || !value.isFinite)) {
      throw const EventFieldError('event', 'invalid_json');
    }
  }

  visit(value, 1);
  if (utf8.encode(jsonEncode(value)).length > _maxEventBytes) {
    throw const EventFieldError('event', 'event_too_large');
  }
}
