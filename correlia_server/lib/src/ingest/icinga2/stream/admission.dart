import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;

import 'database.dart';
import 'decoder.dart';
import 'lease.dart';

/// A single already sanitized wire line and its original receipt time.
sealed class StreamAdmissionItem {
  StreamAdmissionItem._(this.received, this.invalidJson, this.redacted);

  factory StreamAdmissionItem.text(
    DateTime received,
    String line, {
    bool invalidJson,
    bool redacted,
  }) = _TextItem;

  factory StreamAdmissionItem.binary(
    DateTime received,
    Uint8List bytes, {
    bool redacted,
  }) = _BinaryItem;

  final DateTime received;
  final bool invalidJson;
  final bool redacted;

  late final Uint8List _encoded = utf8.encode(jsonEncode(_toJson()));

  /// The byte count in the exact wire representation used at admission.
  int get encodedLength => _encoded.length;

  Map<String, Object> _toJson() => {
    'received': received.microsecondsSinceEpoch,
    switch (this) {
      _TextItem() => 'line',
      _BinaryItem() => 'line_b64',
    }: switch (this) {
      _TextItem(:final line) => line,
      _BinaryItem(:final bytes) => base64Encode(bytes),
    },
    if (invalidJson) 'invalid_json': true,
    if (redacted) 'redacted': true,
  };
}

final class _TextItem extends StreamAdmissionItem {
  _TextItem(
    DateTime received,
    this.line, {
    bool invalidJson = false,
    bool redacted = false,
  }) : super._(received, invalidJson, redacted);

  final String line;
}

final class _BinaryItem extends StreamAdmissionItem {
  _BinaryItem(
    DateTime received,
    this.bytes, {
    bool redacted = false,
  }) : super._(received, true, redacted);

  final Uint8List bytes;
}

/// One delivery attempt; retry an unknown acknowledgement with the same ID.
final class StreamRawBatch {
  const StreamRawBatch({
    required this.id,
    required this.connectionId,
    required this.origin,
    required this.rows,
    this.syncId,
  });

  final String id;
  final String connectionId;
  final IcingaStreamOrigin origin;
  final List<List<StreamAdmissionItem>> rows;
  final String? syncId;
}

Uint8List _rowPrefix(
  IcingaStreamOrigin origin,
  String connectionId,
  String? syncId,
) => utf8.encode(
  '{"format":"$icingaStreamFormat","origin":"${origin.name}",'
  '"connection":${jsonEncode(connectionId)},'
  '${syncId == null ? '' : '"sync":${jsonEncode(syncId)},'}"items":[',
);

/// Bytes outside the items and their separators in an admitted raw row.
int streamEnvelopeBytes(
  IcingaStreamOrigin origin,
  String connectionId, {
  String? syncId,
}) => _rowPrefix(origin, connectionId, syncId).length + 2;

/// The result of a committed admission decision.
enum StreamAdmissionResult {
  committed,
  atCapacity,
  configChanged,
  leaseLost,
  receiptBehindCutoff,
}

/// Admits stream or sync rows, without webhook transport reservations.
final class ConsumerAdmission {
  const ConsumerAdmission(
    this.connection, {
    this.afterFence,
    this.beforeSyncProgressLockForTest,
    this.beforeCapacityLockForTest,
    this.beforeCommit,
    this.beforeWriteForTest,
    this.writeErrorForTest,
  });

  final pg.Connection connection;

  /// Tests can hold an admitted generation open before it writes any rows.
  final Future<void> Function()? afterFence;

  /// A test can hold the real admission transaction just before commit.
  final Future<void> Function(pg.TxSession)? beforeCommit;

  /// Observes the transaction immediately before locking sync progress.
  final Future<void> Function(pg.TxSession)? beforeSyncProgressLockForTest;

  /// Lets a contention fixture identify the transaction before it waits.
  final Future<void> Function(pg.TxSession)? beforeCapacityLockForTest;

  /// Observes or stages the exact raw write transaction in a fixture.
  final Future<void> Function(pg.TxSession, StreamRawBatch)? beforeWriteForTest;

  /// Observes a failed raw statement before the reader handles its error.
  final void Function(StreamRawBatch, pg.ServerException)? writeErrorForTest;

