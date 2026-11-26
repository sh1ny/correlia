import 'dart:async';

import 'package:postgres/postgres.dart' as pg;

/// Reclaims only silent tombstones with no retained or potentially ready evidence.
final class TombstoneSweep {
  /// Uses a dedicated connection owned by the caller.
  const TombstoneSweep(
    this.connection, {
    this.clock,
    this.beforeCommit,
    this.beforeCutoffLockForTest,
  });

  final pg.Connection connection;
  final DateTime Function()? clock;
  static const _deadline = Duration(seconds: 1);
  final Future<void> Function(pg.TxSession)? beforeCommit;

  /// Holds the real cutoff query under fixture-owned timing instead of the
  /// production sweep deadline.
  final Future<void> Function(pg.TxSession)? beforeCutoffLockForTest;

  /// Returns rows deleted by an acknowledged transaction, at most 500.
  Future<int> runOnce() async {
    final watch = Stopwatch()..start();
    try {
      final beforeCutoffLock = beforeCutoffLockForTest;
      var fixtureOwnsTimeout = false;
      final work = connection.runTx((tx) async {
        Duration? remaining() {
          if (fixtureOwnsTimeout) return null;
          if (beforeCutoffLock != null) return _deadline;
          final duration = _deadline - watch.elapsed;
          if (duration <= Duration.zero) throw const _SweepDeadline();
          return duration;
        }

        Future<void> bound() async {
          final duration = remaining();
          if (duration == null) return;
          final milliseconds = duration.inMilliseconds;
          if (milliseconds <= 0) throw const _SweepDeadline();
          await tx.execute(
            "SET LOCAL lock_timeout='${milliseconds}ms'; SET LOCAL statement_timeout='${milliseconds}ms'",
            queryMode: pg.QueryMode.simple,
            timeout: duration,
          );
        }

        if (beforeCutoffLock != null) {
          await bound();
          // Let the fixture verify the normal SQL settings before overriding them.
          await beforeCutoffLock(tx);
          fixtureOwnsTimeout = true;
        }
        await bound();
        // Neither evidence probe may wait behind DDL with the cutoff held.
        await tx.execute(
          'LOCK TABLE ONLY raw_inbox, ONLY events IN ACCESS SHARE MODE',
          timeout: remaining(),
        );
        await bound();
        final state = (await tx.execute(
          pg.Sql.named('''
          SELECT * FROM correlia_advance_raw_cutoff(COALESCE(CAST(@now AS timestamptz),clock_timestamp()))
        '''),
          parameters: {'now': clock?.call()},
          timeout: remaining(),
        )).single;
        await bound();
        // A distinct statement obtains a fresh snapshot after the cutoff lock.
        final candidates = await tx.execute(
          pg.Sql.named('''
          WITH horizon AS (
            SELECT LEAST(cutoff,(SELECT min(observed_at) FROM raw_inbox WHERE status IN ('pending','failed')))
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
        '''),
          parameters: {
            'seconds': state[0],
            'nanos': state[1],
            'id': state[2],
          },
          timeout: remaining(),
        );
        var deleted = 0;
        if (candidates.isNotEmpty) {
          await bound();
          final locked = await tx.execute(
            pg.Sql.named('''
            SELECT id FROM alerts WHERE id=ANY(CAST(@ids AS bigint[])) AND silent_tombstone
            ORDER BY tenant,fingerprint FOR UPDATE SKIP LOCKED
          '''),
            parameters: {
              'ids': [for (final row in candidates) row[0]! as int],
            },
            timeout: remaining(),
          );
          if (locked.isNotEmpty) {
            await bound();
            // The non-locking indexed probes see commits from previous holders
            // but never wait for a provisional observation reservation.
            final removed = await tx.execute(
              pg.Sql.named('''
              WITH horizon AS (
                SELECT LEAST(cutoff,(SELECT min(observed_at) FROM raw_inbox WHERE status IN ('pending','failed')))
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
            '''),
              parameters: {
                'ids': [for (final row in locked) row[0]! as int],
              },
              timeout: remaining(),
            );
            deleted = removed.length;
          }
        }
        final last = candidates.length == 500 ? candidates.last : null;
        await bound();
        await tx.execute(
          pg.Sql.named(
            '''UPDATE raw_admission_cutoff
          SET cursor_seconds=@seconds,cursor_nanos=@nanos,cursor_id=@id WHERE singleton=1''',
          ),
          parameters: {
            'seconds': last?[1] ?? 0,
            'nanos': last?[2] ?? 0,
            'id': last?[0] ?? 0,
          },
          timeout: remaining(),
        );
        if (beforeCommit != null) await beforeCommit!(tx);
        await bound();
        remaining();
        return deleted;
      });
      if (beforeCutoffLock != null) return await work;
      return await work.timeout(
        _deadline,
        onTimeout: () {
          unawaited(connection.close(force: true));
          return 0;
        },
      );
    } on _SweepDeadline {
      unawaited(connection.close(force: true));
      return 0;
    } on TimeoutException {
      unawaited(connection.close(force: true));
      return 0;
    } on pg.ServerException catch (error) {
      if (error.code == '55P03' || error.code == '57014') {
        unawaited(connection.close(force: true));
        return 0;
      }
      rethrow;
    }
  }
}

final class _SweepDeadline implements Exception {
  const _SweepDeadline();
}
