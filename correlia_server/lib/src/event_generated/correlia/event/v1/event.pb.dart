// This is a generated file - do not edit.
//
// Generated from correlia/event/v1/event.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as $0;

import 'event.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'event.pbenum.dart';

/// Observer describes the source system that reported an event.
class Observer extends $pb.GeneratedMessage {
  factory Observer({
    $core.String? sourceInstance,
    $core.String? sourceKind,
    $core.String? name,
    $core.String? version,
  }) {
    final result = Observer._();
    if (sourceInstance != null) result.sourceInstance = sourceInstance;
    if (sourceKind != null) result.sourceKind = sourceKind;
    if (name != null) result.name = name;
    if (version != null) result.version = version;
    return result;
  }

  Observer._();

  factory Observer.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Observer()..mergeFromBuffer(data, registry);
  factory Observer.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Observer()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Observer',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.event.v1'),
      createEmptyInstance: Observer.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'source_instance')
    ..aOS(2, _omitFieldNames ? '' : 'source_kind')
    ..aOS(3, _omitFieldNames ? '' : 'name')
    ..aOS(4, _omitFieldNames ? '' : 'version')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Observer clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Observer copyWith(void Function(Observer) updates) =>
      super.copyWith((message) => updates(message as Observer)) as Observer;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Observer() / Observer.new instead')
  static Observer create() => Observer._();
  static $pb.GeneratedMessage $_createMessage() => Observer._();
  @$core.override
  Observer createEmptyInstance() => Observer._();
  @$core.pragma('dart2js:noInline')
  static Observer getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Observer>(Observer.$_createMessage);
  static Observer? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get sourceInstance => $_getSZ(0);
  @$pb.TagNumber(1)
  set sourceInstance($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSourceInstance() => $_has(0);
  @$pb.TagNumber(1)
  void clearSourceInstance() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get sourceKind => $_getSZ(1);
  @$pb.TagNumber(2)
  set sourceKind($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSourceKind() => $_has(1);
  @$pb.TagNumber(2)
  void clearSourceKind() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get name => $_getSZ(2);
  @$pb.TagNumber(3)
  set name($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasName() => $_has(2);
  @$pb.TagNumber(3)
  void clearName() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get version => $_getSZ(3);
  @$pb.TagNumber(4)
  set version($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasVersion() => $_has(3);
  @$pb.TagNumber(4)
  void clearVersion() => $_clearField(4);
}

/// Link describes a bounded external reference associated with an event.
class Link extends $pb.GeneratedMessage {
  factory Link({
    $core.String? href,
    $core.String? relation,
    $core.String? text,
  }) {
    final result = Link._();
    if (href != null) result.href = href;
    if (relation != null) result.relation = relation;
    if (text != null) result.text = text;
    return result;
  }

  Link._();

  factory Link.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Link()..mergeFromBuffer(data, registry);
  factory Link.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Link()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Link',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.event.v1'),
      createEmptyInstance: Link.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'href')
    ..aOS(2, _omitFieldNames ? '' : 'relation')
    ..aOS(3, _omitFieldNames ? '' : 'text')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Link clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Link copyWith(void Function(Link) updates) =>
      super.copyWith((message) => updates(message as Link)) as Link;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Link() / Link.new instead')
  static Link create() => Link._();
  static $pb.GeneratedMessage $_createMessage() => Link._();
  @$core.override
  Link createEmptyInstance() => Link._();
  @$core.pragma('dart2js:noInline')
  static Link getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Link>(Link.$_createMessage);
  static Link? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get href => $_getSZ(0);
  @$pb.TagNumber(1)
  set href($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasHref() => $_has(0);
  @$pb.TagNumber(1)
  void clearHref() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get relation => $_getSZ(1);
  @$pb.TagNumber(2)
  set relation($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasRelation() => $_has(1);
  @$pb.TagNumber(2)
  void clearRelation() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get text => $_getSZ(2);
  @$pb.TagNumber(3)
  set text($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasText() => $_has(2);
  @$pb.TagNumber(3)
  void clearText() => $_clearField(3);
}

/// RawReference identifies the referenced source body without embedding it.
class RawReference extends $pb.GeneratedMessage {
  factory RawReference({
    $core.String? ref,
    $core.String? sha256,
    $core.int? size,
  }) {
    final result = RawReference._();
    if (ref != null) result.ref = ref;
    if (sha256 != null) result.sha256 = sha256;
    if (size != null) result.size = size;
    return result;
  }

  RawReference._();

  factory RawReference.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RawReference()..mergeFromBuffer(data, registry);
  factory RawReference.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RawReference()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RawReference',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.event.v1'),
      createEmptyInstance: RawReference.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'ref')
    ..aOS(2, _omitFieldNames ? '' : 'sha256')
    ..aI(3, _omitFieldNames ? '' : 'size', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RawReference clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RawReference copyWith(void Function(RawReference) updates) =>
      super.copyWith((message) => updates(message as RawReference))
          as RawReference;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use RawReference() / RawReference.new instead')
  static RawReference create() => RawReference._();
  static $pb.GeneratedMessage $_createMessage() => RawReference._();
  @$core.override
  RawReference createEmptyInstance() => RawReference._();
  @$core.pragma('dart2js:noInline')
  static RawReference getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<RawReference>(
          RawReference.$_createMessage);
  static RawReference? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get ref => $_getSZ(0);
  @$pb.TagNumber(1)
  set ref($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasRef() => $_has(0);
  @$pb.TagNumber(1)
  void clearRef() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get sha256 => $_getSZ(1);
  @$pb.TagNumber(2)
  set sha256($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSha256() => $_has(1);
  @$pb.TagNumber(2)
  void clearSha256() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get size => $_getIZ(2);
  @$pb.TagNumber(3)
  set size($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSize() => $_has(2);
  @$pb.TagNumber(3)
  void clearSize() => $_clearField(3);
}

/// EnrichmentError records a bounded, typed pipeline enrichment failure.
class EnrichmentError extends $pb.GeneratedMessage {
  factory EnrichmentError({
    $core.String? stage,
    $core.String? code,
    $core.String? message,
  }) {
    final result = EnrichmentError._();
    if (stage != null) result.stage = stage;
    if (code != null) result.code = code;
    if (message != null) result.message = message;
    return result;
  }

  EnrichmentError._();

  factory EnrichmentError.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EnrichmentError()..mergeFromBuffer(data, registry);
  factory EnrichmentError.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EnrichmentError()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EnrichmentError',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.event.v1'),
      createEmptyInstance: EnrichmentError.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'stage')
    ..aOS(2, _omitFieldNames ? '' : 'code')
    ..aOS(3, _omitFieldNames ? '' : 'message')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnrichmentError clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnrichmentError copyWith(void Function(EnrichmentError) updates) =>
      super.copyWith((message) => updates(message as EnrichmentError))
          as EnrichmentError;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use EnrichmentError() / EnrichmentError.new instead')
  static EnrichmentError create() => EnrichmentError._();
  static $pb.GeneratedMessage $_createMessage() => EnrichmentError._();
  @$core.override
  EnrichmentError createEmptyInstance() => EnrichmentError._();
  @$core.pragma('dart2js:noInline')
  static EnrichmentError getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<EnrichmentError>(
          EnrichmentError.$_createMessage);
  static EnrichmentError? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get stage => $_getSZ(0);
  @$pb.TagNumber(1)
  set stage($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStage() => $_has(0);
  @$pb.TagNumber(1)
  void clearStage() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get code => $_getSZ(1);
  @$pb.TagNumber(2)
  set code($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCode() => $_has(1);
  @$pb.TagNumber(2)
  void clearCode() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get message => $_getSZ(2);
  @$pb.TagNumber(3)
  set message($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMessage() => $_has(2);
  @$pb.TagNumber(3)
  void clearMessage() => $_clearField(3);
}

/// Pipeline records the processing provenance of an event.
class Pipeline extends $pb.GeneratedMessage {
  factory Pipeline({
    $core.String? version,
    $core.int? generation,
    $core.Iterable<$core.String>? stagesApplied,
    $core.Iterable<EnrichmentError>? enrichmentErrors,
    $core.String? originalEventId,
  }) {
    final result = Pipeline._();
    if (version != null) result.version = version;
    if (generation != null) result.generation = generation;
    if (stagesApplied != null) result.stagesApplied.addAll(stagesApplied);
    if (enrichmentErrors != null)
      result.enrichmentErrors.addAll(enrichmentErrors);
    if (originalEventId != null) result.originalEventId = originalEventId;
    return result;
  }

  Pipeline._();

  factory Pipeline.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Pipeline()..mergeFromBuffer(data, registry);
  factory Pipeline.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Pipeline()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Pipeline',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.event.v1'),
      createEmptyInstance: Pipeline.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'version')
    ..aI(2, _omitFieldNames ? '' : 'generation', fieldType: $pb.PbFieldType.OU3)
    ..pPS(3, _omitFieldNames ? '' : 'stages_applied')
    ..pPM<EnrichmentError>(4, _omitFieldNames ? '' : 'enrichment_errors',
        subBuilder: EnrichmentError.$_createMessage)
    ..aOS(5, _omitFieldNames ? '' : 'original_event_id')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Pipeline clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Pipeline copyWith(void Function(Pipeline) updates) =>
      super.copyWith((message) => updates(message as Pipeline)) as Pipeline;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Pipeline() / Pipeline.new instead')
  static Pipeline create() => Pipeline._();
  static $pb.GeneratedMessage $_createMessage() => Pipeline._();
  @$core.override
  Pipeline createEmptyInstance() => Pipeline._();
  @$core.pragma('dart2js:noInline')
  static Pipeline getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Pipeline>(Pipeline.$_createMessage);
  static Pipeline? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get version => $_getSZ(0);
  @$pb.TagNumber(1)
  set version($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearVersion() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get generation => $_getIZ(1);
  @$pb.TagNumber(2)
  set generation($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasGeneration() => $_has(1);
  @$pb.TagNumber(2)
  void clearGeneration() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get stagesApplied => $_getList(2);

  @$pb.TagNumber(4)
  $pb.PbList<EnrichmentError> get enrichmentErrors => $_getList(3);

  @$pb.TagNumber(5)
  $core.String get originalEventId => $_getSZ(4);
  @$pb.TagNumber(5)
  set originalEventId($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasOriginalEventId() => $_has(4);
  @$pb.TagNumber(5)
  void clearOriginalEventId() => $_clearField(5);
}

enum IdentityComponent_Value { raw, sha256, notSet }

/// IdentityComponent is one bounded identity value or its SHA-256 digest.
class IdentityComponent extends $pb.GeneratedMessage {
  factory IdentityComponent({
    $core.String? raw,
    $core.List<$core.int>? sha256,
  }) {
    final result = IdentityComponent._();
    if (raw != null) result.raw = raw;
    if (sha256 != null) result.sha256 = sha256;
    return result;
  }

  IdentityComponent._();

  factory IdentityComponent.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      IdentityComponent()..mergeFromBuffer(data, registry);
  factory IdentityComponent.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      IdentityComponent()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, IdentityComponent_Value>
      _IdentityComponent_ValueByTag = {
    1: IdentityComponent_Value.raw,
    2: IdentityComponent_Value.sha256,
    0: IdentityComponent_Value.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'IdentityComponent',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.event.v1'),
      createEmptyInstance: IdentityComponent.$_createMessage)
    ..oo(0, [1, 2])
    ..aOS(1, _omitFieldNames ? '' : 'raw')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'sha256', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  IdentityComponent clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  IdentityComponent copyWith(void Function(IdentityComponent) updates) =>
      super.copyWith((message) => updates(message as IdentityComponent))
          as IdentityComponent;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use IdentityComponent() / IdentityComponent.new instead')
  static IdentityComponent create() => IdentityComponent._();
  static $pb.GeneratedMessage $_createMessage() => IdentityComponent._();
  @$core.override
  IdentityComponent createEmptyInstance() => IdentityComponent._();
  @$core.pragma('dart2js:noInline')
  static IdentityComponent getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<IdentityComponent>(
          IdentityComponent.$_createMessage);
  static IdentityComponent? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  IdentityComponent_Value whichValue() =>
      _IdentityComponent_ValueByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearValue() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.String get raw => $_getSZ(0);
  @$pb.TagNumber(1)
  set raw($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasRaw() => $_has(0);
  @$pb.TagNumber(1)
  void clearRaw() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get sha256 => $_getN(1);
  @$pb.TagNumber(2)
  set sha256($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSha256() => $_has(1);
  @$pb.TagNumber(2)
  void clearSha256() => $_clearField(2);
}

/// CanonicalEvent is the versioned Correlia event payload.
class CanonicalEvent extends $pb.GeneratedMessage {
  factory CanonicalEvent({
    $core.String? eventId,
    $core.String? fingerprint,
    $core.String? tenant,
    $core.String? namespace,
    EventKind? kind,
    EventStatus? status,
    EventSeverity? severity,
    $core.int? severityNumber,
    $core.String? severityOriginal,
    $core.String? dedupKey,
    $core.String? summary,
    $core.String? description,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? resource,
    Observer? observer,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? labels,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? labelsOrigin,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? annotations,
    $core.Iterable<Link>? links,
    $0.Timestamp? startsAt,
    $0.Timestamp? endsAt,
    $0.Timestamp? sourceTime,
    $core.String? reportedSourceTime,
    $0.Timestamp? observedAt,
    $0.Timestamp? processedAt,
    RawReference? raw,
    Pipeline? pipeline,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? extensions,
    $core.Iterable<$core.MapEntry<$core.String, IdentityComponent>>?
        identityFields,
    $core.List<$core.int>? observationKey,
  }) {
    final result = CanonicalEvent._();
    if (eventId != null) result.eventId = eventId;
    if (fingerprint != null) result.fingerprint = fingerprint;
    if (tenant != null) result.tenant = tenant;
    if (namespace != null) result.namespace = namespace;
    if (kind != null) result.kind = kind;
    if (status != null) result.status = status;
    if (severity != null) result.severity = severity;
    if (severityNumber != null) result.severityNumber = severityNumber;
    if (severityOriginal != null) result.severityOriginal = severityOriginal;
    if (dedupKey != null) result.dedupKey = dedupKey;
    if (summary != null) result.summary = summary;
    if (description != null) result.description = description;
    if (resource != null) result.resource.addEntries(resource);
    if (observer != null) result.observer = observer;
    if (labels != null) result.labels.addEntries(labels);
    if (labelsOrigin != null) result.labelsOrigin.addEntries(labelsOrigin);
    if (annotations != null) result.annotations.addEntries(annotations);
    if (links != null) result.links.addAll(links);
    if (startsAt != null) result.startsAt = startsAt;
    if (endsAt != null) result.endsAt = endsAt;
    if (sourceTime != null) result.sourceTime = sourceTime;
    if (reportedSourceTime != null)
      result.reportedSourceTime = reportedSourceTime;
    if (observedAt != null) result.observedAt = observedAt;
    if (processedAt != null) result.processedAt = processedAt;
    if (raw != null) result.raw = raw;
    if (pipeline != null) result.pipeline = pipeline;
    if (extensions != null) result.extensions.addEntries(extensions);
    if (identityFields != null)
      result.identityFields.addEntries(identityFields);
    if (observationKey != null) result.observationKey = observationKey;
    return result;
  }

  CanonicalEvent._();

  factory CanonicalEvent.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CanonicalEvent()..mergeFromBuffer(data, registry);
  factory CanonicalEvent.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CanonicalEvent()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CanonicalEvent',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.event.v1'),
      createEmptyInstance: CanonicalEvent.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'event_id')
    ..aOS(2, _omitFieldNames ? '' : 'fingerprint')
    ..aOS(3, _omitFieldNames ? '' : 'tenant')
    ..aOS(4, _omitFieldNames ? '' : 'namespace')
    ..aE<EventKind>(5, _omitFieldNames ? '' : 'kind',
        enumValues: EventKind.values)
    ..aE<EventStatus>(6, _omitFieldNames ? '' : 'status',
        enumValues: EventStatus.values)
    ..aE<EventSeverity>(7, _omitFieldNames ? '' : 'severity',
        enumValues: EventSeverity.values)
    ..aI(8, _omitFieldNames ? '' : 'severity_number',
        fieldType: $pb.PbFieldType.OU3)
    ..aOS(9, _omitFieldNames ? '' : 'severity_original')
    ..aOS(10, _omitFieldNames ? '' : 'dedup_key')
    ..aOS(11, _omitFieldNames ? '' : 'summary')
    ..aOS(12, _omitFieldNames ? '' : 'description')
    ..m<$core.String, $core.String>(13, _omitFieldNames ? '' : 'resource',
        entryClassName: 'CanonicalEvent.ResourceEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('correlia.event.v1'))
    ..aOM<Observer>(14, _omitFieldNames ? '' : 'observer',
        subBuilder: Observer.$_createMessage)
    ..m<$core.String, $core.String>(15, _omitFieldNames ? '' : 'labels',
        entryClassName: 'CanonicalEvent.LabelsEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('correlia.event.v1'))
    ..m<$core.String, $core.String>(16, _omitFieldNames ? '' : 'labels_origin',
        entryClassName: 'CanonicalEvent.LabelsOriginEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('correlia.event.v1'))
    ..m<$core.String, $core.String>(17, _omitFieldNames ? '' : 'annotations',
        entryClassName: 'CanonicalEvent.AnnotationsEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('correlia.event.v1'))
    ..pPM<Link>(18, _omitFieldNames ? '' : 'links',
        subBuilder: Link.$_createMessage)
    ..aOM<$0.Timestamp>(19, _omitFieldNames ? '' : 'starts_at',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOM<$0.Timestamp>(20, _omitFieldNames ? '' : 'ends_at',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOM<$0.Timestamp>(21, _omitFieldNames ? '' : 'source_time',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOS(22, _omitFieldNames ? '' : 'reported_source_time')
    ..aOM<$0.Timestamp>(23, _omitFieldNames ? '' : 'observed_at',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOM<$0.Timestamp>(24, _omitFieldNames ? '' : 'processed_at',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOM<RawReference>(25, _omitFieldNames ? '' : 'raw',
        subBuilder: RawReference.$_createMessage)
    ..aOM<Pipeline>(26, _omitFieldNames ? '' : 'pipeline',
        subBuilder: Pipeline.$_createMessage)
    ..m<$core.String, $core.String>(27, _omitFieldNames ? '' : 'extensions',
        entryClassName: 'CanonicalEvent.ExtensionsEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('correlia.event.v1'))
    ..m<$core.String, IdentityComponent>(
        28, _omitFieldNames ? '' : 'identity_fields',
        entryClassName: 'CanonicalEvent.IdentityFieldsEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OM,
        valueCreator: IdentityComponent.$_createMessage,
        valueDefaultOrMaker: IdentityComponent.getDefault,
        packageName: const $pb.PackageName('correlia.event.v1'))
    ..a<$core.List<$core.int>>(
        29, _omitFieldNames ? '' : 'observation_key', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CanonicalEvent clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CanonicalEvent copyWith(void Function(CanonicalEvent) updates) =>
      super.copyWith((message) => updates(message as CanonicalEvent))
          as CanonicalEvent;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CanonicalEvent() / CanonicalEvent.new instead')
  static CanonicalEvent create() => CanonicalEvent._();
  static $pb.GeneratedMessage $_createMessage() => CanonicalEvent._();
  @$core.override
  CanonicalEvent createEmptyInstance() => CanonicalEvent._();
  @$core.pragma('dart2js:noInline')
  static CanonicalEvent getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CanonicalEvent>(
          CanonicalEvent.$_createMessage);
  static CanonicalEvent? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get eventId => $_getSZ(0);
  @$pb.TagNumber(1)
  set eventId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasEventId() => $_has(0);
  @$pb.TagNumber(1)
  void clearEventId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get fingerprint => $_getSZ(1);
  @$pb.TagNumber(2)
  set fingerprint($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasFingerprint() => $_has(1);
  @$pb.TagNumber(2)
  void clearFingerprint() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get tenant => $_getSZ(2);
  @$pb.TagNumber(3)
  set tenant($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTenant() => $_has(2);
  @$pb.TagNumber(3)
  void clearTenant() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get namespace => $_getSZ(3);
  @$pb.TagNumber(4)
  set namespace($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasNamespace() => $_has(3);
  @$pb.TagNumber(4)
  void clearNamespace() => $_clearField(4);

  @$pb.TagNumber(5)
  EventKind get kind => $_getN(4);
  @$pb.TagNumber(5)
  set kind(EventKind value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasKind() => $_has(4);
  @$pb.TagNumber(5)
  void clearKind() => $_clearField(5);

  @$pb.TagNumber(6)
  EventStatus get status => $_getN(5);
  @$pb.TagNumber(6)
  set status(EventStatus value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasStatus() => $_has(5);
  @$pb.TagNumber(6)
  void clearStatus() => $_clearField(6);

  @$pb.TagNumber(7)
  EventSeverity get severity => $_getN(6);
  @$pb.TagNumber(7)
  set severity(EventSeverity value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasSeverity() => $_has(6);
  @$pb.TagNumber(7)
  void clearSeverity() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.int get severityNumber => $_getIZ(7);
  @$pb.TagNumber(8)
  set severityNumber($core.int value) => $_setUnsignedInt32(7, value);
  @$pb.TagNumber(8)
  $core.bool hasSeverityNumber() => $_has(7);
  @$pb.TagNumber(8)
  void clearSeverityNumber() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.String get severityOriginal => $_getSZ(8);
  @$pb.TagNumber(9)
  set severityOriginal($core.String value) => $_setString(8, value);
  @$pb.TagNumber(9)
  $core.bool hasSeverityOriginal() => $_has(8);
  @$pb.TagNumber(9)
  void clearSeverityOriginal() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.String get dedupKey => $_getSZ(9);
  @$pb.TagNumber(10)
  set dedupKey($core.String value) => $_setString(9, value);
  @$pb.TagNumber(10)
  $core.bool hasDedupKey() => $_has(9);
  @$pb.TagNumber(10)
  void clearDedupKey() => $_clearField(10);

  @$pb.TagNumber(11)
  $core.String get summary => $_getSZ(10);
  @$pb.TagNumber(11)
  set summary($core.String value) => $_setString(10, value);
  @$pb.TagNumber(11)
  $core.bool hasSummary() => $_has(10);
  @$pb.TagNumber(11)
  void clearSummary() => $_clearField(11);

  @$pb.TagNumber(12)
  $core.String get description => $_getSZ(11);
  @$pb.TagNumber(12)
  set description($core.String value) => $_setString(11, value);
  @$pb.TagNumber(12)
  $core.bool hasDescription() => $_has(11);
  @$pb.TagNumber(12)
  void clearDescription() => $_clearField(12);

  @$pb.TagNumber(13)
  $pb.PbMap<$core.String, $core.String> get resource => $_getMap(12);

  @$pb.TagNumber(14)
  Observer get observer => $_getN(13);
  @$pb.TagNumber(14)
  set observer(Observer value) => $_setField(14, value);
  @$pb.TagNumber(14)
  $core.bool hasObserver() => $_has(13);
  @$pb.TagNumber(14)
  void clearObserver() => $_clearField(14);
  @$pb.TagNumber(14)
  Observer ensureObserver() => $_ensure(13);

  @$pb.TagNumber(15)
  $pb.PbMap<$core.String, $core.String> get labels => $_getMap(14);

  @$pb.TagNumber(16)
  $pb.PbMap<$core.String, $core.String> get labelsOrigin => $_getMap(15);

  @$pb.TagNumber(17)
  $pb.PbMap<$core.String, $core.String> get annotations => $_getMap(16);

  @$pb.TagNumber(18)
  $pb.PbList<Link> get links => $_getList(17);

  @$pb.TagNumber(19)
  $0.Timestamp get startsAt => $_getN(18);
  @$pb.TagNumber(19)
  set startsAt($0.Timestamp value) => $_setField(19, value);
  @$pb.TagNumber(19)
  $core.bool hasStartsAt() => $_has(18);
  @$pb.TagNumber(19)
  void clearStartsAt() => $_clearField(19);
  @$pb.TagNumber(19)
  $0.Timestamp ensureStartsAt() => $_ensure(18);

  @$pb.TagNumber(20)
  $0.Timestamp get endsAt => $_getN(19);
  @$pb.TagNumber(20)
  set endsAt($0.Timestamp value) => $_setField(20, value);
  @$pb.TagNumber(20)
  $core.bool hasEndsAt() => $_has(19);
  @$pb.TagNumber(20)
  void clearEndsAt() => $_clearField(20);
  @$pb.TagNumber(20)
  $0.Timestamp ensureEndsAt() => $_ensure(19);

  @$pb.TagNumber(21)
  $0.Timestamp get sourceTime => $_getN(20);
  @$pb.TagNumber(21)
  set sourceTime($0.Timestamp value) => $_setField(21, value);
  @$pb.TagNumber(21)
  $core.bool hasSourceTime() => $_has(20);
  @$pb.TagNumber(21)
  void clearSourceTime() => $_clearField(21);
  @$pb.TagNumber(21)
  $0.Timestamp ensureSourceTime() => $_ensure(20);

  @$pb.TagNumber(22)
  $core.String get reportedSourceTime => $_getSZ(21);
  @$pb.TagNumber(22)
  set reportedSourceTime($core.String value) => $_setString(21, value);
  @$pb.TagNumber(22)
  $core.bool hasReportedSourceTime() => $_has(21);
  @$pb.TagNumber(22)
  void clearReportedSourceTime() => $_clearField(22);

  @$pb.TagNumber(23)
  $0.Timestamp get observedAt => $_getN(22);
  @$pb.TagNumber(23)
  set observedAt($0.Timestamp value) => $_setField(23, value);
  @$pb.TagNumber(23)
  $core.bool hasObservedAt() => $_has(22);
  @$pb.TagNumber(23)
  void clearObservedAt() => $_clearField(23);
  @$pb.TagNumber(23)
  $0.Timestamp ensureObservedAt() => $_ensure(22);

  @$pb.TagNumber(24)
  $0.Timestamp get processedAt => $_getN(23);
  @$pb.TagNumber(24)
  set processedAt($0.Timestamp value) => $_setField(24, value);
  @$pb.TagNumber(24)
  $core.bool hasProcessedAt() => $_has(23);
  @$pb.TagNumber(24)
  void clearProcessedAt() => $_clearField(24);
  @$pb.TagNumber(24)
  $0.Timestamp ensureProcessedAt() => $_ensure(23);

  @$pb.TagNumber(25)
  RawReference get raw => $_getN(24);
  @$pb.TagNumber(25)
  set raw(RawReference value) => $_setField(25, value);
  @$pb.TagNumber(25)
  $core.bool hasRaw() => $_has(24);
  @$pb.TagNumber(25)
  void clearRaw() => $_clearField(25);
  @$pb.TagNumber(25)
  RawReference ensureRaw() => $_ensure(24);

  @$pb.TagNumber(26)
  Pipeline get pipeline => $_getN(25);
  @$pb.TagNumber(26)
  set pipeline(Pipeline value) => $_setField(26, value);
  @$pb.TagNumber(26)
  $core.bool hasPipeline() => $_has(25);
  @$pb.TagNumber(26)
  void clearPipeline() => $_clearField(26);
  @$pb.TagNumber(26)
  Pipeline ensurePipeline() => $_ensure(25);

  @$pb.TagNumber(27)
  $pb.PbMap<$core.String, $core.String> get extensions => $_getMap(26);

  @$pb.TagNumber(28)
  $pb.PbMap<$core.String, IdentityComponent> get identityFields => $_getMap(27);

  @$pb.TagNumber(29)
  $core.List<$core.int> get observationKey => $_getN(28);
  @$pb.TagNumber(29)
  set observationKey($core.List<$core.int> value) => $_setBytes(28, value);
  @$pb.TagNumber(29)
  $core.bool hasObservationKey() => $_has(28);
  @$pb.TagNumber(29)
  void clearObservationKey() => $_clearField(29);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
