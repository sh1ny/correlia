@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../db/ingest_config_test.dart' as fixture;
import '../support/shared_cluster.dart';

const _source = '11111111-1111-4111-8111-111111111111';
const _output = '22222222-2222-4222-8222-222222222222';
final _token = base64Url.encode(List<int>.filled(32, 1)).replaceAll('=', '');
final _other = base64Url.encode(List<int>.filled(32, 2)).replaceAll('=', '');

Future<void> _withServer(
  Future<void> Function(ChildServer, pg.Connection) action, {
  bool configured = true,
}) async {
  final database = await SharedClusterDatabase.create(Directory.current);
  final files = Directory.systemTemp.createTempSync('correlia-ingress-');
  ChildServer? child;
  pg.Connection? connection;
  try {
    final config = File('${files.path}/config.json')
      ..writeAsStringSync(
        jsonEncode({
          'format_version': 1,
          'revision': 1,
          'sources': [
            {
              'id': _source,
              'enabled': true,
              'token_ref': 'token',
              'path_token_enabled': true,
              'output_ids': [_output],
            },
          ],
          'outputs': [
            {
              'id': _output,
              'kind': 'webhook',
              'url': 'http://127.0.0.1:9099/events',
              'signing_key_ref': 'key',
            },
          ],
        }),
      );
    final secrets = File('${files.path}/secrets.json')
      ..writeAsStringSync(jsonEncode({'token': _token, 'key': _other}));
    final chmod = await Process.run('mise', [
      'exec',
      '--',
      'chmod',
      '600',
      secrets.path,
    ]);
    if (chmod.exitCode != 0) throw StateError('Cannot protect fixture secrets');
    child = await ChildServer.startOnSharedCluster(
      serverDir: Directory.current,
      database: database,
      environment: configured
          ? {
              'CORRELIA_INGEST_CONFIG': config.path,
              'CORRELIA_INGEST_SECRETS': secrets.path,
            }
          : {},
    );
    await child.waitUntilReady();
    connection = await pg.Connection.open(
      pg.Endpoint(
        host: database.socketPath,
        port: database.port,
        database: database.name,
        username: 'postgres',
        isUnixSocket: true,
      ),
      settings: const pg.ConnectionSettings(sslMode: pg.SslMode.disable),
    );
    await action(child, connection);
  } finally {
    await connection?.close();
    if (child != null) await tearDownChildren([child]);
    await database.drop();
    files.deleteSync(recursive: true);
  }
}

Future<int> _post(
  ChildServer child,
  String path, {
  String? bearer,
  List<int> body = const [123, 125],
  bool chunked = false,
  String? encoding,
  String? key,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${child.webPort}$path'),
    );
    request.headers.contentType = ContentType.json;
    if (bearer != null) request.headers.set('Authorization', 'Bearer $bearer');
    if (encoding != null) request.headers.set('Content-Encoding', encoding);
    if (key != null) request.headers.set('Idempotency-Key', key);
    if (!chunked) request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<int> _rawStatus(ChildServer child, String target) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    child.webPort,
  );
  try {
    socket.write(
      'POST $target HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
    );
    final response = await socket
        .cast<List<int>>()
        .transform(latin1.decoder)
        .join();
    return int.parse(response.split(' ').elementAt(1));
  } finally {
    socket.destroy();
  }
}

