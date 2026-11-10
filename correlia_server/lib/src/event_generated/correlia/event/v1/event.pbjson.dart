// This is a generated file - do not edit.
//
// Generated from correlia/event/v1/event.proto.

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

@$core.Deprecated('Use eventKindDescriptor instead')
const EventKind$json = {
  '1': 'EventKind',
  '2': [
    {'1': 'EVENT_KIND_UNSPECIFIED', '2': 0},
    {'1': 'EVENT_KIND_ALERT', '2': 1},
    {'1': 'EVENT_KIND_STATE', '2': 2},
    {'1': 'EVENT_KIND_ACK', '2': 3},
    {'1': 'EVENT_KIND_DOWNTIME', '2': 4},
    {'1': 'EVENT_KIND_COMMENT', '2': 5},
    {'1': 'EVENT_KIND_HEARTBEAT', '2': 6},
  ],
};

/// Descriptor for `EventKind`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List eventKindDescriptor = $convert.base64Decode(
    'CglFdmVudEtpbmQSGgoWRVZFTlRfS0lORF9VTlNQRUNJRklFRBAAEhQKEEVWRU5UX0tJTkRfQU'
    'xFUlQQARIUChBFVkVOVF9LSU5EX1NUQVRFEAISEgoORVZFTlRfS0lORF9BQ0sQAxIXChNFVkVO'
    'VF9LSU5EX0RPV05USU1FEAQSFgoSRVZFTlRfS0lORF9DT01NRU5UEAUSGAoURVZFTlRfS0lORF'
    '9IRUFSVEJFQVQQBg==');

@$core.Deprecated('Use eventStatusDescriptor instead')
const EventStatus$json = {
  '1': 'EventStatus',
  '2': [
    {'1': 'EVENT_STATUS_UNSPECIFIED', '2': 0},
    {'1': 'EVENT_STATUS_FIRING', '2': 1},
    {'1': 'EVENT_STATUS_RESOLVED', '2': 2},
    {'1': 'EVENT_STATUS_INFO', '2': 3},
  ],
};

/// Descriptor for `EventStatus`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List eventStatusDescriptor = $convert.base64Decode(
    'CgtFdmVudFN0YXR1cxIcChhFVkVOVF9TVEFUVVNfVU5TUEVDSUZJRUQQABIXChNFVkVOVF9TVE'
    'FUVVNfRklSSU5HEAESGQoVRVZFTlRfU1RBVFVTX1JFU09MVkVEEAISFQoRRVZFTlRfU1RBVFVT'
    'X0lORk8QAw==');

@$core.Deprecated('Use eventSeverityDescriptor instead')
const EventSeverity$json = {
  '1': 'EventSeverity',
  '2': [
    {'1': 'EVENT_SEVERITY_UNSPECIFIED', '2': 0},
    {'1': 'EVENT_SEVERITY_CRITICAL', '2': 1},
    {'1': 'EVENT_SEVERITY_ERROR', '2': 2},
    {'1': 'EVENT_SEVERITY_WARNING', '2': 3},
    {'1': 'EVENT_SEVERITY_INFO', '2': 4},
    {'1': 'EVENT_SEVERITY_UNKNOWN', '2': 5},
  ],
};

/// Descriptor for `EventSeverity`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List eventSeverityDescriptor = $convert.base64Decode(
    'Cg1FdmVudFNldmVyaXR5Eh4KGkVWRU5UX1NFVkVSSVRZX1VOU1BFQ0lGSUVEEAASGwoXRVZFTl'
    'RfU0VWRVJJVFlfQ1JJVElDQUwQARIYChRFVkVOVF9TRVZFUklUWV9FUlJPUhACEhoKFkVWRU5U'
    'X1NFVkVSSVRZX1dBUk5JTkcQAxIXChNFVkVOVF9TRVZFUklUWV9JTkZPEAQSGgoWRVZFTlRfU0'
    'VWRVJJVFlfVU5LTk9XThAF');

