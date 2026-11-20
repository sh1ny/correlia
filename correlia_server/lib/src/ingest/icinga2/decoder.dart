import '../../event/canonical_event.dart';
import '../../event/identity.dart';
import '../source_decoder.dart';
import 'mapper.dart';
import 'webhook_parser.dart';

/// Decodes one Icinga2 webhook delivery into its single canonical event.
///
/// Throws an [EventValidationError] for every malformed delivery; no partial
/// result is returned.
DecodedBatch decodeIcinga2Request(DecodeRequest request) {
  final fact = parseIcinga2Webhook(request.bytes);
  final event = mapIcinga2Fact(
    fact,
    source: SourceContext(
      sourceInstance: request.sourceInstance,
      sourceKind: 'icinga2',
      namespace: request.namespace,
    ),
    raw: EventRawReference(
      ref: request.rawRef,
      sha256: request.rawSha256,
      size: request.bytes.length,
    ),
    pipeline: EventPipeline(version: request.configVersion),
    observedAt: request.observedAt,
    processedAt: request.processedAt,
  );
  return DecodedBatch(events: [event]);
}
