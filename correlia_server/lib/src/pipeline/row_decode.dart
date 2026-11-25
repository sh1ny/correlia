import 'dart:convert';
import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';

import '../event/event_timestamp.dart';
import '../event/validation.dart';
import '../ingest/bootstrap.dart'
    show
        AlertmanagerSourceKind,
        GenericMapping,
        GenericSourceKind,
        Icinga2SourceKind,
        SourceKind,
        SourceMode,
        StreamStateTypePolicy;
import '../ingest/generic_decoder.dart';
import '../ingest/icinga2/decoder.dart';
import '../ingest/icinga2/stream/decoder.dart';
import '../ingest/source_decoder.dart';

/// The primary key of one stored raw row.
final class RawKey {
  /// Creates the key of the row [rawId] observed at [observedAt].
  const RawKey(this.observedAt, this.rawId);

  /// When the delivery was observed, the partition key of the row.
  final DateTime observedAt;

  /// The raw row's UUID.
  final String rawId;
}

/// The trusted admission metadata of one Icinga2 Event Streams row.
///
/// It comes from the snapshot the row was admitted under, which can differ
/// from the snapshot the row is processed under.
final class StreamAdmission {
  /// Creates admission metadata as stored.
  const StreamAdmission({
    required this.origin,
    required this.statePolicy,
    required this.syncId,
  });

  /// The stored origin, `sync` or `stream`.
  final String? origin;

  /// The state policy wire value of the admission snapshot's source, if any.
  final String? statePolicy;

  /// The sync the row belongs to, `null` for live stream rows.
  final String? syncId;
}

/// Why a row cannot be decoded at all, before any bytes are looked at.
enum DecodeRejection {
  /// The pin has no enabled source with the row's source ID.
  sourceNotConfigured('source_not_configured'),

  /// A generic source's pinned mapping is missing or unsupported.
  unsupportedMapping('unsupported_mapping'),

  /// The source's kind is unknown.
  unsupportedKind('unsupported_kind');

  const DecodeRejection(this.code);

  /// The stable failure code recorded for the row.
  final String code;
}

/// Everything [decodeRow] needs about one raw row, read from the database.
final class DecodeInputs {
  /// Creates inputs for a row that cannot decode, for [rejection].
  const DecodeInputs.rejected({
    required this.rawKey,
    required this.sourceId,
    required this.digest,
    required this.pin,
    required this.snapshot,
    required this.source,
    required DecodeRejection this.rejection,
    this.kind,
    this.mapping,
  }) : namespace = null,
       excludedLabels = const [],
       stream = false,
       admission = null;

  /// Creates inputs for a decodable row.
  const DecodeInputs({
    required this.rawKey,
    required this.sourceId,
    required this.digest,
    required this.pin,
    required this.snapshot,
    required Map<String, Object?> this.source,
    required SourceKind this.kind,
    required this.mapping,
    required String this.namespace,
    required this.excludedLabels,
    required this.stream,
    required this.admission,
  }) : rejection = null;

  /// The row being decoded.
  final RawKey rawKey;

  /// The row's source UUID.
  final String sourceId;

  /// The stored digest of the row's bytes.
  final String digest;

  /// The processing pin, the snapshot the source settings come from.
  final String pin;

  /// The pin's public snapshot document.
  final Map<String, Object?> snapshot;

  /// The pin's enabled source definition, `null` when there is none.
  final Map<String, Object?>? source;

  /// The reason the row cannot decode, or `null` when it can.
  final DecodeRejection? rejection;

  /// The source's resolved kind, `null` when it is unknown.
  final SourceKind? kind;

  /// The pinned mapping of a generic source.
  final GenericMapping? mapping;

  /// The identity namespace of the pinned source.
  final String? namespace;

  /// The identity labels the pinned source excludes.
  final List<String> excludedLabels;

  /// Whether the row is an Icinga2 Event Streams row.
  final bool stream;

  /// The admission metadata of a stream row, `null` when none is stored.
  final StreamAdmission? admission;
}

/// The result of decoding one raw row.
typedef DecodedRow = ({DecodedBatch batch, String? syncId});

