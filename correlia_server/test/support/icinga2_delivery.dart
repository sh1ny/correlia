import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/icinga2/decoder.dart';
import 'package:correlia_server/src/ingest/source_decoder.dart';

/// The source UUID the Icinga2 unit tests decode under.
const icinga2SourceInstance = '11111111-1111-4111-8111-111111111111';

/// A Correlia-authored Icinga2 webhook document v1 (a service problem).
///
/// [set] overrides or adds fields; a field whose value is `null` is removed.
Map<String, Object?> delivery({Map<String, Object?> set = const {}}) {
  final document = <String, Object?>{
    'format': 'correlia.icinga2.v1',
    'object_type': 'service',
    'host': 'db1',
    'service': 'disk',
    'state': 'CRITICAL',
    'state_type': 'HARD',
    'last_state_change': '1763571234.123456',
    'output': 'DISK CRITICAL - free space: / 100 MB',
    'notification_type': 'PROBLEM',
    'notification_time': '1763571240.500000',
    ...set,
  };
  document.removeWhere((_, value) => value == null);
  return document;
}

/// A host document (`web1`) in [state].
Map<String, Object?> hostDelivery({
  String state = 'DOWN',
  Map<String, Object?> set = const {},
}) => delivery(
  set: {
    'object_type': 'host',
    'host': 'web1',
    'service': null,
    'state': state,
    'output': 'PING CRITICAL - Packet loss = 100%',
    ...set,
  },
);

/// The body bytes of [document].
Uint8List body(Object? document) =>
    Uint8List.fromList(utf8.encode(jsonEncode(document)));

/// Decodes [document] through the pipeline's Icinga2 decoder function.
DecodedBatch decodeDelivery(
  Object? document, {
  String sourceInstance = icinga2SourceInstance,
  String? namespace,
}) => decodeIcinga2Request(
  DecodeRequest(
    bytes: document is Uint8List ? document : body(document),
    sourceInstance: sourceInstance,
    namespace: namespace ?? sourceInstance,
    excludedLabels: const [],
    rawRef: 'raw:fixture',
    rawSha256:
        '0000000000000000000000000000000000000000000000000000000000000000',
    observedAt: EventTimestamp.parse('2025-11-19T16:34:00Z'),
    processedAt: EventTimestamp.parse('2025-11-19T16:34:01Z'),
    configVersion: 'snapshot-1',
  ),
);

/// The single event [decodeDelivery] produces.
CanonicalEvent decodeOne(
  Object? document, {
  String sourceInstance = icinga2SourceInstance,
  String? namespace,
}) => decodeDelivery(
  document,
  sourceInstance: sourceInstance,
  namespace: namespace,
).events.single;
