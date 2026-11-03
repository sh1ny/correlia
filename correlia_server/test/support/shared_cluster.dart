import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod/serverpod.dart' show PostgresDatabaseConfig;
import 'package:serverpod_test/serverpod_test.dart'
    show EphemeralTestDatabase, TestDatabaseManager;

/// An empty database on the shared test cluster `.serverpod/test/`, for a
/// child server that does not supervise its own embedded Postgres (design D7).
///
/// Serverpod starts or attaches the cluster and creates and drops the
/// database, through [EphemeralTestDatabase], the way every `db` test does.
/// Nothing here starts, stops or signals a PostgreSQL process; the cluster
/// keeps running after the test, as it does after any `db` test (design D4).
final class SharedClusterDatabase {
  SharedClusterDatabase._(this._database, this.socketDir, this.port);

  /// Creates a database named for this process on the shared test cluster of
  /// [serverDir] (the directory of `config/test.yaml`).
  static Future<SharedClusterDatabase> create(Directory serverDir) async {
    final database = await EphemeralTestDatabase.create(
      runMode: 'test',
      databaseName: TestDatabaseManager.generateDatabaseName(),
      serverDirectory: serverDir,
    );
    if (database == null) {
      throw StateError('config/test.yaml configures no PostgreSQL database');
    }
    final config = EphemeralTestDatabase.resolveProjectDatabaseConfig(
      runMode: 'test',
      serverDirectory: serverDir.path,
    );
    if (config is! PostgresDatabaseConfig || config.dataPath == null) {
      throw StateError('the test database is not the embedded cluster');
    }
    final socketDir = Directory(
      p.join(serverDir.path, p.dirname(config.dataPath!), 'run'),
    );
    return SharedClusterDatabase._(
      database,
      socketDir.absolute.path,
      _socketPort(socketDir),
    );
  }

  /// The cluster's port is not TCP: it is the suffix of its socket file
  /// `.s.PGSQL.<port>` in the cluster's `run` directory (design D8).
  static int _socketPort(Directory socketDir) {
    final ports = <int>[
      for (final entry in socketDir.listSync())
        if (RegExp(r'^\.s\.PGSQL\.(\d+)$').firstMatch(p.basename(entry.path))
            case final RegExpMatch match)
          int.parse(match.group(1)!),
    ];
    return switch (ports) {
      [final port] => port,
      _ => throw StateError(
        'expected one .s.PGSQL.<port> socket in ${socketDir.path}, '
        'found $ports',
      ),
    };
  }

  final EphemeralTestDatabase _database;

  /// The database's name.
  String get name => _database.name;

  /// The cluster's Unix socket directory, inside the cluster root.
  final String socketDir;

  /// The port that names the socket file (`.s.PGSQL.<port>`); nothing listens
  /// on it over TCP.
  final int port;

  /// The socket file itself: `package:postgres` connects to the host as given
  /// and does not append `.s.PGSQL.<port>` (the embedded Postgres endpoint
  /// carries the full path too).
  String get socketPath => p.join(socketDir, '.s.PGSQL.$port');

  /// The `SERVERPOD_DATABASE_*` variables that point a child at this database
  /// over the Unix socket, with the child's own embedded Postgres off.
  Map<String, String> get environment => {
    'SERVERPOD_DATABASE_DATA_PATH': '',
    'SERVERPOD_DATABASE_HOST': socketPath,
    'SERVERPOD_DATABASE_IS_UNIX_SOCKET': 'true',
    'SERVERPOD_DATABASE_PORT': '$port',
    'SERVERPOD_DATABASE_NAME': name,
  };

  /// Drops the database, closing any connection to it (`WITH (FORCE)`).
  /// Does nothing if it is already gone.
  Future<void> drop() => _database.drop();
}
