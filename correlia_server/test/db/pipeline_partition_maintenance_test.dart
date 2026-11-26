import 'dart:async';

import 'package:correlia_server/src/pipeline/maintenance.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/postgres_lock_witness.dart' show ContentionGate;

const _futureDay = '2030-02-01';
const _otherDay = '2030-02-02';
const _outside = '2030-02-06';

Future<int?> _reserve(Session session, String day, DateTime now) async =>
    (await session.db.unsafeQuery(
          "SELECT correlia_reserve_partition('raw_inbox',@day::date,@now)",
          parameters: QueryParameters.named({'day': day, 'now': now}),
        )).single[0]
        as int?;

Future<bool> _attach(
  Session session,
  String day,
  int attempt, {
  Transaction? tx,
}) async =>
    (await session.db.unsafeQuery(
          "SELECT correlia_attach_partition('raw_inbox',@day::date,@attempt)",
          parameters: QueryParameters.named({'day': day, 'attempt': attempt}),
          transaction: tx,
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
          final restarted = MaintenanceRepository(builder.build());
          for (var i = 0; i < 24; i++) {
            await restarted.prepareOne(
              nowForTest: now.add(const Duration(minutes: 1)),
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
        const day = '2030-03-01';
        final now = DateTime.utc(2030, 2, 27);
        final first = (await _reserve(session, day, now))!;
        await expectLater(
          session.db.transaction((tx) async {
            expect(await _attach(session, day, first, tx: tx), isTrue);
            await session.db.unsafeQuery('SELECT 1/0', transaction: tx);
          }),
          throwsA(isA<DatabaseQueryException>()),
        );
        final successor = builder.build();
        final next = (await _reserve(
          successor,
          day,
          now.add(const Duration(minutes: 10)),
        ))!;
        expect(await _attach(successor, day, next), isTrue);
        expect(await _fail(session, day, first, now), isFalse);
        expect(await _reserve(session, day, now), isNull);
        expect(await _write(session, day), 'raw_inbox_20300301');
        expect(
          (await session.db.unsafeQuery(
            "SELECT count(*) FROM pipeline_partition_retry WHERE day='$day'",
          )).single[0],
          0,
        );
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
        expect(
          (await session.db.unsafeQuery(
            "SELECT correlia_drop_old_partition('raw_inbox','2020-10-01')",
          )).single[0],
          isTrue,
        );
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
              "SELECT correlia_drop_old_partition('raw_inbox','2000-04-01 UTC')",
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
