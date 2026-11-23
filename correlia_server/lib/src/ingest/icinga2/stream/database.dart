import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart' as pg;
import 'package:serverpod/serverpod.dart';

/// The server's database endpoint, resolved before consumer work starts.
final class StreamDatabaseEndpoint {
  const StreamDatabaseEndpoint._(this._endpoint, this._sslMode);

  final pg.Endpoint _endpoint;
  final pg.SslMode _sslMode;

  /// Resolve the actual embedded socket, including an ephemeral test database.
  /// This lookup uses Serverpod once; opening a dedicated connection does not.
  static Future<StreamDatabaseEndpoint> resolve(Serverpod pod) async {
    final config = pod.config.database;
    if (config is! PostgresDatabaseConfig) {
      throw StateError('Icinga2 Event Streams requires PostgreSQL');
    }
    if (config.dataPath != null) {
      return pod.withSession((session) async {
        final row = (await session.db.unsafeQuery('''
          SELECT current_setting('unix_socket_directories'),
            current_setting('port')::int, current_database(), current_user,
            current_setting('data_directory')
        ''')).single;
        // PostgreSQL resolves a relative socket directory from PGDATA, not
        // from the Dart process. Use a short path for the Linux sun_path limit.
        final port = row[1]! as int;
        final socket = p.normalize(
          p.join(row[4]! as String, row[0]! as String, '.s.PGSQL.$port'),
        );
        final relative = p.relative(socket, from: Directory.current.path);
        return StreamDatabaseEndpoint._(
          pg.Endpoint(
            host: relative.length < socket.length ? relative : socket,
            port: port,
            database: row[2]! as String,
            username: row[3]! as String,
            isUnixSocket: true,
          ),
          pg.SslMode.disable,
        );
      });
    }
    return StreamDatabaseEndpoint._(
      pg.Endpoint(
        host: config.host,
        port: config.port,
        database: config.name,
        username: config.user,
        password: config.password,
        isUnixSocket: config.isUnixSocket,
      ),
      config.requireSsl ? pg.SslMode.require : pg.SslMode.disable,
    );
  }

  /// Opens an independent connection the caller may force-close on shutdown.
  Future<pg.Connection> open() async {
    final connection = await pg.Connection.open(
      _endpoint,
      settings: pg.ConnectionSettings(
        connectTimeout: const Duration(seconds: 1),
        queryTimeout: const Duration(seconds: 2),
        timeZone: 'UTC',
        sslMode: _sslMode,
        applicationName: 'correlia-icinga2-stream',
      ),
    );
    try {
      await connection.execute('''
        SET client_connection_check_interval='1s';
        SET idle_in_transaction_session_timeout='5s';
        ${_endpoint.isUnixSocket ? '' : '''
          SET tcp_keepalives_idle=5;
          SET tcp_keepalives_interval=1;
          SET tcp_keepalives_count=3;
          SET tcp_user_timeout=10000;
        '''}
      ''', queryMode: pg.QueryMode.simple);
      return connection;
    } catch (_) {
      await connection.close(force: true);
      rethrow;
    }
  }
}

/// Opens a dedicated connection when the caller does not need to reuse the endpoint.
Future<pg.Connection> openStreamDatabase(Serverpod pod) async =>
    (await StreamDatabaseEndpoint.resolve(pod)).open();

/// Runs one fenced write with short PostgreSQL statement and lock timeouts.
Future<T> runStreamWrite<T>(
  pg.Connection connection,
  Future<T> Function(pg.TxSession) apply,
) => connection.runTx((tx) async {
  await tx.execute('''
    SET LOCAL statement_timeout='2s';
    SET LOCAL lock_timeout='2s';
    SET LOCAL idle_in_transaction_session_timeout='5s';
  ''', queryMode: pg.QueryMode.simple);
  return apply(tx);
});