@$core.Deprecated('Use observerDescriptor instead')
const Observer$json = {
  '1': 'Observer',
  '2': [
    {
      '1': 'source_instance',
      '3': 1,
      '4': 1,
      '5': 9,
      '8': {},
      '10': 'source_instance'
    },
    {'1': 'source_kind', '3': 2, '4': 1, '5': 9, '8': {}, '10': 'source_kind'},
    {
      '1': 'name',
      '3': 3,
      '4': 1,
      '5': 9,
      '8': {},
      '9': 0,
      '10': 'name',
      '17': true
    },
    {
      '1': 'version',
      '3': 4,
      '4': 1,
      '5': 9,
      '8': {},
      '9': 1,
      '10': 'version',
      '17': true
    },
  ],
  '8': [
    {'1': '_name'},
    {'1': '_version'},
  ],
};

/// Descriptor for `Observer`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List observerDescriptor = $convert.base64Decode(
    'CghPYnNlcnZlchJ1Cg9zb3VyY2VfaW5zdGFuY2UYASABKAlCS7pISMgBAXJDMj5eWzAtOWEtZl'
    '17OH0tWzAtOWEtZl17NH0tWzAtOWEtZl17NH0tWzAtOWEtZl17NH0tWzAtOWEtZl17MTJ9JJgB'
    'JFIPc291cmNlX2luc3RhbmNlEkEKC3NvdXJjZV9raW5kGAIgASgJQh+6SBzIAQFyFxABGEAyEV'
    '5bYS16XVthLXowLTlfXSokUgtzb3VyY2Vfa2luZBIhCgRuYW1lGAMgASgJQgi6SAVyAxiAAkgA'
    'UgRuYW1liAEBEicKB3ZlcnNpb24YBCABKAlCCLpIBXIDGIACSAFSB3ZlcnNpb26IAQFCBwoFX2'
    '5hbWVCCgoIX3ZlcnNpb24=');

@$core.Deprecated('Use linkDescriptor instead')
const Link$json = {
  '1': 'Link',
  '2': [
    {'1': 'href', '3': 1, '4': 1, '5': 9, '8': {}, '10': 'href'},
    {'1': 'relation', '3': 2, '4': 1, '5': 9, '8': {}, '10': 'relation'},
    {
      '1': 'text',
      '3': 3,
      '4': 1,
      '5': 9,
      '8': {},
      '9': 0,
      '10': 'text',
      '17': true
    },
  ],
  '8': [
    {'1': '_text'},
  ],
};

/// Descriptor for `Link`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List linkDescriptor = $convert.base64Decode(
    'CgRMaW5rEjAKBGhyZWYYASABKAlCHLpIGcgBAXIUEAEYgBAyDV5odHRwcz86Ly8uKyRSBGhyZW'
    'YSKAoIcmVsYXRpb24YAiABKAlCDLpICcgBAXIEEAEYQFIIcmVsYXRpb24SIQoEdGV4dBgDIAEo'
    'CUIIukgFcgMYgAJIAFIEdGV4dIgBAUIHCgVfdGV4dA==');

@$core.Deprecated('Use rawReferenceDescriptor instead')
const RawReference$json = {
  '1': 'RawReference',
  '2': [
    {'1': 'ref', '3': 1, '4': 1, '5': 9, '8': {}, '10': 'ref'},
    {'1': 'sha256', '3': 2, '4': 1, '5': 9, '8': {}, '10': 'sha256'},
    {'1': 'size', '3': 3, '4': 1, '5': 13, '8': {}, '10': 'size'},
  ],
};

/// Descriptor for `RawReference`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List rawReferenceDescriptor = $convert.base64Decode(
    'CgxSYXdSZWZlcmVuY2USHwoDcmVmGAEgASgJQg26SArIAQFyBRABGIACUgNyZWYSMwoGc2hhMj'
    'U2GAIgASgJQhu6SBjIAQFyEzIOXlswLTlhLWZdezY0fSSYAUBSBnNoYTI1NhIhCgRzaXplGAMg'
    'ASgNQg26SAoqCBj/////DygAUgRzaXpl');