void main() {
  final path = '/hooks/alertmanager/$_source';
  test(
    'authenticated_source_delivery',
    () => _withServer((child, db) async {
      expect(await _post(child, path, bearer: _token), 202);
      expect((await db.execute('SELECT count(*) FROM raw_inbox')).single[0], 1);
    }),
  );
  test(
    'sec_1_another_source_token',
    () => _withServer((child, db) async {
      expect(await _post(child, path, bearer: _other), 401);
      expect(await _post(child, path), 401);
      expect((await db.execute('SELECT count(*) FROM raw_inbox')).single[0], 0);
    }),
  );
  test(
    'sec_5_path_token_redaction',
    () => _withServer((child, db) async {
      expect(await _post(child, '$path/$_token'), 202);
      expect(await _post(child, '$path/$_other'), 401);
      await db.execute(
        "ALTER TABLE raw_inbox ADD CONSTRAINT ingress_fail CHECK (content_type <> 'application/json') NOT VALID",
      );
      try {
        expect(await _post(child, '$path/$_token', body: [1]), 503);
        expect(
          (await db.execute('SELECT count(*) FROM raw_inbox')).single[0],
          1,
        );
        expect(
          (await db.execute('SELECT count(*) FROM transport_keys')).single[0],
          1,
        );
      } finally {
        await db.execute('ALTER TABLE raw_inbox DROP CONSTRAINT ingress_fail');
      }
      expect(
        await _post(child, '$path/$_token?probe=SYNTHETIC_QUERY_SECRET'),
        400,
      );
      expect(
        await _rawStatus(
          child,
          '$path/SYNTHETIC_PATH_TOKEN/%FF?probe=SYNTHETIC_QUERY_SECRET',
        ),
        400,
      );
      expect(
        await _rawStatus(
          child,
          '$path/SYNTHETIC_PATH_TOKEN?probe=SYNTHETIC_QUERY_SECRET%FF',
        ),
        400,
      );
      expect(child.output, isNot(contains('SYNTHETIC_PATH_TOKEN')));
      expect(child.output, isNot(contains(_token)));
      expect(child.output, isNot(contains(_other)));
      expect(child.output, isNot(contains('SYNTHETIC_QUERY_SECRET')));
      final metadata = (await db.execute(
        'SELECT row_to_json(s)::text FROM serverpod_session_log s',
      )).map((row) => row[0]).join();
      expect(
        metadata,
        isNot(
          anyOf(
            contains(_token),
            contains(_other),
            contains('SYNTHETIC_QUERY_SECRET'),
          ),
        ),
      );
    }),
  );
  test(
    'conflicting_credentials',
    () => _withServer((child, db) async {
      expect(await _post(child, '$path/$_token', bearer: _token), 401);
      expect((await db.execute('SELECT count(*) FROM raw_inbox')).single[0], 0);
    }),
  );
  test(
    'accepted_body_above_endpoint_default',
    () => _withServer((child, db) async {
      final body = List<int>.filled(600 * 1024, 32);
      expect(await _post(child, path, bearer: _token, body: body), 202);
      final row = (await db.execute(
        "SELECT encode(body, 'hex'), body_sha256 FROM raw_inbox",
      )).single;
      expect(
        row[0],
        body.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      );
      expect(row[1], sha256.convert(body).toString());
    }),
  );
  test(
    'chunked_oversized_delivery',
    () => _withServer((child, db) async {
      expect(
        await _post(
          child,
          path,
          bearer: _token,
          body: List<int>.filled(1024 * 1024 + 1, 32),
          chunked: true,
        ),
        413,
      );
      expect(await _post(child, path, bearer: _token, encoding: 'gzip'), 415);
      expect((await db.execute('SELECT count(*) FROM raw_inbox')).single[0], 0);
    }),
  );
  test(
    'concurrent_http_retries_and_conflict',
    () => _withServer((child, db) async {
      final responses = await Future.wait([
        _post(child, path, bearer: _token, key: 'delivery'),
        _post(child, path, bearer: _token, key: 'delivery'),
      ]);
      expect(responses, [202, 202]);
      expect(
        await _post(child, path, bearer: _token, key: 'delivery', body: [1]),
        409,
      );
      expect((await db.execute('SELECT count(*) FROM raw_inbox')).single[0], 1);
    }),
  );
  test(
    'remote_publication_rekeys_ingress',
    () => _withServer((child, db) async {
      expect(await _post(child, path, bearer: _token), 202);
      final next = fixture.input(2, includeSource: false);
      await db.runTx((tx) async {
        await tx.execute(
          pg.Sql.named(
            'INSERT INTO ingest_config_snapshot ("snapshotId", revision, "publicJson") VALUES (@id:text, 2, @json:text)',
          ),
          parameters: {'id': next.snapshotId, 'json': next.publicJson},
        );
        await tx.execute('UPDATE ingest_source SET enabled=false');
        await tx.execute(
          pg.Sql.named(
            'UPDATE ingest_active_config SET "snapshotId"=@id:text WHERE singleton=1',
          ),
          parameters: {'id': next.snapshotId},
        );
      });
      expect(await _post(child, path, bearer: _token), 401);
      expect((await db.execute('SELECT count(*) FROM raw_inbox')).single[0], 1);
    }),
  );
  test(
    'unconfigured_ingress_still_protects_token_paths',
    () => _withServer((child, db) async {
      expect(
        await _post(
          child,
          '$path/SYNTHETIC_PATH_TOKEN?probe=SYNTHETIC_QUERY_SECRET',
        ),
        503,
      );
      expect(child.output, isNot(contains('SYNTHETIC_PATH_TOKEN')));
      expect(child.output, isNot(contains('SYNTHETIC_QUERY_SECRET')));
    }, configured: false),
  );
}
