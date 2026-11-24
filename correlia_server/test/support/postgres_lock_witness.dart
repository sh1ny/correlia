import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

/// A held fixture gate that releases and joins its actors before witness teardown.
final class ContentionGate {
  ContentionGate() {
    addTearDown(join);
  }

  final _release = Completer<void>();
  final _actors = <Future<void>>[];

  Future<void> get future => _release.future;

  /// Starts and tracks an actor; the caller still owns its outcome assertion.
  Future<T> run<T>(Future<T> Function() work) {
    if (_release.isCompleted) throw StateError('Contention gate already open');
    final actor = work();
    _actors.add(actor.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return actor;
  }

  /// Opens the gate and waits for successful or failed actors to settle.
  Future<void> join() async {
    if (!_release.isCompleted) _release.complete();
    await Future.wait(_actors);
  }
}

/// Owns the embedded postmaster and its log for one contention suite.
///
/// The shared test postmaster can outlive the Dart isolate that forwards its
/// log. Running this suite's pool as the owner keeps the log observable until
/// the suite's Serverpod shuts down.
final class LockWitnessCluster {
  Directory? _root;

  /// Use with `ephemeralDatabase: false`; the entire cluster is disposable.
  ServerpodConfig override(ServerpodConfig config) {
    final database = config.database;
    if (database is! PostgresDatabaseConfig || database.dataPath == null) {
      throw StateError('Lock witness requires embedded test PostgreSQL');
    }
    final root = _root ??= (Directory(
      '.serverpod',
    )..createSync()).createTempSync('lock-');
    return config.copyWith(
      database: PostgresDatabaseConfig.embedded(
        dataPath: '${root.path}/pgdata',
        name: database.name,
        maxConnectionCount: database.maxConnectionCount,
      ),
    );
  }

  /// Deletes the owned root after the inner withServerpod group shuts down.
  Future<void> close() async {
    if (_root case final root?) await root.delete(recursive: true);
  }
}

/// Identity captured on the exact database transaction that owns or waits for a lock.
typedef LockActor = ({int pid, String started, String database, String name});

var _actorSequence = 0;
String _tagActor() =>
    "SET LOCAL application_name='correlia-lock-${++_actorSequence}'";

const _actorSql = '''SELECT pid, backend_start::text, datname, application_name
  FROM pg_stat_activity WHERE pid = pg_backend_pid()''';
const _observeWaitSql =
    "SET LOCAL log_lock_waits=on; SET LOCAL deadlock_timeout='1ms'";
const _parkSql = '''SET LOCAL idle_in_transaction_session_timeout=0;
  SET LOCAL lock_timeout=0; SET LOCAL statement_timeout=0''';

const _timeoutsSql = '''SELECT setting::int FROM pg_settings
  WHERE name IN ('idle_in_transaction_session_timeout', 'lock_timeout', 'statement_timeout')
  ORDER BY name''';

/// Expected ordinary SQL settings, in milliseconds, on the contested transaction.
enum SqlTimeouts {
  streamWrite(5000, 2000, 2000),
  sweep(5000, 1000, 1000),
  poolDefault(0, 0, 0),
  publication(0, 5000, 5000),
  schemaStep(0, 30000, 0);

  const SqlTimeouts(this.idle, this.lock, this.statement);

  final int idle;
  final int lock;
  final int statement;

  void verify(Iterable<List<Object?>> rows) {
    expect(
      rows.map((row) => row.single),
      [idle, lock, statement],
      reason: '$name idle-in-transaction, lock and statement timeout (ms)',
    );
  }
}

LockActor _actor(List<Object?> row) => (
  pid: row[0]! as int,
  started: row[1]! as String,
  database: row[2]! as String,
  name: row[3]! as String,
);

/// Prepares a dedicated fixture transaction and records its backend identity.
Future<LockActor> lockActor(pg.TxSession tx, {SqlTimeouts? waiter}) async {
  waiter?.verify(await tx.execute(_timeoutsSql));
  await tx.execute(_parkSql, queryMode: pg.QueryMode.simple);
  await tx.execute(_tagActor(), queryMode: pg.QueryMode.simple);
  if (waiter != null) {
    await tx.execute(_observeWaitSql, queryMode: pg.QueryMode.simple);
  }
  return _actor((await tx.execute(_actorSql)).single);
}

/// Prepares a pooled fixture transaction and records its backend identity in it.
Future<LockActor> pooledLockActor(
  Session session,
  Transaction tx, {
  SqlTimeouts? waiter,
}) async {
  if (waiter != null) {
    waiter.verify(await session.db.unsafeQuery(_timeoutsSql, transaction: tx));
  }
  await session.db.unsafeSimpleExecute(_parkSql, transaction: tx);
  await session.db.unsafeSimpleExecute(_tagActor(), transaction: tx);
  if (waiter != null) {
    await session.db.unsafeSimpleExecute(_observeWaitSql, transaction: tx);
  }
  return _actor(
    (await session.db.unsafeQuery(_actorSql, transaction: tx)).single,
  );
}

/// Waits for a backend lock diagnostic, then verifies the exact live lock edge.
///
/// Start before dispatching the waiter and leave the blocker held until the
/// witness returns. Do not use this for a waiter meant to time out on its own.
final class PostgresLockWitness {
  PostgresLockWitness._(
    this._session,
    this._reader,
    this._database,
  );

