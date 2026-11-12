// This is a generated file - do not edit.
//
// Generated from correlia/plugin/v1/plugin.proto.

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

@$core.Deprecated('Use deliveryOutcomeDescriptor instead')
const DeliveryOutcome$json = {
  '1': 'DeliveryOutcome',
  '2': [
    {'1': 'DELIVERY_OUTCOME_UNSPECIFIED', '2': 0},
    {'1': 'DELIVERY_OUTCOME_ACKNOWLEDGED', '2': 1},
    {'1': 'DELIVERY_OUTCOME_RETRYABLE', '2': 2},
    {'1': 'DELIVERY_OUTCOME_REJECTED', '2': 3},
  ],
};

/// Descriptor for `DeliveryOutcome`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List deliveryOutcomeDescriptor = $convert.base64Decode(
    'Cg9EZWxpdmVyeU91dGNvbWUSIAocREVMSVZFUllfT1VUQ09NRV9VTlNQRUNJRklFRBAAEiEKHU'
    'RFTElWRVJZX09VVENPTUVfQUNLTk9XTEVER0VEEAESHgoaREVMSVZFUllfT1VUQ09NRV9SRVRS'
    'WUFCTEUQAhIdChlERUxJVkVSWV9PVVRDT01FX1JFSkVDVEVEEAM=');

@$core.Deprecated('Use getMetadataRequestDescriptor instead')
const GetMetadataRequest$json = {
  '1': 'GetMetadataRequest',
};

/// Descriptor for `GetMetadataRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getMetadataRequestDescriptor =
    $convert.base64Decode('ChJHZXRNZXRhZGF0YVJlcXVlc3Q=');

@$core.Deprecated('Use getMetadataResponseDescriptor instead')
const GetMetadataResponse$json = {
  '1': 'GetMetadataResponse',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'version', '3': 2, '4': 1, '5': 9, '10': 'version'},
    {'1': 'kinds', '3': 3, '4': 3, '5': 9, '10': 'kinds'},
    {
      '1': 'config_schema_json',
      '3': 4,
      '4': 1,
      '5': 12,
      '10': 'configSchemaJson'
    },
    {'1': 'protocol_minor', '3': 5, '4': 1, '5': 13, '10': 'protocolMinor'},
  ],
};

/// Descriptor for `GetMetadataResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getMetadataResponseDescriptor = $convert.base64Decode(
    'ChNHZXRNZXRhZGF0YVJlc3BvbnNlEhIKBG5hbWUYASABKAlSBG5hbWUSGAoHdmVyc2lvbhgCIA'
    'EoCVIHdmVyc2lvbhIUCgVraW5kcxgDIAMoCVIFa2luZHMSLAoSY29uZmlnX3NjaGVtYV9qc29u'
    'GAQgASgMUhBjb25maWdTY2hlbWFKc29uEiUKDnByb3RvY29sX21pbm9yGAUgASgNUg1wcm90b2'
    'NvbE1pbm9y');

@$core.Deprecated('Use deliveryLimitsDescriptor instead')
const DeliveryLimits$json = {
  '1': 'DeliveryLimits',
  '2': [
    {
      '1': 'max_events_per_batch',
      '3': 1,
      '4': 1,
      '5': 13,
      '10': 'maxEventsPerBatch'
    },
    {
      '1': 'max_bytes_per_batch',
      '3': 2,
      '4': 1,
      '5': 4,
      '10': 'maxBytesPerBatch'
    },
    {
      '1': 'max_outstanding_batches',
      '3': 3,
      '4': 1,
      '5': 13,
      '10': 'maxOutstandingBatches'
    },
  ],
};

/// Descriptor for `DeliveryLimits`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deliveryLimitsDescriptor = $convert.base64Decode(
    'Cg5EZWxpdmVyeUxpbWl0cxIvChRtYXhfZXZlbnRzX3Blcl9iYXRjaBgBIAEoDVIRbWF4RXZlbn'
    'RzUGVyQmF0Y2gSLQoTbWF4X2J5dGVzX3Blcl9iYXRjaBgCIAEoBFIQbWF4Qnl0ZXNQZXJCYXRj'
    'aBI2ChdtYXhfb3V0c3RhbmRpbmdfYmF0Y2hlcxgDIAEoDVIVbWF4T3V0c3RhbmRpbmdCYXRjaG'
    'Vz');

