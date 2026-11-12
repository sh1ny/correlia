import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import 'bootstrap.dart';

/// A rejected activation containing only public snapshot identities and revisions.
final class SnapshotActivationError implements Exception {
  const SnapshotActivationError(
    this.inputId,
    this.inputRevision,
    this.activeId,
    this.activeRevision,
  );
  final String inputId;
  final int inputRevision;
  final String activeId;
  final int activeRevision;
  @override
  String toString() =>
      'ingest activation_conflict input=$inputId revision=$inputRevision active=$activeId revision=$activeRevision';
}

/// Publishes immutable snapshots and current admission credentials atomically.
final class IngestConfigRepository {
  const IngestConfigRepository(this.session);
  final Session session;

  /// Returns the active public snapshot, if ingest has ever been configured.
  Future<Map<String, Object?>?> activeSnapshot({
    Transaction? transaction,
  }) async {
    final rows = await session.db.unsafeQuery(
      '''SELECT c."snapshotId", c.revision, c."publicJson"
      FROM ingest_active_config a JOIN ingest_config_snapshot c ON c."snapshotId"=a."snapshotId"
      WHERE a.singleton=1''',
      transaction: transaction,
      timeoutInSeconds: 5,
    );
    return rows.isEmpty ? null : rows.single.toColumnMap();
  }

  /// Atomically activates only a new higher revision, or accepts an identical restart.
  Future<void> publish(
    IngestBootstrap input, {
    bool requireLiveSecrets = true,
  }) async {
    try {
      await session.db.transaction((transaction) async {
        await session.db.unsafeQuery(
          'SELECT pg_advisory_xact_lock(1129271884)',
          transaction: transaction,
          timeoutInSeconds: 5,
        );
        await session.db.unsafeSimpleExecute(
          "SET LOCAL statement_timeout = '5s'",
          transaction: transaction,
        );
        await session.db.unsafeSimpleExecute(
          "SET LOCAL lock_timeout = '5s'",
          transaction: transaction,
        );
        final active = await activeSnapshot(transaction: transaction);
        if (active != null && active['snapshotId'] != input.snapshotId) {
          final stored = await session.db.unsafeQuery(
            'SELECT 1 FROM ingest_config_snapshot WHERE "snapshotId"=@id',
            parameters: QueryParameters.named({'id': input.snapshotId}),
            transaction: transaction,
          );
          if (stored.isNotEmpty ||
              input.revision <= (active['revision']! as int)) {
            throw SnapshotActivationError(
              input.snapshotId,
              input.revision,
              active['snapshotId']! as String,
              active['revision']! as int,
            );
          }
        }
        await _validateCommitments(input, transaction);
        if (requireLiveSecrets) {
          await validateLiveSecrets(input, transaction: transaction);
        }
        final retained = await session.db.unsafeQuery(
          "SELECT DISTINCT output_id::text FROM outbox WHERE status IN ('queued','delivering')",
          transaction: transaction,
        );
        final lanes = {
          for (final row in retained) row[0]! as String,
          ...input.outputs.map((output) => output.id),
        };
        if (lanes.length > 64) {
          throw const BootstrapError(
            'config',
            'outputs',
            'retained_output_bound',
          );
        }
        if (active?['snapshotId'] == input.snapshotId) return;
        await session.db.unsafeExecute(
          'INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson") VALUES (@id,@revision,@json)',
          parameters: QueryParameters.named({
            'id': input.snapshotId,
            'revision': input.revision,
            'json': input.publicJson,
          }),
          transaction: transaction,
        );
        for (final output in input.outputs) {
          for (final entry in output.commitments.entries) {
            await session.db.unsafeExecute(
              'INSERT INTO ingest_secret_commitment (reference,digest) VALUES (@reference,@digest) ON CONFLICT (reference) DO NOTHING',
              parameters: QueryParameters.named({
                'reference': entry.key,
                'digest': entry.value,
              }),
              transaction: transaction,
            );
          }
        }
        // Publication obtains exclusive source locks; admission uses shared locks.
        await session.db.unsafeExecute(
          'UPDATE ingest_source SET enabled=false',
          transaction: transaction,
        );
        for (final source in input.sources) {
          await session.db.unsafeExecute(
            '''INSERT INTO ingest_source ("sourceId","tokenDigest",enabled,"allowPathToken")
            VALUES (@id::uuid,@digest,@enabled,@path) ON CONFLICT ("sourceId") DO UPDATE
            SET "tokenDigest"=EXCLUDED."tokenDigest", enabled=EXCLUDED.enabled,"allowPathToken"=EXCLUDED."allowPathToken"''',
            parameters: QueryParameters.named({
              'id': source.id,
              'digest': source.tokenDigest,
              'enabled': source.enabled,
              'path': source.pathTokenEnabled,
            }),
            transaction: transaction,
          );
        }
        await session.db.unsafeExecute(
          '''INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,@id)
          ON CONFLICT (singleton) DO UPDATE SET "snapshotId"=EXCLUDED."snapshotId"''',
          parameters: QueryParameters.named({'id': input.snapshotId}),
          transaction: transaction,
        );
      });
    } on BootstrapError {
      rethrow;
    } on SnapshotActivationError {
      rethrow;
    } catch (_) {
      throw const BootstrapError('config', r'$', 'publication_failed');
    }
  }

