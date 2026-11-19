import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:serverpod/serverpod.dart' show PostgresDatabaseConfig;
import 'package:serverpod_test/serverpod_test.dart'
    show EphemeralTestDatabase, TestDatabaseManager;

/// Creates or reuses a private canonical key in [directory].
///
/// Atomic publication preserves the same key when multiple children start on
/// the same database or a root is recovered after an interrupted run.
String childSecretKeyFile(Directory directory) {
  directory.createSync(recursive: true);
  final target = File(p.join(directory.absolute.path, 'secret-key'));
  if (target.existsSync()) return target.path;
  final temporary = directory.createTempSync('.secret-key-');
  try {
    final candidate = File(p.join(temporary.path, 'key'))..createSync();
    final chmod = Process.runSync('/usr/bin/chmod', ['600', candidate.path]);
    if (chmod.exitCode != 0) throw StateError('Cannot protect child key file');
    final random = Random.secure();
    candidate.writeAsStringSync(
      base64Url
          .encode(List<int>.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', ''),
    );
    final link = Process.runSync('/usr/bin/ln', [candidate.path, target.path]);
    if (link.exitCode != 0 && !target.existsSync()) {
      throw StateError('Cannot publish child key file');
    }
    return target.path;
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

/// An empty database on the shared test cluster `.serverpod/test/`, for a
/// child server that does not supervise its own embedded Postgres (design D7).
///
/// Serverpod starts or attaches the cluster and creates and drops the
/// database, through [EphemeralTestDatabase], the way every `db` test does.
/// Nothing here starts, stops or signals a PostgreSQL process; the cluster
/// keeps running after the test, as it does after any `db` test (design D4).
final class SharedClusterDatabase {
  SharedClusterDatabase._(
    this._database,
    this.socketDir,
    this.port,
    this._serverDir,
    this._keyDirectory,
  );

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
      serverDir.absolute.path,
      Directory.systemTemp.createTempSync('correlia-child-key-'),
    );
  }

  /// The private key shared by children using this database.
  String get secretKeyFile => childSecretKeyFile(_keyDirectory);

  final Directory _keyDirectory;

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

  /// The child's working directory, which a relative socket path resolves
  /// against.
  final String _serverDir;

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
  ///
  /// The host is [socketHostFor] the child's working directory, so a checkout
  /// under a long path still fits the socket path limit.
  Map<String, String> get environment => {
    'SERVERPOD_DATABASE_DATA_PATH': '',
    'SERVERPOD_DATABASE_HOST': socketHostFor(
      socketPath,
      workingDirectory: _serverDir,
    ),
    'SERVERPOD_DATABASE_IS_UNIX_SOCKET': 'true',
    'SERVERPOD_DATABASE_PORT': '$port',
    'SERVERPOD_DATABASE_NAME': name,
  };

  /// Drops the database, closing any connection to it (`WITH (FORCE)`).
  /// Does nothing if it is already gone.
  Future<void> drop() async {
    try {
      await _database.drop();
    } finally {
      if (_keyDirectory.existsSync()) _keyDirectory.deleteSync(recursive: true);
    }
  }
}

/// The shorter of [socketPath] and its path relative to [workingDirectory].
///
/// A Unix socket path must fit `sun_path` (108 bytes on Linux), so a checkout
/// under a long path cannot reach its socket by absolute path. Serverpod's
/// embedded Postgres connects the same way (`shortestPath`).
String socketHostFor(String socketPath, {required String workingDirectory}) {
  final relative = p.relative(socketPath, from: workingDirectory);
  return relative.length < socketPath.length ? relative : socketPath;
}
