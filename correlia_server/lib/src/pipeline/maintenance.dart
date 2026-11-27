import 'dart:async';

import 'package:serverpod/serverpod.dart';

import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';

const _lanes = [
  'expiry',
  'raw',
  'events',
  'outbox',
  'attempts',
  'cutoff',
  'transport',
  'observation',
];
const _parents = ['raw_inbox', 'events', 'outbox'];
const _candidateCap = 500;

/// Bounded retention and partition preparation, owned by worker roles.
final class PipelineMaintenance extends Subsystem {
  PipelineMaintenance({
    required this.openSession,
    required this.log,
    this.interval = const Duration(seconds: 2),
    this.beforeCommitForTest,
  });

  final Future<Session> Function() openSession;
  final void Function(String) log;
  final Duration interval;

  /// Lets a fixture hold or fail a real batch before it commits.
  final Future<void> Function(String lane)? beforeCommitForTest;
  final _stopping = Completer<void>();
  Future<void>? _loop;
  Timer? _timer;
  Completer<void>? _wake;

  @override
  Set<ProcessRole> get roles => const {ProcessRole.worker, ProcessRole.all};

  @override
  String get name => 'pipeline-maintenance';

  @override
  Future<void> start() async {
    final session = await openSession();
    _loop = _run(session);
  }

  Future<void> _run(Session session) async {
    final maintenance = MaintenanceRepository(
      session,
      beforeCommitForTest: beforeCommitForTest,
    );
    final turnCount = _lanes.length + _parents.length + 1;
    var step = 0;
    var filledPage = false;
    try {
      while (!_stopping.isCompleted) {
        try {
          if (step < _lanes.length) {
            filledPage = await maintenance.sweep(_lanes[step]) || filledPage;
          } else if (step < _lanes.length + _parents.length) {
            await maintenance.dropOld(_parents[step - _lanes.length]);
          } else {
            await maintenance.prepareOne();
          }
        } catch (_) {
          log('pipeline-maintenance: outcome unavailable');
        }
        step = (step + 1) % turnCount;
        if (_stopping.isCompleted) break;
        // Give every lane a turn before retrying a full page. Keep the old
        // idle cadence without throttling the rate at which a backlog drains.
        if (step != 0) continue;
        if (filledPage) {
          filledPage = false;
          continue;
        }
        final wake = _wake = Completer<void>();
        _timer = Timer(interval * turnCount, wake.complete);
        await wake.future;
        _wake = null;
        _timer = null;
      }
    } finally {
      await session.close();
    }
  }

  @override
  Future<void> stop() async {
    if (!_stopping.isCompleted) _stopping.complete();
    if (beforeCommitForTest != null) log('test maintenance: stopping');
    _timer?.cancel();
    if (_wake case final wake? when !wake.isCompleted) wake.complete();
    await _loop;
  }
}

/// Fences each batch across workers. It reports counts only after a successful
/// transaction; a failed batch records its fixed failure class after rollback.
final class MaintenanceRepository {
  const MaintenanceRepository(
    this.session, {
    this.beforeCommitForTest,
    this.beforeSweepFailureForTest,
    this.beforePartitionAttachForTest,
    this.beforePartitionFailureForTest,
  });

  final Session session;
  final Future<void> Function(String lane)? beforeCommitForTest;

  /// Parks a failed sweep after rollback but before reporting its outcome.
  final Future<void> Function()? beforeSweepFailureForTest;

  /// Parks preparation after committing its reservation, before attempting DDL.
  final Future<void> Function()? beforePartitionAttachForTest;

  /// Parks a failed attach after rollback and before recording the retry.
  final Future<void> Function()? beforePartitionFailureForTest;

  Future<void> _limits(
    Transaction tx, {
    bool ddl = false,
  }) => session.db.unsafeSimpleExecute(
    "SET LOCAL lock_timeout='500ms'; SET LOCAL statement_timeout='${ddl ? '1s' : '2s'}'",
    transaction: tx,
  );

