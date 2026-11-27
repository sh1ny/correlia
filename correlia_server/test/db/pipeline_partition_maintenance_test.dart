import 'dart:async';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/maintenance.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/postgres_lock_witness.dart' show ContentionGate;
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' as config;

const _futureDay = '2030-02-01';
const _otherDay = '2030-02-02';
const _outside = '2030-02-06';

Future<int?> _reserve(Session session, String day, DateTime now) async =>
    (await session.db.unsafeQuery(
          "SELECT correlia_reserve_partition('raw_inbox',@day::date,@now)",
          parameters: QueryParameters.named({'day': day, 'now': now}),
        )).single[0]
        as int?;

Future<bool> _attach(Session session, String day, int attempt) async =>
    (await session.db.unsafeQuery(
          "SELECT correlia_attach_partition('raw_inbox',@day::date,@attempt)",
          parameters: QueryParameters.named({'day': day, 'attempt': attempt}),
        )).single[0]!
        as bool;

Future<bool> _fail(
  Session session,
  String day,
  int attempt,
  DateTime now,
) async =>
    (await session.db.unsafeQuery(
          "SELECT correlia_partition_failed('raw_inbox',@day::date,@attempt,'lock_timeout',@now)",
          parameters: QueryParameters.named({
            'day': day,
            'attempt': attempt,
            'now': now,
          }),
        )).single[0]!
        as bool;

Future<String> _write(Session session, String when) async =>
    (await session.db.unsafeQuery('''
      INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type,status)
      VALUES (@when::timestamptz,gen_random_uuid(),gen_random_uuid(),decode('01','hex'),
        'digest','application/json','done') RETURNING tableoid::regclass::text
    ''', parameters: QueryParameters.named({'when': '$when UTC'}))).single[0]!
        as String;

Future<String> _writeEvent(Session session, String day) async =>
    (await session.db.unsafeQuery('''
      INSERT INTO events(observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,
        config_snapshot_id,source_time,payload)
      VALUES (@at,gen_random_uuid(),'ready',@at,gen_random_uuid(),gen_random_uuid(),'fixture',@at,
        convert_to('{"subject":"fixture"}','UTF8'))
      RETURNING tableoid::regclass::text
    ''', parameters: QueryParameters.named({'at': '$day UTC'}))).single[0]!
        as String;

