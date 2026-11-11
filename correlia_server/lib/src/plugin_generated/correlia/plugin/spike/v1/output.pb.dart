// This is a generated file - do not edit.
//
// Generated from correlia/plugin/spike/v1/output.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

/// DeliverRequest identifies one batch within a connection epoch.
class DeliverRequest extends $pb.GeneratedMessage {
  factory DeliverRequest({
    $core.String? epoch,
    $fixnum.Int64? sequence,
    $core.Iterable<Event>? events,
  }) {
    final result = DeliverRequest._();
    if (epoch != null) result.epoch = epoch;
    if (sequence != null) result.sequence = sequence;
    if (events != null) result.events.addAll(events);
    return result;
  }

  DeliverRequest._();

  factory DeliverRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeliverRequest()..mergeFromBuffer(data, registry);
  factory DeliverRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeliverRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeliverRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'correlia.plugin.spike.v1'),
      createEmptyInstance: DeliverRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'epoch')
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'sequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..pPM<Event>(3, _omitFieldNames ? '' : 'events',
        subBuilder: Event.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeliverRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeliverRequest copyWith(void Function(DeliverRequest) updates) =>
      super.copyWith((message) => updates(message as DeliverRequest))
          as DeliverRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DeliverRequest() / DeliverRequest.new instead')
  static DeliverRequest create() => DeliverRequest._();
  static $pb.GeneratedMessage $_createMessage() => DeliverRequest._();
  @$core.override
  DeliverRequest createEmptyInstance() => DeliverRequest._();
  @$core.pragma('dart2js:noInline')
  static DeliverRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<DeliverRequest>(
          DeliverRequest.$_createMessage);
  static DeliverRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get epoch => $_getSZ(0);
  @$pb.TagNumber(1)
  set epoch($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasEpoch() => $_has(0);
  @$pb.TagNumber(1)
  void clearEpoch() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get sequence => $_getI64(1);
  @$pb.TagNumber(2)
  set sequence($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSequence() => $_has(1);
  @$pb.TagNumber(2)
  void clearSequence() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbList<Event> get events => $_getList(2);
}

/// Event carries the canonical structured JSON snapshot and its envelope id.
class Event extends $pb.GeneratedMessage {
  factory Event({
    $core.String? eventId,
    $core.List<$core.int>? canonicalJson,
  }) {
    final result = Event._();
    if (eventId != null) result.eventId = eventId;
    if (canonicalJson != null) result.canonicalJson = canonicalJson;
    return result;
  }

  Event._();

  factory Event.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Event()..mergeFromBuffer(data, registry);
  factory Event.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Event()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Event',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'correlia.plugin.spike.v1'),
      createEmptyInstance: Event.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'eventId')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'canonicalJson', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Event clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Event copyWith(void Function(Event) updates) =>
      super.copyWith((message) => updates(message as Event)) as Event;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Event() / Event.new instead')
  static Event create() => Event._();
  static $pb.GeneratedMessage $_createMessage() => Event._();
  @$core.override
  Event createEmptyInstance() => Event._();
  @$core.pragma('dart2js:noInline')
  static Event getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Event>(Event.$_createMessage);
  static Event? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get eventId => $_getSZ(0);
  @$pb.TagNumber(1)
  set eventId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasEventId() => $_has(0);
  @$pb.TagNumber(1)
  void clearEventId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get canonicalJson => $_getN(1);
  @$pb.TagNumber(2)
  set canonicalJson($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCanonicalJson() => $_has(1);
  @$pb.TagNumber(2)
  void clearCanonicalJson() => $_clearField(2);
}

/// DeliverResponse acknowledges the entire identified batch.
class DeliverResponse extends $pb.GeneratedMessage {
  factory DeliverResponse({
    $core.String? epoch,
    $fixnum.Int64? sequence,
  }) {
    final result = DeliverResponse._();
    if (epoch != null) result.epoch = epoch;
    if (sequence != null) result.sequence = sequence;
    return result;
  }

  DeliverResponse._();

  factory DeliverResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeliverResponse()..mergeFromBuffer(data, registry);
  factory DeliverResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeliverResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeliverResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'correlia.plugin.spike.v1'),
      createEmptyInstance: DeliverResponse.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'epoch')
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'sequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeliverResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeliverResponse copyWith(void Function(DeliverResponse) updates) =>
      super.copyWith((message) => updates(message as DeliverResponse))
          as DeliverResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DeliverResponse() / DeliverResponse.new instead')
  static DeliverResponse create() => DeliverResponse._();
  static $pb.GeneratedMessage $_createMessage() => DeliverResponse._();
  @$core.override
  DeliverResponse createEmptyInstance() => DeliverResponse._();
  @$core.pragma('dart2js:noInline')
  static DeliverResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<DeliverResponse>(
          DeliverResponse.$_createMessage);
  static DeliverResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get epoch => $_getSZ(0);
  @$pb.TagNumber(1)
  set epoch($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasEpoch() => $_has(0);
  @$pb.TagNumber(1)
  void clearEpoch() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get sequence => $_getI64(1);
  @$pb.TagNumber(2)
  set sequence($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSequence() => $_has(1);
  @$pb.TagNumber(2)
  void clearSequence() => $_clearField(2);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
