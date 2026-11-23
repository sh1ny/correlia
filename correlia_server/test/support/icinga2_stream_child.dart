import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'child_server.dart';
import 'icinga2_consumer_loopback.dart';
import 'icinga2_pipeline.dart';
import 'icinga2_stream_fixture.dart';
import 'shared_cluster.dart';

const _source = icinga2DbSourceId;

/// An isolated real Correlia process and a local TLS Icinga2 peer.
final class Icinga2StreamChild {
  Icinga2StreamChild._(this.cluster, this.db, this.upstream, this.files);

  final SharedClusterDatabase cluster;
  final Connection db;
  final IcingaConsumerLoopback upstream;
  final Directory files;
  final children = <ChildServer>[];

  /// Creates a fixture and registers teardown in dependency order.
  static Future<Icinga2StreamChild> create() async {
    final cluster = await SharedClusterDatabase.create(Directory.current);
    addTearDown(cluster.drop);
    final files = Directory.systemTemp.createTempSync('correlia-stream-child-');
    addTearDown(() => files.deleteSync(recursive: true));
    final db = await Connection.open(
      Endpoint(
        host: socketHostFor(
          cluster.socketPath,
          workingDirectory: Directory.current.path,
        ),
        port: cluster.port,
        database: cluster.name,
        username: 'postgres',
        isUnixSocket: true,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    addTearDown(db.close);
    final upstream = await IcingaConsumerLoopback.start();
    addTearDown(upstream.close);
    final result = Icinga2StreamChild._(cluster, db, upstream, files);
    addTearDown(() => tearDownChildren(result.children));
    return result;
  }

  Map<String, Object?> source({bool enabled = true, Uri? url}) {
    final value = streamSource(_source, enabled: enabled);
    (value['api']! as Map<String, Object?>)['url'] = (url ?? upstream.url)
        .toString();
    return value;
  }

  Future<ChildServer> start({
    String role = 'all',
    String mode = 'test',
    int? revision,
    List<Object?>? sources,
    Map<String, Object?>? material,
  }) async {
    final env = {
      'CORRELIA_SECRET_KEY_FILE': cluster.secretKeyFile,
      'SERVERPOD_DATABASE_REQUIRE_SSL': 'false',
    };
    if (revision != null) {
      final config = File('${files.path}/config-$revision.json')
        ..writeAsStringSync(
          jsonEncode(streamBootstrap(revision, sources ?? [source()])),
        );
      final secrets = File('${files.path}/secrets-$revision.json')
        ..writeAsStringSync(jsonEncode(material ?? streamMaterial()));
      expect((await Process.run('chmod', ['600', secrets.path])).exitCode, 0);
      env['CORRELIA_INGEST_CONFIG'] = config.path;
      env['CORRELIA_INGEST_SECRETS'] = secrets.path;
    }
    final child = await ChildServer.startOnSharedCluster(
      serverDir: Directory.current,
      database: cluster,
      args: ['--mode', mode, '--apply-migrations', '--process-role', role],
      environment: env,
    );
    children.add(child);
    if (mode != 'test') {
      addTearDown(() async {
        if (!child.hasExited)
          expect(await child.stop(), 0, reason: child.output);
      });
    }
    await child.waitUntilReady();
    return child;
  }

  Future<void> ageSync() async {
    await db.execute(
      "UPDATE icinga2_sync_progress SET started_at=clock_timestamp()-interval '61 seconds'",
    );
  }

  Future<int> count(String relation) async =>
      (await db.execute('SELECT count(*) FROM $relation')).single.single!
          as int;

  Future<void> waitState(String state) => until(
    () async => (await db.execute(
      "SELECT 1 FROM icinga2_stream_status WHERE state='$state'",
    )).isNotEmpty,
  );

  Future<void> until(Future<bool> Function() condition) async {
    final deadline = Stopwatch()..start();
    while (!await condition()) {
      if (deadline.elapsed > const Duration(seconds: 45)) {
        fail(
          'State not reached. ${children.map((child) => child.output).join('\n')}',
        );
      }
    }
  }
}
