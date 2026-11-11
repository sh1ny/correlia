import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'child_server.dart';
import 'shared_cluster.dart';

const outputSource = '11111111-1111-4111-8111-111111111111';
const outputId = '22222222-2222-4222-8222-222222222222';
const secondOutputId = '33333333-3333-4333-8333-333333333333';
final outputToken = base64Url
    .encode(List<int>.filled(32, 1))
    .replaceAll('=', '');
final outputKey = base64Url.encode(List<int>.filled(32, 2)).replaceAll('=', '');

Future<Connection> outputConnection(SharedClusterDatabase database) =>
    Connection.open(
      Endpoint(
        host: socketHostFor(
          database.socketPath,
          workingDirectory: Directory.current.path,
        ),
        port: database.port,
        database: database.name,
        username: 'postgres',
        isUnixSocket: true,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

Future<void> postOutputAlert(ChildServer child) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse(
        'http://127.0.0.1:${child.webPort}/hooks/alertmanager/$outputSource',
      ),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('Authorization', 'Bearer $outputToken');
    request.write(
      jsonEncode({
        'version': '4',
        'status': 'firing',
        'alerts': [
          {
            'status': 'firing',
            'labels': {'alertname': 'Recovery'},
            'annotations': <String, String>{},
            'startsAt': DateTime.now().toUtc().toIso8601String(),
          },
        ],
      }),
    );
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 202);
  } finally {
    client.close(force: true);
  }
}

Future<void> withOutputProcess(
  Future<void> Function(
    SharedClusterDatabase,
    Map<String, String>,
    HttpServer,
    List<ChildServer>,
  )
  action, {
  bool twoOutputs = false,
}) async {
  final database = await SharedClusterDatabase.create(Directory.current);
  final files = Directory.systemTemp.createTempSync(
    'correlia-output-recovery-',
  );
  final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final children = <ChildServer>[];
  try {
    final config = File('${files.path}/config.json')
      ..writeAsStringSync(
        jsonEncode({
          'format_version': 1,
          'revision': 1,
          'sources': [
            {
              'id': outputSource,
              'enabled': true,
              'token_ref': 'token',
              'output_ids': [outputId, if (twoOutputs) secondOutputId],
            },
          ],
          'outputs': [
            {
              'id': outputId,
              'kind': 'webhook',
              'url': 'http://127.0.0.1:${receiver.port}/healthy',
              'signing_key_ref': 'key',
            },
            if (twoOutputs)
              {
                'id': secondOutputId,
                'kind': 'webhook',
                'url': 'http://127.0.0.1:${receiver.port}/fail',
                'signing_key_ref': 'key',
              },
          ],
        }),
      );
    final secrets = File('${files.path}/secrets.json')
      ..writeAsStringSync(jsonEncode({'token': outputToken, 'key': outputKey}));
    final chmod = await Process.run('chmod', ['600', secrets.path]);
    if (chmod.exitCode != 0) throw StateError('chmod failed');
    await action(
      database,
      {
        'CORRELIA_INGEST_CONFIG': config.path,
        'CORRELIA_INGEST_SECRETS': secrets.path,
        'TEST_GATE_PATH': '${files.path}/gate',
      },
      receiver,
      children,
    );
  } finally {
    await tearDownChildren(children);
    await receiver.close(force: true);
    await database.drop();
    files.deleteSync(recursive: true);
  }
}

Future<ChildServer> startOutputChild(
  SharedClusterDatabase db,
  Map<String, String> env,
  List<ChildServer> children, {
  bool gated = false,
}) async {
  final child = await ChildServer.startOnSharedCluster(
    serverDir: Directory.current,
    database: db,
    environment: {
      'CORRELIA_INGEST_CONFIG': env['CORRELIA_INGEST_CONFIG']!,
      'CORRELIA_INGEST_SECRETS': env['CORRELIA_INGEST_SECRETS']!,
      if (gated) 'CORRELIA_TEST_RELAY_ACQUIRE_GATE': env['TEST_GATE_PATH']!,
    },
  );
  children.add(child);
  await child.waitUntilReady();
  return child;
}
