@Tags(['e2e'])
library;

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/shared_cluster.dart';

void main() {
  test('guarded YAML rollback restarts identically', () async {
    final serverDir = Directory.current;
    final database = await SharedClusterDatabase.create(serverDir);
    final files = await Directory.systemTemp.createTemp(
      'correlia-matcher-restart-',
    );
    final children = <ChildServer>[];
    Connection? db;
    try {
      final config = File('${files.path}/config.yaml');
      Future<List<Object?>> restart() async {
        final child = await ChildServer.startOnSharedCluster(
          serverDir: serverDir,
          database: database,
          environment: {'CORRELIA_INGEST_CONFIG': config.path},
        );
        children.add(child);
        await child.waitUntilReady();
        final connection = db ??= await Connection.open(
          Endpoint(
            host: socketHostFor(
              database.socketPath,
              workingDirectory: serverDir.path,
            ),
            port: database.port,
            database: database.name,
            username: 'postgres',
            isUnixSocket: true,
          ),
          settings: const ConnectionSettings(sslMode: SslMode.disable),
        );
        final rows = await connection.execute('''
SELECT a."snapshotId", c.revision,
       c."publicJson"::jsonb #>> '{matcher,rules,0,actions,0,value}',
       (SELECT count(*) FROM ingest_config_snapshot)
FROM ingest_active_config a JOIN ingest_config_snapshot c USING ("snapshotId")
''');
        expect(await child.closeStdin(), 0);
        return rows.single;
      }

      Future<List<Object?>> publish(
        int revision,
        String? expected,
        String label,
      ) async {
        await config.writeAsString('''
format_version: 2
revision: $revision
expected_active_snapshot: ${expected == null ? 'null' : '"$expected"'}
sources: []
outputs: []
matcher:
  language: matcher
  version: 1
  rules:
    - id: example
      when: {field: summary, op: exists}
      actions:
        - {type: set_label, key: team, value: "$label"}
''');
        return restart();
      }

      final first = await publish(1, null, 'original');
      final second = await publish(2, first[0] as String, 'new');
      final rollback = await publish(3, second[0] as String, 'original');
      expect(rollback[0], isNot(first[0]));
      expect(rollback.sublist(1), [3, 'original', 3]);
      expect(await restart(), rollback);
    } finally {
      await db?.close();
      await tearDownChildren(children);
      await database.drop();
      await files.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 7)));
}
