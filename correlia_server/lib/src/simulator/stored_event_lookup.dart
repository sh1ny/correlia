import 'dart:convert';
import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';

import '../event/canonical_event.dart';
import '../event/cloud_event.dart';
import '../event/validation.dart';
import '../generated/protocol.dart' hide ConditionTrace;
import '../ingest/bootstrap.dart' show BootstrapError;
import '../pipeline/row_decode.dart';
import 'simulation_input.dart';

/// The error code of a stored key that names no stored event.
const simulationEventNotFound = 'event_not_found';

/// The error code of a stored event whose raw row cannot be decoded again.
const simulationRawUnavailable = 'raw_unavailable';

/// The error code of a stored event whose kept member cannot be identified.
const simulationAmbiguousMember = 'ambiguous_member';

/// The result of [lookupStoredEvent].
sealed class StoredEventLookup {
  const StoredEventLookup();
}

/// The decoded member the pipeline kept for a stored event.
final class FoundStoredEvent extends StoredEventLookup {
  const FoundStoredEvent({
    required this.member,
    required this.stored,
    required this.snapshotId,
  });

  /// The member decoded from the raw row, before any matcher change.
  final CanonicalEvent member;

  /// The event the pipeline stored, with its matcher effects and diagnostics.
  final CanonicalEvent stored;

  /// The snapshot the event was processed under.
  final String snapshotId;
}

/// A lookup that failed with a typed [error].
final class StoredEventLookupFailure extends StoredEventLookup {
  const StoredEventLookupFailure(this.error);

  /// The error to return to the caller.
  final SimulationError error;
}

StoredEventLookupFailure _failure(String code, [String? field]) =>
    StoredEventLookupFailure(SimulationError(code: code, field: field));

/// The rank of a disposition when the lookup has to choose: an eligible row
/// before a future-dated one.
const _dispositionOrder = {'ready': 0, 'late': 1, 'future_dated': 2};

/// Finds a stored event by key and the member of its raw row the pipeline kept.
///
/// Reads through [tx], which the caller opens read-only; the function writes
/// nothing. [request] names the event by `(observed_at, event_id)`, and by
/// disposition when one is given; without one the non-`future_dated` row is
/// preferred. The row's raw row is decoded again through the shared decode, so
/// a stream row keeps its admission metadata, and the member is chosen by
/// [selectKeptMember]. The decoded events carry the stored event's own
/// processing time: the wire size bound counts the timestamp's text, so
/// another time could push a member that fit when stored over the bound.
Future<StoredEventLookup> lookupStoredEvent(
  Session session,
  Transaction tx,
  StoredEventRequest request,
) async {
  final rows = await session.db.unsafeQuery(
    '''SELECT disposition, raw_observed_at, raw_id::text, config_snapshot_id, payload
FROM events WHERE observed_at=@observed AND event_id=CAST(@id AS uuid)
${request.disposition == null ? '' : 'AND disposition=@disposition'}''',
    parameters: QueryParameters.named({
      'observed': request.observedAt,
      'id': request.eventId,
      'disposition': ?request.disposition,
    }),
    transaction: tx,
    timeoutInSeconds: 5,
  );
  if (rows.isEmpty) return _failure(simulationEventNotFound, 'eventId');
  final row =
      ([...rows]..sort(
            (a, b) => (_dispositionOrder[a[0]] ?? 3).compareTo(
              _dispositionOrder[b[0]] ?? 3,
            ),
          ))
          .first;
  final rawKey = RawKey(row[1]! as DateTime, row[2]! as String);
  final pin = row[3]! as String;
  final CanonicalEvent stored;
  try {
    stored = CloudEvent.decode(_bytes(row[4])).event;
  } on EventValidationError {
    return _failure(simulationRawUnavailable, 'eventId');
  }
  final raw = await session.db.unsafeQuery(
    '''SELECT body, source_id::text, body_sha256 FROM raw_inbox
WHERE observed_at=@observed AND raw_id=CAST(@raw AS uuid)''',
    parameters: QueryParameters.named({
      'observed': rawKey.observedAt,
      'raw': rawKey.rawId,
    }),
    transaction: tx,
    timeoutInSeconds: 5,
  );
  if (raw.isEmpty) return _failure(simulationRawUnavailable, 'eventId');
  // Neither the event nor the raw row has a foreign key to its processing
  // snapshot, so the pin can be gone; without it the row cannot decode.
  final pinned = await session.db.unsafeQuery(
    'SELECT 1 FROM ingest_config_snapshot WHERE "snapshotId"=@pin',
    parameters: QueryParameters.named({'pin': pin}),
    transaction: tx,
    timeoutInSeconds: 5,
  );
  if (pinned.isEmpty) return _failure(simulationRawUnavailable, 'eventId');
  final DecodeInputs inputs;
  try {
    inputs = await readDecodeInputs(
      session,
      tx,
      rawKey,
      pin,
      sourceId: raw.single[1]! as String,
      digest: raw.single[2]! as String,
    );
  } on BootstrapError {
    // The pin's decode settings no longer parse, such as a mapping in a
    // format this binary cannot read. Database failures still propagate.
    return _failure(simulationRawUnavailable, 'eventId');
  } on InvalidStoredSettings {
    // The pin's stored source settings have the wrong shape, such as a
    // source without its namespace.
    return _failure(simulationRawUnavailable, 'eventId');
  }
  if (inputs.rejection != null) {
    return _failure(simulationRawUnavailable, 'eventId');
  }
  final DecodedRow decoded;
  try {
    decoded = decodeRow(
      inputs,
      _bytes(raw.single[0]),
      processedAt: stored.processedAt,
    );
  } on EventValidationError {
    return _failure(simulationRawUnavailable, 'eventId');
  }
  final member = selectKeptMember(
    [
      for (final event in decoded.batch.events)
        if (event.eventId == request.eventId) event,
    ],
    stored,
  );
  if (member == null) return _failure(simulationAmbiguousMember, 'eventId');
  return FoundStoredEvent(member: member, stored: stored, snapshotId: pin);
}