  Future<void> _validateCommitments(
    IngestBootstrap input,
    Transaction transaction,
  ) async {
    final commitments = await session.db.unsafeQuery(
      'SELECT reference,digest FROM ingest_secret_commitment',
      transaction: transaction,
    );
    for (final row in commitments) {
      final reference = row[0]! as String;
      final material = input.secret(reference);
      if (material != null && sha256.convert(material).toString() != row[1]) {
        throw const BootstrapError('secrets', 'value', 'reference_rebound');
      }
    }
  }

  /// Requires matching material for live historical deliveries, not terminal rows.
  Future<void> validateLiveSecrets(
    IngestBootstrap input, {
    Transaction? transaction,
  }) async {
    final refs = await session.db.unsafeQuery(
      '''SELECT DISTINCT signing_key_ref,signing_key_commitment
      FROM outbox WHERE output_kind = 'webhook' AND status IN ('queued','delivering')''',
      transaction: transaction,
      timeoutInSeconds: 5,
    );
    for (final row in refs) {
      final bytes = input.secret(row[0]! as String);
      if (bytes == null || sha256.convert(bytes).toString() != row[1]) {
        throw const BootstrapError(
          'secrets',
          'value',
          'historical_key_unavailable',
        );
      }
    }
  }

  /// Rejects an unattended configured worker even after its queues have drained.
  Future<void> validateWithoutBootstrap() async {
    try {
      final rows = await session.db.unsafeQuery(
        '''SELECT
        (SELECT count(*) FROM ingest_active_config) AS active,
        (SELECT count(*) FROM raw_inbox WHERE status='pending') AS raw,
        (SELECT count(*) FROM outbox WHERE status IN ('queued','delivering')) AS output''',
        timeoutInSeconds: 5,
      );
      final counts = rows.single.toColumnMap();
      if (counts.values.any((value) => (value! as int) > 0)) {
        throw BootstrapError(
          'config',
          'active=${counts['active']},raw=${counts['raw']},output=${counts['output']}',
          'bootstrap_required',
        );
      }
    } on BootstrapError {
      rethrow;
    } catch (_) {
      throw const BootstrapError('config', r'$', 'work_inspection_failed');
    }
  }

  /// Loads a persisted snapshot for deterministic processing of a committed pin.
  Future<Map<String, Object?>> snapshot(
    String id, {
    Transaction? transaction,
  }) async {
    final rows = await session.db.unsafeQuery(
      'SELECT "publicJson" FROM ingest_config_snapshot WHERE "snapshotId"=@id',
      parameters: QueryParameters.named({'id': id}),
      transaction: transaction,
      timeoutInSeconds: 5,
    );
    if (rows.length != 1) {
      throw const BootstrapError('config', 'snapshot', 'missing');
    }
    return jsonDecode(rows.single[0]! as String) as Map<String, Object?>;
  }
}