@$core.Deprecated('Use enrichmentErrorDescriptor instead')
const EnrichmentError$json = {
  '1': 'EnrichmentError',
  '2': [
    {'1': 'stage', '3': 1, '4': 1, '5': 9, '8': {}, '10': 'stage'},
    {'1': 'code', '3': 2, '4': 1, '5': 9, '8': {}, '10': 'code'},
    {'1': 'message', '3': 3, '4': 1, '5': 9, '8': {}, '10': 'message'},
  ],
};

/// Descriptor for `EnrichmentError`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List enrichmentErrorDescriptor = $convert.base64Decode(
    'Cg9FbnJpY2htZW50RXJyb3ISIgoFc3RhZ2UYASABKAlCDLpICcgBAXIEEAEYQFIFc3RhZ2USIA'
    'oEY29kZRgCIAEoCUIMukgJyAEBcgQQARhAUgRjb2RlEicKB21lc3NhZ2UYAyABKAlCDbpICsgB'
    'AXIFEAEYgAJSB21lc3NhZ2U=');

@$core.Deprecated('Use pipelineDescriptor instead')
const Pipeline$json = {
  '1': 'Pipeline',
  '2': [
    {'1': 'version', '3': 1, '4': 1, '5': 9, '8': {}, '10': 'version'},
    {'1': 'generation', '3': 2, '4': 1, '5': 13, '8': {}, '10': 'generation'},
    {
      '1': 'stages_applied',
      '3': 3,
      '4': 3,
      '5': 9,
      '8': {},
      '10': 'stages_applied'
    },
    {
      '1': 'enrichment_errors',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.correlia.event.v1.EnrichmentError',
      '8': {},
      '10': 'enrichment_errors'
    },
    {
      '1': 'original_event_id',
      '3': 5,
      '4': 1,
      '5': 9,
      '8': {},
      '9': 0,
      '10': 'original_event_id',
      '17': true
    },
  ],
  '8': [
    {'1': '_original_event_id'},
  ],
};

/// Descriptor for `Pipeline`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pipelineDescriptor = $convert.base64Decode(
    'CghQaXBlbGluZRInCgd2ZXJzaW9uGAEgASgJQg26SArIAQFyBRABGIABUgd2ZXJzaW9uEi0KCm'
    'dlbmVyYXRpb24YAiABKA1CDbpICioIGP////8PKABSCmdlbmVyYXRpb24SOAoOc3RhZ2VzX2Fw'
    'cGxpZWQYAyADKAlCELpIDZIBChAgIgZyBBABGEBSDnN0YWdlc19hcHBsaWVkEloKEWVucmljaG'
    '1lbnRfZXJyb3JzGAQgAygLMiIuY29ycmVsaWEuZXZlbnQudjEuRW5yaWNobWVudEVycm9yQgi6'
    'SAWSAQIQIFIRZW5yaWNobWVudF9lcnJvcnMSewoRb3JpZ2luYWxfZXZlbnRfaWQYBSABKAlCSL'
    'pIRXJDMj5eWzAtOWEtZl17OH0tWzAtOWEtZl17NH0tWzAtOWEtZl17NH0tWzAtOWEtZl17NH0t'
    'WzAtOWEtZl17MTJ9JJgBJEgAUhFvcmlnaW5hbF9ldmVudF9pZIgBAUIUChJfb3JpZ2luYWxfZX'
    'ZlbnRfaWQ=');

@$core.Deprecated('Use identityComponentDescriptor instead')
const IdentityComponent$json = {
  '1': 'IdentityComponent',
  '2': [
    {'1': 'raw', '3': 1, '4': 1, '5': 9, '8': {}, '9': 0, '10': 'raw'},
    {'1': 'sha256', '3': 2, '4': 1, '5': 12, '8': {}, '9': 0, '10': 'sha256'},
  ],
  '8': [
    {'1': 'value', '2': {}},
  ],
};