/// Reads what [decodeRow] needs for the raw row [rawKey] under snapshot [pin].
///
/// Every decode of a raw row goes through the shared decode, which reads
/// stream admission metadata.
///
/// Reads the row's source and digest, the pin's source settings and, for an
/// Icinga2 Event Streams row, the origin, state policy and sync ID stored at
/// admission. The admission metadata is joined to the snapshot the row was
/// admitted under, not to [pin]. The reads need no row lock and no pipeline
/// claim state, so a plain read-only transaction [tx] is enough. Throws a
/// [StateError] when the row or the pin does not exist.
Future<DecodeInputs> readDecodeInputs(
  Session session,
  Transaction tx,
  RawKey rawKey,
  String pin,
) async {
  final rows = await session.db.unsafeQuery(
    '''SELECT source_id::text,body_sha256 FROM raw_inbox
WHERE observed_at=@observed AND raw_id=CAST(@raw AS uuid)''',
    parameters: QueryParameters.named({
      'observed': rawKey.observedAt,
      'raw': rawKey.rawId,
    }),
    transaction: tx,
    timeoutInSeconds: 5,
  );
  if (rows.isEmpty) throw StateError('Unknown raw row');
  final sourceId = rows.single[0]! as String;
  final digest = rows.single[1]! as String;
  final snapshots = await session.db.unsafeQuery(
    'SELECT "publicJson" FROM ingest_config_snapshot WHERE "snapshotId"=@pin',
    parameters: QueryParameters.named({'pin': pin}),
    transaction: tx,
    timeoutInSeconds: 5,
  );
  final snapshot =
      jsonDecode(snapshots.single[0] as String) as Map<String, Object?>;
  final matches = (snapshot['sources'] as List<Object?>)
      .cast<Map<String, Object?>>()
      .where((entry) => entry['id'] == sourceId && entry['enabled'] == true);
  if (matches.isEmpty) {
    return DecodeInputs.rejected(
      rawKey: rawKey,
      sourceId: sourceId,
      digest: digest,
      pin: pin,
      snapshot: snapshot,
      source: null,
      rejection: DecodeRejection.sourceNotConfigured,
    );
  }
  final source = matches.single;
  final kind = switch (snapshot['format_version']) {
    1 => SourceKind.alertmanager,
    _ => SourceKind.named(source['kind']),
  };
  final mapping = kind is GenericSourceKind
      ? GenericMapping.fromSnapshot(snapshot, source['mapping'])
      : null;
  final rejection = switch (kind) {
    null => DecodeRejection.unsupportedKind,
    GenericSourceKind() when mapping == null =>
      DecodeRejection.unsupportedMapping,
    _ => null,
  };
  if (rejection != null) {
    return DecodeInputs.rejected(
      rawKey: rawKey,
      sourceId: sourceId,
      digest: digest,
      pin: pin,
      snapshot: snapshot,
      source: source,
      rejection: rejection,
      kind: kind,
      mapping: mapping,
    );
  }
  final stream =
      kind is Icinga2SourceKind &&
      source['mode'] == SourceMode.eventStreams.wire;
  StreamAdmission? admission;
  if (stream) {
    final admitted = await session.db.unsafeQuery(
      '''SELECT o.origin, source->>'state_type_policy', o.sync_id::text
        FROM icinga2_raw_origin o
        JOIN ingest_config_snapshot c ON c."snapshotId"=o.admission_snapshot_id
        CROSS JOIN LATERAL jsonb_array_elements(c."publicJson"::jsonb->'sources') source
        WHERE o.raw_id=CAST(@raw AS uuid) AND source->>'id'=@source''',
      parameters: QueryParameters.named({
        'raw': rawKey.rawId,
        'source': sourceId,
      }),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    if (admitted.isNotEmpty) {
      final metadata = admitted.single;
      admission = StreamAdmission(
        origin: metadata[0] as String?,
        statePolicy: metadata[1] as String?,
        syncId: metadata[2] as String?,
      );
    }
  }
  return DecodeInputs(
    rawKey: rawKey,
    sourceId: sourceId,
    digest: digest,
    pin: pin,
    snapshot: snapshot,
    source: source,
    kind: kind!,
    mapping: mapping,
    namespace: source['namespace'] as String,
    excludedLabels: (source['excluded_identity_labels'] as List<Object?>)
        .cast<String>(),
    stream: stream,
    admission: admission,
  );
}

/// Decodes [bytes] of a raw row into canonical events, purely over [inputs].
///
/// Touches no database and reads no clock: [processedAt] is the processing
/// time stamped on every event, and [icinga2Decoder] decodes `icinga2` webhook
/// rows. Throws an [EventValidationError] when the bytes or the stored
/// admission metadata do not decode, and a [StateError] when [inputs] carries a
/// [DecodeInputs.rejection].
DecodedRow decodeRow(
  DecodeInputs inputs,
  Uint8List bytes, {
  required EventTimestamp processedAt,
  KindDecoder icinga2Decoder = decodeIcinga2Request,
}) {
  final kind = inputs.kind;
  if (inputs.rejection != null || kind == null) {
    throw StateError('Row cannot be decoded: ${inputs.rejection?.code}');
  }
  final rawKey = inputs.rawKey;
  final request = DecodeRequest(
    bytes: bytes,
    sourceInstance: inputs.sourceId,
    namespace: inputs.namespace!,
    excludedLabels: inputs.excludedLabels,
    rawRef:
        'raw:${rawKey.observedAt.toUtc().toIso8601String()}/${rawKey.rawId}',
    rawSha256: inputs.digest,
    observedAt: EventTimestamp.parse(
      rawKey.observedAt.toUtc().toIso8601String(),
    ),
    processedAt: processedAt,
    configVersion: inputs.pin,
  );
  if (inputs.stream) {
    final envelope = IcingaStreamRow.parse(request.bytes);
    final admission = inputs.admission;
    if (admission == null) {
      throw const EventFieldError('origin', 'missing_origin');
    }
    final policy = switch (admission.statePolicy) {
      'hard_only' => StreamStateTypePolicy.hardOnly,
      'soft_and_hard' => StreamStateTypePolicy.softAndHard,
      _ => throw const EventFieldError(
        'state_type_policy',
        'invalid_state_type_policy',
      ),
    };
    final origin = admission.origin == 'sync'
        ? IcingaStreamOrigin.sync
        : IcingaStreamOrigin.stream;
    return (
      batch: envelope.decode(request, origin, policy),
      syncId: admission.syncId,
    );
  }
  final decoder = switch (kind) {
    GenericSourceKind() => (DecodeRequest r) => decodeGeneric(
      r,
      inputs.mapping!,
    ),
    AlertmanagerSourceKind() => decodeAlertmanagerRequest,
    Icinga2SourceKind() => icinga2Decoder,
  };
  return (batch: decoder(request), syncId: null);
}
