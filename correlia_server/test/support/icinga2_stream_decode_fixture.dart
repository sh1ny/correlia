import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/event/event_timestamp.dart';
import 'package:correlia_server/src/ingest/source_decoder.dart';
import 'package:crypto/crypto.dart';

/// Identity scope for the fixed event-id vectors.
const streamDecodeSource = '11111111-1111-4111-8111-111111111111';

/// The maintained Icinga 2 release captures.
const streamCaptures = ['2.13.14', '2.14.10', '2.15.7', '2.16.6'];

/// Reads the real filtered subscription from [release].
List<Map<String, Object?>> capturedStreamEvents(String release) => [
  for (final line in File(
    'test/unit/ingest/fixtures/icinga2/$release/stream/events.ndjson',
  ).readAsLinesSync())
    jsonDecode(line) as Map<String, Object?>,
];

/// Looks up the last projected check of an object by its reported result.
Map<String, Object?> capturedStreamSync(String release, String collection) {
  final response =
      jsonDecode(
            File(
              'test/unit/ingest/fixtures/icinga2/$release/stream/$collection.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  return (response['results']! as List<Object?>).first! as Map<String, Object?>;
}

/// Creates a request with a stable metadata scope and the supplied raw bytes.
DecodeRequest streamDecodeRequest(String raw) {
  final bytes = Uint8List.fromList(utf8.encode(raw));
  final observed = EventTimestamp.fromParts(1795500000, 0);
  return DecodeRequest(
    bytes: bytes,
    sourceInstance: streamDecodeSource,
    namespace: streamDecodeSource,
    excludedLabels: const [],
    rawRef: 'raw:stream-fixture',
    rawSha256: sha256.convert(bytes).toString(),
    observedAt: observed,
    processedAt: observed,
    configVersion: 'stream-fixture',
  );
}