  // Every caller records its outcome last. The transaction lock keeps
  // completion numbers in commit order without blocking admission or delivery.
  // Success can finish out of reservation order. Keep the highest accepted
  // attempt separately so a late failure cannot reopen a cleared lane.
  Future<void> _outcome(
    Transaction tx,
    String lane,
    int attempt,
    String outcome,
    int count,
  ) => session.db.unsafeExecute(
    '''
        WITH ordered AS MATERIALIZED (SELECT pg_advisory_xact_lock(1129271902))
        INSERT INTO pipeline_maintenance_outcome AS prior (lane,attempt_fence,outcome,finished_at,affected)
        SELECT @lane,@attempt::bigint,@outcome,clock_timestamp(),@count::integer FROM ordered
        ON CONFLICT (lane) DO UPDATE SET
          attempt_fence=greatest(prior.attempt_fence,excluded.attempt_fence),
          outcome=excluded.outcome,finished_at=excluded.finished_at,affected=excluded.affected,
          completion_order=excluded.completion_order
        WHERE excluded.outcome='ok' OR prior.attempt_fence<excluded.attempt_fence
      ''',
    parameters: QueryParameters.named({
      'lane': lane,
      'attempt': attempt,
      'outcome': outcome,
      'count': count,
    }),
    transaction: tx,
    timeoutInSeconds: 4,
  );

  static String _problem(Object error) => switch (error) {
    DatabaseQueryException(code: '55P03') => 'lock_timeout',
    DatabaseQueryException(code: '57014') ||
    TimeoutException() => 'statement_timeout',
    _ => 'failed',
  };

  Future<void> _recordFailure(String lane, int attempt, Object error) =>
      session.db.transaction((tx) async {
        await _limits(tx);
        await _outcome(tx, lane, attempt, _problem(error), 0);
      });

  Future<({int attempt, DatabaseResultRow row})?> _reservePartition(
    String lane,
    Future<DatabaseResultRow?> Function(Transaction) reserve,
  ) async {
    int? attempt;
    try {
      return await session.db.transaction((tx) async {
        await _limits(tx, ddl: true);
        final id =
            (await session.db.unsafeQuery(
                  "SELECT nextval('pipeline_maintenance_attempt')",
                  transaction: tx,
                  timeoutInSeconds: 4,
                )).single[0]!
                as int;
        attempt = id;
        final row = await reserve(tx);
        return row == null ? null : (attempt: id, row: row);
      });
    } catch (error) {
      final id = attempt;
      if (id == null) rethrow;
      await _recordFailure(lane, id, error);
      return null;
    }
  }

  /// Runs one lane on up to 500 candidates. Returns whether a committed batch
  /// reclaimed a full page, so the worker can make another pass without delay.
  Future<bool> sweep(String lane) async {
    int? attempt;
    try {
      return await session.db.transaction((tx) async {
        await _limits(tx);
        final id =
            (await session.db.unsafeQuery(
                  '''SELECT CASE WHEN pg_try_advisory_xact_lock(1129271901)
          THEN nextval('pipeline_maintenance_attempt') END''',
                  transaction: tx,
                )).single[0]
                as int?;
        if (id == null) return false;
        attempt = id;
        final count =
            (await session.db.unsafeQuery(
                  'SELECT correlia_maintain(@lane,clock_timestamp(),$_candidateCap)',
                  parameters: QueryParameters.named({'lane': lane}),
                  transaction: tx,
                  timeoutInSeconds: 4,
                )).single[0]!
                as int;
        await beforeCommitForTest?.call(lane);
        await _outcome(tx, lane, id, 'ok', count);
        return count == _candidateCap;
      });
    } catch (error) {
      final id = attempt;
      if (id == null) rethrow;
      await beforeSweepFailureForTest?.call();
      await _recordFailure(lane, id, error);
      return false;
    }
  }

