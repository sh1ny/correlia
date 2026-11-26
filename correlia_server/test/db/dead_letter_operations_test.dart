import 'dart:async';

import 'package:correlia_server/src/generated/protocol.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;
import '../support/postgres_lock_witness.dart' show ContentionGate;
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' as fixture;
import 'output_relay_test.dart' as delivery;

final _now = DateTime.utc(2026, 11, 25);
const _other = '11111111-aaaa-4aaa-8aaa-111111111111';

Future<void> _seed(
  Session session,
  String source,
  int count, {
  String code = 'invalid_json',
}) => session.db.unsafeSimpleExecute('''
      WITH inserted AS (
        INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type,status)
        SELECT '2026-11-10 UTC',gen_random_uuid(),'$source',decode('ff','hex'),'digest','application/json','failed'
        FROM generate_series(1,$count) RETURNING observed_at,raw_id,source_id
      ) SELECT correlia_record_raw_failure(observed_at,raw_id,source_id,NULL,'$code',NULL,'2026-11-24 UTC')
        FROM inserted
    ''');

void main() {
  withServerpod(
    'dead letter selection and replay',
    (builder, _) {
      late Session session;
      late QueueOperations operations;
      QueueOperations repo(
        Session connection, {
        Future<void> Function()? beforeWorkLock,
      }) => QueueOperations(
        connection,
        secretStore: testSecretStore,
        clock: () => _now,
        beforeWorkLockForTest: beforeWorkLock,
      );
      QueueFailureFilter filter({
        String? scope = fixture.sourceId,
        String? error,
      }) => QueueFailureFilter(
        kind: QueueFailureKind.raw,
        scopeId: scope,
        errorClass: error,
      );
      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(fixture.input(1));
        operations = repo(session);
      });

      test('equal_times_and_invalid_filter_cursor', () async {
        await _seed(session, fixture.sourceId, 3);
        final first = await operations.list(filter(), limit: 2);
        final second = await operations.list(
          filter(),
          limit: 2,
          cursor: first.continuation,
        );
        final ids = [
          ...first.failures,
          ...second.failures,
        ].map((row) => row.occurrence).toList();
        expect(ids, hasLength(3));
        expect(ids.toSet(), hasLength(3));
        expect(ids, orderedEquals([...ids]..sort()));
        expect(second.continuation, isNull);
        for (final call in [
          () => operations.list(filter(scope: 'unknown')),
          () => operations.list(
            filter(scope: _other),
            cursor: first.continuation,
          ),
          () => operations.list(filter(), limit: 101),
        ]) {
          await expectLater(call(), throwsA(isA<QueueOperatorException>()));
        }
      });

      test(
        'continuation_keeps_its_bound_after_database_clock_rewinds',
        () async {
          await _seed(session, fixture.sourceId, 3);
          await session.db.unsafeExecute('''
          UPDATE pipeline_dead_letter SET failed_at='2026-11-25 06:00 UTC'
          WHERE occurrence_id=(SELECT max(occurrence_id) FROM pipeline_dead_letter)
        ''');
          var now = _now;
          final listing = QueueOperations(session, clock: () => now);
          final range = QueueFailureFilter(
            kind: QueueFailureKind.raw,
            scopeId: fixture.sourceId,
            through: _now.add(const Duration(days: 1)),
          );
          final first = await listing.list(range, limit: 1);
          expect(first.failures, hasLength(1));
          expect(first.continuation, isNotNull);
          now = _now.subtract(const Duration(days: 2));
          final second = await listing.list(
            range,
            limit: 1,
            cursor: first.continuation,
          );
          expect(
            second.failures.single.occurrence,
            greaterThan(first.failures.single.occurrence),
          );
          expect(second.failures.single.failedAt, DateTime.utc(2026, 11, 24));
          expect(second.continuation, isNull);
        },
      );

      test('sparse_filter_pages_use_matching_index', () async {
        await _seed(session, _other, 500);
        await _seed(session, fixture.sourceId, 500, code: 'body_bound');
        await _seed(session, fixture.sourceId, 3);
        await session.db.unsafeExecute('ANALYZE pipeline_dead_letter');
        final plans = <String>[];
        final listing = QueueOperations(
          session,
          clock: () => _now,
          observePageQueryForTest: (tx, sql, parameters) async {
            final rows = await session.db.unsafeQuery(
              'EXPLAIN (COSTS OFF) $sql',
              transaction: tx,
              parameters: parameters,
            );
            plans.add(rows.map((row) => row[0]).join('\n'));
          },
        );
        final page = await listing.list(
          filter(error: 'invalid_json'),
          limit: 2,
        );
        final last = await listing.list(
          filter(error: 'invalid_json'),
          limit: 2,
          cursor: page.continuation,
        );
        expect(page.failures, hasLength(2));
        expect(last.failures, hasLength(1));
        expect(last.continuation, isNull);
        expect(plans, hasLength(2));
        for (final plan in plans) {
          expect(plan, contains('pipeline_dead_letter_scope_class_idx'));
          expect(plan, contains('Index Cond:'));
          expect(plan, isNot(contains('Filter:')));
        }
        expect(plans.last, contains('ROW(failed_at, occurrence_id) >'));
      });

      test('filtered_replay_batches_report_and_audit', () async {
        await _seed(session, fixture.sourceId, 3);
        await _seed(session, _other, 4);
        final page = await operations.replayBatch(filter(), 'demo', limit: 2);
        expect((page.queued, page.refused), (2, 0));
        final remaining = await operations.replayBatch(
          filter(),
          'demo',
          limit: 2,
          cursor: page.continuation,
        );
        expect(
          (remaining.queued, remaining.refused, remaining.continuation),
          (1, 0, null),
        );
        expect(
          page.items.map((i) => i.occurrence),
          isNot(contains(remaining.items.single.occurrence)),
        );
        final state = await session.db.unsafeQuery(
          'SELECT status,count(*) FROM raw_inbox GROUP BY status',
        );
        expect(
          {for (final row in state) row[0]: row[1]},
          {'pending': 3, 'failed': 4},
        );
        final audit = await session.db.unsafeQuery(
          "SELECT actor_ref,entity_version FROM activity WHERE change_kind='dead_letter_replayed' ORDER BY id",
        );
        expect(audit.map((r) => r.toList()), [
          ['demo', 2],
          ['demo', 1],
        ]);
      });

      test('replay_rolls_back_when_its_transaction_budget_is_spent', () async {
        await _seed(session, fixture.sourceId, 2);
        final before = (await operations.list(
          filter(),
        )).failures.map((f) => f.occurrence).toList();
        var elapsed = Duration.zero;
        final replay = QueueOperations(
          session,
          clock: () => _now,
          elapsedForTest: () => elapsed,
          beforeWorkLockForTest: () async {
            elapsed = const Duration(seconds: 4);
          },
          beforeCommitForTest: (tx) async {
            final staged = (await session.db.unsafeQuery('''
              SELECT pending_rows,(SELECT count(*) FROM activity WHERE change_kind='dead_letter_replayed')
              FROM pipeline_pending
            ''', transaction: tx)).single;
            expect(staged.toList(), [2, 1]);
            elapsed += const Duration(seconds: 1);
          },
        );
        await expectLater(
          replay.replayBatch(filter(), 'operator'),
          throwsA(isA<TimeoutException>()),
        );
        expect(
          (await operations.list(filter())).failures.map((f) => f.occurrence),
          before,
        );
        expect((await operations.status()).pendingRows, 0);
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM activity',
          )).single[0],
          0,
        );
        expect((await operations.replayBatch(filter(), 'operator')).queued, 2);
      });

      test('publication_shortens_retention_before_replay_locks_policy', () async {
        await _seed(session, fixture.sourceId, 1);
        final before = (await operations.list(filter())).failures.single;
        final replay = QueueOperations(
          session,
          clock: () => _now,
          beforeConfigLockForTest: () async {
            await IngestConfigRepository(
              builder.build(),
              secretStore: testSecretStore,
            ).publishConfig(
              fixture.cutoverV2(2)
                ..['pipeline_operations'] = {'dead_letter_retention_days': 1},
              const <String, Object?>{},
              runMode: 'test',
            );
          },
        );
        final result = await replay.replayOne(
          QueueFailureKind.raw,
          before.occurrence,
          'demo',
        );
        expect(result.items.single.outcome, 'expired');
        expect(
          (await operations.list(filter())).failures.single.occurrence,
          before.occurrence,
        );
        expect(
          (await session.db.unsafeQuery(
            "SELECT count(*) FROM activity WHERE change_kind='dead_letter_replayed'",
          )).single[0],
          0,
        );
      });

      test('replay_and_expiry_use_utc_days_in_non_utc_sessions', () async {
        await _seed(session, fixture.sourceId, 1);
        await delivery.seed(session);
        await session.db.unsafeSimpleExecute('''
          UPDATE outbox SET status='dead',dead_reason='network';
          UPDATE pipeline_dead_letter SET failed_at='2026-03-02 12:30 UTC'
        ''');
        final before = DateTime.utc(2026, 3, 16, 12);
        const timezone = "SET LOCAL TIME ZONE 'America/New_York'";
        final eligible = QueueOperations(
          session,
          clock: () => before,
          secretStore: testSecretStore,
          observePageQueryForTest: (tx, _, _) =>
              session.db.unsafeSimpleExecute(timezone, transaction: tx),
        );
        Future<int> expire(DateTime now) => session.db.transaction((tx) async {
          await session.db.unsafeSimpleExecute(timezone, transaction: tx);
          return (await session.db.unsafeQuery(
                "SELECT correlia_maintain('expiry',@now,10)",
                parameters: QueryParameters.named({'now': now}),
                transaction: tx,
              )).single[0]!
              as int;
        });
        final deliveries = QueueFailureFilter(kind: QueueFailureKind.delivery);
        expect(await expire(before), 0);
        expect((await eligible.replayBatch(filter(), 'demo')).queued, 1);
        expect((await eligible.replayBatch(deliveries, 'demo')).queued, 1);
        await _seed(session, fixture.sourceId, 1);
        await session.db.unsafeExecute(
          "UPDATE pipeline_dead_letter SET failed_at='2026-03-02 12:30 UTC'",
        );
        expect(await expire(DateTime.utc(2026, 3, 16, 12, 30)), 1);
      });

      test('concurrent_replays_and_late_replay_cannot_requeue_twice', () async {
        await _seed(session, fixture.sourceId, 1);
        final occurrence = (await operations.list(
          filter(),
        )).failures.single.occurrence;
        final selected = Completer<void>();
        final gate = ContentionGate();
        final stale = gate.run(
          () => repo(
            builder.build(),
            beforeWorkLock: () async {
              selected.complete();
              await gate.future;
            },
          ).replayOne(QueueFailureKind.raw, occurrence, 'stale'),
        );
        await selected.future;
        expect(
          (await operations.replayOne(
            QueueFailureKind.raw,
            occurrence,
            'winner',
          )).queued,
          1,
        );
        await gate.join();
        expect((await stale).items.single.outcome, 'not_active');
        await _seed(session, fixture.sourceId, 1);
        final expiring = (await operations.list(
          filter(),
        )).failures.single.occurrence;
        var checkAt = _now;
        final atBoundary = QueueOperations(
          session,
          clock: () => checkAt,
          beforeWorkLockForTest: () async {
            checkAt = DateTime.utc(2026, 12, 8);
          },
        );
        expect(
          (await atBoundary.replayOne(
            QueueFailureKind.raw,
            expiring,
            'past-boundary',
          )).items.single.outcome,
          'expired',
        );
        await session.db.unsafeQuery(
          "SELECT correlia_maintain('expiry','2027-01-01 UTC',5)",
        );
        expect(
          (await operations.replayOne(
            QueueFailureKind.raw,
            expiring,
            'after-expiry',
          )).queued,
          0,
        );
        final actor = await session.db.unsafeQuery(
          "SELECT actor_ref FROM activity WHERE change_kind='dead_letter_replayed'",
        );
        expect(actor.single[0], 'winner');
      });

      for (final replayFirst in [true, false]) {
        test(
          'delivery_replay_and_expiry ${replayFirst ? 'replay wins' : 'expiry wins'}',
          () async {
            await delivery.seed(session);
            await session.db.unsafeExecute("""
            UPDATE outbox SET status='dead',dead_reason='network',terminal_at='2026-11-24 UTC'
          """);
            final filter = QueueFailureFilter(kind: QueueFailureKind.delivery);
            final occurrence = (await operations.list(
              filter,
            )).failures.single.occurrence;
            final held = Completer<void>();
            final gate = ContentionGate();
            Future<void> hold() async {
              held.complete();
              await gate.future;
            }

            final replay = gate.run(
              () => QueueOperations(
                builder.build(),
                secretStore: testSecretStore,
                clock: () => _now,
                beforeWorkLockForTest: replayFirst ? null : hold,
                beforeConfigLockForTest: replayFirst ? hold : null,
              ).replayOne(QueueFailureKind.delivery, occurrence, 'operator'),
            );
            const sweep =
                "SELECT correlia_maintain('expiry','2027-01-01 UTC',5)";
            try {
              await Future.any([
                held.future,
                replay.then<void>((_) => fail('Replay did not reach its gate')),
              ]);
              expect(
                (await session.db.unsafeQuery(sweep)).single[0],
                replayFirst ? 0 : 1,
              );
            } finally {
              await gate.join();
            }
            expect(
              (await replay).items.single.outcome,
              replayFirst ? 'queued' : 'not_active',
            );
            expect((await session.db.unsafeQuery(sweep)).single[0], 0);
            expect((await operations.list(filter)).failures, isEmpty);
            final result = (await session.db.unsafeQuery('''
            SELECT o.status,c.used_rows,c.used_bytes,c.live_rows
            FROM outbox o JOIN pipeline_output_capacity c USING(output_id)
          ''')).single.toList();
            expect(
              result,
              replayFirst ? ['queued', 1, 2, 1] : ['discarded', 0, 0, 0],
            );
            final ledger = (await session.db.unsafeQuery('''
            SELECT change_kind,actor_ref,entity_version FROM activity
            WHERE change_kind IN ('dead_letter_replayed','dead_letter_expired')
          ''')).single.toList();
            expect(
              ledger,
              replayFirst
                  ? ['dead_letter_replayed', 'operator', 1]
                  : ['dead_letter_expired', null, 1],
            );
          },
        );
      }

      for (final replayFirst in [true, false]) {
        test(
          'replay_and_expiry_lock_one_occurrence ${replayFirst ? 'replay wins' : 'expiry wins'}',
          () async {
            await _seed(session, fixture.sourceId, 1);
            final occurrence = (await operations.list(
              filter(),
            )).failures.single.occurrence;
            final held = Completer<void>();
            final gate = ContentionGate();
            Future<void> hold() async {
              held.complete();
              await gate.future;
            }

            final replay = gate.run(
              () => QueueOperations(
                builder.build(),
                clock: () => _now,
                beforeWorkLockForTest: replayFirst ? null : hold,
                beforeConfigLockForTest: replayFirst ? hold : null,
              ).replayOne(QueueFailureKind.raw, occurrence, 'operator'),
            );
            const sweep =
                "SELECT correlia_maintain('expiry','2027-01-01 UTC',5)";
            await held.future;
            expect(
              (await session.db.unsafeQuery(sweep)).single[0],
              replayFirst ? 0 : 1,
            );
            await gate.join();
            final result = await replay;
            expect(
              result.items.single.outcome,
              replayFirst ? 'queued' : 'not_active',
            );
            expect((await session.db.unsafeQuery(sweep)).single[0], 0);
            expect(
              (await session.db.unsafeQuery(
                'SELECT status FROM raw_inbox',
              )).single[0],
              replayFirst ? 'pending' : 'discarded',
            );
            expect((await operations.list(filter())).failures, isEmpty);
            final ledger = await session.db.unsafeQuery('''
            SELECT change_kind,actor_ref,entity_version FROM activity
            WHERE change_kind IN ('dead_letter_replayed','dead_letter_expired')
          ''');
            expect(
              ledger.single.toList(),
              replayFirst
                  ? ['dead_letter_replayed', 'operator', 1]
                  : ['dead_letter_expired', null, 1],
            );
          },
        );
      }
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
