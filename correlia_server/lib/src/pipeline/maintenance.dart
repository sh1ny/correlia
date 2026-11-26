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
    var step = 0;
    try {
      while (!_stopping.isCompleted) {
        try {
          if (step < _lanes.length) {
            await maintenance.sweep(_lanes[step]);
          } else if (step < _lanes.length + _parents.length) {
            await maintenance.dropOld(_parents[step - _lanes.length]);
          } else {
            await maintenance.prepareOne();
          }
        } catch (_) {
          log('pipeline-maintenance: outcome unavailable');
        }
        step = (step + 1) % (_lanes.length + _parents.length + 1);
        if (_stopping.isCompleted) break;
        final wake = _wake = Completer<void>();
        _timer = Timer(interval, wake.complete);
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
    this.beforePartitionFailureForTest,
  });

  final Session session;
  final Future<void> Function(String lane)? beforeCommitForTest;

  /// Parks a failed attach after rollback and before recording the retry.
  final Future<void> Function()? beforePartitionFailureForTest;

  Future<void> _limits(
    Transaction tx, {
    bool ddl = false,
  }) => session.db.unsafeSimpleExecute(
    "SET LOCAL lock_timeout='500ms'; SET LOCAL statement_timeout='${ddl ? '1s' : '2s'}'",
    transaction: tx,
  );

  Future<void> _outcome(
    Transaction tx,
    String lane,
    String outcome,
    int count,
  ) => session.db.unsafeExecute(
    '''
        INSERT INTO pipeline_maintenance_outcome VALUES (1,@lane,@outcome,clock_timestamp(),@count)
        ON CONFLICT (singleton) DO UPDATE SET lane=excluded.lane,outcome=excluded.outcome,
          finished_at=excluded.finished_at,affected=excluded.affected
      ''',
    parameters: QueryParameters.named({
      'lane': lane,
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

  Future<void> _batch(
    String lane,
    Future<int> Function(Transaction) execute,
  ) async {
    try {
      await session.db.transaction((tx) async {
        await _limits(tx);
        final held = await session.db.unsafeQuery(
          'SELECT pg_try_advisory_xact_lock(1129271901)',
          transaction: tx,
        );
        if (held.single[0] != true) return;
        final count = await execute(tx);
        await beforeCommitForTest?.call(lane);
        await _outcome(tx, lane, 'ok', count);
      });
    } catch (error) {
      await session.db.transaction((tx) async {
        await _limits(tx);
        await _outcome(tx, lane, _problem(error), 0);
      });
    }
  }

  /// Runs one lane on up to 500 candidates.
  Future<void> sweep(String lane) => _batch(
    lane,
    (tx) async =>
        (await session.db.unsafeQuery(
              'SELECT correlia_maintain(@lane,clock_timestamp())',
              parameters: QueryParameters.named({'lane': lane}),
              transaction: tx,
              timeoutInSeconds: 4,
            )).single[0]!
            as int,
  );

  /// Drops at most one eligible closed child, after its final safety check.
  Future<void> dropOld(String parent, {DateTime? nowForTest}) async {
    final args = QueryParameters.named({'parent': parent, 'now': nowForTest});
    const now = 'coalesce(@now::timestamptz,clock_timestamp())';
    final reservation = await session.db.transaction((tx) async {
      await _limits(tx, ddl: true);
      return (await session.db.unsafeQuery(
        'SELECT child_name,attempt_id FROM correlia_reserve_drop(@parent,$now)',
        parameters: args,
        transaction: tx,
        timeoutInSeconds: 4,
      )).singleOrNull;
    });
    if (reservation == null) return;
    final child = reservation[0];
    final attempt = reservation[1];
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
        if (result != null)
          await _outcome(tx, 'drop_partition', 'ok', result ? 1 : 0);
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
        if (recorded == true)
          await _outcome(tx, 'drop_partition', _problem(error), 0);
      });
    }
  }

  /// Prepares one uncovered UTC day, or records a retry after DDL rollback.
  Future<void> prepareOne({DateTime? nowForTest}) async {
    final clock = QueryParameters.named({'now': nowForTest});
    final next = await session.db.transaction((tx) async {
      await _limits(tx, ddl: true);
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
    if (next == null || next[2] == null) return;
    final parameters = <String, Object?>{
      'parent': next[0],
      'day': next[1],
      'attempt': next[2],
    };
    try {
      await session.db.transaction((tx) async {
        await _limits(tx, ddl: true);
        final attached = await session.db.unsafeQuery(
          'SELECT correlia_attach_partition(@parent,@day::date,@attempt)',
          parameters: QueryParameters.named(parameters),
          transaction: tx,
          timeoutInSeconds: 4,
        );
        if (attached.single[0] == true) {
          await _outcome(tx, 'prepare_partition', 'ok', 1);
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
          await _outcome(tx, 'prepare_partition', problem, 0);
        }
      });
    }
  }
}
