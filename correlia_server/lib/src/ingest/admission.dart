import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import '../event/identity.dart' show transportKey;

import '../schema/ingest_records.dart';

/// The committed result of a delivery admission.
enum AdmissionOutcome { accepted, duplicate, conflict, unauthorized }

/// Compares fixed-length credential digests without an early mismatch exit.
bool constantTimeDigestEquals(String left, String right) {
  if (left.length != 64 || right.length != 64) return false;
  var difference = 0;
  for (var i = 0; i < 64; i++) {
    difference |= left.codeUnitAt(i) ^ right.codeUnitAt(i);
  }
  return difference == 0;
}

/// Atomically rechecks source authorization and reserves transport evidence.
final class IngestAdmission {
  /// Creates an admission repository for [session].
  const IngestAdmission(
    this.session, {
    this.window = const Duration(minutes: 10),
  });

  /// The session used for database operations.
  final Session session;

  /// The non-sliding transport deduplication window.
  final Duration window;

  /// Stores a delivery or returns its existing reservation's outcome.
  Future<AdmissionOutcome> admit({
    required String sourceId,
    required String credentialReference,
    required String tokenDigest,
    required bool pathToken,
    required Uint8List body,
    required String contentType,
    required DateTime observedAt,
    String? idempotencyKey,
  }) async {
    final bodyDigest = sha256.convert(body);
    final digest = bodyDigest.toString();
    final key = transportKey(
      sourceInstance: sourceId,
      idempotencyKey: idempotencyKey,
      bodySha256: idempotencyKey == null
          ? Uint8List.fromList(bodyDigest.bytes)
          : null,
    );
    final rawId = const Uuid().v4();
    return session.db.transaction((tx) async {
      await session.db.unsafeSimpleExecute(
        "SET LOCAL statement_timeout = '5s'",
        transaction: tx,
      );
      await session.db.unsafeSimpleExecute(
        "SET LOCAL lock_timeout = '5s'",
        transaction: tx,
      );
      final sources = await session.db.unsafeQuery(
        'SELECT enabled, "allowPathToken" FROM ingest_source WHERE "sourceId"=CAST(@source AS uuid) FOR SHARE',
        parameters: QueryParameters.named({'source': sourceId}),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (sources.isEmpty ||
          sources.single[0] != true ||
          (pathToken && sources.single[1] != true)) {
        return AdmissionOutcome.unauthorized;
      }
      final credentials = await session.db.unsafeQuery(
        '''SELECT digest FROM ingest_source_credential
        WHERE "sourceId"=CAST(@source AS uuid) AND reference=@reference AND type='bearer' ''',
        parameters: QueryParameters.named({
          'source': sourceId,
          'reference': credentialReference,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (credentials.isEmpty ||
          !constantTimeDigestEquals(
            credentials.single[0]! as String,
            tokenDigest,
          )) {
        return AdmissionOutcome.unauthorized;
      }
      final params = QueryParameters.named({
        'source': sourceId,
        'key': key,
        'digest': digest,
        'now': observedAt,
        'expires': observedAt.add(window),
        'raw': rawId,
      });
      final inserted = await session.db.unsafeQuery(
        '''INSERT INTO transport_keys
("sourceId", "key", "bodySha256", "firstSeenAt", "expiresAt", "rawObservedAt", "rawId")
VALUES (CAST(@source AS uuid), @key, @digest, @now, @expires, @now, CAST(@raw AS uuid))
ON CONFLICT ("sourceId", "key") DO NOTHING RETURNING "key"''',
        parameters: params,
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (inserted.isEmpty) {
        final existing = await session.db.unsafeQuery(
          '''SELECT "bodySha256", "expiresAt" FROM transport_keys
WHERE "sourceId"=CAST(@source AS uuid) AND "key"=@key FOR UPDATE''',
          parameters: QueryParameters.named({'source': sourceId, 'key': key}),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        final row = existing.single;
        if ((row[1] as DateTime).isAfter(observedAt)) {
          return row[0] == digest
              ? AdmissionOutcome.duplicate
              : AdmissionOutcome.conflict;
        }
        await session.db.unsafeExecute(
          '''UPDATE transport_keys SET "bodySha256"=@digest,
"firstSeenAt"=@now, "expiresAt"=@expires, "rawObservedAt"=@now, "rawId"=CAST(@raw AS uuid)
WHERE "sourceId"=CAST(@source AS uuid) AND "key"=@key''',
          parameters: params,
          transaction: tx,
          timeoutInSeconds: 5,
        );
      }
      await IngestRecords(session).insertRaw(
        RawInboxRecord(
          identity: RawIdentity(observedAt, rawId),
          sourceId: sourceId,
          body: body,
          bodySha256: digest,
          contentType: contentType,
        ),
        transaction: tx,
      );
      return AdmissionOutcome.accepted;
    });
  }
}
