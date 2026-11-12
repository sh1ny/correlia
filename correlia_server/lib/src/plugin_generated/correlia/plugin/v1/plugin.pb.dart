// This is a generated file - do not edit.
//
// Generated from correlia/plugin/v1/plugin.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'plugin.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'plugin.pbenum.dart';

class GetMetadataRequest extends $pb.GeneratedMessage {
  factory GetMetadataRequest() => GetMetadataRequest._();

  GetMetadataRequest._();

  factory GetMetadataRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMetadataRequest()..mergeFromBuffer(data, registry);
  factory GetMetadataRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMetadataRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetMetadataRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: GetMetadataRequest.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMetadataRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMetadataRequest copyWith(void Function(GetMetadataRequest) updates) =>
      super.copyWith((message) => updates(message as GetMetadataRequest))
          as GetMetadataRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetMetadataRequest() / GetMetadataRequest.new instead')
  static GetMetadataRequest create() => GetMetadataRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetMetadataRequest._();
  @$core.override
  GetMetadataRequest createEmptyInstance() => GetMetadataRequest._();
  @$core.pragma('dart2js:noInline')
  static GetMetadataRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetMetadataRequest>(
          GetMetadataRequest.$_createMessage);
  static GetMetadataRequest? _defaultInstance;
}

class GetMetadataResponse extends $pb.GeneratedMessage {
  factory GetMetadataResponse({
    $core.String? name,
    $core.String? version,
    $core.Iterable<$core.String>? kinds,
    $core.List<$core.int>? configSchemaJson,
    $core.int? protocolMinor,
  }) {
    final result = GetMetadataResponse._();
    if (name != null) result.name = name;
    if (version != null) result.version = version;
    if (kinds != null) result.kinds.addAll(kinds);
    if (configSchemaJson != null) result.configSchemaJson = configSchemaJson;
    if (protocolMinor != null) result.protocolMinor = protocolMinor;
    return result;
  }

  GetMetadataResponse._();

