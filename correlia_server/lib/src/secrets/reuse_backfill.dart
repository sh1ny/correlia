import 'package:serverpod/serverpod.dart';

const _batchSize = 500;

/// Backfills retained bare commitments after the schema cutover.
///
/// Outbox pins hold only copies of their pinned snapshot's commitments. Read
/// snapshots, not the outbox; any writer that changes that must add an outbox
/// pass. New publishers inventory their own writes; retired pre-cutover
/// credentials are captured separately by the cutover trigger.
Future<void> backfillSecretReuse(Session session) async {
  while (await session.db.transaction((tx) => _nextBatch(session, tx))) {}
}

enum _Pass {
  snapshot(
    'ingest_config_snapshot',
    'revision',
    '"publicJson"::jsonb AS config',
  ),
  commitment('ingest_secret_commitment', 'id', 'digest'),
  credential('ingest_source_credential', 'id', 'digest');

  const _Pass(this.table, this.cursor, this.data);

  final String table;
  final String cursor;
  final String data;
}

Future<bool> _nextBatch(Session session, Transaction tx) async {
  final state = (await session.db.unsafeQuery(
    '''SELECT snapshot_mark,snapshot_boundary,commitment_mark,commitment_boundary,
      credential_mark,credential_boundary,complete
      FROM secret_reuse_backfill WHERE singleton=1 FOR UPDATE''',
    transaction: tx,
  )).single;
  if (state[6]! as bool) return false;
  for (final pass in _Pass.values) {
    final mark = state[pass.index * 2]! as int;
    final boundary = state[pass.index * 2 + 1]! as int;
    if (mark == boundary) continue;
    final result = (await session.db.unsafeQuery(
      '''WITH batch AS MATERIALIZED (
        SELECT ${pass.cursor} AS cursor, ${pass.data} FROM ${pass.table}
        WHERE ${pass.cursor} > @mark AND ${pass.cursor} <= @boundary
        ORDER BY ${pass.cursor} LIMIT $_batchSize
      ), bare AS (${pass == _Pass.snapshot ? _snapshotDigests : 'SELECT digest FROM batch'}),
      inserted AS (
        INSERT INTO secret_reuse_digest (kind,digest)
        SELECT 'bare', digest FROM bare WHERE digest ~ '^[0-9a-f]{64}\$'
        GROUP BY digest ORDER BY digest ON CONFLICT DO NOTHING
      )
      SELECT count(*), max(cursor) FROM batch''',
      parameters: QueryParameters.named({'mark': mark, 'boundary': boundary}),
      transaction: tx,
    )).single;
    final end = result[0] == _batchSize ? result[1]! as int : boundary;
    final complete =
        end == boundary &&
        switch (pass) {
          _Pass.snapshot => state[2] == state[3] && state[4] == state[5],
          _Pass.commitment => state[4] == state[5],
          _Pass.credential => true,
        };
    await session.db.unsafeExecute(
      'UPDATE secret_reuse_backfill SET ${pass.name}_mark=@mark,complete=@complete WHERE singleton=1',
      parameters: QueryParameters.named({'mark': end, 'complete': complete}),
      transaction: tx,
    );
    return !complete;
  }
  await session.db.unsafeExecute(
    'UPDATE secret_reuse_backfill SET complete=true WHERE singleton=1',
    transaction: tx,
  );
  return false;
}

const _snapshotDigests = '''
  SELECT source->>'token_digest' AS digest FROM batch
  CROSS JOIN LATERAL jsonb_array_elements(config->'sources') source
  UNION ALL
  SELECT credential->>'digest' FROM batch
  CROSS JOIN LATERAL jsonb_array_elements(config->'sources') source
  CROSS JOIN LATERAL jsonb_array_elements(source->'credentials') credential
  UNION ALL
  SELECT output->>'signing_key_commitment' FROM batch
  CROSS JOIN LATERAL jsonb_array_elements(config->'outputs') output
  WHERE output->>'kind'='webhook'
  UNION ALL
  SELECT entry.value->>'commitment' FROM batch
  CROSS JOIN LATERAL jsonb_array_elements(config->'outputs') output
  CROSS JOIN LATERAL jsonb_each(output->'secret_refs') entry
  WHERE output->>'kind'='plugin'
''';