/// Descriptor for `IdentityComponent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List identityComponentDescriptor = $convert.base64Decode(
    'ChFJZGVudGl0eUNvbXBvbmVudBIeCgNyYXcYASABKAlCCrpIB3IFEAAogAhIAFIDcmF3EiEKBn'
    'NoYTI1NhgCIAEoDEIHukgEegJoIEgAUgZzaGEyNTZCDgoFdmFsdWUSBbpIAggB');

@$core.Deprecated('Use canonicalEventDescriptor instead')
const CanonicalEvent$json = {
  '1': 'CanonicalEvent',
  '2': [
    {'1': 'event_id', '3': 1, '4': 1, '5': 9, '8': {}, '10': 'event_id'},
    {'1': 'fingerprint', '3': 2, '4': 1, '5': 9, '8': {}, '10': 'fingerprint'},
    {'1': 'tenant', '3': 3, '4': 1, '5': 9, '8': {}, '10': 'tenant'},
    {'1': 'namespace', '3': 4, '4': 1, '5': 9, '8': {}, '10': 'namespace'},
    {
      '1': 'kind',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.correlia.event.v1.EventKind',
      '8': {},
      '10': 'kind'
    },
    {
      '1': 'status',
      '3': 6,
      '4': 1,
      '5': 14,
      '6': '.correlia.event.v1.EventStatus',
      '8': {},
      '10': 'status'
    },
    {
      '1': 'severity',
      '3': 7,
      '4': 1,
      '5': 14,
      '6': '.correlia.event.v1.EventSeverity',
      '8': {},
      '10': 'severity'
    },
    {
      '1': 'severity_number',
      '3': 8,
      '4': 1,
      '5': 13,
      '8': {},
      '9': 0,
      '10': 'severity_number',
      '17': true
    },
    {
      '1': 'severity_original',
      '3': 9,
      '4': 1,
      '5': 9,
      '8': {},
      '9': 1,
      '10': 'severity_original',
      '17': true
    },
    {
      '1': 'dedup_key',
      '3': 10,
      '4': 1,
      '5': 9,
      '8': {},
      '9': 2,
      '10': 'dedup_key',
      '17': true
    },
    {'1': 'summary', '3': 11, '4': 1, '5': 9, '8': {}, '10': 'summary'},
    {
      '1': 'description',
      '3': 12,
      '4': 1,
      '5': 9,
      '8': {},
      '9': 3,
      '10': 'description',
      '17': true
    },
    {
      '1': 'resource',
      '3': 13,
      '4': 3,
      '5': 11,
      '6': '.correlia.event.v1.CanonicalEvent.ResourceEntry',
      '8': {},
      '10': 'resource'
    },
    {
      '1': 'observer',
      '3': 14,
      '4': 1,
      '5': 11,
      '6': '.correlia.event.v1.Observer',
      '8': {},
      '10': 'observer'
    },
    {
      '1': 'labels',
      '3': 15,
      '4': 3,
      '5': 11,
      '6': '.correlia.event.v1.CanonicalEvent.LabelsEntry',
      '8': {},
      '10': 'labels'
    },
    {
      '1': 'labels_origin',
      '3': 16,
      '4': 3,
      '5': 11,
      '6': '.correlia.event.v1.CanonicalEvent.LabelsOriginEntry',
      '8': {},
      '10': 'labels_origin'
    },
    {
      '1': 'annotations',
      '3': 17,
      '4': 3,
      '5': 11,
      '6': '.correlia.event.v1.CanonicalEvent.AnnotationsEntry',
      '8': {},
      '10': 'annotations'
    },
    {
      '1': 'links',
      '3': 18,
      '4': 3,
      '5': 11,
      '6': '.correlia.event.v1.Link',
      '8': {},
      '10': 'links'
    },
    {
      '1': 'starts_at',
      '3': 19,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '9': 4,
      '10': 'starts_at',
      '17': true
    },
    {
      '1': 'ends_at',
      '3': 20,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '9': 5,
      '10': 'ends_at',
      '17': true
    },
    {
      '1': 'source_time',
      '3': 21,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '9': 6,
      '10': 'source_time',
      '17': true
    },
    {
      '1': 'reported_source_time',
      '3': 22,
      '4': 1,
      '5': 9,
      '8': {},
      '9': 7,
      '10': 'reported_source_time',
      '17': true
    },
    {
      '1': 'observed_at',
      '3': 23,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '8': {},
      '10': 'observed_at'
    },
    {
      '1': 'processed_at',
      '3': 24,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '8': {},
      '10': 'processed_at'
    },
    {
      '1': 'raw',
      '3': 25,
      '4': 1,
      '5': 11,
      '6': '.correlia.event.v1.RawReference',
      '8': {},
      '10': 'raw'
    },
    {
      '1': 'pipeline',
      '3': 26,
      '4': 1,
      '5': 11,
      '6': '.correlia.event.v1.Pipeline',
      '8': {},
      '10': 'pipeline'
    },
    {
      '1': 'extensions',
      '3': 27,
      '4': 3,
      '5': 11,
      '6': '.correlia.event.v1.CanonicalEvent.ExtensionsEntry',
      '8': {},
      '10': 'extensions'
    },
    {
      '1': 'identity_fields',
      '3': 28,
      '4': 3,
      '5': 11,
      '6': '.correlia.event.v1.CanonicalEvent.IdentityFieldsEntry',
      '8': {},
      '10': 'identity_fields'
    },
    {
      '1': 'observation_key',
      '3': 29,
      '4': 1,
      '5': 12,
      '8': {},
      '10': 'observation_key'
    },
  ],
  '3': [
    CanonicalEvent_ResourceEntry$json,
    CanonicalEvent_LabelsEntry$json,
    CanonicalEvent_LabelsOriginEntry$json,
    CanonicalEvent_AnnotationsEntry$json,
    CanonicalEvent_ExtensionsEntry$json,
    CanonicalEvent_IdentityFieldsEntry$json
  ],
  '8': [
    {'1': '_severity_number'},
    {'1': '_severity_original'},
    {'1': '_dedup_key'},
    {'1': '_description'},
    {'1': '_starts_at'},
    {'1': '_ends_at'},
    {'1': '_source_time'},
    {'1': '_reported_source_time'},
  ],
};

