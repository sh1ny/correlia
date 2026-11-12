import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../plugin/support/natsdev.dart';
import 'child_server.dart';
import 'output_process.dart';
import 'shared_cluster.dart';

/// Private NATS, bootstrap files, and shared embedded database for child tests.
final class NatsProcessFixture {
  NatsProcessFixture._(this.database, this.nats, this.files, this.environment);

  /// Creates an isolated stream and a plugin bootstrap pinned to its binary.
  static Future<NatsProcessFixture> start() async {
    final database = await SharedClusterDatabase.create(Directory.current);
    NatsTestServer? nats;
    Directory? files;
    try {
      nats = await NatsTestServer.start();
      files = await Directory.systemTemp.createTemp('correlia-nats-process-');
      final binary = File(
        '${Directory.current.parent.path}/build/plugins/output-nats',
      );
      final digest = sha256.convert(await binary.readAsBytes()).toString();
      final config = File('${files.path}/config.json');
      await config.writeAsString(
        jsonEncode({
          'format_version': 1,
          'revision': 1,
          'sources': [
            {
              'id': outputSource,
              'enabled': true,
              'token_ref': 'token',
              'output_ids': [outputId],
            },
          ],
          'outputs': [
            {
              'id': outputId,
              'kind': 'plugin',
              'plugin': 'output-nats',
              'sha256': digest,
              'config': {
                'server': nats.url.toString(),
                'stream': 'CORRELIA_EVENTS',
              },
              'secret_refs': <String, String>{},
            },
          ],
        }),
      );
      final secrets = File('${files.path}/secrets.json');
      await secrets.writeAsString(jsonEncode({'token': outputToken}));
      final chmod = await Process.run('chmod', ['600', secrets.path]);
      if (chmod.exitCode != 0) {
        throw StateError('chmod failed: ${chmod.stderr}');
      }
      final stream = await Process.run(
        '${Directory.current.parent.path}/build/plugins/natsdev',
        ['stream', '--url', nats.url.toString()],
      );
      if (stream.exitCode != 0) {
        throw StateError('NATS stream setup failed: ${stream.stderr}');
      }
      return NatsProcessFixture._(database, nats, files, {
        'CORRELIA_INGEST_CONFIG': config.path,
        'CORRELIA_INGEST_SECRETS': secrets.path,
        'CORRELIA_PLUGIN_DIR': binary.parent.path,
      });
    } catch (_) {
      await nats?.close();
      if (files != null && files.existsSync()) {
        await files.delete(recursive: true);
      }
      await database.drop();
      rethrow;
    }
  }

  /// Test-owned database on the shared embedded PostgreSQL cluster.
  final SharedClusterDatabase database;

  /// Private loopback JetStream server.
  final NatsTestServer nats;

  /// Owner-only test configuration directory.
  final Directory files;

  /// Child environment pointing at the private bootstrap.
  final Map<String, String> environment;
  final List<ChildServer> _children = [];

  /// Starts a child and waits for startup readiness.
  Future<ChildServer> startChild({
    List<String> args = const ['--mode', 'test', '--apply-migrations'],
    List<String> vmArgs = const [],
    Map<String, String> environment = const {},
  }) async {
    final child = await ChildServer.startOnSharedCluster(
      serverDir: Directory.current,
      database: database,
      args: args,
      vmArgs: vmArgs,
      environment: {...this.environment, ...environment},
    );
    _children.add(child);
    await child.waitUntilReady();
    return child;
  }

  /// Stops only owned children and NATS, then drops their private data.
  Future<void> close() async {
    try {
      await tearDownChildren(_children);
    } finally {
      try {
        await nats.close();
      } finally {
        try {
          await database.drop();
        } finally {
          if (files.existsSync()) await files.delete(recursive: true);
        }
      }
    }
  }
}
