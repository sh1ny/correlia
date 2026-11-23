import 'package:serverpod/serverpod.dart';

/// Reclaims only silent tombstones with no retained or potentially ready evidence.
final class TombstoneSweep {
  /// The caller owns the session and closes its connection on shutdown.
  const TombstoneSweep(this.session, {this.clock});

  final Session session;
  final DateTime Function()? clock;

  /// Returns rows deleted by an acknowledged transaction, at most 500.
  Future<int> runOnce() async {
    final watch = Stopwatch()..start();
    try {
      return await session.db.transaction((tx) async {
        Future<void> bound() async {
          final remaining = 1000 - watch.elapsedMilliseconds;
          if (remaining <= 0) throw const _SweepDeadline();
          await session.db.unsafeSimpleExecute(
            "SET LOCAL lock_timeout='${remaining}ms'; SET LOCAL statement_timeout='${remaining}ms'",
            transaction: tx,
          );
        }

        await bound();
        final state = (await session.db.unsafeQuery(
          '''
          UPDATE raw_admission_cutoff
          SET cutoff=GREATEST(cutoff, COALESCE(CAST(@now AS timestamptz),clock_timestamp()) - interval '1 hour')
          WHERE singleton=1 RETURNING cursor_seconds,cursor_nanos,cursor_id
        ''',
          parameters: QueryParameters.named({'now': clock?.call()}),
          transaction: tx,
        )).single;
        await bound();
        // A distinct statement obtains a fresh snapshot after the cutoff lock.
        final candidates = await session.db.unsafeQuery(
          '''
          WITH horizon AS (
            SELECT LEAST(cutoff,(SELECT min(observed_at) FROM raw_inbox WHERE status='pending'))
              - interval '7 days' AS boundary FROM raw_admission_cutoff WHERE singleton=1
          )
          SELECT a.id,a."fenceEffectiveSeconds",a."fenceEffectiveNanos"
          FROM alerts a CROSS JOIN horizon h WHERE a.silent_tombstone
            AND (a."fenceEffectiveSeconds",a."fenceEffectiveNanos",a.id) > (@seconds,@nanos,@id)
            AND (a."fenceEffectiveSeconds",a."fenceEffectiveNanos") < (
              floor(extract(epoch FROM h.boundary)),
              mod(extract(epoch FROM h.boundary),1)*1000000000
            )
          ORDER BY a."fenceEffectiveSeconds",a."fenceEffectiveNanos",a.id LIMIT 500
        ''',
          parameters: QueryParameters.named({
            'seconds': state[0],
            'nanos': state[1],
            'id': state[2],
          }),
          transaction: tx,
        );
        var deleted = 0;
        if (candidates.isNotEmpty) {
          await bound();
          final locked = await session.db.unsafeQuery(
            '''
            SELECT id FROM alerts WHERE id=ANY(CAST(@ids AS bigint[])) AND silent_tombstone
            ORDER BY tenant,fingerprint FOR UPDATE SKIP LOCKED
          ''',
            parameters: QueryParameters.named({
              'ids': [for (final row in candidates) row[0]! as int],
            }),
            transaction: tx,
          );
          if (locked.isNotEmpty) {
            await bound();
            // The non-locking indexed probes see commits from previous holders
            // but never wait for a provisional observation reservation.
            final removed = await session.db.unsafeQuery(
              '''
              WITH horizon AS (
                SELECT LEAST(cutoff,(SELECT min(observed_at) FROM raw_inbox WHERE status='pending'))
                  - interval '7 days' AS boundary FROM raw_admission_cutoff WHERE singleton=1
              )
              DELETE FROM alerts a USING horizon h
              WHERE a.id=ANY(CAST(@ids AS bigint[])) AND a.silent_tombstone
                AND (a."fenceEffectiveSeconds",a."fenceEffectiveNanos") < (
                  floor(extract(epoch FROM h.boundary)),
                  mod(extract(epoch FROM h.boundary),1)*1000000000
                )
                AND NOT EXISTS (SELECT 1 FROM activity e WHERE e.entity_kind='alert' AND e.entity_id=a.id)
                AND NOT EXISTS (SELECT 1 FROM observation_keys k WHERE k.fingerprint=a.fingerprint)
                AND NOT EXISTS (SELECT 1 FROM events e WHERE correlia_event_subject(e.payload)=a.fingerprint)
              RETURNING a.id
            ''',
              parameters: QueryParameters.named({
                'ids': [for (final row in locked) row[0]! as int],
              }),
              transaction: tx,
            );
            deleted = removed.length;
          }
        }
        final last = candidates.length == 500 ? candidates.last : null;
        await bound();
        await session.db.unsafeExecute(
          '''UPDATE raw_admission_cutoff
          SET cursor_seconds=@seconds,cursor_nanos=@nanos,cursor_id=@id WHERE singleton=1''',
          parameters: QueryParameters.named({
            'seconds': last?[1] ?? 0,
            'nanos': last?[2] ?? 0,
            'id': last?[0] ?? 0,
          }),
          transaction: tx,
        );
        await bound();
        return deleted;
      });
    } on _SweepDeadline {
      return 0;
    } on DatabaseQueryException catch (error) {
      if (error.code == '55P03' || error.code == '57014') return 0;
      rethrow;
    }
  }
}

final class _SweepDeadline implements Exception {
  const _SweepDeadline();
}