@$core.Deprecated('Use canonicalEventDescriptor instead')
const CanonicalEvent_ResourceEntry$json = {
  '1': 'ResourceEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use canonicalEventDescriptor instead')
const CanonicalEvent_LabelsEntry$json = {
  '1': 'LabelsEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use canonicalEventDescriptor instead')
const CanonicalEvent_LabelsOriginEntry$json = {
  '1': 'LabelsOriginEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use canonicalEventDescriptor instead')
const CanonicalEvent_AnnotationsEntry$json = {
  '1': 'AnnotationsEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use canonicalEventDescriptor instead')
const CanonicalEvent_ExtensionsEntry$json = {
  '1': 'ExtensionsEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use canonicalEventDescriptor instead')
const CanonicalEvent_IdentityFieldsEntry$json = {
  '1': 'IdentityFieldsEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {
      '1': 'value',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.correlia.event.v1.IdentityComponent',
      '10': 'value'
    },
  ],
  '7': {'7': true},
};

/// Descriptor for `CanonicalEvent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List canonicalEventDescriptor = $convert.base64Decode(
    'Cg5DYW5vbmljYWxFdmVudBJnCghldmVudF9pZBgBIAEoCUJLukhIyAEBckMyPl5bMC05YS1mXX'
    's4fS1bMC05YS1mXXs0fS1bMC05YS1mXXs0fS1bMC05YS1mXXs0fS1bMC05YS1mXXsxMn0kmAEk'
    'UghldmVudF9pZBI9CgtmaW5nZXJwcmludBgCIAEoCUIbukgYyAEBchMyDl5bMC05YS1mXXs2NH'
    '0kmAFAUgtmaW5nZXJwcmludBIpCgZ0ZW5hbnQYAyABKAlCEbpIDsgBAXIJCgdkZWZhdWx0UgZ0'
    'ZW5hbnQSKwoJbmFtZXNwYWNlGAQgASgJQg26SArIAQFyBRABGIACUgluYW1lc3BhY2USPQoEa2'
    'luZBgFIAEoDjIcLmNvcnJlbGlhLmV2ZW50LnYxLkV2ZW50S2luZEILukgIyAEBggECEAFSBGtp'
    'bmQSQwoGc3RhdHVzGAYgASgOMh4uY29ycmVsaWEuZXZlbnQudjEuRXZlbnRTdGF0dXNCC7pICM'
    'gBAYIBAhABUgZzdGF0dXMSSQoIc2V2ZXJpdHkYByABKA4yIC5jb3JyZWxpYS5ldmVudC52MS5F'
    'dmVudFNldmVyaXR5Qgu6SAjIAQGCAQIQAVIIc2V2ZXJpdHkSOAoPc2V2ZXJpdHlfbnVtYmVyGA'
    'ggASgNQgm6SAYqBBgYKAFIAFIPc2V2ZXJpdHlfbnVtYmVyiAEBEjsKEXNldmVyaXR5X29yaWdp'
    'bmFsGAkgASgJQgi6SAVyAxiAAUgBUhFzZXZlcml0eV9vcmlnaW5hbIgBARIrCglkZWR1cF9rZX'
    'kYCiABKAlCCLpIBXIDGIAISAJSCWRlZHVwX2tleYgBARInCgdzdW1tYXJ5GAsgASgJQg26SArI'
    'AQFyBRABGIACUgdzdW1tYXJ5Ei8KC2Rlc2NyaXB0aW9uGAwgASgJQgi6SAVyAxiAIEgDUgtkZX'
    'NjcmlwdGlvbogBARJmCghyZXNvdXJjZRgNIAMoCzIvLmNvcnJlbGlhLmV2ZW50LnYxLkNhbm9u'
    'aWNhbEV2ZW50LlJlc291cmNlRW50cnlCGbpIFpoBExCAASIHcgUQARiAASoFcgMYgAhSCHJlc2'
    '91cmNlEj8KCG9ic2VydmVyGA4gASgLMhsuY29ycmVsaWEuZXZlbnQudjEuT2JzZXJ2ZXJCBrpI'
    'A8gBAVIIb2JzZXJ2ZXISYAoGbGFiZWxzGA8gAygLMi0uY29ycmVsaWEuZXZlbnQudjEuQ2Fub2'
    '5pY2FsRXZlbnQuTGFiZWxzRW50cnlCGbpIFpoBExCAASIHcgUQARiAASoFcgMYgAhSBmxhYmVs'
    'cxJ0Cg1sYWJlbHNfb3JpZ2luGBAgAygLMjMuY29ycmVsaWEuZXZlbnQudjEuQ2Fub25pY2FsRX'
    'ZlbnQuTGFiZWxzT3JpZ2luRW50cnlCGbpIFpoBExCAASIHcgUQARiAASoFcgMYgAhSDWxhYmVs'
    'c19vcmlnaW4SbwoLYW5ub3RhdGlvbnMYESADKAsyMi5jb3JyZWxpYS5ldmVudC52MS5DYW5vbm'
    'ljYWxFdmVudC5Bbm5vdGF0aW9uc0VudHJ5Qhm6SBaaARMQgAEiB3IFEAEYgAEqBXIDGIAIUgth'
    'bm5vdGF0aW9ucxI3CgVsaW5rcxgSIAMoCzIXLmNvcnJlbGlhLmV2ZW50LnYxLkxpbmtCCLpIBZ'
    'IBAhAQUgVsaW5rcxI9CglzdGFydHNfYXQYEyABKAsyGi5nb29nbGUucHJvdG9idWYuVGltZXN0'
    'YW1wSARSCXN0YXJ0c19hdIgBARI5CgdlbmRzX2F0GBQgASgLMhouZ29vZ2xlLnByb3RvYnVmLl'
    'RpbWVzdGFtcEgFUgdlbmRzX2F0iAEBEkEKC3NvdXJjZV90aW1lGBUgASgLMhouZ29vZ2xlLnBy'
    'b3RvYnVmLlRpbWVzdGFtcEgGUgtzb3VyY2VfdGltZYgBARJAChRyZXBvcnRlZF9zb3VyY2VfdG'
    'ltZRgWIAEoCUIHukgEcgIYQEgHUhRyZXBvcnRlZF9zb3VyY2VfdGltZYgBARJECgtvYnNlcnZl'
    'ZF9hdBgXIAEoCzIaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBCBrpIA8gBAVILb2JzZXJ2ZW'
    'RfYXQSRgoMcHJvY2Vzc2VkX2F0GBggASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcEIG'
    'ukgDyAEBUgxwcm9jZXNzZWRfYXQSOQoDcmF3GBkgASgLMh8uY29ycmVsaWEuZXZlbnQudjEuUm'
    'F3UmVmZXJlbmNlQga6SAPIAQFSA3JhdxI/CghwaXBlbGluZRgaIAEoCzIbLmNvcnJlbGlhLmV2'
    'ZW50LnYxLlBpcGVsaW5lQga6SAPIAQFSCHBpcGVsaW5lEpIBCgpleHRlbnNpb25zGBsgAygLMj'
    'EuY29ycmVsaWEuZXZlbnQudjEuQ2Fub25pY2FsRXZlbnQuRXh0ZW5zaW9uc0VudHJ5Qj+6SDya'
    'ATkQICIuciwQARiAATIlXlthLXowLTldW2EtejAtOS4tXSovW2EtekEtWjAtOV8uLV0rJCoFcg'
    'MYgAhSCmV4dGVuc2lvbnMSeAoPaWRlbnRpdHlfZmllbGRzGBwgAygLMjUuY29ycmVsaWEuZXZl'
    'bnQudjEuQ2Fub25pY2FsRXZlbnQuSWRlbnRpdHlGaWVsZHNFbnRyeUIXukgUyAEBmgEOCAEQgA'
    'EiB3IFEAEYgAFSD2lkZW50aXR5X2ZpZWxkcxI3Cg9vYnNlcnZhdGlvbl9rZXkYHSABKAxCDbpI'
    'CsgBAXoFEAEYgEBSD29ic2VydmF0aW9uX2tleRo7Cg1SZXNvdXJjZUVudHJ5EhAKA2tleRgBIA'
    'EoCVIDa2V5EhQKBXZhbHVlGAIgASgJUgV2YWx1ZToCOAEaOQoLTGFiZWxzRW50cnkSEAoDa2V5'
    'GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZhbHVlOgI4ARo/ChFMYWJlbHNPcmlnaW5Fbn'
    'RyeRIQCgNrZXkYASABKAlSA2tleRIUCgV2YWx1ZRgCIAEoCVIFdmFsdWU6AjgBGj4KEEFubm90'
    'YXRpb25zRW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZhbHVlOgI4AR'
    'o9Cg9FeHRlbnNpb25zRW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZh'
    'bHVlOgI4ARpnChNJZGVudGl0eUZpZWxkc0VudHJ5EhAKA2tleRgBIAEoCVIDa2V5EjoKBXZhbH'
    'VlGAIgASgLMiQuY29ycmVsaWEuZXZlbnQudjEuSWRlbnRpdHlDb21wb25lbnRSBXZhbHVlOgI4'
    'AUISChBfc2V2ZXJpdHlfbnVtYmVyQhQKEl9zZXZlcml0eV9vcmlnaW5hbEIMCgpfZGVkdXBfa2'
    'V5Qg4KDF9kZXNjcmlwdGlvbkIMCgpfc3RhcnRzX2F0QgoKCF9lbmRzX2F0Qg4KDF9zb3VyY2Vf'
    'dGltZUIXChVfcmVwb3J0ZWRfc291cmNlX3RpbWU=');
