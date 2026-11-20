import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:postgres/postgres.dart';

import '../../test/support/child_server.dart';
import '../../test/support/shared_cluster.dart';

/// The Icinga2 source the capture's real Correlia child serves.
const captureSource = '33333333-3333-4333-8333-333333333333';

String _secret(int bytes) {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(bytes, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

/// One request the proxy or the recorder saw.
final class SeenRequest {
  SeenRequest({
    required this.id,
    required this.path,
    required this.auth,
    required this.body,
    required this.status,
    required this.newRawIds,
    this.credentials = const [],
  });

  final String id;
  final String path;

  /// `bearer`, `hmac` or `none`; the credential itself is never kept.
  final String auth;
  final Uint8List body;
  final int status;

  /// Raw rows that appeared while the request was forwarded.
  final List<String> newRawIds;

  /// The credential material the request carried (token, signature). Kept in
  /// memory only, to scan logs for it; never written to a fixture.
  final List<String> credentials;
}

/// What the raw row of an admitted request ended as.
final class RawResult {
  RawResult(this.id, this.status, this.outcome, this.failure, this.events);
  final String id;
  final String status;
  final Map<String, Object?>? outcome;
  final Map<String, Object?>? failure;
  final List<Map<String, Object?>> events;
}

/// A real Correlia child with one `icinga2` source, a reverse proxy in front
/// of it that records every request and which raw rows it created, and a
/// recording receiver that answers 202 to everything.
final class CorreliaRig {
  CorreliaRig._(
    this.database,
    this.files,
    this.child,
    this.connection,
    this.token,
    this.hmacKey,
  );

  static Future<CorreliaRig> start() async {
    final database = await SharedClusterDatabase.create(Directory.current);
    final files = Directory.systemTemp.createTempSync('icinga2-capture-');
    final token = _secret(32);
    final key = _secret(32);
    ChildServer? child;
    Connection? connection;
    try {
      File('${files.path}/config.json').writeAsStringSync(
        jsonEncode({
          'format_version': 2,
          'revision': 1,
          'outputs': <Object?>[],
          'sources': [
            {
              'id': captureSource,
              'kind': 'icinga2',
              'enabled': true,
              'credentials': [
                {'ref': 'token', 'type': 'bearer'},
                {'ref': 'key', 'type': 'hmac'},
              ],
              'output_ids': <Object?>[],
            },
          ],
        }),
      );
      final secrets = File('${files.path}/secrets.json')
        ..writeAsStringSync(jsonEncode({'token': token, 'key': key}));
      await Process.run('chmod', ['600', secrets.path]);
      child = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: database,
        environment: {
          'CORRELIA_INGEST_CONFIG': '${files.path}/config.json',
          'CORRELIA_INGEST_SECRETS': secrets.path,
        },
      );
      await child.waitUntilReady();
      connection = await Connection.open(
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
      return CorreliaRig._(database, files, child, connection, token, key);
    } catch (_) {
      await connection?.close();
      if (child != null) await tearDownChildren([child]);
      await database.drop();
      files.deleteSync(recursive: true);
      rethrow;
    }
  }

  final SharedClusterDatabase database;
  final Directory files;
  final ChildServer child;
  final Connection connection;

  /// The bearer token and HMAC key of this run (test-generated, never kept).
  final String token;
  final String hmacKey;

  HttpServer? _proxy;
  HttpServer? _receiver;
  final List<SeenRequest> proxied = [];
  final List<SeenRequest> received = [];
  int _ids = 0;
  Future<void> _chain = Future.value();

  /// When set, the proxy replaces a non-202 answer's body with this text,
  /// the way a reverse proxy that adds its own page would.
  String? injectedBodyOnRejection;

  int get proxyPort => _proxy!.port;
  int get receiverPort => _receiver!.port;

  Future<void> startListeners() async {
    _proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _proxy!.listen((request) {
      _chain = _chain.then((_) => _forward(request)).catchError((Object _) {});
    });
    _receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _receiver!.listen(_record);
  }

  static String _auth(HttpHeaders headers) {
    if (headers.value('authorization') != null) return 'bearer';
    if (headers.value('x-correlia-signature') != null) return 'hmac';
    return 'none';
  }

  Future<void> _forward(HttpRequest request) async {
    final body = Uint8List.fromList(
      await request.fold<List<int>>([], (a, b) => a..addAll(b)),
    );
    final before = await rawIds();
    final client = HttpClient()..autoUncompress = false;
    int status;
    List<int> answer;
    try {
      final upstream = await client.postUrl(
        Uri.parse('http://127.0.0.1:${child.webPort}${request.uri.path}'),
      );
      for (final name in [
        'content-type',
        'authorization',
        'x-correlia-timestamp',
        'x-correlia-signature',
      ]) {
        final value = request.headers.value(name);
        if (value != null) upstream.headers.set(name, value);
      }
      upstream.contentLength = body.length;
      upstream.add(body);
      final response = await upstream.close();
      status = response.statusCode;
      answer = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    } finally {
      client.close(force: true);
    }
    final after = await rawIds();
    proxied.add(
      SeenRequest(
        id: 'p${++_ids}',
        path: request.uri.path,
        auth: _auth(request.headers),
        body: body,
        status: status,
        newRawIds: after.difference(before).toList(),
        credentials: [
          for (final name in ['authorization', 'x-correlia-signature'])
            ?request.headers.value(name),
        ],
      ),
    );
    final text = injectedBodyOnRejection;
    if (status != 202 && text != null) {
      answer = utf8.encode(text);
    }
    request.response
      ..statusCode = status
      ..contentLength = answer.length
      ..add(answer);
    await request.response.close();
  }

  Future<void> _record(HttpRequest request) async {
    final body = Uint8List.fromList(
      await request.fold<List<int>>([], (a, b) => a..addAll(b)),
    );
    received.add(
      SeenRequest(
        id: 'r${++_ids}',
        path: request.uri.path,
        auth: _auth(request.headers),
        body: body,
        status: 202,
        newRawIds: const [],
      ),
    );
    request.response
      ..statusCode = 202
      ..contentLength = 0;
    await request.response.close();
  }

  // --- Database ---------------------------------------------------------

  Future<Set<String>> rawIds() async => {
    for (final row in await connection.execute(
      'SELECT raw_id::text FROM raw_inbox',
    ))
      row[0]! as String,
  };

  /// Waits until the raw row [id] is `done` or `failed` and returns it with
  /// its outcome, failure and the events it produced.
  Future<RawResult> rawResult(String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      final rows = await connection.execute(
        Sql.named(
          'SELECT status, outcome_json FROM raw_inbox '
          'WHERE raw_id = @id::uuid',
        ),
        parameters: {'id': id},
      );
      final status = rows.single[0]! as String;
      if (status == 'done' || status == 'failed') {
        final outcome = rows.single[1] as String?;
        Map<String, Object?>? failure;
        if (status == 'failed') {
          final f = await connection.execute(
            Sql.named(
              'SELECT "errorClass", "fieldPath" FROM pipeline_failures '
              'WHERE "rawId" = @id::uuid',
            ),
            parameters: {'id': id},
          );
          if (f.isNotEmpty) {
            failure = {'error_class': f.first[0], 'field_path': f.first[1]};
          }
        }
        final events = <Map<String, Object?>>[];
        final e = await connection.execute(
          Sql.named(
            'SELECT disposition, state_outcome, source_time, payload '
            'FROM events WHERE raw_id = @id::uuid ORDER BY event_id',
          ),
          parameters: {'id': id},
        );
        for (final row in e) {
          final payload = jsonDecode(
            utf8.decode(row[3]! as List<int>),
          );
          events.add({
            'disposition': row[0],
            'state_outcome': row[1],
            'source_time': (row[2]! as DateTime).toUtc().toIso8601String(),
            'cloud_event': payload,
          });
        }
        return RawResult(
          id,
          status,
          outcome == null ? null : jsonDecode(outcome) as Map<String, Object?>,
          failure,
          events,
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('raw row $id stayed $status');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// The committed alert row for [fingerprint], or null.
  Future<Map<String, Object?>?> alert(String fingerprint) async {
    final rows = await connection.execute(
      Sql.named(
        'SELECT status, severity, version, "fenceEventId", '
        '"fenceEffectiveSeconds", "fenceEffectiveNanos", summary '
        'FROM alerts WHERE fingerprint = @f',
      ),
      parameters: {'f': fingerprint},
    );
    if (rows.isEmpty) return null;
    final r = rows.single;
    return {
      'status': r[0],
      'severity': r[1],
      'version': r[2],
      'fence_event_id': r[3],
      'fence_effective_seconds': r[4],
      'fence_effective_nanos': r[5],
      'summary': r[6],
    };
  }

  /// Counts the events whose fingerprint is [fingerprint], by disposition.
  Future<Map<String, Object?>> eventCounts(String fingerprint) async {
    final rows = await connection.execute(
      'SELECT disposition, payload FROM events',
    );
    final byDisposition = <String, int>{};
    final byStatus = <String, int>{};
    var total = 0;
    for (final row in rows) {
      final event = CloudEvent.decode(
        Uint8List.fromList(row[1]! as List<int>),
      ).event;
      if (event.fingerprint != fingerprint) continue;
      total++;
      byDisposition.update(
        row[0]! as String,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      byStatus.update(event.status.name, (n) => n + 1, ifAbsent: () => 1);
    }
    return {
      'total': total,
      'by_disposition': byDisposition,
      'by_status': byStatus,
    };
  }

  Future<void> dispose() async {
    await _proxy?.close(force: true);
    await _receiver?.close(force: true);
    await connection.close();
    try {
      await tearDownChildren([child]);
    } finally {
      await database.drop();
      files.deleteSync(recursive: true);
    }
  }
}