  /// Drops at most one eligible closed child, after its final safety check.
  Future<void> dropOld(String parent, {DateTime? nowForTest}) async {
    final lane = 'drop_partition:$parent';
    final args = QueryParameters.named({'parent': parent, 'now': nowForTest});
    const now = 'coalesce(@now::timestamptz,clock_timestamp())';
    final reservation = await _reservePartition(lane, (tx) async {
      return (await session.db.unsafeQuery(
        'SELECT child_name,attempt_id FROM correlia_reserve_drop(@parent,$now)',
        parameters: args,
        transaction: tx,
        timeoutInSeconds: 4,
      )).singleOrNull;
    });
    if (reservation == null) return;
    final child = reservation.row[0];
    final attempt = reservation.row[1];
    try {
      await session.db.transaction((tx) async {
        await _limits(tx, ddl: true);
        final result =
            (await session.db.unsafeQuery(
                  'SELECT correlia_drop_old_partition(@parent,@child,@attempt,$now)',
                  parameters: QueryParameters.named({
                    'parent': parent,
                    'child': child,
                    'attempt': attempt,
                    'now': nowForTest,
                  }),
                  transaction: tx,
                  timeoutInSeconds: 4,
                )).single[0]
                as bool?;
        if (result != null) {
          await _outcome(tx, lane, reservation.attempt, 'ok', result ? 1 : 0);
        }
      });
    } catch (error) {
      await session.db.transaction((tx) async {
        await _limits(tx, ddl: true);
        final recorded = (await session.db.unsafeQuery(
          'SELECT correlia_partition_drop_failed(@child,@attempt,$now)',
          parameters: QueryParameters.named({
            'child': child,
            'attempt': attempt,
            'now': nowForTest,
          }),
          transaction: tx,
          timeoutInSeconds: 4,
        )).single[0];
        if (recorded == true) {
          await _outcome(tx, lane, reservation.attempt, _problem(error), 0);
        }
      });
    }
  }

  /// Prepares one uncovered UTC day, or records a retry after DDL rollback.
  Future<void> prepareOne({DateTime? nowForTest}) async {
    final clock = QueryParameters.named({'now': nowForTest});
    final next = await _reservePartition('prepare_partition', (tx) async {
      await session.db.unsafeExecute(
        '''
        DELETE FROM pipeline_partition_retry WHERE (parent_name,day) IN (
          SELECT parent_name,day FROM pipeline_partition_retry
          WHERE day < (coalesce(@now::timestamptz,clock_timestamp()) AT TIME ZONE 'UTC')::date
          ORDER BY day,parent_name LIMIT 16 FOR UPDATE SKIP LOCKED)
      ''',
        parameters: clock,
        transaction: tx,
        timeoutInSeconds: 4,
      );
      return (await session.db.unsafeQuery(
        '''
        WITH instant AS MATERIALIZED (
          SELECT coalesce(@now::timestamptz,clock_timestamp()) AS at
        ), candidates AS MATERIALIZED (
          SELECT parent,today+lead AS day FROM
            unnest(ARRAY['raw_inbox','events','outbox']) parent
            CROSS JOIN generate_series(0,7) lead
            CROSS JOIN (SELECT (at AT TIME ZONE 'UTC')::date AS today FROM instant) clock
            LEFT JOIN pipeline_partition_retry r ON r.parent_name=parent AND r.day=today+lead
          WHERE NOT correlia_partition_covered(parent,today+lead)
            AND (r.retry_at IS NULL OR r.retry_at<=(SELECT at FROM instant))
          ORDER BY r.attempt_id NULLS FIRST,today+lead,parent LIMIT 1
        )
        SELECT parent,day::text,correlia_reserve_partition(parent,day,(SELECT at FROM instant))
        FROM candidates
      ''',
        parameters: clock,
        transaction: tx,
        timeoutInSeconds: 4,
      )).singleOrNull;
    });
    if (next == null || next.row[2] == null) return;
    final parameters = <String, Object?>{
      'parent': next.row[0],
      'day': next.row[1],
      'attempt': next.row[2],
    };
    try {
      await beforePartitionAttachForTest?.call();
      await session.db.transaction((tx) async {
        await _limits(tx, ddl: true);
        final attached = await session.db.unsafeQuery(
          'SELECT correlia_attach_partition(@parent,@day::date,@attempt)',
          parameters: QueryParameters.named(parameters),
          transaction: tx,
          timeoutInSeconds: 4,
        );
        if (attached.single[0] == true) {
          await _outcome(tx, 'prepare_partition', next.attempt, 'ok', 1);
        }
      });
    } catch (error) {
      await beforePartitionFailureForTest?.call();
      final problem = _problem(error);
      await session.db.transaction((tx) async {
        await _limits(tx, ddl: true);
        final recorded = await session.db.unsafeQuery(
          'SELECT correlia_partition_failed(@parent,@day::date,@attempt,@problem,coalesce(@now::timestamptz,clock_timestamp()))',
          parameters: QueryParameters.named({
            ...parameters,
            'problem': problem,
            'now': nowForTest,
          }),
          transaction: tx,
          timeoutInSeconds: 4,
        );
        if (recorded.single[0] == true) {
          await _outcome(tx, 'prepare_partition', next.attempt, problem, 0);
        }
      });
    }
  }
}