/// The member of [candidates] the pipeline kept as [stored], or `null`.
///
/// Members of one raw row can share an event ID. The pipeline keeps one of
/// them and then changes labels, label origins, links and severity, adds
/// enrichment errors, and stamps its own processing time and observation
/// generation. A member is the kept one when it equals [stored] in every other
/// field. The choice is `null` when no member equals it, or when members that
/// do equal it differ from each other (for example in an identity-excluded
/// label), because the stored fields then do not tell them apart.
CanonicalEvent? selectKeptMember(
  List<CanonicalEvent> candidates,
  CanonicalEvent stored,
) {
  final target = _invariant(stored);
  final matches = [
    for (final candidate in candidates)
      if (_invariant(candidate) == target) candidate,
  ];
  if (matches.isEmpty) return null;
  final first = _text(_withoutProcessing(matches.first));
  for (final other in matches.skip(1)) {
    if (_text(_withoutProcessing(other)) != first) return null;
  }
  return matches.first;
}

Map<String, Object?> _withoutProcessing(CanonicalEvent event) {
  final projection = event.toJson()..remove('processed_at');
  final pipeline = Map<String, Object?>.of(
    projection['pipeline']! as Map<String, Object?>,
  )..remove('generation');
  projection['pipeline'] = pipeline;
  return projection;
}

/// The fields the matcher and the pipeline's diagnostics leave alone, as text.
String _invariant(CanonicalEvent event) {
  final projection = _withoutProcessing(event)
    ..remove('labels')
    ..remove('labels_origin')
    ..remove('links')
    ..remove('severity');
  final pipeline = Map<String, Object?>.of(
    projection['pipeline']! as Map<String, Object?>,
  )..remove('enrichment_errors');
  projection['pipeline'] = pipeline;
  return _text(projection);
}

/// [value] as JSON with every map's keys sorted and list order kept.
///
/// Map key order carries no meaning in an event: the stored payload and a
/// re-decoded member can hold the same labels in a different order.
String _text(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) => switch (value) {
  Map<String, Object?> map => {
    for (final key in map.keys.toList()..sort()) key: _sorted(map[key]),
  },
  List<Object?> list => [for (final item in list) _sorted(item)],
  _ => value,
};

Uint8List _bytes(Object? value) => switch (value) {
  Uint8List bytes => bytes,
  ByteData data => data.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  ),
  _ => throw StateError('Unexpected byte representation'),
};
