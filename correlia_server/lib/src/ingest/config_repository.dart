import 'dart:convert';
import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';

import '../secrets/commitments.dart';
import '../secrets/secret_store.dart';
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
  const IngestConfigRepository(this.session, {this.secretStore});
  final Session session;

  /// The publication store; read-only snapshot users do not need one.
  final SecretStore? secretStore;

  SecretStore get _store =>
      secretStore ??
      (throw StateError('Publication requires an external secret key'));

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

  /// Resolves configuration material and publishes it in one transaction.
  Future<IngestBootstrap> publishConfig(
    Object? config,
    Object? secretInput, {
    required String runMode,
    bool requireLiveSecrets = true,
  }) async {
    final imported = decodeBootstrapSecrets(secretInput);
    return _publish(
      (tx) async {
        final material = Map<String, Uint8List>.of(imported);
        final store = _store;
        for (final reference in IngestBootstrap.references(config)) {
          if (material.containsKey(reference)) continue;
          final bytes = await store.read(session, reference, transaction: tx);
          if (bytes != null) material[reference] = bytes;
        }
        return IngestBootstrap.parseResolved(
          config,
          material,
          runMode: runMode,
          pluginCommitment: store.commitments.plugin,
        );
      },
      imported,
      requireLiveSecrets: requireLiveSecrets,
    );
  }

  /// Atomically activates validated input or accepts an identical restart.
  Future<void> publish(
    IngestBootstrap input, {
    bool requireLiveSecrets = true,
  }) async {
    for (final output in input.outputs.whereType<PluginIngestOutput>()) {
      for (final ref in output.secretRefs.values) {
        if (ref.commitment !=
            _store.commitments.plugin(
              ref.reference,
              input.secret(ref.reference)!,
            )) {
          throw const BootstrapError(
            'config',
            'secret_refs',
            'commitment_scheme',
          );
        }
      }
    }
    await _publish(
      (_) async => input,
      {for (final ref in input.loadedReferences) ref: input.secret(ref)!},
      requireLiveSecrets: requireLiveSecrets,
    );
  }

  Future<IngestBootstrap> _publish(
    Future<IngestBootstrap> Function(Transaction) prepare,
    Map<String, Uint8List> imported, {
    required bool requireLiveSecrets,
  }) async {
    try {
      return await session.db.transaction((transaction) async {
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
        await _store.checkKey(session, transaction);
        final input = await prepare(transaction);
        if (input.inputFormatVersion == 2) {
          throw const BootstrapError('config', 'format_version', 'not_enabled');
        }
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
        await _validateCommitments(imported, transaction);
        await _importSecrets(input, imported, transaction);
        if (requireLiveSecrets) {
          await validateLiveSecrets(transaction: transaction);
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
        if (active?['snapshotId'] == input.snapshotId) return input;
        await session.db.unsafeExecute(
          'INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson") VALUES (@id,@revision,@json)',
          parameters: QueryParameters.named({
            'id': input.snapshotId,
            'revision': input.revision,
            'json': input.publicJson,
          }),
          transaction: transaction,
        );
        // The plugin scheme wins when a new reference is shared with a webhook.
        // Existing M1 entries remain immutable and are checked by their own scheme.
        final commitments = <String, String>{
          for (final output in input.outputs.whereType<WebhookIngestOutput>())
            ...output.commitments,
          for (final output in input.outputs.whereType<PluginIngestOutput>())
            ...output.commitments,
        };
        for (final entry in commitments.entries) {
          await session.db.unsafeExecute(
            'INSERT INTO ingest_secret_commitment (reference,digest) VALUES (@reference,@digest) ON CONFLICT (reference) DO NOTHING',
            parameters: QueryParameters.named({
              'reference': entry.key,
              'digest': entry.value,
            }),
            transaction: transaction,
          );
        }
        // Publication obtains exclusive source locks; admission uses shared locks.
        await session.db.unsafeExecute(
          'UPDATE ingest_source SET enabled=false',
          transaction: transaction,
        );
        await session.db.unsafeExecute(
          'DELETE FROM ingest_source_credential',
          transaction: transaction,
        );
        for (final source in input.sources) {
          await session.db.unsafeExecute(
            '''INSERT INTO ingest_source ("sourceId",kind,enabled,"allowPathToken")
            VALUES (@id::uuid,@kind,@enabled,@path) ON CONFLICT ("sourceId") DO UPDATE
            SET kind=EXCLUDED.kind,enabled=EXCLUDED.enabled,"allowPathToken"=EXCLUDED."allowPathToken"''',
            parameters: QueryParameters.named({
              'id': source.id,
              'kind': source.kind,
              'enabled': source.enabled,
              'path': source.pathTokenEnabled,
            }),
            transaction: transaction,
          );
          for (final credential in source.credentials) {
            await session.db.unsafeExecute(
              '''INSERT INTO ingest_source_credential ("sourceId",reference,type,digest,"notBefore","notAfter")
              VALUES (@id::uuid,@reference,@type,@digest,@before,@after)''',
              parameters: QueryParameters.named({
                'id': source.id,
                'reference': credential.reference,
                'type': credential.type.name,
                'digest': credential.digest,
                'before': credential.notBefore,
                'after': credential.notAfter,
              }),
              transaction: transaction,
            );
          }
        }
        await session.db.unsafeExecute(
          '''INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,@id)
          ON CONFLICT (singleton) DO UPDATE SET "snapshotId"=EXCLUDED."snapshotId"''',
          parameters: QueryParameters.named({'id': input.snapshotId}),
          transaction: transaction,
        );
        return input;
      });
    } on BootstrapError {
      rethrow;
    } on SnapshotActivationError {
      rethrow;
    } on SecretResolutionError catch (error) {
      throw BootstrapError('secrets', r'$', error.code);
    } catch (_) {
      throw const BootstrapError('config', r'$', 'publication_failed');
    }
  }

  Future<void> _validateCommitments(
    Map<String, Uint8List> imported,
    Transaction transaction,
  ) async {
    if (imported.isEmpty) return;
    final commitments = await session.db.unsafeQuery(
      '''SELECT old.reference,old.digest FROM ingest_secret_commitment old
      WHERE CAST(@refs AS jsonb) ? old.reference
        AND NOT EXISTS (SELECT 1 FROM secret_record s WHERE s.reference=old.reference)''',
      parameters: QueryParameters.named({
        'refs': jsonEncode(imported.keys.toList()),
      }),
      transaction: transaction,
      timeoutInSeconds: 5,
    );
    for (final row in commitments) {
      final reference = row[0]! as String;
      if (!_store.commitments.verify(
        reference,
        row[1]! as String,
        imported[reference]!,
      )) {
        throw const BootstrapError('secrets', 'value', 'reference_rebound');
      }
    }
  }

  Future<void> _importSecrets(
    IngestBootstrap input,
    Map<String, Uint8List> imported,
    Transaction transaction,
  ) async {
    final store = _store;
    final required = <String, bool>{
      for (final source in input.sources)
        for (final credential in source.credentials)
          credential.reference: false,
      for (final output in input.outputs)
        if (output is WebhookIngestOutput) output.signingKeyRef: false,
      for (final output in input.outputs)
        if (output is PluginIngestOutput)
          for (final ref in output.secretRefs.values) ref.reference: true,
    };
    if (imported.isNotEmpty) {
      final rows = await session.db.unsafeQuery(
        '''SELECT DISTINCT o.signing_key_ref, o.signing_key_commitment, false
        FROM outbox o WHERE o.output_kind='webhook' AND o.status IN ('queued','delivering')
          AND CAST(@refs AS jsonb) ? o.signing_key_ref
        UNION
        SELECT DISTINCT entry.value->>'reference', entry.value->>'commitment', true
        FROM outbox o
        JOIN ingest_config_snapshot s ON s."snapshotId"=o.config_snapshot_id
        CROSS JOIN LATERAL jsonb_array_elements(s."publicJson"::jsonb->'outputs') output
        CROSS JOIN LATERAL jsonb_each(COALESCE(output->'secret_refs','{}'::jsonb)) entry
        WHERE o.output_kind='plugin' AND o.status IN ('queued','delivering')
          AND output->>'id'=o.output_id::text
          AND CAST(@refs AS jsonb) ? (entry.value->>'reference')''',
        parameters: QueryParameters.named({
          'refs': jsonEncode(imported.keys.toList()),
        }),
        transaction: transaction,
        timeoutInSeconds: 5,
      );
      for (final row in rows) {
        final reference = row[0]! as String;
        if (!store.commitments.verify(
          reference,
          row[1]! as String,
          imported[reference]!,
        )) {
          throw const BootstrapError('secrets', 'value', 'reference_rebound');
        }
        required[reference] = required[reference] == true || row[2] == true;
      }
    }
    for (final MapEntry(key: reference, value: plugin) in required.entries) {
      final stored = await store.read(
        session,
        reference,
        transaction: transaction,
      );
      final bytes = imported[reference];
      if (stored != null) {
        if (bytes != null && !secretBytesEqual(stored, bytes)) {
          throw const BootstrapError('secrets', 'value', 'reference_rebound');
        }
      } else if (bytes != null) {
        await store.insert(
          session,
          transaction,
          reference,
          bytes,
          plugin: plugin,
        );
      } else {
        throw const BootstrapError('config', r'$', 'missing_secret');
      }
    }
  }

  /// Requires matching material for live historical deliveries, not terminal rows.
  Future<void> validateLiveSecrets({Transaction? transaction}) async {
    final refs = await session.db.unsafeQuery(
      '''SELECT DISTINCT signing_key_ref,signing_key_commitment
      FROM outbox WHERE output_kind = 'webhook' AND status IN ('queued','delivering')''',
      transaction: transaction,
      timeoutInSeconds: 5,
    );
    for (final row in refs) {
      final reference = row[0]! as String;
      final bytes = await _store.read(
        session,
        reference,
        transaction: transaction,
      );
      if (bytes == null ||
          !_store.commitments.verify(reference, row[1]! as String, bytes)) {
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
