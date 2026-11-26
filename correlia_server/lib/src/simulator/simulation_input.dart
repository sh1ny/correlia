import 'dart:convert';
import 'dart:typed_data';

import '../event/canonical_event.dart';
import '../event/cloud_event.dart';
import '../event/event_timestamp.dart';
import '../event/validation.dart';
import '../generated/protocol.dart' hide ConditionTrace;
import '../matcher/matcher_document.dart';

/// The `invalid_input` error code of a request that names no usable input.
const simulationInvalidInput = 'invalid_input';

/// The `too_large` error code of an event over the wire bound.
const simulationTooLarge = 'too_large';

/// The dispositions a stored event can carry.
const storedDispositions = {'ready', 'late', 'future_dated'};

/// One validated simulation request.
sealed class SimulationRequest {
  const SimulationRequest();
}

/// A pasted canonical event, already decoded and validated.
final class PastedEventRequest extends SimulationRequest {
  const PastedEventRequest(this.event);

  /// The decoded event.
  final CanonicalEvent event;
}

/// A stored event named by its key.
final class StoredEventRequest extends SimulationRequest {
  const StoredEventRequest({
    required this.eventId,
    required this.observedAt,
    this.disposition,
  });

  /// The lower-case canonical event UUID.
  final String eventId;

  /// The stored `observed_at` key: UTC, truncated to microseconds.
  final DateTime observedAt;

  /// The disposition to select, or `null` to let the lookup choose.
  final String? disposition;
}

/// The result of [validateSimulationInput].
sealed class SimulationInputCheck {
  const SimulationInputCheck();
}

/// A request that passed every check.
final class AcceptedSimulationInput extends SimulationInputCheck {
  const AcceptedSimulationInput(this.request);

  /// The validated request.
  final SimulationRequest request;
}

/// A request refused before any lookup.
final class RejectedSimulationInput extends SimulationInputCheck {
  const RejectedSimulationInput(this.error);

  /// The typed error to return to the caller.
  final SimulationError error;
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

RejectedSimulationInput _invalid(String field) => RejectedSimulationInput(
  SimulationError(code: simulationInvalidInput, field: field),
);

/// Checks the simulator's input before any lookup or evaluation.
///
/// The input is exactly one of [eventJson] (a CloudEvent JSON document, with
/// no stored-key field) or [eventId] with [observedAt] and an optional
/// [disposition]. A conflicting, partial or orphaned key field, a malformed
/// event ID, an unknown disposition or an [observedAt] that is not an RFC 3339
/// timestamp with an offset is `invalid_input` naming the field. A pasted
/// event is decoded here: a validation failure carries the event field path and
/// code, and a document over the wire bound is `too_large`.
///
/// [observedAt] is read as ADR 0021 reads canonical timestamps, never in the
/// local zone, and is projected to the stored UTC microsecond key.
SimulationInputCheck validateSimulationInput({
  String? eventJson,
  String? eventId,
  String? observedAt,
  String? disposition,
}) {
  final keyField = eventId != null
      ? 'eventId'
      : observedAt != null
      ? 'observedAt'
      : disposition != null
      ? 'disposition'
      : null;
  if (eventJson != null) {
    if (keyField != null) return _invalid(keyField);
    return _pasted(eventJson);
  }
  if (keyField == null) return _invalid('eventJson');
  if (eventId == null && observedAt == null) return _invalid('disposition');
  if (eventId == null) return _invalid('eventId');
  if (observedAt == null) return _invalid('observedAt');
  if (!_uuid.hasMatch(eventId)) return _invalid('eventId');
  if (disposition != null && !storedDispositions.contains(disposition)) {
    return _invalid('disposition');
  }
  final DateTime key;
  try {
    final stamp = EventTimestamp.parse(observedAt, path: 'observedAt');
    key = DateTime.fromMicrosecondsSinceEpoch(
      stamp.seconds * 1000000 + stamp.nanos ~/ 1000,
      isUtc: true,
    );
  } on EventValidationError {
    return _invalid('observedAt');
  }
  return AcceptedSimulationInput(
    StoredEventRequest(
      eventId: eventId.toLowerCase(),
      observedAt: key,
      disposition: disposition,
    ),
  );
}

SimulationInputCheck _pasted(String eventJson) {
  final bytes = Uint8List.fromList(utf8.encode(eventJson));
  // Only text over the wire bound is `too_large`. Text within it that decodes
  // to an event whose canonical form is over the bound keeps the event's own
  // validation error.
  if (bytes.length > cloudEventEnvelopeLimit) {
    return RejectedSimulationInput(
      SimulationError(code: simulationTooLarge, field: 'eventJson'),
    );
  }
  try {
    final event = CloudEvent.decode(bytes).event;
    return AcceptedSimulationInput(PastedEventRequest(event));
  } on EventValidationError catch (error) {
    return RejectedSimulationInput(
      SimulationError(code: error.code, field: error.path),
    );
  }
}

/// The error for a draft matcher section that publication would refuse.
SimulationError simulationErrorFromDocument(MatcherDocumentError error) =>
    SimulationError(
      code: error.code,
      field: error.field,
      missingOutputId: error.missingOutputId,
    );

/// Refuses a parsed draft that writes the reserved noise key without `classify`.
///
/// A draft is always new content, so this applies whatever an earlier stored
/// snapshot held. Returns `null` when the draft may be simulated. No lookup is
/// needed.
SimulationError? checkSimulationDraft(MatcherDocument draft) {
  final field = draft.writesReservedKey;
  if (field == null) return null;
  return simulationErrorFromDocument(reservedKeyError(field));
}