void main() {
  withServerpod(
    'daily partition preparation',
    (builder, _) {
      test('failed_partition_reservations_replace_stale_status', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final now = DateTime.utc(2026, 2, 1);
        const day = '2025-09-01';
        expect(
          await _attach(session, day, (await _reserve(session, day, now))!),
          isTrue,
        );
        final maintenance = MaintenanceRepository(session);
        final blocker = builder.build();
        for (final (lane, table, run) in [
          (
            'prepare_partition',
            'pipeline_partition_retry',
            () => maintenance.prepareOne(nowForTest: now),
          ),
          (
            'drop_partition:raw_inbox',
            'pipeline_partition_range',
            () => maintenance.dropOld('raw_inbox', nowForTest: now),
          ),
        ]) {
          await maintenance.sweep('events');
          final hold = ContentionGate();
          final held = Completer<void>();
          final locked = hold.run(
            () => blocker.db.transaction((tx) async {
              await blocker.db.unsafeExecute(
                'LOCK TABLE ONLY "$table" IN SHARE MODE',
                transaction: tx,
              );
              held.complete();
              await hold.future;
            }),
          );
          try {
            await Future.any([
              held.future,
              locked.then<void>((_) => fail('Reservation lock not acquired')),
            ]);
            await run();
            final status = (await QueueOperations(
              session,
            ).status()).maintenance!;
            expect(
              (status.lane, status.outcome, status.affected),
              (lane, 'lock_timeout', 0),
            );
          } finally {
            await hold.join();
          }
        }
        expect(
          (await session.db.unsafeQuery(
            "SELECT to_regclass('raw_inbox_20250901')::text",
          )).single[0],
          'raw_inbox_20250901',
        );
      });

      test(
        'default_validation_timeout_records_retry_without_blocking_writes',
        () async {
          final session = builder.build();
          await initializeIngestSchema(session);
          final now = DateTime.utc(2030, 2, 1);
          expect(await _writeEvent(session, _otherDay), 'events_default');
          final maintenance = MaintenanceRepository(session);
          await maintenance.sweep('events');
          final status = QueueOperations(session);
          final previous = (await status.status()).maintenance!;
          expect((previous.lane, previous.outcome), ('events', 'ok'));
          final gate = ContentionGate();
          final entered = Completer<void>();
          final blocker = builder.build();
          final holding = gate.run(
            () => blocker.db.transaction((tx) async {
              // The default occupancy read still runs. The attach needs a
              // stronger child lock and fails while this lock is held.
              await blocker.db.unsafeExecute(
                'LOCK TABLE ONLY events_default IN SHARE MODE',
                transaction: tx,
              );
              entered.complete();
              await gate.future;
            }),
          );
          await entered.future;
          await maintenance.prepareOne(nowForTest: now);
          final failure = (await session.db.unsafeQuery('''
            SELECT parent_name, day::text, problem, retry_at FROM pipeline_partition_retry
            WHERE parent_name='events' AND day='$_futureDay'
          ''')).single;
          expect(failure.take(3), ['events', _futureDay, 'lock_timeout']);
          expect((failure[3]! as DateTime).isAfter(now), isTrue);
          final failed = await status.status();
          expect(failed.partitionDegraded, isTrue);
          expect(
            (
              failed.maintenance!.lane,
              failed.maintenance!.outcome,
              failed.maintenance!.affected,
            ),
            ('prepare_partition', 'lock_timeout', 0),
          );
          await gate.join();
          await holding;
          expect(await _writeEvent(session, _outside), 'events_default');
          expect(await _writeEvent(session, _futureDay), 'events_default');
          final next =
              (await session.db.unsafeQuery('''
            SELECT correlia_reserve_partition('events','$_futureDay','2030-02-01 00:01 UTC')
          ''')).single[0]!
                  as int;
          expect(
            (await session.db.unsafeQuery(
              '''
              SELECT correlia_attach_partition('events','$_futureDay',@attempt)
            ''',
              parameters: QueryParameters.named({'attempt': next}),
            )).single[0],
            isFalse,
          );
          expect((await status.status()).partitionDegraded, isTrue);
          expect(
            (await session.db.unsafeQuery('''
              SELECT problem FROM pipeline_partition_retry
              WHERE parent_name='events' AND day='$_futureDay'
            ''')).single[0],
            'lock_timeout',
          );
          await session.db.unsafeExecute(
            "DELETE FROM events WHERE observed_at='$_futureDay UTC'",
          );
          final restarted = MaintenanceRepository(builder.build());
          for (var i = 0; i < 24; i++) {
            await restarted.prepareOne(
              nowForTest: now.add(const Duration(minutes: 2)),
            );
          }
          expect(await _writeEvent(session, _futureDay), 'events_20300201');
          expect(await _writeEvent(session, _otherDay), 'events_default');
          final recovered = await status.status();
          expect(recovered.partitionDegraded, isFalse);
          expect(
            (
              recovered.maintenance!.lane,
              recovered.maintenance!.outcome,
              recovered.maintenance!.affected,
            ),
            ('prepare_partition', 'ok', 1),
          );
          expect(
            (await session.db.unsafeQuery(
              "SELECT count(*) FROM pipeline_partition_retry WHERE day='$_futureDay' AND parent_name='events'",
            )).single[0],
            0,
          );
        },
      );

      test('failed_partition_attempt_retries_after_its_day_begins', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        const day = '2030-04-05';
        final now = DateTime.utc(2030, 4, 5);
        final beforeMidnight = now.subtract(const Duration(minutes: 1));
        final attempt = (await _reserve(session, day, beforeMidnight))!;
        expect(await _fail(session, day, attempt, beforeMidnight), isTrue);
        final repo = MaintenanceRepository(session);
        for (var i = 0; i < 24; i++) {
          await repo.prepareOne(nowForTest: now);
        }
        expect(await _write(session, day), 'raw_inbox_20300405');
      });

      test('untried_ranges_precede_persistently_eligible_retries', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final now = DateTime.utc(2030, 3, 15);
        await session.db.unsafeExecute('''
          INSERT INTO pipeline_partition_retry (parent_name,day,attempt_id,retry_at,problem)
          SELECT parent,'2030-03-15',nextval('pipeline_partition_attempt_id'),'-infinity','lock_timeout'
          FROM unnest(ARRAY['events','outbox']) parent
        ''');
        await MaintenanceRepository(session).prepareOne(nowForTest: now);
        expect(await _write(session, '2030-03-15'), 'raw_inbox_20300315');
      });

      test('late_attach_failure_cannot_replace_success', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        const day = '2030-05-01';
        final now = DateTime.utc(2030, 5, 1);
        final lock = ContentionGate();
        final held = Completer<void>();
        final blocker = builder.build();
        final blocking = lock.run(
          () => blocker.db.transaction((tx) async {
            await blocker.db.unsafeExecute(
              'LOCK TABLE ONLY events_default IN SHARE MODE',
              transaction: tx,
            );
            held.complete();
            await lock.future;
          }),
        );
        final afterRollback = ContentionGate();
        final rolledBack = Completer<void>();
        await held.future;
        final first = afterRollback.run(
          () => MaintenanceRepository(
            session,
            beforePartitionFailureForTest: () async {
              rolledBack.complete();
              await afterRollback.future;
            },
          ).prepareOne(nowForTest: now),
        );
        await Future.any([
          rolledBack.future,
          first.then((_) => fail('The first attempt did not roll back')),
        ]);
        await lock.join();
        await blocking;
        final successor = MaintenanceRepository(builder.build());
        for (var i = 0; i < 24; i++) {
          await successor.prepareOne(
            nowForTest: now.add(const Duration(minutes: 1)),
          );
        }
        expect(await _writeEvent(session, day), 'events_20300501');
        final committed = (await QueueOperations(
          session,
        ).status()).maintenance!;
        expect(
          (committed.lane, committed.outcome, committed.affected),
          ('prepare_partition', 'ok', 1),
        );
        await afterRollback.join();
        await first;
        final status = await QueueOperations(session).status();
        expect(status.partitionDegraded, isFalse);
        expect(
          (
            status.maintenance!.lane,
            status.maintenance!.outcome,
            status.maintenance!.affected,
            status.maintenance!.finishedAt,
          ),
          (
            committed.lane,
            committed.outcome,
            committed.affected,
            committed.finishedAt,
          ),
        );
        expect(
          (await session.db.unsafeQuery(
            "SELECT count(*) FROM pipeline_partition_retry WHERE parent_name='events' AND day='$day'",
          )).single[0],
          0,
        );
      });

      for (final newerFails in [false, true]) {
        final outcome = newerFails ? 'failure' : 'success';
        test('older_partition_success_after_newer_$outcome', () async {
          final session = builder.build();
          await initializeIngestSchema(session);
          final year = newerFails ? 2031 : 2030;
          final gate = ContentionGate();
          final reserved = Completer<void>();
          final first = gate.run(
            () => MaintenanceRepository(
              builder.build(),
              beforePartitionAttachForTest: () async {
                reserved.complete();
                await gate.future;
              },
            ).prepareOne(nowForTest: DateTime.utc(year, 9, 1)),
          );
          try {
            await Future.any([
              reserved.future,
              first.then((_) => fail('The first reservation was not parked')),
            ]);
            final newer = MaintenanceRepository(
              session,
              beforePartitionAttachForTest: newerFails
                  ? () async => throw StateError('test attach failure')
                  : null,
            );
            await newer.prepareOne(nowForTest: DateTime.utc(year, 8, 1));
            final ops = QueueOperations(session);
            final second = await ops.status();
            final batch = second.maintenance!;
            expect(
              (batch.lane, batch.outcome),
              ('prepare_partition', newerFails ? 'failed' : 'ok'),
            );
            expect(
              second.maintenanceFailures.any(
                (r) => r.lane == 'prepare_partition',
              ),
              newerFails,
            );
            await newer.sweep('transport');
            expect((await ops.status()).maintenance!.lane, 'transport');

            await gate.join();
            await first;
            expect(
              await _writeEvent(session, '$year-09-01'),
              'events_${year}0901',
            );
            final report = await ops.status();
            expect(
              (report.maintenance!.lane, report.maintenance!.outcome),
              ('prepare_partition', 'ok'),
            );
            expect(
              report.maintenanceFailures.map((r) => r.lane),
              isNot(contains('prepare_partition')),
            );
            expect(report.partitionDegraded, newerFails);
          } finally {
            await gate.join();
          }
        });
      }

      test('attach_failure_reports_without_the_ddl_lock', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final child = ContentionGate();
        final childLocked = Completer<void>();
        final blocker = builder.build();
        final childLock = child.run(
          () => blocker.db.transaction((tx) async {
            await blocker.db.unsafeExecute(
              'LOCK TABLE ONLY events_default IN SHARE MODE',
              transaction: tx,
            );
            childLocked.complete();
            await child.future;
          }),
        );
        final afterRollback = ContentionGate();
        final rolledBack = Completer<void>();
        final ddl = ContentionGate();
        try {
          await Future.any([
            childLocked.future,
            childLock.then((_) => fail('The default child was not locked')),
          ]);
          final preparation = afterRollback.run(
            () => MaintenanceRepository(
              session,
              beforePartitionFailureForTest: () async {
                rolledBack.complete();
                await afterRollback.future;
              },
            ).prepareOne(nowForTest: DateTime.utc(2030, 10, 1)),
          );
          await Future.any([
            rolledBack.future,
            preparation.then((_) => fail('The attachment did not roll back')),
          ]);
          await child.join();
          expect(await _writeEvent(session, '2030-10-01'), 'events_default');

          final ddlSession = builder.build();
          final ddlLocked = Completer<void>();
          final ddlLock = ddl.run(
            () => ddlSession.db.transaction((tx) async {
              await ddlSession.db.unsafeQuery(
                'SELECT pg_advisory_xact_lock(1129271900)',
                transaction: tx,
              );
              ddlLocked.complete();
              await ddl.future;
            }),
          );
          await Future.any([
            ddlLocked.future,
            ddlLock.then((_) => fail('The DDL gate was not acquired')),
          ]);
          await afterRollback.join();
          await preparation;
          final report = await QueueOperations(session).status();
          expect(report.partitionDegraded, isTrue);
          expect(
            report.maintenanceFailures.map((row) => (row.lane, row.outcome)),
            contains(('prepare_partition', 'lock_timeout')),
          );
        } finally {
          await ddl.join();
          await child.join();
          await afterRollback.join();
        }
      });

      test('eligible_closed_partition_drops', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        const day = '2020-04-01';
        final now = DateTime.utc(2020, 3, 31);
        expect(
          await _attach(session, day, (await _reserve(session, day, now))!),
          isTrue,
        );
        expect(await _write(session, day), 'raw_inbox_20200401');
        final snapshot = config.input(1);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(snapshot);
        expect(await _write(session, '2020-09-30'), 'raw_inbox_default');
        await session.db.unsafeExecute('''
          INSERT INTO icinga2_raw_origin(raw_observed_at,raw_id,origin,admission_snapshot_id)
          SELECT observed_at,raw_id,'stream',@pin FROM raw_inbox
          WHERE observed_at IN ('2020-04-01 UTC','2020-09-30 UTC')
        ''', parameters: QueryParameters.named({'pin': snapshot.snapshotId}));
        await MaintenanceRepository(
          session,
        ).dropOld('raw_inbox', nowForTest: DateTime.utc(2020, 10, 1));
        expect(
          (await session.db.unsafeQuery(
            "SELECT to_regclass('raw_inbox_20200401')::text",
          )).single[0],
          'raw_inbox_20200401',
        );
        expect(
          (await session.db.unsafeQuery(
            "SELECT correlia_maintain('raw','2020-10-01 UTC',5)",
          )).single[0],
          1,
        );
        expect(await _write(session, day), 'raw_inbox_20200401');
        await MaintenanceRepository(
          session,
        ).dropOld('raw_inbox', nowForTest: DateTime.utc(2020, 10, 1, 0, 1));
        expect(
          (await session.db.unsafeQuery(
            "SELECT to_regclass('raw_inbox_20200401')::text",
          )).single[0],
          isNull,
        );
        expect(
          (await session.db.unsafeQuery(
            "SELECT to_regclass('raw_inbox_default')::text",
          )).single[0],
          'raw_inbox_default',
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM icinga2_raw_origin',
          )).single[0],
          1,
        );
      });

      test('locked_oldest_child_does_not_starve_later_drops', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        for (final day in ['1999-01-01', '1999-01-02']) {
          expect(
            await _attach(
              session,
              day,
              (await _reserve(session, day, DateTime.utc(1999)))!,
            ),
            isTrue,
          );
        }
        final gate = ContentionGate();
        final held = Completer<void>();
        final blocker = builder.build();
        final locked = gate.run(
          () => blocker.db.transaction((tx) async {
            await blocker.db.unsafeExecute(
              'LOCK TABLE ONLY raw_inbox_19990101 IN ACCESS SHARE MODE',
              transaction: tx,
            );
            held.complete();
            await gate.future;
          }),
        );
        await Future.any([
          held.future,
          locked.then<void>((_) => fail('Child lock not acquired')),
        ]);
        final first = MaintenanceRepository(session);
        final now = DateTime.utc(1999, 10, 1);
        Future<List<Object?>> children() async => [
          for (final row in await session.db.unsafeQuery('''
            SELECT child_name FROM pipeline_partition_range WHERE parent_name='raw_inbox'
              AND first_day IN ('1999-01-01','1999-01-02') ORDER BY first_day
          '''))
            row[0],
        ];
        try {
          await first.dropOld('raw_inbox', nowForTest: now);
          final status = (await QueueOperations(session).status()).maintenance!;
          expect(
            (status.lane, status.outcome, status.affected),
            ('drop_partition:raw_inbox', 'lock_timeout', 0),
          );
          final restarted = MaintenanceRepository(builder.build());
          await restarted.dropOld('raw_inbox', nowForTest: now);
          expect(await children(), ['raw_inbox_19990101']);
        } finally {
          await gate.join();
        }
        await MaintenanceRepository(session).dropOld(
          'raw_inbox',
          nowForTest: now.add(const Duration(seconds: 30)),
        );
        expect(await children(), isEmpty);
      });

      test('partition_drop_rechecks_policy_after_ddl_lock', () async {
        final session = builder.build();
        final blocker = builder.build();
        final worker = builder.build();
        await initializeIngestSchema(session);
        const day = '2000-01-01';
        final initial = (await _reserve(session, day, DateTime.utc(2000)))!;
        expect(await _attach(session, day, initial), isTrue);
        expect(await _write(session, day), 'raw_inbox_20000101');
        await session.db.unsafeExecute(
          "UPDATE raw_inbox SET status='done' WHERE observed_at='2000-01-01 UTC'",
        );
        final gate = ContentionGate();
        final held = Completer<void>();
        final heldLock = gate.run(
          () => blocker.db.transaction((tx) async {
            await blocker.db.unsafeExecute(
              'LOCK TABLE ONLY raw_inbox IN ACCESS SHARE MODE',
              transaction: tx,
            );
            held.complete();
            await gate.future;
            await blocker.db.unsafeExecute(
              'UPDATE pipeline_queue_policy SET raw_retention_days=365 WHERE singleton=1',
              transaction: tx,
            );
          }),
        );
        await held.future;
        final reservation = (await session.db.unsafeQuery(
          "SELECT attempt_id FROM correlia_reserve_drop('raw_inbox','2000-04-01 UTC')",
        )).single[0];
        final waiter = Completer<int>();
        final drop = gate.run(
          () => worker.db.transaction((tx) async {
            waiter.complete(
              (await worker.db.unsafeQuery(
                    'SELECT pg_backend_pid()',
                    transaction: tx,
                  )).single[0]!
                  as int,
            );
            return (await worker.db.unsafeQuery(
              "SELECT correlia_drop_old_partition('raw_inbox','raw_inbox_20000101',@attempt,'2000-04-01 UTC')",
              parameters: QueryParameters.named({'attempt': reservation}),
              transaction: tx,
              timeoutInSeconds: 60,
            )).single[0];
          }),
        );
        final pid = await waiter.future;
        Future<void> waitForDdl() async {
          final watch = Stopwatch()..start();
          while (watch.elapsed < const Duration(seconds: 30)) {
            final rows = await session.db.unsafeQuery('''
              SELECT 1 FROM pg_locks WHERE pid=@pid AND relation='raw_inbox'::regclass
                AND NOT granted AND mode='AccessExclusiveLock'
            ''', parameters: QueryParameters.named({'pid': pid}));
            if (rows.isNotEmpty) return;
          }
          fail('Partition worker did not reach the parent DDL lock');
        }

        await waitForDdl();
        await gate.join();
        await heldLock;
        expect(await drop, isFalse);
        expect(
          (await session.db.unsafeQuery(
            "SELECT status FROM raw_inbox WHERE observed_at='2000-01-01 UTC'",
          )).single[0],
          'done',
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
