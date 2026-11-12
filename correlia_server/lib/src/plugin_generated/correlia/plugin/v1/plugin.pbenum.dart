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

import 'package:protobuf/protobuf.dart' as $pb;

/// DeliveryOutcome distinguishes successful, transient and permanent results.
class DeliveryOutcome extends $pb.ProtobufEnum {
  static const DeliveryOutcome DELIVERY_OUTCOME_UNSPECIFIED = DeliveryOutcome._(
      0, _omitEnumNames ? '' : 'DELIVERY_OUTCOME_UNSPECIFIED');
  static const DeliveryOutcome DELIVERY_OUTCOME_ACKNOWLEDGED =
      DeliveryOutcome._(
          1, _omitEnumNames ? '' : 'DELIVERY_OUTCOME_ACKNOWLEDGED');
  static const DeliveryOutcome DELIVERY_OUTCOME_RETRYABLE =
      DeliveryOutcome._(2, _omitEnumNames ? '' : 'DELIVERY_OUTCOME_RETRYABLE');
  static const DeliveryOutcome DELIVERY_OUTCOME_REJECTED =
      DeliveryOutcome._(3, _omitEnumNames ? '' : 'DELIVERY_OUTCOME_REJECTED');

  static const $core.List<DeliveryOutcome> values = <DeliveryOutcome>[
    DELIVERY_OUTCOME_UNSPECIFIED,
    DELIVERY_OUTCOME_ACKNOWLEDGED,
    DELIVERY_OUTCOME_RETRYABLE,
    DELIVERY_OUTCOME_REJECTED,
  ];

  static final $core.List<DeliveryOutcome?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static DeliveryOutcome? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const DeliveryOutcome._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
