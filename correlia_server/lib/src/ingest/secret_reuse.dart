import 'dart:convert';

import 'package:serverpod/serverpod.dart';

import '../secrets/commitments.dart';
import 'bootstrap.dart';

/// Checks both reuse directions and inventories an accepted publication.
/// The caller holds the publication lock and commits this with the snapshot.
Future<void> recordPublicationReuse(
  Session session,
  Transaction transaction,
  IngestBootstrap input,
  SecretCommitments commitments, {
  int? timeoutInSecondsForTest,
}) async {
  final bare = <String, String>{};
  void addBare(String reference, String digest) {
    bare[digest] = commitments.passwordReuse(input.secret(reference)!);
  }

  for (final source in input.sources) {
    for (final credential in source.credentials) {
      addBare(credential.reference, credential.digest);
    }
  }
  for (final output in input.outputs.whereType<WebhookIngestOutput>()) {
    addBare(output.signingKeyRef, output.signingKeyCommitment);
  }
  final passwords = <String, ({String reuse, String field})>{};
  final keyed = <String>{};
  for (final source in input.sources) {
    final stream = source.stream;
    if (stream == null) continue;
    final bytes = input.secret(stream.passwordRef)!;
    passwords[legacySecretCommitment(bytes)] = (
      reuse: commitments.passwordReuse(bytes),
      field: 'sources[${source.declaredAt}].api.password_ref',
    );
    keyed.add(stream.passwordRef);
    keyed.add(stream.caRef);
  }
  if (bare.isEmpty && passwords.isEmpty) return;
  if (passwords.isNotEmpty) {
    final complete =
        (await session.db.unsafeQuery(
              'SELECT complete FROM secret_reuse_backfill WHERE singleton=1',
              transaction: transaction,
            )).single[0]!
            as bool;
    if (!complete) {
      throw const BootstrapError(
        'config',
        'sources',
        'reuse_inventory_pending',
      );
    }
  }
  final reuseValues = jsonEncode([
    for (final MapEntry(key: digest, value: reuse) in bare.entries)
      {'kind': 'bare', 'digest': digest, 'reuse': reuse},
    for (final MapEntry(key: digest, value: value) in passwords.entries)
      {'kind': 'password', 'digest': digest, 'reuse': value.reuse},
  ]);
  final matches = await session.db.unsafeQuery(
    '''WITH candidate AS MATERIALIZED (
      SELECT * FROM jsonb_to_recordset(CAST(@values AS jsonb))
        AS c(kind text,digest text,reuse text)
    ), conflict AS MATERIALIZED (
      SELECT p.digest FROM candidate p WHERE p.kind='password' AND (
        EXISTS (SELECT 1 FROM candidate b WHERE b.kind='bare' AND b.digest=p.digest)
        OR EXISTS (SELECT 1 FROM secret_reuse_digest b WHERE b.kind='bare' AND b.digest=p.digest)
        OR EXISTS (SELECT 1 FROM secret_reuse_retired_credential b WHERE b.digest=p.digest)
      )
      UNION ALL
      SELECT NULL FROM candidate b WHERE b.kind='bare' AND EXISTS (
        SELECT 1 FROM secret_reuse_digest p WHERE p.kind='password' AND p.digest=b.reuse
      )
    ), inserted AS (
      INSERT INTO secret_reuse_digest (kind,digest)
      SELECT kind,CASE WHEN kind='bare' THEN digest ELSE reuse END AS stored_digest
      FROM candidate WHERE NOT EXISTS (SELECT 1 FROM conflict)
      ORDER BY kind,stored_digest ON CONFLICT DO NOTHING
    )
    SELECT digest FROM conflict ORDER BY digest NULLS LAST LIMIT 1''',
    parameters: QueryParameters.named({'values': reuseValues}),
    transaction: transaction,
    timeoutInSeconds: timeoutInSecondsForTest,
  );
  if (matches.isNotEmpty) {
    throw BootstrapError(
      'config',
      passwords[matches.single[0]]?.field ?? r'$',
      'password_reuse',
    );
  }
  if (keyed.isEmpty) return;
  final legacy = await session.db.unsafeQuery(
    '''SELECT 1 FROM secret_record WHERE CAST(@refs AS jsonb) ? reference
      AND commitment NOT LIKE 'hmac-sha256:%' LIMIT 1''',
    parameters: QueryParameters.named({'refs': jsonEncode(keyed.toList())}),
    transaction: transaction,
  );
  if (legacy.isNotEmpty) {
    throw const BootstrapError('secrets', 'value', 'commitment_scheme');
  }
}
