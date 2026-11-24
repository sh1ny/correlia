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
  ) async {
    final connection = await openStreamDatabase(pod);
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
  Future<void> close() async {
    await _subscription.cancel();
    try {
      await _connection.execute('DROP FUNCTION $_channel() CASCADE');
    } finally {
      await _connection.close(force: true);
    }
  }
}
