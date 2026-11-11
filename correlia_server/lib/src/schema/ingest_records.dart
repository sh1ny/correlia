import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';

/// Immutable identity of a raw delivery.
final class RawIdentity {
  /// Creates a time-qualified raw identity.
  const RawIdentity(this.observedAt, this.rawId);

  /// The observed timestamp.
  final DateTime observedAt;

  /// The delivery UUID.
  final String rawId;
}

/// Immutable identity of an event evidence row.
final class EventIdentity {
  /// Creates a time-qualified event identity.
  const EventIdentity(this.observedAt, this.eventId, this.disposition);

  /// The observed timestamp.
  final DateTime observedAt;

  /// The deterministic event UUID.
  final String eventId;

  /// The processing disposition.
  final String disposition;
}

/// Immutable identity of a delivery intent.
final class DeliveryIdentity {
  /// Creates a time-qualified delivery identity.
  const DeliveryIdentity(this.createdAt, this.deliveryId);

  /// The creation timestamp.
  final DateTime createdAt;

  /// The delivery UUID.
  final String deliveryId;
}

/// A raw delivery's immutable admission evidence.
final class RawInboxRecord {
  /// Creates raw admission evidence.
  const RawInboxRecord({
    required this.identity,
    required this.sourceId,
    required this.body,
    required this.bodySha256,
    required this.contentType,
  });

  /// The time-qualified identity.
  final RawIdentity identity;

  /// The source UUID.
  final String sourceId;

  /// The exact received bytes.
  final Uint8List body;

  /// The hexadecimal body digest.
  final String bodySha256;

  /// The normalized content type.
  final String contentType;
}

/// Immutable canonical event evidence.
final class EventRecord {
  /// Creates event evidence.
  const EventRecord({
    required this.identity,
    required this.raw,
    required this.sourceId,
    required this.configSnapshotId,
    required this.sourceTime,
    required this.payload,
  });

  /// The event identity.
  final EventIdentity identity;

  /// The originating raw identity.
  final RawIdentity raw;

  /// The source UUID.
  final String sourceId;

  /// The pinned configuration identifier.
  final String configSnapshotId;

  /// The original source timestamp.
  final DateTime sourceTime;

  /// The immutable encoded event.
  final Uint8List payload;
}

/// Immutable routing intent and its encoded event.
final class OutboxRecord {
  /// Creates a delivery intent.
  const OutboxRecord({
    required this.identity,
    required this.event,
    required this.outputId,
    required this.configSnapshotId,
    required this.targetUrl,
    required this.signingKeyRef,
    required this.signingKeyCommitment,
    required this.payload,
  });

  /// The delivery identity.
  final DeliveryIdentity identity;

  /// The originating event identity.
  final EventIdentity event;

  /// The output UUID.
  final String outputId;

  /// The pinned configuration identifier.
  final String configSnapshotId;

  /// The pinned destination.
  final String targetUrl;

  /// The immutable signing-key reference.
  final String signingKeyRef;

  /// The signing-key digest commitment.
  final String signingKeyCommitment;

  /// The immutable encoded event.
  final Uint8List payload;
}

/// Parameterized inserts into the SQL-owned ingest tables.
final class IngestRecords {
  /// Creates a repository over an existing session.
  const IngestRecords(this.session);

  /// The session used by the repository.
  final Session session;

  /// Inserts raw evidence in the caller's transaction.
  Future<void> insertRaw(
    RawInboxRecord row, {
    required Transaction transaction,
  }) async {
    await session.db.unsafeExecute(
      '''INSERT INTO raw_inbox
(observed_at, raw_id, source_id, body, body_sha256, content_type)
VALUES (@observedAt, CAST(@rawId AS uuid), CAST(@sourceId AS uuid), @body, @digest, @contentType)''',
      parameters: QueryParameters.named({
        'observedAt': row.identity.observedAt,
        'rawId': row.identity.rawId,
        'sourceId': row.sourceId,
        'body': row.body,
        'digest': row.bodySha256,
        'contentType': row.contentType,
      }),
      transaction: transaction,
    );
  }

  /// Inserts canonical evidence in the caller's transaction.
  Future<void> insertEvent(
    EventRecord row, {
    required Transaction transaction,
  }) async {
    await session.db.unsafeExecute(
      '''INSERT INTO events
(observed_at, event_id, disposition, raw_observed_at, raw_id, source_id, config_snapshot_id, source_time, payload)
VALUES (@observedAt, CAST(@eventId AS uuid), @disposition, @rawObservedAt, CAST(@rawId AS uuid), CAST(@sourceId AS uuid), @config, @sourceTime, @payload)''',
      parameters: QueryParameters.named({
        'observedAt': row.identity.observedAt,
        'eventId': row.identity.eventId,
        'disposition': row.identity.disposition,
        'rawObservedAt': row.raw.observedAt,
        'rawId': row.raw.rawId,
        'sourceId': row.sourceId,
        'config': row.configSnapshotId,
        'sourceTime': row.sourceTime,
        'payload': row.payload,
      }),
      transaction: transaction,
    );
  }

  /// Inserts a routed delivery in the caller's transaction.
  Future<void> insertOutbox(
    OutboxRecord row, {
    required Transaction transaction,
  }) async {
    await session.db.unsafeExecute(
      '''INSERT INTO outbox
(created_at, delivery_id, event_observed_at, event_id, event_disposition, output_id, config_snapshot_id, target_url, signing_key_ref, signing_key_commitment, payload)
VALUES (@createdAt, CAST(@deliveryId AS uuid), @eventObservedAt, CAST(@eventId AS uuid), @disposition, CAST(@outputId AS uuid), @config, @target, @keyRef, @commitment, @payload)''',
      parameters: QueryParameters.named({
        'createdAt': row.identity.createdAt,
        'deliveryId': row.identity.deliveryId,
        'eventObservedAt': row.event.observedAt,
        'eventId': row.event.eventId,
        'disposition': row.event.disposition,
        'outputId': row.outputId,
        'config': row.configSnapshotId,
        'target': row.targetUrl,
        'keyRef': row.signingKeyRef,
        'commitment': row.signingKeyCommitment,
        'payload': row.payload,
      }),
      transaction: transaction,
    );
  }
}