  factory GetMetadataResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMetadataResponse()..mergeFromBuffer(data, registry);
  factory GetMetadataResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMetadataResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetMetadataResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: GetMetadataResponse.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'version')
    ..pPS(3, _omitFieldNames ? '' : 'kinds')
    ..a<$core.List<$core.int>>(
        4, _omitFieldNames ? '' : 'configSchemaJson', $pb.PbFieldType.OY)
    ..aI(5, _omitFieldNames ? '' : 'protocolMinor',
        fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMetadataResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMetadataResponse copyWith(void Function(GetMetadataResponse) updates) =>
      super.copyWith((message) => updates(message as GetMetadataResponse))
          as GetMetadataResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use GetMetadataResponse() / GetMetadataResponse.new instead')
  static GetMetadataResponse create() => GetMetadataResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetMetadataResponse._();
  @$core.override
  GetMetadataResponse createEmptyInstance() => GetMetadataResponse._();
  @$core.pragma('dart2js:noInline')
  static GetMetadataResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetMetadataResponse>(
          GetMetadataResponse.$_createMessage);
  static GetMetadataResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get version => $_getSZ(1);
  @$pb.TagNumber(2)
  set version($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearVersion() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get kinds => $_getList(2);

  @$pb.TagNumber(4)
  $core.List<$core.int> get configSchemaJson => $_getN(3);
  @$pb.TagNumber(4)
  set configSchemaJson($core.List<$core.int> value) => $_setBytes(3, value);
  @$pb.TagNumber(4)
  $core.bool hasConfigSchemaJson() => $_has(3);
  @$pb.TagNumber(4)
  void clearConfigSchemaJson() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get protocolMinor => $_getIZ(4);
  @$pb.TagNumber(5)
  set protocolMinor($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasProtocolMinor() => $_has(4);
  @$pb.TagNumber(5)
  void clearProtocolMinor() => $_clearField(5);
}

/// DeliveryLimits bounds batch size and outstanding batches.
class DeliveryLimits extends $pb.GeneratedMessage {
  factory DeliveryLimits({
    $core.int? maxEventsPerBatch,
    $fixnum.Int64? maxBytesPerBatch,
    $core.int? maxOutstandingBatches,
  }) {
    final result = DeliveryLimits._();
    if (maxEventsPerBatch != null) result.maxEventsPerBatch = maxEventsPerBatch;
    if (maxBytesPerBatch != null) result.maxBytesPerBatch = maxBytesPerBatch;
    if (maxOutstandingBatches != null)
      result.maxOutstandingBatches = maxOutstandingBatches;
    return result;
  }

  DeliveryLimits._();

  factory DeliveryLimits.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeliveryLimits()..mergeFromBuffer(data, registry);
  factory DeliveryLimits.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeliveryLimits()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeliveryLimits',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: DeliveryLimits.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'maxEventsPerBatch',
        fieldType: $pb.PbFieldType.OU3)
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'maxBytesPerBatch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aI(3, _omitFieldNames ? '' : 'maxOutstandingBatches',
        fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeliveryLimits clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeliveryLimits copyWith(void Function(DeliveryLimits) updates) =>
      super.copyWith((message) => updates(message as DeliveryLimits))
          as DeliveryLimits;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DeliveryLimits() / DeliveryLimits.new instead')
  static DeliveryLimits create() => DeliveryLimits._();
  static $pb.GeneratedMessage $_createMessage() => DeliveryLimits._();
  @$core.override
  DeliveryLimits createEmptyInstance() => DeliveryLimits._();
  @$core.pragma('dart2js:noInline')
  static DeliveryLimits getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<DeliveryLimits>(
          DeliveryLimits.$_createMessage);
  static DeliveryLimits? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get maxEventsPerBatch => $_getIZ(0);
  @$pb.TagNumber(1)
  set maxEventsPerBatch($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMaxEventsPerBatch() => $_has(0);
  @$pb.TagNumber(1)
  void clearMaxEventsPerBatch() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get maxBytesPerBatch => $_getI64(1);
  @$pb.TagNumber(2)
  set maxBytesPerBatch($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMaxBytesPerBatch() => $_has(1);
  @$pb.TagNumber(2)
  void clearMaxBytesPerBatch() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get maxOutstandingBatches => $_getIZ(2);
  @$pb.TagNumber(3)
  set maxOutstandingBatches($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMaxOutstandingBatches() => $_has(2);
  @$pb.TagNumber(3)
  void clearMaxOutstandingBatches() => $_clearField(3);
}

class ConfigureRequest extends $pb.GeneratedMessage {
  factory ConfigureRequest({
    $core.List<$core.int>? configJson,
    $core.Iterable<$core.MapEntry<$core.String, $core.List<$core.int>>>?
        secrets,
    DeliveryLimits? limits,
  }) {
    final result = ConfigureRequest._();
    if (configJson != null) result.configJson = configJson;
    if (secrets != null) result.secrets.addEntries(secrets);
    if (limits != null) result.limits = limits;
    return result;
  }

  ConfigureRequest._();

  factory ConfigureRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConfigureRequest()..mergeFromBuffer(data, registry);
  factory ConfigureRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConfigureRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ConfigureRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: ConfigureRequest.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'configJson', $pb.PbFieldType.OY)
    ..m<$core.String, $core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'secrets',
        entryClassName: 'ConfigureRequest.SecretsEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OY,
        packageName: const $pb.PackageName('correlia.plugin.v1'))
    ..aOM<DeliveryLimits>(3, _omitFieldNames ? '' : 'limits',
        subBuilder: DeliveryLimits.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConfigureRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConfigureRequest copyWith(void Function(ConfigureRequest) updates) =>
      super.copyWith((message) => updates(message as ConfigureRequest))
          as ConfigureRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ConfigureRequest() / ConfigureRequest.new instead')
  static ConfigureRequest create() => ConfigureRequest._();
  static $pb.GeneratedMessage $_createMessage() => ConfigureRequest._();
  @$core.override
  ConfigureRequest createEmptyInstance() => ConfigureRequest._();
  @$core.pragma('dart2js:noInline')
  static ConfigureRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ConfigureRequest>(
          ConfigureRequest.$_createMessage);
  static ConfigureRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get configJson => $_getN(0);
  @$pb.TagNumber(1)
  set configJson($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConfigJson() => $_has(0);
  @$pb.TagNumber(1)
  void clearConfigJson() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbMap<$core.String, $core.List<$core.int>> get secrets => $_getMap(1);

  @$pb.TagNumber(3)
  DeliveryLimits get limits => $_getN(2);
  @$pb.TagNumber(3)
  set limits(DeliveryLimits value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasLimits() => $_has(2);
  @$pb.TagNumber(3)
  void clearLimits() => $_clearField(3);
  @$pb.TagNumber(3)
  DeliveryLimits ensureLimits() => $_ensure(2);
}

/// FieldError identifies an invalid configuration or secret key without its value.
class FieldError extends $pb.GeneratedMessage {
  factory FieldError({
    $core.String? field_1,
    $core.String? message,
  }) {
    final result = FieldError._();
    if (field_1 != null) result.field_1 = field_1;
    if (message != null) result.message = message;
    return result;
  }

  FieldError._();

  factory FieldError.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FieldError()..mergeFromBuffer(data, registry);
  factory FieldError.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FieldError()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FieldError',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: FieldError.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'field')
    ..aOS(2, _omitFieldNames ? '' : 'message')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FieldError clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FieldError copyWith(void Function(FieldError) updates) =>
      super.copyWith((message) => updates(message as FieldError)) as FieldError;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use FieldError() / FieldError.new instead')
  static FieldError create() => FieldError._();
  static $pb.GeneratedMessage $_createMessage() => FieldError._();
  @$core.override
  FieldError createEmptyInstance() => FieldError._();
  @$core.pragma('dart2js:noInline')
  static FieldError getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FieldError>(FieldError.$_createMessage);
  static FieldError? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get field_1 => $_getSZ(0);
  @$pb.TagNumber(1)
  set field_1($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasField_1() => $_has(0);
  @$pb.TagNumber(1)
  void clearField_1() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get message => $_getSZ(1);
  @$pb.TagNumber(2)
  set message($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearMessage() => $_clearField(2);
}

class ConfigureResponse extends $pb.GeneratedMessage {
  factory ConfigureResponse({
    $core.bool? accepted,
    DeliveryLimits? limits,
    $core.Iterable<FieldError>? fieldErrors,
    $core.String? errorClass,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>?
        configurationInfo,
  }) {
    final result = ConfigureResponse._();
    if (accepted != null) result.accepted = accepted;
    if (limits != null) result.limits = limits;
    if (fieldErrors != null) result.fieldErrors.addAll(fieldErrors);
    if (errorClass != null) result.errorClass = errorClass;
    if (configurationInfo != null)
      result.configurationInfo.addEntries(configurationInfo);
    return result;
  }

  ConfigureResponse._();

  factory ConfigureResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConfigureResponse()..mergeFromBuffer(data, registry);
  factory ConfigureResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConfigureResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ConfigureResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: ConfigureResponse.$_createMessage)
    ..aOB(1, _omitFieldNames ? '' : 'accepted')
    ..aOM<DeliveryLimits>(2, _omitFieldNames ? '' : 'limits',
        subBuilder: DeliveryLimits.$_createMessage)
    ..pPM<FieldError>(3, _omitFieldNames ? '' : 'fieldErrors',
        subBuilder: FieldError.$_createMessage)
    ..aOS(4, _omitFieldNames ? '' : 'errorClass')
    ..m<$core.String, $core.String>(
        5, _omitFieldNames ? '' : 'configurationInfo',
        entryClassName: 'ConfigureResponse.ConfigurationInfoEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('correlia.plugin.v1'))
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConfigureResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConfigureResponse copyWith(void Function(ConfigureResponse) updates) =>
      super.copyWith((message) => updates(message as ConfigureResponse))
          as ConfigureResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ConfigureResponse() / ConfigureResponse.new instead')
  static ConfigureResponse create() => ConfigureResponse._();
  static $pb.GeneratedMessage $_createMessage() => ConfigureResponse._();
  @$core.override
  ConfigureResponse createEmptyInstance() => ConfigureResponse._();
  @$core.pragma('dart2js:noInline')
  static ConfigureResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ConfigureResponse>(
          ConfigureResponse.$_createMessage);
  static ConfigureResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get accepted => $_getBF(0);
  @$pb.TagNumber(1)
  set accepted($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAccepted() => $_has(0);
  @$pb.TagNumber(1)
  void clearAccepted() => $_clearField(1);

  @$pb.TagNumber(2)
  DeliveryLimits get limits => $_getN(1);
  @$pb.TagNumber(2)
  set limits(DeliveryLimits value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasLimits() => $_has(1);
  @$pb.TagNumber(2)
  void clearLimits() => $_clearField(2);
  @$pb.TagNumber(2)
  DeliveryLimits ensureLimits() => $_ensure(1);

  @$pb.TagNumber(3)
  $pb.PbList<FieldError> get fieldErrors => $_getList(2);

  /// Empty on acceptance; a bounded, value-free class on rejection.
  @$pb.TagNumber(4)
  $core.String get errorClass => $_getSZ(3);
  @$pb.TagNumber(4)
  set errorClass($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasErrorClass() => $_has(3);
  @$pb.TagNumber(4)
  void clearErrorClass() => $_clearField(4);

  /// Non-secret information returned only for accepted configurations.
  @$pb.TagNumber(5)
  $pb.PbMap<$core.String, $core.String> get configurationInfo => $_getMap(4);
}

class CheckHealthRequest extends $pb.GeneratedMessage {
  factory CheckHealthRequest() => CheckHealthRequest._();

  CheckHealthRequest._();

  factory CheckHealthRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckHealthRequest()..mergeFromBuffer(data, registry);
  factory CheckHealthRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckHealthRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CheckHealthRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: CheckHealthRequest.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckHealthRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckHealthRequest copyWith(void Function(CheckHealthRequest) updates) =>
      super.copyWith((message) => updates(message as CheckHealthRequest))
          as CheckHealthRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CheckHealthRequest() / CheckHealthRequest.new instead')
  static CheckHealthRequest create() => CheckHealthRequest._();
  static $pb.GeneratedMessage $_createMessage() => CheckHealthRequest._();
  @$core.override
  CheckHealthRequest createEmptyInstance() => CheckHealthRequest._();
  @$core.pragma('dart2js:noInline')
  static CheckHealthRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CheckHealthRequest>(
          CheckHealthRequest.$_createMessage);
  static CheckHealthRequest? _defaultInstance;
}

class CheckHealthResponse extends $pb.GeneratedMessage {
  factory CheckHealthResponse({
    $core.bool? serving,
    $core.String? reason,
  }) {
    final result = CheckHealthResponse._();
    if (serving != null) result.serving = serving;
    if (reason != null) result.reason = reason;
    return result;
  }

  CheckHealthResponse._();

  factory CheckHealthResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckHealthResponse()..mergeFromBuffer(data, registry);
  factory CheckHealthResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckHealthResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CheckHealthResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: CheckHealthResponse.$_createMessage)
    ..aOB(1, _omitFieldNames ? '' : 'serving')
    ..aOS(2, _omitFieldNames ? '' : 'reason')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckHealthResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckHealthResponse copyWith(void Function(CheckHealthResponse) updates) =>
      super.copyWith((message) => updates(message as CheckHealthResponse))
          as CheckHealthResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use CheckHealthResponse() / CheckHealthResponse.new instead')
  static CheckHealthResponse create() => CheckHealthResponse._();
  static $pb.GeneratedMessage $_createMessage() => CheckHealthResponse._();
  @$core.override
  CheckHealthResponse createEmptyInstance() => CheckHealthResponse._();
  @$core.pragma('dart2js:noInline')
  static CheckHealthResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CheckHealthResponse>(
          CheckHealthResponse.$_createMessage);
  static CheckHealthResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get serving => $_getBF(0);
  @$pb.TagNumber(1)
  set serving($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasServing() => $_has(0);
  @$pb.TagNumber(1)
  void clearServing() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get reason => $_getSZ(1);
  @$pb.TagNumber(2)
  set reason($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasReason() => $_has(1);
  @$pb.TagNumber(2)
  void clearReason() => $_clearField(2);
}

/// Event contains the exact stored bytes and their stable event identifier.
class Event extends $pb.GeneratedMessage {
  factory Event({
    $core.String? eventId,
    $core.List<$core.int>? payload,
  }) {
    final result = Event._();
    if (eventId != null) result.eventId = eventId;
    if (payload != null) result.payload = payload;
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
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: Event.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'eventId')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'payload', $pb.PbFieldType.OY)
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
  $core.List<$core.int> get payload => $_getN(1);
  @$pb.TagNumber(2)
  set payload($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPayload() => $_has(1);
  @$pb.TagNumber(2)
  void clearPayload() => $_clearField(2);
}

class DeliverRequest extends $pb.GeneratedMessage {
  factory DeliverRequest({
    $fixnum.Int64? sequence,
    $core.Iterable<Event>? events,
  }) {
    final result = DeliverRequest._();
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
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: DeliverRequest.$_createMessage)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'sequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..pPM<Event>(2, _omitFieldNames ? '' : 'events',
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
  $fixnum.Int64 get sequence => $_getI64(0);
  @$pb.TagNumber(1)
  set sequence($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSequence() => $_has(0);
  @$pb.TagNumber(1)
  void clearSequence() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<Event> get events => $_getList(1);
}

/// EventResult is one event's outcome in a batch.
class EventResult extends $pb.GeneratedMessage {
  factory EventResult({
    $core.String? eventId,
    DeliveryOutcome? outcome,
    $core.String? errorClass,
  }) {
    final result = EventResult._();
    if (eventId != null) result.eventId = eventId;
    if (outcome != null) result.outcome = outcome;
    if (errorClass != null) result.errorClass = errorClass;
    return result;
  }

  EventResult._();

  factory EventResult.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EventResult()..mergeFromBuffer(data, registry);
  factory EventResult.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EventResult()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EventResult',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: EventResult.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'eventId')
    ..aE<DeliveryOutcome>(2, _omitFieldNames ? '' : 'outcome',
        enumValues: DeliveryOutcome.values)
    ..aOS(3, _omitFieldNames ? '' : 'errorClass')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EventResult clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EventResult copyWith(void Function(EventResult) updates) =>
      super.copyWith((message) => updates(message as EventResult))
          as EventResult;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use EventResult() / EventResult.new instead')
  static EventResult create() => EventResult._();
  static $pb.GeneratedMessage $_createMessage() => EventResult._();
  @$core.override
  EventResult createEmptyInstance() => EventResult._();
  @$core.pragma('dart2js:noInline')
  static EventResult getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<EventResult>(
          EventResult.$_createMessage);
  static EventResult? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get eventId => $_getSZ(0);
  @$pb.TagNumber(1)
  set eventId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasEventId() => $_has(0);
  @$pb.TagNumber(1)
  void clearEventId() => $_clearField(1);

  @$pb.TagNumber(2)
  DeliveryOutcome get outcome => $_getN(1);
  @$pb.TagNumber(2)
  set outcome(DeliveryOutcome value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasOutcome() => $_has(1);
  @$pb.TagNumber(2)
  void clearOutcome() => $_clearField(2);

  /// Empty for acknowledged events; otherwise a bounded, value-free class.
  @$pb.TagNumber(3)
  $core.String get errorClass => $_getSZ(2);
  @$pb.TagNumber(3)
  set errorClass($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasErrorClass() => $_has(2);
  @$pb.TagNumber(3)
  void clearErrorClass() => $_clearField(3);
}

class DeliverResponse extends $pb.GeneratedMessage {
  factory DeliverResponse({
    $fixnum.Int64? sequence,
    $core.Iterable<EventResult>? results,
  }) {
    final result = DeliverResponse._();
    if (sequence != null) result.sequence = sequence;
    if (results != null) result.results.addAll(results);
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
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'correlia.plugin.v1'),
      createEmptyInstance: DeliverResponse.$_createMessage)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'sequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..pPM<EventResult>(2, _omitFieldNames ? '' : 'results',
        subBuilder: EventResult.$_createMessage)
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
  $fixnum.Int64 get sequence => $_getI64(0);
  @$pb.TagNumber(1)
  set sequence($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSequence() => $_has(0);
  @$pb.TagNumber(1)
  void clearSequence() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<EventResult> get results => $_getList(1);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
