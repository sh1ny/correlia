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
       admission = null,
       admissionFailure = null;

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
    this.admissionFailure,
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

  /// Why a stream row's admission snapshot does not read, or `null`: it is
  /// not JSON, or it lists the row's source more than once.
  ///
  /// [decodeRow] throws it only after the row's own format is validated, so a
  /// row in an unknown format still fails with `unsupported_format`.
  final InvalidStoredSettings? admissionFailure;
}

/// The result of decoding one raw row.
typedef DecodedRow = ({DecodedBatch batch, String? syncId});

/// Reads what [decodeRow] needs for the raw row [rawKey] under snapshot [pin].
///
/// Every decode of a raw row goes through the shared decode, which reads
/// stream admission metadata.
///
/// The caller passes the row's [sourceId], body [digest] and body [bytes],
/// which it has already read with the row: the pipeline from its claim, the
/// simulator with the body. This reads the pin's source settings and, for an Icinga2 Event
/// Streams row whose envelope parses, the origin, state policy and sync ID
/// stored at admission. The
/// admission metadata is joined to the snapshot the row was admitted under,
/// not to [pin]. The reads need no row lock and no pipeline claim state, so a
/// plain read-only transaction [tx] is enough. Throws a [StateError] when the
/// pin does not exist, and an [InvalidStoredSettings] when the stored snapshot
/// or source settings do not have the shape this binary reads. An admission
/// snapshot that is not JSON, or that lists the source more than once, does not
/// throw here: [DecodeInputs.admissionFailure] carries it to [decodeRow]. Database errors propagate unchanged.
Future<DecodeInputs> readDecodeInputs(
  Session session,
  Transaction tx,
  RawKey rawKey,
  String pin, {
  required String sourceId,
  required String digest,
  required Uint8List bytes,
}) async {
  try {
    return await _readDecodeInputs(
      session,
      tx,
      rawKey,
      pin,
      sourceId: sourceId,
      digest: digest,
      bytes: bytes,
    );
  } on TypeError catch (error) {
    throw InvalidStoredSettings(pin, '$error');
  } on FormatException catch (error) {
    throw InvalidStoredSettings(pin, error.message);
  }
}

/// The stored snapshot [pin] or its source settings do not have the shape
/// this binary reads, such as a source without its `namespace` or a source
/// enabled twice.
final class InvalidStoredSettings implements Exception {
  /// Creates the error for snapshot [pin], with what failed in [detail].
  const InvalidStoredSettings(this.pin, this.detail);

  /// The snapshot whose stored settings failed to read.
  final String pin;

  /// What failed to read.
  final String detail;

  @override
  String toString() => 'Stored settings of snapshot $pin do not read: $detail';
}

Future<DecodeInputs> _readDecodeInputs(
  Session session,
  Transaction tx,
  RawKey rawKey,
  String pin, {
  required String sourceId,
  required String digest,
  required Uint8List bytes,
}) async {
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
  final [source] = switch (matches.toList()) {
    [_] && final single => single,
    _ => throw InvalidStoredSettings(
      pin,
      'source $sourceId is enabled more than once',
    ),
  };
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
  InvalidStoredSettings? admissionFailure;
  // A row whose envelope does not parse fails with that error in decodeRow,
  // so its admission metadata is not read: an unavailable admission read
  // must not turn the row's own format error into a retry.
  if (stream && _streamEnvelopeParses(bytes)) {
    // The admission snapshot is read as text and decoded here: a U+0000
    // escape elsewhere in it cannot become jsonb, and a failed cast would hide
    // the row's own format error. When it is the pin itself, the document
    // already parsed above is reused and its text is not read again.
    final admitted = await session.db.unsafeQuery(
      '''SELECT o.origin, o.sync_id::text,
          CASE WHEN c."snapshotId"=@pin THEN NULL ELSE c."publicJson" END,
          c."snapshotId"
        FROM icinga2_raw_origin o
        JOIN ingest_config_snapshot c ON c."snapshotId"=o.admission_snapshot_id
        WHERE o.raw_id=CAST(@raw AS uuid)''',
      parameters: QueryParameters.named({'raw': rawKey.rawId, 'pin': pin}),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    if (admitted.isNotEmpty) {
      final metadata = admitted.single;
      Object? document;
      try {
        document = metadata[3] == pin
            ? snapshot
            : jsonDecode(metadata[2]! as String);
      } on FormatException catch (error) {
        admissionFailure = InvalidStoredSettings(
          metadata[3]! as String,
          error.message,
        );
      }
      final admittedSource = switch (document) {
        {'sources': final List<Object?> sources} =>
          sources.whereType<Map<String, Object?>>().where(
            (entry) => entry['id'] == sourceId,
          ),
        _ => const <Map<String, Object?>>[],
      };
      // Exactly one entry may name the source: with two, array order would
      // pick the policy, which the stored row cannot confirm.
      if (admittedSource.length > 1) {
        admissionFailure = InvalidStoredSettings(
          metadata[3]! as String,
          'source $sourceId is listed more than once',
        );
      } else if (admittedSource.isNotEmpty) {
        final policy = admittedSource.single['state_type_policy'];
        admission = StreamAdmission(
          origin: metadata[0] as String?,
          statePolicy: policy is String ? policy : null,
          syncId: metadata[1] as String?,
        );
      }
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
    // Each element is checked here: a lazy cast would fail later, in the
    // decoder, outside the settings read.
    excludedLabels: [
      for (final label in source['excluded_identity_labels'] as List<Object?>)
        label as String,
    ],
    stream: stream,
    admission: admission,
    admissionFailure: admissionFailure,
  );
}

/// Whether [bytes] hold an Icinga2 stream envelope that [decodeRow] reads.
bool _streamEnvelopeParses(Uint8List bytes) {
  try {
    IcingaStreamRow.parse(bytes);
    return true;
  } on EventValidationError {
    return false;
  }
}

/// Decodes [bytes] of a raw row into canonical events, purely over [inputs].
///
/// Touches no database and reads no clock: [processedAt] is the processing
/// time stamped on every event, and [icinga2Decoder] decodes `icinga2` webhook
/// rows. Throws an [EventValidationError] when the bytes or the stored
/// admission metadata do not decode, an [InvalidStoredSettings] when a stream
/// row in a known format was admitted under a snapshot that is not JSON or
/// that lists the row's source more than once, and a
/// [StateError] when [inputs] carries a [DecodeInputs.rejection].
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
    if (inputs.admissionFailure case final failure?) throw failure;
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