  /// The retained-work lookup used for both monitoring and admitting a batch.
  static const retainedCountSql = '''SELECT count(*) FROM (
    SELECT 1 FROM raw_inbox WHERE source_id=CAST(@source AS uuid)
      AND status IN ('pending','failed') LIMIT @limit
  ) AS retained''';

  /// Returns the bounded count of pending and failed raw rows for one source.
  Future<int> retained(String sourceId, {required int limit}) =>
      _retained(connection, sourceId, limit);

  Future<StreamAdmissionResult> admit({
    required StreamLease lease,
    required String snapshotId,
    required StreamRawBatch batch,
  }) async {
    final batchKey = {'source': lease.sourceId, 'batch': batch.id};
    try {
      return await runStreamWrite(connection, (tx) async {
        if (await _isCommitted(tx, batchKey)) {
          return StreamAdmissionResult.committed;
        }
        final sourceArg = {'source': lease.sourceId};
        final source = await tx.execute(
          pg.Sql.named(
            '''SELECT 1 FROM ingest_source WHERE "sourceId"=CAST(@source AS uuid)
            AND enabled AND kind='icinga2' AND mode='event_streams' FOR SHARE''',
          ),
          parameters: sourceArg,
        );
        if (source.isEmpty) return StreamAdmissionResult.configChanged;

        final snapshot = await tx.execute(
          pg.Sql.named(
            '''SELECT a."snapshotId", (source->>'max_pending_rows')::int
            FROM ingest_active_config a JOIN ingest_config_snapshot c USING ("snapshotId")
            CROSS JOIN LATERAL jsonb_array_elements(c."publicJson"::jsonb->'sources') source
            WHERE a.singleton=1 AND source->>'id'=@source''',
          ),
          parameters: sourceArg,
        );
        if (snapshot.isEmpty || snapshot.single[0] != snapshotId) {
          return StreamAdmissionResult.configChanged;
        }
        if (!await lockStreamLease(tx, lease)) {
          return StreamAdmissionResult.leaseLost;
        }
        final cap = snapshot.single[1]! as int;
        final retainedRows = await _retained(tx, lease.sourceId, cap + 1);
        if (retainedRows + batch.rows.length > cap) {
          if (await _isCommitted(tx, batchKey)) {
            return StreamAdmissionResult.committed;
          }
          await _checkRefusedReceipt(tx, batch);
          return StreamAdmissionResult.atCapacity;
        }
        if (batch.rows.isEmpty ||
            (batch.origin == IcingaStreamOrigin.sync) !=
                (batch.syncId != null)) {
          throw ArgumentError('Invalid stream batch shape');
        }
        await afterFence?.call();
        final claimed = await tx.execute(
          pg.Sql.named(
            '''INSERT INTO icinga2_admitted_batch ("sourceId","batchId","admittedAt")
            VALUES (CAST(@source AS uuid),CAST(@batch AS uuid),clock_timestamp())
            ON CONFLICT ("sourceId","batchId") DO NOTHING RETURNING id''',
          ),
          parameters: batchKey,
        );
        // PostgreSQL waits for an uncommitted unique-key conflict to settle.
        // A rollback lets this insert claim the batch instead.
        if (claimed.isEmpty) return StreamAdmissionResult.committed;

        if (batch.syncId case final syncId?) {
          await beforeSyncProgressLockForTest?.call(tx);
          final progress = await tx.execute(
            pg.Sql.named('''SELECT 1 FROM icinga2_sync_progress
              WHERE sync_id=CAST(@sync AS uuid) AND source_id=CAST(@source AS uuid)
                AND read_end_at IS NULL FOR UPDATE'''),
            parameters: {...sourceArg, 'sync': syncId},
          );
          if (progress.isEmpty) throw StateError('Icinga2 sync is not reading');
        }
        if (beforeCapacityLockForTest case final beforeCapacityLock?) {
          await beforeCapacityLock(tx);
        }
        final pressure = (await tx.execute(
          pg.Sql.named('SELECT correlia_reserve_raw(@count)'),
          parameters: {'count': batch.rows.length},
        )).single[0];
        if (pressure != null) {
          await _checkRefusedReceipt(tx, batch);
          await tx.execute(
            pg.Sql.named(
              '''DELETE FROM icinga2_admitted_batch
              WHERE "sourceId"=CAST(@source AS uuid) AND "batchId"=CAST(@batch AS uuid)''',
            ),
            parameters: batchKey,
          );
          return StreamAdmissionResult.atCapacity;
        }

        await beforeWriteForTest?.call(tx, batch);
        for (final row in batch.rows) {
          try {
            await _insertRow(tx, lease.sourceId, snapshotId, batch, row);
          } on pg.ServerException catch (error) {
            writeErrorForTest?.call(batch, error);
            rethrow;
          }
        }
        if (batch.syncId case final syncId?) {
          final updated = await tx.execute(
            pg.Sql.named(
              '''UPDATE icinga2_sync_progress SET rows_admitted=rows_admitted+@count
              WHERE sync_id=CAST(@sync AS uuid) AND source_id=CAST(@source AS uuid)
                AND read_end_at IS NULL RETURNING sync_id''',
            ),
            parameters: {
              ...sourceArg,
              'sync': syncId,
              'count': batch.rows.length,
            },
          );
          if (updated.isEmpty) throw StateError('Icinga2 sync is not reading');
        }
        await beforeCommit?.call(tx);
        return StreamAdmissionResult.committed;
      });
    } on pg.ServerException catch (error) {
      if (error.code == 'CR001') {
        return StreamAdmissionResult.receiptBehindCutoff;
      }
      rethrow;
    }
  }

