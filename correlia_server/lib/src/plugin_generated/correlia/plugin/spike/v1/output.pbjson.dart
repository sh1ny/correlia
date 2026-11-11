// This is a generated file - do not edit.
//
// Generated from correlia/plugin/spike/v1/output.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use deliverRequestDescriptor instead')
const DeliverRequest$json = {
  '1': 'DeliverRequest',
  '2': [
    {'1': 'epoch', '3': 1, '4': 1, '5': 9, '10': 'epoch'},
    {'1': 'sequence', '3': 2, '4': 1, '5': 4, '10': 'sequence'},
    {
      '1': 'events',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.correlia.plugin.spike.v1.Event',
      '10': 'events'
    },
  ],
};

/// Descriptor for `DeliverRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deliverRequestDescriptor = $convert.base64Decode(
    'Cg5EZWxpdmVyUmVxdWVzdBIUCgVlcG9jaBgBIAEoCVIFZXBvY2gSGgoIc2VxdWVuY2UYAiABKA'
    'RSCHNlcXVlbmNlEjcKBmV2ZW50cxgDIAMoCzIfLmNvcnJlbGlhLnBsdWdpbi5zcGlrZS52MS5F'
    'dmVudFIGZXZlbnRz');

@$core.Deprecated('Use eventDescriptor instead')
const Event$json = {
  '1': 'Event',
  '2': [
    {'1': 'event_id', '3': 1, '4': 1, '5': 9, '10': 'eventId'},
    {'1': 'canonical_json', '3': 2, '4': 1, '5': 12, '10': 'canonicalJson'},
  ],
};

/// Descriptor for `Event`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List eventDescriptor = $convert.base64Decode(
    'CgVFdmVudBIZCghldmVudF9pZBgBIAEoCVIHZXZlbnRJZBIlCg5jYW5vbmljYWxfanNvbhgCIA'
    'EoDFINY2Fub25pY2FsSnNvbg==');

@$core.Deprecated('Use deliverResponseDescriptor instead')
const DeliverResponse$json = {
  '1': 'DeliverResponse',
  '2': [
    {'1': 'epoch', '3': 1, '4': 1, '5': 9, '10': 'epoch'},
    {'1': 'sequence', '3': 2, '4': 1, '5': 4, '10': 'sequence'},
  ],
};

/// Descriptor for `DeliverResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deliverResponseDescriptor = $convert.base64Decode(
    'Cg9EZWxpdmVyUmVzcG9uc2USFAoFZXBvY2gYASABKAlSBWVwb2NoEhoKCHNlcXVlbmNlGAIgAS'
    'gEUghzZXF1ZW5jZQ==');
