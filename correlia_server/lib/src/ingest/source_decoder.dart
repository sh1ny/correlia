import 'dart:typed_data';

import '../event/canonical_event.dart';
import '../event/event_timestamp.dart';
import 'alertmanager_decoder.dart';

/// Everything a kind's decoder needs about one claimed raw row.
final class DecodeRequest {
  /// Creates the request for one raw row pinned to one source definition.
  const DecodeRequest({
    required this.bytes,
    required this.sourceInstance,
    required this.namespace,
    required this.excludedLabels,
    required this.rawRef,
    required this.rawSha256,
    required this.observedAt,
    required this.processedAt,
    required this.configVersion,
  });

  /// The persisted request body.
  final Uint8List bytes;

  /// The source UUID.
  final String sourceInstance;

  /// The pinned source's identity namespace.
  final String namespace;

  /// The pinned source's excluded identity labels.
  final List<String> excludedLabels;

  /// The durable reference to the persisted body.
  final String rawRef;

  /// The digest of the persisted body.
  final String rawSha256;

  /// The ingress time.
  final EventTimestamp observedAt;

  /// The worker clock.
  final EventTimestamp processedAt;

  /// The pinned snapshot identifier.
  final String configVersion;
}

/// The canonical events of one decoded delivery, whatever its kind.
final class DecodedBatch {
  /// Creates a batch with its upstream omission and unknown-field evidence.
  DecodedBatch({
    required List<CanonicalEvent> events,
    this.upstreamOmissions = 0,
    this.softInfo = 0,
    List<String> unknownTopLevelFields = const [],
    this.unknownTopLevelOverflow = 0,
  }) : events = List.unmodifiable(events),
       unknownTopLevelFields = List.unmodifiable(unknownTopLevelFields);

  /// The events in delivery order.
  final List<CanonicalEvent> events;

  /// The number of alerts omitted upstream.
  final int upstreamOmissions;

  /// The first valid unknown top-level names, sorted.
  final List<String> unknownTopLevelFields;

  /// The count of unknown names omitted from [unknownTopLevelFields].
  final int unknownTopLevelOverflow;

  /// SOFT non-OK stream observations skipped by the admission policy.
  final int softInfo;
}

/// Decodes one raw body into canonical events or throws an event validation error.
typedef KindDecoder = DecodedBatch Function(DecodeRequest request);

/// Decodes an Alertmanager v4 delivery.
DecodedBatch decodeAlertmanagerRequest(DecodeRequest request) {
  final batch = decodeAlertmanager(
    bytes: request.bytes,
    sourceInstance: request.sourceInstance,
    namespace: request.namespace,
    excludedLabels: request.excludedLabels,
    rawRef: request.rawRef,
    rawSha256: request.rawSha256,
    observedAt: request.observedAt,
    processedAt: request.processedAt,
    configVersion: request.configVersion,
  );
  return DecodedBatch(
    events: batch.events,
    upstreamOmissions: batch.upstreamOmissions,
    unknownTopLevelFields: batch.unknownTopLevelFields,
    unknownTopLevelOverflow: batch.unknownTopLevelOverflow,
  );
}
