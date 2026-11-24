import 'dart:async';

import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:serverpod/serverpod.dart';

/// Wakes test predicates on committed writes, without polling or step deadlines.
///
/// Use one observer per test group database and close it after stopping writers.
final class IcingaTestDbChanges {
  IcingaTestDbChanges._(this._connection) {
    _failure.future.ignore();
    _subscription = _connection.channels.all.listen(
      (event) {
        if (event.channel != _channel) return;
        final changed = _changed;
        _changed = Completer<void>();
        changed.complete();
      },
      onError: _fail,
      onDone: () => _fail(StateError('Icinga2 test database listener closed')),
    );
  }

  static const _channel = 'icinga2_test_change';
  final pg.Connection _connection;
  late final StreamSubscription<pg.Notification> _subscription;
  var _changed = Completer<void>();
  final _failure = Completer<Never>();

  /// Observes writes to the named fixture [tables] on the embedded database.
  static Future<IcingaTestDbChanges> start(
    Serverpod pod,
    List<String> tables,
  ) async => onConnection(await openStreamDatabase(pod), tables);

  /// Installs test witnesses on a connection this observer takes ownership of.
  static Future<IcingaTestDbChanges> onConnection(
    pg.Connection connection,
    List<String> tables, {
    bool journalStreamStatus = false,
  }) async {
    final changes = IcingaTestDbChanges._(connection);
    try {
      await connection.runTx((tx) async {
        await tx.execute('''
          CREATE FUNCTION $_channel() RETURNS trigger LANGUAGE plpgsql AS \$\$
          BEGIN
            PERFORM pg_notify('$_channel', TG_TABLE_NAME);
            RETURN NULL;
          END \$\$
        ''');
        for (final table in tables) {
          await tx.execute('''
            CREATE TRIGGER $_channel AFTER INSERT OR UPDATE OR DELETE ON $table
            FOR EACH STATEMENT EXECUTE FUNCTION $_channel()
          ''');
        }
        if (journalStreamStatus) {
          await tx.execute('''
            CREATE TABLE icinga2_test_transitions (
              seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              source_id uuid NOT NULL, connection_id text, connection_seq bigint,
              state text NOT NULL, error_class text, gap_count bigint NOT NULL
            )
          ''');
          await tx.execute('''
            CREATE FUNCTION icinga2_test_transition() RETURNS trigger LANGUAGE plpgsql AS \$\$
            BEGIN
              IF TG_OP = 'INSERT' OR
                  (NEW.state, NEW."connectionId", NEW."connectionSeq", NEW."lastErrorClass", NEW."gapCount")
                  IS DISTINCT FROM
                  (OLD.state, OLD."connectionId", OLD."connectionSeq", OLD."lastErrorClass", OLD."gapCount") THEN
                INSERT INTO icinga2_test_transitions
                  (source_id, connection_id, connection_seq, state, error_class, gap_count)
                VALUES (NEW."sourceId", NEW."connectionId", NEW."connectionSeq",
                  NEW.state, NEW."lastErrorClass", NEW."gapCount");
                PERFORM pg_notify('$_channel', TG_TABLE_NAME);
              END IF;
              RETURN NULL;
            END \$\$
          ''');
          await tx.execute('''
            CREATE TRIGGER icinga2_test_transition AFTER INSERT OR UPDATE ON icinga2_stream_status
            FOR EACH ROW EXECUTE FUNCTION icinga2_test_transition()
          ''');
        }
        await tx.execute('LISTEN $_channel');
      });
      return changes;
    } catch (_) {
      await changes._subscription.cancel();
      await connection.close(force: true);
      rethrow;
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (!_failure.isCompleted) _failure.completeError(error, stack);
  }

  /// Reads [condition] initially and again only after a committed change.
  Future<void> until(Future<bool> Function() condition) async {
    while (true) {
      final changed = _changed.future;
      if (await condition()) return;
      await Future.any([changed, _failure.future]);
    }
  }

  /// Removes the listener and its test-only database objects.
  Future<void> close({bool dropObjects = true}) async {
    await _subscription.cancel();
    try {
      if (!dropObjects) return;
      await _connection.execute(
        'DROP FUNCTION IF EXISTS icinga2_test_transition() CASCADE',
      );
      await _connection.execute(
        'DROP TABLE IF EXISTS icinga2_test_transitions',
      );
      await _connection.execute('DROP FUNCTION $_channel() CASCADE');
    } finally {
      await _connection.close(force: true);
    }
  }
}
