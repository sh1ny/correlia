import 'dart:async';

import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';

class _ScheduledCall {
  _ScheduledCall(this.at, this.callback);

  final Duration at;
  final void Function() callback;
  bool cancelled = false;
}

class _Clock {
  Duration time = Duration.zero;
  final calls = <_ScheduledCall>[];

  void Function() schedule(Duration delay, void Function() callback) {
    final call = _ScheduledCall(time + delay, callback);
    calls.add(call);
    return () => call.cancelled = true;
  }

  void advance(Duration value, {bool runTimers = true}) {
    time = value;
    if (!runTimers) return;
    for (final call in List<_ScheduledCall>.of(calls)) {
      if (!call.cancelled && call.at <= time) {
        call.cancelled = true;
        call.callback();
      }
    }
  }
}

void main() {
  withServerpod(
    'stream lease fencing and deadlines',
    (builder, _) {
      late Session session;
      late pg.Connection firstConnection;
      late pg.Connection secondConnection;
      late StreamLeaseStore first;
      late StreamLeaseStore second;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute('''
          TRUNCATE icinga2_stream_lease;
          CREATE TABLE IF NOT EXISTS lease_test_writes (marker text NOT NULL);
          TRUNCATE lease_test_writes;
        ''');
        await publishStreamDb(session);
        firstConnection = await openStreamDatabase(session.serverpod);
        addTearDown(() async {
          if (firstConnection.isOpen) await firstConnection.close();
        });
        secondConnection = await openStreamDatabase(session.serverpod);
        addTearDown(() async {
          if (secondConnection.isOpen) await secondConnection.close();
        });
        first = StreamLeaseStore(firstConnection);
        second = StreamLeaseStore(secondConnection);
      });

      Future<void> expireLease() => session.db.unsafeSimpleExecute('''
        UPDATE icinga2_stream_lease
        SET "expiresAt" = clock_timestamp() - interval '1 second'
        WHERE "sourceId" = '$icinga2DbSourceId'
      ''');

      test('two_workers_start', () async {
        final leases = await Future.wait([
          first.acquire(icinga2DbSourceId, 'worker-a'),
          second.acquire(icinga2DbSourceId, 'worker-b'),
        ]);
        expect(leases.whereType<StreamLease>(), hasLength(1));
        final winner = leases.whereType<StreamLease>().single;
        final winningStore = winner.holder == 'worker-a' ? first : second;
        final waitingStore = winner.holder == 'worker-a' ? second : first;
        final waitingHolder = winner.holder == 'worker-a'
            ? 'worker-b'
            : 'worker-a';
        expect(
          await waitingStore.acquire(icinga2DbSourceId, waitingHolder),
          isNull,
        );
        expect(await winningStore.release(winner), isTrue);
        final successor = await waitingStore.acquire(
          icinga2DbSourceId,
          waitingHolder,
        );
        expect(successor, isNotNull);
        expect(successor!.generation, greaterThan(winner.generation));
        expect(await winningStore.release(winner), isFalse);
      });

      test('first_start_of_a_new_source', () async {
        final before = await session.db.unsafeQuery('''
          SELECT 1 FROM icinga2_stream_lease WHERE "sourceId" = '$icinga2DbSourceId'
        ''');
        expect(before, isEmpty);
        final lease = await first.acquire(icinga2DbSourceId, 'worker-a');
        expect(lease, isNotNull);
        expect(lease!.sourceId, icinga2DbSourceId);
        expect(lease.holder, 'worker-a');
        expect(lease.generation, 1);
        final row = (await session.db.unsafeQuery('''
          SELECT holder, generation, "expiresAt" > clock_timestamp()
          FROM icinga2_stream_lease WHERE "sourceId" = '$icinga2DbSourceId'
        ''')).single;
        expect(row[0], 'worker-a');
        expect(row[1], 1);
        expect(row[2], isTrue);
      });

      test('expiry_between_the_lease_check_and_the_commit', () async {
        final lease = (await first.acquire(icinga2DbSourceId, 'worker-a'))!;
        await session.db.unsafeSimpleExecute('''
          UPDATE icinga2_stream_lease SET "expiresAt" = clock_timestamp() + interval '1 second'
          WHERE "sourceId" = '$icinga2DbSourceId'
        ''');
        final entered = Completer<int>();
        final finish = Completer<void>();
        final writing = first.fenced<String>(lease, (tx) async {
          await tx.execute(
            "INSERT INTO lease_test_writes VALUES ('old-generation')",
          );
          final pid =
              (await tx.execute('SELECT pg_backend_pid()')).single[0]! as int;
          entered.complete(pid);
          await finish.future;
          return 'committed';
        });
        Future<StreamLease?>? takeover;
        StreamLease? next;
        try {
          final pid = await entered.future;
          expect(
            await session.db.unsafeQuery('SELECT 1 FROM lease_test_writes'),
            isEmpty,
          );
          final watch = Stopwatch()..start();
          while (true) {
            final expired =
                (await session.db.unsafeQuery('''
              SELECT "expiresAt" <= clock_timestamp() FROM icinga2_stream_lease
              WHERE "sourceId" = '$icinga2DbSourceId'
            ''')).single[0]
                    as bool;
            if (expired) break;
            if (watch.elapsed > const Duration(seconds: 5)) {
              fail('Database clock did not reach lease expiry');
            }
          }
          takeover = second.acquire(icinga2DbSourceId, 'worker-b');
          while (true) {
            final blocked = await session.db.unsafeQuery('''
              SELECT 1 FROM pg_stat_activity
              WHERE $pid = ANY(pg_blocking_pids(pid)) AND datname = current_database()
            ''');
            if (blocked.isNotEmpty) break;
            if (watch.elapsed > const Duration(seconds: 5)) {
              fail('Takeover did not wait for the fenced transaction');
            }
          }
          final row = (await session.db.unsafeQuery('''
            SELECT holder, generation FROM icinga2_stream_lease
            WHERE "sourceId" = '$icinga2DbSourceId'
          ''')).single;
          expect(row[0], 'worker-a');
          expect(row[1], lease.generation);
          expect(
            await session.db.unsafeQuery('SELECT 1 FROM lease_test_writes'),
            isEmpty,
          );
        } finally {
          finish.complete();
          try {
            expect(await writing, 'committed');
          } finally {
            if (takeover != null) next = await takeover;
          }
        }
        expect(next, isNotNull);
        expect(next!.generation, greaterThan(lease.generation));
        expect(
          await session.db.unsafeQuery('SELECT marker FROM lease_test_writes'),
          hasLength(1),
        );
      });

      test(
        'a_lease_expiring_while_the_lock_waits_cannot_authorize_work',
        () async {
          for (final renewal in [false, true]) {
            final lease = (await first.acquire(icinga2DbSourceId, 'worker-a'))!;
            await session.db.unsafeExecute('''
            UPDATE icinga2_stream_lease SET "expiresAt"=clock_timestamp()+interval '1 second'
            WHERE "sourceId"='$icinga2DbSourceId'
          ''');
            final locked = Completer<int>();
            final unlock = Completer<void>();
            final locker = secondConnection.runTx((tx) async {
              await tx.execute(
                'SELECT id FROM icinga2_stream_lease FOR UPDATE',
              );
              locked.complete(
                (await tx.execute('SELECT pg_backend_pid()')).single[0]! as int,
              );
              await unlock.future;
            });
            final pid = await locked.future;
            final attempt = renewal
                ? first.renew(lease)
                : first.fenced(lease, (_) async => true);
            try {
              final budget = Stopwatch()..start();
              while ((await session.db.unsafeQuery('''
              SELECT 1 FROM pg_stat_activity
              WHERE $pid=ANY(pg_blocking_pids(pid)) AND datname=current_database()
            ''')).isEmpty) {
                if (budget.elapsed > const Duration(milliseconds: 750)) {
                  fail(
                    'Lease operation did not wait on the row before expiration',
                  );
                }
              }
              while ((await session.db.unsafeQuery('''
              SELECT "expiresAt">clock_timestamp() FROM icinga2_stream_lease
            ''')).single[0] ==
                  true) {
                if (budget.elapsed > const Duration(milliseconds: 1500)) {
                  fail('Database clock did not reach lease expiry');
                }
              }
            } finally {
              unlock.complete();
              await locker;
            }
            expect(await attempt, renewal ? isFalse : isNull);
          }
        },
      );

      test('holder_renews_after_expiry', () async {
        final old = (await first.acquire(icinga2DbSourceId, 'worker-a'))!;
        await expireLease();
        expect(await first.renew(old), isFalse);
        final fresh = await first.acquire(icinga2DbSourceId, 'worker-a');
        expect(fresh, isNotNull);
        expect(fresh!.generation, greaterThan(old.generation));
        expect(await first.renew(old), isFalse);
      });

      test('holder_frozen_past_expiry', () async {
        final old = (await first.acquire(icinga2DbSourceId, 'worker-a'))!;
        final clock = _Clock();
        var closed = 0;
        final deadline = StreamLeaseDeadline(
          now: () => clock.time,
          onLost: () => closed++,
          schedule: clock.schedule,
        );
        addTearDown(deadline.close);
        expect(deadline.acknowledge(Duration.zero), isTrue);
        clock.advance(const Duration(seconds: 31), runTimers: false);
        await expireLease();
        final next = (await second.acquire(icinga2DbSourceId, 'worker-b'))!;
        expect(next.generation, greaterThan(old.generation));
        expect(deadline.isLive, isFalse);
        expect(closed, 1);
        var ran = false;
        final result = await first.fenced<int>(old, (tx) async {
          ran = true;
          await tx.execute("INSERT INTO lease_test_writes VALUES ('stale')");
          return 1;
        });
        expect(result, isNull);
        expect(ran, isFalse);
        expect(
          await session.db.unsafeQuery('SELECT 1 FROM lease_test_writes'),
          isEmpty,
        );
        clock.advance(const Duration(seconds: 32));
        expect(closed, 1);
      });

      test('database_lost_before_the_first_renewal', () async {
        final clock = _Clock();
        var closed = 0;
        final deadline = StreamLeaseDeadline(
          now: () => clock.time,
          onLost: () => closed++,
          schedule: clock.schedule,
        );
        addTearDown(deadline.close);
        expect(await first.acquire(icinga2DbSourceId, 'worker-a'), isNotNull);
        expect(deadline.acknowledge(Duration.zero), isTrue);
        await firstConnection.close();
        clock.advance(const Duration(seconds: 19));
        expect(deadline.isLive, isTrue);
        expect(closed, 0);
        clock.advance(const Duration(seconds: 20));
        expect(deadline.isLive, isFalse);
        expect(closed, 1);
      });

      test('renewal_acknowledged_after_the_deadline', () async {
        final old = (await first.acquire(icinga2DbSourceId, 'worker-a'))!;
        final clock = _Clock();
        var closed = 0;
        final deadline = StreamLeaseDeadline(
          now: () => clock.time,
          onLost: () => closed++,
          schedule: clock.schedule,
        );
        addTearDown(deadline.close);
        expect(deadline.acknowledge(Duration.zero), isTrue);
        clock.advance(const Duration(seconds: 10));
        expect(await first.renew(old), isTrue);
        clock.advance(const Duration(seconds: 20));
        expect(closed, 1);
        clock.advance(const Duration(seconds: 22));
        expect(deadline.acknowledge(const Duration(seconds: 10)), isFalse);
        expect(deadline.isLive, isFalse);
        expect(closed, 1);
        await expireLease();
        final fresh = (await first.acquire(icinga2DbSourceId, 'worker-a'))!;
        expect(fresh.generation, greaterThan(old.generation));
      });

      test('database_unreachable_for_the_holder', () async {
        final old = (await first.acquire(icinga2DbSourceId, 'worker-a'))!;
        final clock = _Clock();
        var closed = 0;
        final deadline = StreamLeaseDeadline(
          now: () => clock.time,
          onLost: () => closed++,
          schedule: clock.schedule,
        );
        addTearDown(deadline.close);
        expect(deadline.acknowledge(Duration.zero), isTrue);
        clock.advance(const Duration(seconds: 10));
        expect(await first.renew(old), isTrue);
        expect(deadline.acknowledge(const Duration(seconds: 10)), isTrue);
        await firstConnection.close();
        await expectLater(first.renew(old), throwsA(anything));
        clock.advance(const Duration(seconds: 29));
        expect(deadline.isLive, isTrue);
        clock.advance(const Duration(seconds: 30));
        expect(deadline.isLive, isFalse);
        expect(closed, 1);
        final unexpired = (await session.db.unsafeQuery('''
          SELECT "expiresAt" > clock_timestamp() FROM icinga2_stream_lease
          WHERE "sourceId" = '$icinga2DbSourceId'
        ''')).single[0];
        expect(unexpired, isTrue);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