@$core.Deprecated('Use configureRequestDescriptor instead')
const ConfigureRequest$json = {
  '1': 'ConfigureRequest',
  '2': [
    {'1': 'config_json', '3': 1, '4': 1, '5': 12, '10': 'configJson'},
    {
      '1': 'secrets',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.correlia.plugin.v1.ConfigureRequest.SecretsEntry',
      '10': 'secrets'
    },
    {
      '1': 'limits',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.correlia.plugin.v1.DeliveryLimits',
      '10': 'limits'
    },
  ],
  '3': [ConfigureRequest_SecretsEntry$json],
};

@$core.Deprecated('Use configureRequestDescriptor instead')
const ConfigureRequest_SecretsEntry$json = {
  '1': 'SecretsEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 12, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `ConfigureRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List configureRequestDescriptor = $convert.base64Decode(
    'ChBDb25maWd1cmVSZXF1ZXN0Eh8KC2NvbmZpZ19qc29uGAEgASgMUgpjb25maWdKc29uEksKB3'
    'NlY3JldHMYAiADKAsyMS5jb3JyZWxpYS5wbHVnaW4udjEuQ29uZmlndXJlUmVxdWVzdC5TZWNy'
    'ZXRzRW50cnlSB3NlY3JldHMSOgoGbGltaXRzGAMgASgLMiIuY29ycmVsaWEucGx1Z2luLnYxLk'
    'RlbGl2ZXJ5TGltaXRzUgZsaW1pdHMaOgoMU2VjcmV0c0VudHJ5EhAKA2tleRgBIAEoCVIDa2V5'
    'EhQKBXZhbHVlGAIgASgMUgV2YWx1ZToCOAE=');

@$core.Deprecated('Use fieldErrorDescriptor instead')
const FieldError$json = {
  '1': 'FieldError',
  '2': [
    {'1': 'field', '3': 1, '4': 1, '5': 9, '10': 'field'},
    {'1': 'message', '3': 2, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `FieldError`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fieldErrorDescriptor = $convert.base64Decode(
    'CgpGaWVsZEVycm9yEhQKBWZpZWxkGAEgASgJUgVmaWVsZBIYCgdtZXNzYWdlGAIgASgJUgdtZX'
    'NzYWdl');

@$core.Deprecated('Use configureResponseDescriptor instead')
const ConfigureResponse$json = {
  '1': 'ConfigureResponse',
  '2': [
    {'1': 'accepted', '3': 1, '4': 1, '5': 8, '10': 'accepted'},
    {
      '1': 'limits',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.correlia.plugin.v1.DeliveryLimits',
      '10': 'limits'
    },
    {
      '1': 'field_errors',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.correlia.plugin.v1.FieldError',
      '10': 'fieldErrors'
    },
    {'1': 'error_class', '3': 4, '4': 1, '5': 9, '8': {}, '10': 'errorClass'},
    {
      '1': 'configuration_info',
      '3': 5,
      '4': 3,
      '5': 11,
      '6': '.correlia.plugin.v1.ConfigureResponse.ConfigurationInfoEntry',
      '8': {},
      '10': 'configurationInfo'
    },
  ],
  '3': [ConfigureResponse_ConfigurationInfoEntry$json],
};

@$core.Deprecated('Use configureResponseDescriptor instead')
const ConfigureResponse_ConfigurationInfoEntry$json = {
  '1': 'ConfigurationInfoEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `ConfigureResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List configureResponseDescriptor = $convert.base64Decode(
    'ChFDb25maWd1cmVSZXNwb25zZRIaCghhY2NlcHRlZBgBIAEoCFIIYWNjZXB0ZWQSOgoGbGltaX'
    'RzGAIgASgLMiIuY29ycmVsaWEucGx1Z2luLnYxLkRlbGl2ZXJ5TGltaXRzUgZsaW1pdHMSQQoM'
    'ZmllbGRfZXJyb3JzGAMgAygLMh4uY29ycmVsaWEucGx1Z2luLnYxLkZpZWxkRXJyb3JSC2ZpZW'
    'xkRXJyb3JzEkEKC2Vycm9yX2NsYXNzGAQgASgJQiC6SB1yGzIZXiR8XlthLXpdW2EtejAtOV9d'
    'ezAsNjN9JFIKZXJyb3JDbGFzcxKYAQoSY29uZmlndXJhdGlvbl9pbmZvGAUgAygLMjwuY29ycm'
    'VsaWEucGx1Z2luLnYxLkNvbmZpZ3VyZVJlc3BvbnNlLkNvbmZpZ3VyYXRpb25JbmZvRW50cnlC'
    'K7pIKJoBJRAIIhpyGDIWXlthLXpdW2EtejAtOV9dezAsNjN9JCoFcgMogAJSEWNvbmZpZ3VyYX'
    'Rpb25JbmZvGkQKFkNvbmZpZ3VyYXRpb25JbmZvRW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoF'
    'dmFsdWUYAiABKAlSBXZhbHVlOgI4AQ==');

@$core.Deprecated('Use checkHealthRequestDescriptor instead')
const CheckHealthRequest$json = {
  '1': 'CheckHealthRequest',
};

/// Descriptor for `CheckHealthRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List checkHealthRequestDescriptor =
    $convert.base64Decode('ChJDaGVja0hlYWx0aFJlcXVlc3Q=');

@$core.Deprecated('Use checkHealthResponseDescriptor instead')
const CheckHealthResponse$json = {
  '1': 'CheckHealthResponse',
  '2': [
    {'1': 'serving', '3': 1, '4': 1, '5': 8, '10': 'serving'},
    {'1': 'reason', '3': 2, '4': 1, '5': 9, '8': {}, '10': 'reason'},
  ],
};

/// Descriptor for `CheckHealthResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List checkHealthResponseDescriptor = $convert.base64Decode(
    'ChNDaGVja0hlYWx0aFJlc3BvbnNlEhgKB3NlcnZpbmcYASABKAhSB3NlcnZpbmcSIAoGcmVhc2'
    '9uGAIgASgJQgi6SAVyAxiAAlIGcmVhc29u');

@$core.Deprecated('Use eventDescriptor instead')
const Event$json = {
  '1': 'Event',
  '2': [
    {'1': 'event_id', '3': 1, '4': 1, '5': 9, '10': 'eventId'},
    {'1': 'payload', '3': 2, '4': 1, '5': 12, '10': 'payload'},
  ],
};

/// Descriptor for `Event`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List eventDescriptor = $convert.base64Decode(
    'CgVFdmVudBIZCghldmVudF9pZBgBIAEoCVIHZXZlbnRJZBIYCgdwYXlsb2FkGAIgASgMUgdwYX'
    'lsb2Fk');

@$core.Deprecated('Use deliverRequestDescriptor instead')
const DeliverRequest$json = {
  '1': 'DeliverRequest',
  '2': [
    {'1': 'sequence', '3': 1, '4': 1, '5': 4, '10': 'sequence'},
    {
      '1': 'events',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.correlia.plugin.v1.Event',
      '10': 'events'
    },
  ],
};

/// Descriptor for `DeliverRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deliverRequestDescriptor = $convert.base64Decode(
    'Cg5EZWxpdmVyUmVxdWVzdBIaCghzZXF1ZW5jZRgBIAEoBFIIc2VxdWVuY2USMQoGZXZlbnRzGA'
    'IgAygLMhkuY29ycmVsaWEucGx1Z2luLnYxLkV2ZW50UgZldmVudHM=');