  static Future<void> _checkRefusedReceipt(
    pg.TxSession tx,
    StreamRawBatch batch,
  ) async {
    DateTime? earliest;
    for (final row in batch.rows) {
      for (final item in row) {
        if (earliest == null || item.received.isBefore(earliest)) {
          earliest = item.received;
        }
      }
    }
    if (earliest == null) return;
    await tx.execute(
      pg.Sql.named('SELECT correlia_check_refused_raw_receipt(@receipt)'),
      parameters: {'receipt': earliest.toUtc()},
    );
  }

  static Future<bool> _isCommitted(
    pg.TxSession tx,
    Map<String, String> key,
  ) async => (await tx.execute(
    pg.Sql.named(
      '''SELECT 1 FROM icinga2_admitted_batch
      WHERE "sourceId"=CAST(@source AS uuid) AND "batchId"=CAST(@batch AS uuid)''',
    ),
    parameters: key,
  )).isNotEmpty;

  static Future<int> _retained(
    pg.Session query,
    String source,
    int limit,
  ) async =>
      (await query.execute(
            pg.Sql.named(retainedCountSql),
            parameters: {'source': source, 'limit': limit},
          )).single[0]!
          as int;

  static Future<void> _insertRow(
    pg.TxSession tx,
    String source,
    String snapshot,
    StreamRawBatch batch,
    List<StreamAdmissionItem> row,
  ) async {
    if (row.isEmpty || row.length > 100) {
      throw ArgumentError('Invalid stream row item count');
    }
    var earliest = row.first.received;
    final encoded = BytesBuilder(copy: false)
      ..add(_rowPrefix(batch.origin, batch.connectionId, batch.syncId));
    var separator = false;
    for (final item in row) {
      if (item.received.isBefore(earliest)) earliest = item.received;
      if (separator) encoded.addByte(44);
      encoded.add(item._encoded);
      separator = true;
    }
    encoded
      ..addByte(93)
      ..addByte(125);
    final body = encoded.takeBytes();
    await tx.execute(
      pg.Sql.named(
        '''WITH admitted AS (
          INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type)
          VALUES (@observed,gen_random_uuid(),CAST(@source AS uuid),@body,@digest,'application/json')
          RETURNING observed_at,raw_id
        ) INSERT INTO icinga2_raw_origin(raw_observed_at,raw_id,origin,sync_id,admission_snapshot_id)
          SELECT observed_at,raw_id,@origin,CAST(@sync AS uuid),@snapshot FROM admitted''',
      ),
      parameters: {
        'observed': earliest.toUtc(),
        'source': source,
        'body': body,
        'digest': sha256.convert(body).toString(),
        'origin': batch.origin.name,
        'sync': batch.syncId,
        'snapshot': snapshot,
      },
    );
  }
}
