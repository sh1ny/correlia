@Tags(['e2e'])
library;

import 'dart:convert';
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

  test('legacy row drains before cutover', () async {
    final serverDir = Directory.current;
    final database = await SharedClusterDatabase.create(serverDir);
    final files = await Directory.systemTemp.createTemp(
      'correlia-matcher-cutover-',
    );
    final children = <ChildServer>[];
    Connection? db;
    try {
      final config = File('${files.path}/config.json');
      final secrets = File('${files.path}/secrets.json');
      await config.writeAsString(
        jsonEncode({
          'format_version': 2,
          'revision': 2,
          'sources': <Object?>[],
          'outputs': [
            for (var i = 0; i < 64; i++)
              {
                'id':
                    'aaaaaaaa-aaaa-4aaa-8aaa-${i.toString().padLeft(12, '0')}',
                'kind': 'webhook',
                'url': 'http://127.0.0.1:8089/events',
                'signing_key_ref': 'key',
              },
          ],
        }),
      );
      await secrets.writeAsString(
        jsonEncode({
          'key': base64Url.encode(List<int>.filled(32, 7)).replaceAll('=', ''),
        }),
      );
      expect(
        (await Process.run('/usr/bin/chmod', ['600', secrets.path])).exitCode,
        0,
      );
      Future<ChildServer> start() async {
        final child = await ChildServer.startOnSharedCluster(
          serverDir: serverDir,
          database: database,
          args: const [
            '--mode',
            'test',
            '--apply-migrations',
            '--process-role',
            'api',
          ],
          environment: {
            'CORRELIA_INGEST_CONFIG': config.path,
            'CORRELIA_INGEST_SECRETS': secrets.path,
          },
        );
        children.add(child);
        return child;
      }

      final baseline = await start();
      await baseline.waitUntilReady();
      expect(await baseline.closeStdin(), 0);
      db = await Connection.open(
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
      const source = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      const output = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      final active = (await db.execute(
        'SELECT "snapshotId" FROM ingest_active_config',
      )).single[0];
      await db.runTx((tx) async {
        await tx.execute('DROP FUNCTION correlia_require_pin_worker() CASCADE');
        await tx.execute(
          'DROP FUNCTION correlia_retained_output_ids(), correlia_pinned_output_routes()',
        );
        await tx.execute(
          'DELETE FROM correlia_schema_versions WHERE version=13',
        );
        await tx.execute(
          File('schema/0010_publisher_version_2.sql').readAsStringSync(),
          queryMode: QueryMode.simple,
        );
        await tx.execute("SET LOCAL correlia.publisher_version = '2'");
        await tx.execute(
          Sql.named('''
INSERT INTO ingest_config_snapshot ("snapshotId", revision, "publicJson")
VALUES ('legacy',1,@public)
'''),
          parameters: {
            'public': jsonEncode({
              'sources': [
                {
                  'id': source,
                  'enabled': true,
                  'output_ids': [output],
                },
              ],
              'outputs': [
                {'id': output},
              ],
            }),
          },
        );
        await tx.execute('''
INSERT INTO raw_inbox (observed_at, raw_id, source_id, body, body_sha256, content_type, config_snapshot_id)
VALUES (now(),'$source','$source',''::bytea,'none','application/json','legacy')
''');
      });
      final refused = await start();
      expect(await refused.exitCode, 1);
      expect(refused.output, contains('Schema step 13 failed'));
      expect(
        (await db.execute(
          'SELECT status, config_snapshot_id FROM raw_inbox',
        )).single,
        ['pending', 'legacy'],
      );
      await db.runTx((tx) async {
        await tx.execute("SET LOCAL correlia.publisher_version = '2'");
        await tx.execute(
          '''INSERT INTO ingest_config_snapshot ("snapshotId", revision, "publicJson") VALUES ('probe', 3, '{}')''',
        );
        await tx.execute("UPDATE raw_inbox SET status = 'done'");
      });
      final upgraded = await start();
      await upgraded.waitUntilReady();
      expect(
        (await db.execute(
          'SELECT "snapshotId" FROM ingest_active_config',
        )).single[0],
        active,
      );
      expect(
        (await db.execute(
          'SELECT status, config_snapshot_id FROM raw_inbox',
        )).single,
        ['done', 'legacy'],
      );
      expect(await upgraded.closeStdin(), 0);
    } finally {
      await db?.close();
      await tearDownChildren(children);
      await database.drop();
      await files.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 7)));
}
