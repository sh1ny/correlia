import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'child_server.dart';
import 'icinga2_consumer_loopback.dart';
import 'icinga2_test_db_changes.dart';
import 'icinga2_pipeline.dart';
import 'icinga2_stream_fixture.dart';
import 'shared_cluster.dart';

const _source = icinga2DbSourceId;

/// An isolated real Correlia process and a local TLS Icinga2 peer.
///
/// This fixture observes real child outcomes; it adds no fault switch or
/// timer override. Controlled timing-order checks run in-process.
/// As required by ADR 0014, observe or terminate only the worktree-owned
/// embedded database and the exact children started by this fixture.
final class Icinga2StreamChild {
  Icinga2StreamChild._(this.cluster, this.db, this.upstream, this.files);

  final SharedClusterDatabase cluster;
  final Connection db;
  final IcingaConsumerLoopback upstream;
  final Directory files;
  final children = <ChildServer>[];
  IcingaTestDbChanges? _changes;
  ChildServer? _consumer;

  /// Creates a fixture and registers teardown in dependency order.
  static Future<Icinga2StreamChild> create() async {
    final cluster = await SharedClusterDatabase.create(Directory.current);
    addTearDown(cluster.drop);
    final files = Directory.systemTemp.createTempSync('correlia-stream-child-');
    addTearDown(() => files.deleteSync(recursive: true));
    final db = await _open(cluster);
    addTearDown(db.close);
    final upstream = await IcingaConsumerLoopback.start();
    addTearDown(upstream.close);
    final result = Icinga2StreamChild._(cluster, db, upstream, files);
    addTearDown(() async => result._changes?.close(dropObjects: false));
    addTearDown(() => tearDownChildren(result.children));
    return result;
  }

  static Future<Connection> _open(SharedClusterDatabase cluster) =>
      Connection.open(
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
    if (_changes == null) {
      final bootstrap = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: cluster,
        args: ['--mode', 'test', '--apply-migrations', '--process-role', 'api'],
      );
      children.add(bootstrap);
      await bootstrap.waitForReadyEvent();
      expect(
        await bootstrap.closeStdin(deadline: null),
        0,
        reason: bootstrap.output,
      );
      _changes = await IcingaTestDbChanges.onConnection(
        await _open(cluster),
        ['raw_inbox', 'events', 'icinga2_sync_progress'],
        journalStreamStatus: true,
      );
    }
    final env = {
      'CORRELIA_SECRET_KEY_FILE': cluster.secretKeyFile,
      'SERVERPOD_DATABASE_REQUIRE_SSL': 'false',
      // Production config requires a value even on our test-owned Unix socket.
      if (mode == 'production')
        'SERVERPOD_PASSWORD_database': 'unused-test-unix-socket-password',
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
        if (!child.hasExited) {
          expect(await child.stop(deadline: null), 0, reason: child.output);
        }
      });
    }
    await child.waitForReadyEvent();
    if (role != 'api') _consumer = child;
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

  /// Waits for committed fixture changes, with no per-step deadline.
  Future<void> until(Future<bool> Function() condition) {
    final producer =
        _consumer ?? (throw StateError('No stream consumer started'));
    return Future.any([
      _changes!.until(condition),
      producer.exitCode.then<void>((code) {
        throw StateError(
          'Stream child ${producer.pid} exited with $code before its DB outcome.\n'
          '${producer.output}',
        );
      }),
    ]);
  }

  /// Marks the committed transitions preceding a new fixture action.
  Future<int> journalCursor() async =>
      (await db.execute(
            Sql.named('''
      SELECT coalesce(max(seq), 0) FROM icinga2_test_transitions
      WHERE source_id = @source:uuid
    '''),
            parameters: {'source': _source},
          )).single.single!
          as int;

  /// Reads the first change of state after [after], excluding [from] and
  /// connecting. A gap-count update can leave the current state unchanged.
  Future<ResultRow> firstAttemptOutcome({
    int after = 0,
    String from = 'connecting',
  }) async {
    late ResultRow outcome;
    await until(() async {
      final rows = await db.execute(
        Sql.named('''
        SELECT state, error_class, connection_seq, gap_count
        FROM icinga2_test_transitions
        WHERE source_id = @source:uuid AND seq > @after:int8
          AND state NOT IN ('connecting', @from:text)
        ORDER BY seq LIMIT 1
      '''),
        parameters: {'source': _source, 'after': after, 'from': from},
      );
      if (rows.isEmpty) return false;
      outcome = rows.single;
      return true;
    });
    return outcome;
  }

  /// Checks the exact source and raw key, failing on a terminal row without an event.
  Future<void> expectDelivery(String source, String bodyMarker) async {
    await until(() async {
      final rows = await db.execute(
        Sql.named('''
        SELECT r.status, r.outcome_json, r.raw_id::text, (
          SELECT count(*) FROM events e
          WHERE (e.raw_observed_at, e.raw_id, e.source_id) =
            (r.observed_at, r.raw_id, r.source_id)
        )
        FROM raw_inbox r
        WHERE r.source_id = @source:uuid
          AND strpos(convert_from(r.body, 'UTF8'), @marker:text) > 0
      '''),
        parameters: {'source': source, 'marker': bodyMarker},
      );
      if (rows.isEmpty) return false;
      expect(
        rows,
        hasLength(1),
        reason: 'raw delivery for $source: $bodyMarker',
      );
      final row = rows.single;
      if (row[0] != 'done' && row[0] != 'failed') return false;
      final reason = 'source $source raw ${row[2]}: ${row[1]}';
      expect(row[0], 'done', reason: reason);
      expect(row[3], 1, reason: reason);
      return true;
    });
  }
}
