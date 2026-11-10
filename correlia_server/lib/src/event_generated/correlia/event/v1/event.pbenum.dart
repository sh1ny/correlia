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

/// EventKind identifies the semantic kind of a canonical event.
class EventKind extends $pb.ProtobufEnum {
  static const EventKind EVENT_KIND_UNSPECIFIED =
      EventKind._(0, _omitEnumNames ? '' : 'EVENT_KIND_UNSPECIFIED');
  static const EventKind EVENT_KIND_ALERT =
      EventKind._(1, _omitEnumNames ? '' : 'EVENT_KIND_ALERT');
  static const EventKind EVENT_KIND_STATE =
      EventKind._(2, _omitEnumNames ? '' : 'EVENT_KIND_STATE');
  static const EventKind EVENT_KIND_ACK =
      EventKind._(3, _omitEnumNames ? '' : 'EVENT_KIND_ACK');
  static const EventKind EVENT_KIND_DOWNTIME =
      EventKind._(4, _omitEnumNames ? '' : 'EVENT_KIND_DOWNTIME');
  static const EventKind EVENT_KIND_COMMENT =
      EventKind._(5, _omitEnumNames ? '' : 'EVENT_KIND_COMMENT');
  static const EventKind EVENT_KIND_HEARTBEAT =
      EventKind._(6, _omitEnumNames ? '' : 'EVENT_KIND_HEARTBEAT');

  static const $core.List<EventKind> values = <EventKind>[
    EVENT_KIND_UNSPECIFIED,
    EVENT_KIND_ALERT,
    EVENT_KIND_STATE,
    EVENT_KIND_ACK,
    EVENT_KIND_DOWNTIME,
    EVENT_KIND_COMMENT,
    EVENT_KIND_HEARTBEAT,
  ];

  static final $core.List<EventKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static EventKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const EventKind._(super.value, super.name);
}

/// EventStatus identifies the lifecycle state of a canonical event.
class EventStatus extends $pb.ProtobufEnum {
  static const EventStatus EVENT_STATUS_UNSPECIFIED =
      EventStatus._(0, _omitEnumNames ? '' : 'EVENT_STATUS_UNSPECIFIED');
  static const EventStatus EVENT_STATUS_FIRING =
      EventStatus._(1, _omitEnumNames ? '' : 'EVENT_STATUS_FIRING');
  static const EventStatus EVENT_STATUS_RESOLVED =
      EventStatus._(2, _omitEnumNames ? '' : 'EVENT_STATUS_RESOLVED');
  static const EventStatus EVENT_STATUS_INFO =
      EventStatus._(3, _omitEnumNames ? '' : 'EVENT_STATUS_INFO');

  static const $core.List<EventStatus> values = <EventStatus>[
    EVENT_STATUS_UNSPECIFIED,
    EVENT_STATUS_FIRING,
    EVENT_STATUS_RESOLVED,
    EVENT_STATUS_INFO,
  ];

  static final $core.List<EventStatus?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static EventStatus? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const EventStatus._(super.value, super.name);
}

/// EventSeverity identifies the normalized severity of a canonical event.
class EventSeverity extends $pb.ProtobufEnum {
  static const EventSeverity EVENT_SEVERITY_UNSPECIFIED =
      EventSeverity._(0, _omitEnumNames ? '' : 'EVENT_SEVERITY_UNSPECIFIED');
  static const EventSeverity EVENT_SEVERITY_CRITICAL =
      EventSeverity._(1, _omitEnumNames ? '' : 'EVENT_SEVERITY_CRITICAL');
  static const EventSeverity EVENT_SEVERITY_ERROR =
      EventSeverity._(2, _omitEnumNames ? '' : 'EVENT_SEVERITY_ERROR');
  static const EventSeverity EVENT_SEVERITY_WARNING =
      EventSeverity._(3, _omitEnumNames ? '' : 'EVENT_SEVERITY_WARNING');
  static const EventSeverity EVENT_SEVERITY_INFO =
      EventSeverity._(4, _omitEnumNames ? '' : 'EVENT_SEVERITY_INFO');
  static const EventSeverity EVENT_SEVERITY_UNKNOWN =
      EventSeverity._(5, _omitEnumNames ? '' : 'EVENT_SEVERITY_UNKNOWN');

  static const $core.List<EventSeverity> values = <EventSeverity>[
    EVENT_SEVERITY_UNSPECIFIED,
    EVENT_SEVERITY_CRITICAL,
    EVENT_SEVERITY_ERROR,
    EVENT_SEVERITY_WARNING,
    EVENT_SEVERITY_INFO,
    EVENT_SEVERITY_UNKNOWN,
  ];

  static final $core.List<EventSeverity?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 5);
  static EventSeverity? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const EventSeverity._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