  final Session _session;
  final RandomAccessFile _reader;
  final String _database;
  late int _cursor;
  final _partial = <int>[];
  var _discardPartial = false;
  late final StreamSubscription<FileSystemEvent> _subscription;
  final _waiting = <(int, String)>{};
  static final _waitingLine = RegExp(
    r'\bprocess (\d+) still waiting for \w+ on (advisory lock|transaction|tuple|relation)\b',
  );
  Completer<void> _changed = Completer<void>();
  Object? _failure;

  /// Attaches only to the embedded database serving this fixture session.
  static Future<PostgresLockWitness> start(Session session) async {
    final config = session.serverpod.config.database;
    if (config is! PostgresDatabaseConfig || config.dataPath == null) {
      throw StateError(
        'Lock witness requires this fixture’s embedded database',
      );
    }
    final row = (await session.db.unsafeQuery(
      '''SELECT
      current_setting('data_directory'), current_database(), inet_server_port()''',
    )).single;
    final path = Directory(row[0]! as String).resolveSymbolicLinksSync();
    final expected = Directory(config.dataPath!).resolveSymbolicLinksSync();
    if (path != expected || row[2] != null) {
      throw StateError('Backend is not on the fixture’s embedded Unix socket');
    }
    final file = File('${Directory(path).parent.path}/postgres.log');
    final reader = file.openSync();
    final witness = PostgresLockWitness._(
      session,
      reader,
      row[1]! as String,
    );
    try {
      witness._subscription = file
          .watch(
            events:
                FileSystemEvent.modify |
                FileSystemEvent.delete |
                FileSystemEvent.move,
          )
          .listen(
            (event) {
              if (event.type != FileSystemEvent.modify) {
                witness._fail(
                  StateError('PostgreSQL fixture log moved or was deleted'),
                );
                return;
              }
              witness._drain();
            },
            onError: witness._fail,
            onDone: () =>
                witness._fail(StateError('PostgreSQL log watch closed')),
          );
      witness._cursor = reader.lengthSync();
      // An existing partial line belongs to the previous log cursor.
      if (witness._cursor > 0) {
        reader.setPositionSync(witness._cursor - 1);
        witness._discardPartial = reader.readByteSync() != 10;
      }
      witness._drain();
      return witness;
    } catch (_) {
      reader.closeSync();
      rethrow;
    }
  }

  void _wake() {
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
  }

  void _fail(Object error) {
    _failure ??= error;
    _wake();
  }

  void _drain() {
    try {
      final length = _reader.lengthSync();
      if (length < _cursor) {
        throw StateError('PostgreSQL fixture log lost continuity');
      }
      _reader.setPositionSync(_cursor);
      while (_cursor < length) {
        final remaining = length - _cursor;
        final bytes = _reader.readSync(remaining < 8192 ? remaining : 8192);
        if (bytes.isEmpty) throw StateError('PostgreSQL fixture log truncated');
        _cursor += bytes.length;
        for (final byte in bytes) {
          if (_discardPartial) {
            if (byte == 10) _discardPartial = false;
            continue;
          }
          if (byte != 10) {
            if (_partial.length < 4096) _partial.add(byte);
            continue;
          }
          final line = utf8.decode(_partial, allowMalformed: true);
          _partial.clear();
          final match = _waitingLine.firstMatch(line);
          if (match != null) _waiting.add((int.parse(match[1]!), match[2]!));
        }
      }
      _wake();
    } catch (error) {
      _fail(error);
    }
  }

  /// Verifies [waiter] is blocked by [blocker], or fails if [operation] ends first.
  Future<void> blockedBy(
    LockActor waiter,
    LockActor blocker,
    Future<Object?> operation, {
    required String statement,
    bool advisory = false,
  }) async {
    if (waiter.database != _database || blocker.database != _database) {
      throw StateError('Lock actors are not in the observed database');
    }
    final ended = operation.then<void>(
      (_) => throw StateError(
        'Waiter ${waiter.pid} finished before its lock witness',
      ),
    );
    ended.ignore();
    bool observed() => advisory
        ? _waiting.remove((waiter.pid, 'advisory lock'))
        : _waiting.remove((waiter.pid, 'transaction')) ||
              _waiting.remove((waiter.pid, 'tuple')) ||
              _waiting.remove((waiter.pid, 'relation'));
    while (!observed()) {
      if (_failure case final failure?) throw failure;
      await Future.any([_changed.future, ended]);
    }
    if (_failure case final failure?) throw failure;
    final result = await _session.db.unsafeQuery(
      '''SELECT 1 FROM pg_stat_activity w
      JOIN pg_stat_activity b ON b.datname=w.datname
      WHERE w.datname=current_database() AND w.pid=@waiter AND b.pid=@blocker
        AND w.backend_start::text=@waiterStarted AND b.backend_start::text=@blockerStarted
        AND w.application_name=@waiterName AND b.application_name=@blockerName
        AND position(@statement in w.query)>0
        AND w.wait_event_type='Lock' AND b.pid=ANY(pg_blocking_pids(w.pid))''',
      parameters: QueryParameters.named({
        'waiter': waiter.pid,
        'blocker': blocker.pid,
        'waiterStarted': waiter.started,
        'blockerStarted': blocker.started,
        'waiterName': waiter.name,
        'blockerName': blocker.name,
        'statement': statement,
      }),
    );
    if (result.isEmpty) {
      throw StateError(
        'Expected ${waiter.name} (${waiter.pid}) at $statement '
        'to be waiting on ${blocker.name} (${blocker.pid})',
      );
    }
  }

  /// Stops the fixture's log observer after both actors have joined.
  Future<void> close() async {
    await _subscription.cancel();
    await _reader.close();
  }
}