@$core.Deprecated('Use eventResultDescriptor instead')
const EventResult$json = {
  '1': 'EventResult',
  '2': [
    {'1': 'event_id', '3': 1, '4': 1, '5': 9, '10': 'eventId'},
    {
      '1': 'outcome',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.correlia.plugin.v1.DeliveryOutcome',
      '10': 'outcome'
    },
    {'1': 'error_class', '3': 3, '4': 1, '5': 9, '8': {}, '10': 'errorClass'},
  ],
};

/// Descriptor for `EventResult`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List eventResultDescriptor = $convert.base64Decode(
    'CgtFdmVudFJlc3VsdBIZCghldmVudF9pZBgBIAEoCVIHZXZlbnRJZBI9CgdvdXRjb21lGAIgAS'
    'gOMiMuY29ycmVsaWEucGx1Z2luLnYxLkRlbGl2ZXJ5T3V0Y29tZVIHb3V0Y29tZRJBCgtlcnJv'
    'cl9jbGFzcxgDIAEoCUIgukgdchsyGV4kfF5bYS16XVthLXowLTlfXXswLDYzfSRSCmVycm9yQ2'
    'xhc3M=');

@$core.Deprecated('Use deliverResponseDescriptor instead')
const DeliverResponse$json = {
  '1': 'DeliverResponse',
  '2': [
    {'1': 'sequence', '3': 1, '4': 1, '5': 4, '10': 'sequence'},
    {
      '1': 'results',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.correlia.plugin.v1.EventResult',
      '10': 'results'
    },
  ],
};

/// Descriptor for `DeliverResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deliverResponseDescriptor = $convert.base64Decode(
    'Cg9EZWxpdmVyUmVzcG9uc2USGgoIc2VxdWVuY2UYASABKARSCHNlcXVlbmNlEjkKB3Jlc3VsdH'
    'MYAiADKAsyHy5jb3JyZWxpYS5wbHVnaW4udjEuRXZlbnRSZXN1bHRSB3Jlc3VsdHM=');
