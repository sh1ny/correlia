@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_client/correlia_client.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/icinga2_stream_decode_fixture.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/output_process.dart';
import '../support/shared_cluster.dart';

const _source = '33333333-3333-4333-8333-333333333333';
const _password = 'echo-"\\-secret-\u00e9';
const _deadline = Duration(seconds: 60);
const _timeout = Timeout(Duration(minutes: 7));

String _encoded(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

final class _Upstream {
  _Upstream(this.server, this.ca);
  final HttpServer server;
  final List<int> ca;
  final connected = Completer<void>();
  final syncRequested = Completer<void>();
  final releaseSync = Completer<void>();
  final authFailed = Completer<void>();
  final sockets = <Socket>[];
  String services = '{"results":[]}';
  bool rejectNext = false;
  int authorized = 0;

  static Future<_Upstream> start() async {
    const fixtures = '../correlia_icinga2_notify/test/fixtures';
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain('$fixtures/server_one.pem')
        ..usePrivateKey('$fixtures/server_one.key'),
    );
    final upstream = _Upstream(
      server,
      await File('$fixtures/ca_one.pem').readAsBytes(),
    );
    server.listen(upstream.serve);
    return upstream;
  }

  Future<void> serve(HttpRequest request) async {
    await request.drain<void>();
    final expected =
        'Basic ${base64.encode(utf8.encode('correlia:$_password'))}';
    if (request.headers.value(HttpHeaders.authorizationHeader) != expected) {
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }
    authorized++;
    if (request.uri.path == '/v1/events') {
      if (rejectNext) {
        request.response.statusCode = 401;
        request.response.write('authentication rejected: $_password');
        await request.response.close();
        if (!authFailed.isCompleted) authFailed.complete();
        return;
      }
      final socket = await request.response.detachSocket(writeHeaders: false);
      sockets.add(socket);
      socket.listen((_) {}, onError: (Object _, StackTrace _) {});
      unawaited(
        socket.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      socket.write('HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n');
      await socket.flush();
      if (!connected.isCompleted) connected.complete();
    } else if (request.uri.path == '/v1/objects/hosts') {
      request.response.write('{"results":[]}');
      await request.response.close();
    } else if (request.uri.path == '/v1/objects/services') {
      if (!syncRequested.isCompleted) syncRequested.complete();
      await releaseSync.future;
      request.response.write(services);
      await request.response.close();
    } else {
      request.response.statusCode = 404;
      await request.response.close();
    }
  }

  Future<void> send(String line) async {
    await connected.future.timeout(_deadline);
    sockets.last.writeln(line);
    await sockets.last.flush();
  }

  Future<void> close() async {
    if (!releaseSync.isCompleted) releaseSync.complete();
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close(force: true);
  }
}

final class _Fixture {
  _Fixture(
    this.db,
    this.dir,
    this.upstream,
    this.connection,
    this.changes,
    this.receiver,
    this.deliveries,
    this.firstDelivery,
  ) {
    nextChange = changes.moveNext();
  }
  final SharedClusterDatabase db;
  final Directory dir;
  final _Upstream upstream;
  final Connection connection;
  final StreamIterator<Object?> changes;
  final HttpServer receiver;
  final List<String> deliveries;
  final Completer<void> firstDelivery;
  late Future<bool> nextChange;
  final children = <ChildServer>[];
  late ChildServer child;
  late String initialCursor;

  Future<void> start() async {
    final source = streamSource(_source);
    source['output_ids'] = [outputId];
    (source['api']! as Map<String, Object?>)['url'] =
        'https://127.0.0.1:${upstream.server.port}';
    final config = File('${dir.path}/config.json');
    final secrets = File('${dir.path}/secrets.json');
    final configData = streamBootstrap(1, [source]);
    configData['outputs'] = [
      {
        'id': outputId,
        'kind': 'webhook',
        'url': 'http://127.0.0.1:${receiver.port}/events',
        'signing_key_ref': 'output-key',
      },
    ];
    await config.writeAsString(jsonEncode(configData));
    await secrets.writeAsString(
      jsonEncode({
        'icinga-password': {'bytes': _encoded(utf8.encode(_password))},
        'icinga-ca': {'bytes': _encoded(upstream.ca)},
        'output-key': outputKey,
      }),
    );
    expect((await Process.run('chmod', ['0600', secrets.path])).exitCode, 0);
    child = await ChildServer.startOnSharedCluster(
      serverDir: Directory.current,
      database: db,
      logs: Directory('${dir.path}/logs'),
      environment: {
        'CORRELIA_INGEST_CONFIG': config.path,
        'CORRELIA_INGEST_SECRETS': secrets.path,
        'CORRELIA_SECRET_KEY_FILE': db.secretKeyFile,
      },
    );
    children.add(child);
    await child.waitUntilReady();
    await upstream.connected.future.timeout(_deadline);
    final api = Client('http://127.0.0.1:${child.apiPort}/');
    try {
      initialCursor = (await api.alertConsole.snapshot()).cursor;
    } finally {
      api.close();
    }
  }

  Future<void> until(Future<bool> Function() condition) async {
    await (() async {
      while (!await condition()) {
        if (!await nextChange) {
          throw StateError('database notifications closed');
        }
        nextChange = changes.moveNext();
      }
    })().timeout(_deadline);
  }

  Future<List<String>> admitted() async => (await connection.execute(
    'SELECT convert_from(body,\'UTF8\') FROM secret_test_admission ORDER BY seq',
  )).map((row) => row[0]! as String).toList();

  Future<void> scan() async {
    final passwordBytes = utf8.encode(_password);
    final forbidden = <String>{
      _password,
      jsonEncode(_password).substring(1, jsonEncode(_password).length - 1),
      base64.encode(passwordBytes),
      base64.encode(passwordBytes).replaceAll('=', ''),
      base64Url.encode(passwordBytes),
      _encoded(passwordBytes),
      utf8.decode(upstream.ca),
      base64.encode(upstream.ca),
      _encoded(upstream.ca),
      passwordBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      upstream.ca.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    };
    void absent(String text, String where) {
      for (final secret in forbidden) {
        expect(
          text.contains(secret),
          isFalse,
          reason: 'secret exposed in $where',
        );
      }
    }

    final api = Client('http://127.0.0.1:${child.apiPort}/');
    try {
      final snapshot = await api.alertConsole.snapshot();
      absent(jsonEncode(snapshot.toJson()), 'snapshot');
      final page = await api.alertConsole.feed(initialCursor, 100);
      absent(jsonEncode(page.toJson()), 'feed');
    } finally {
      api.close();
    }
    final http = HttpClient();
    try {
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:${child.apiPort}/icinga2Stream/status'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'sourceId': _source}));
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 200);
      absent(body, 'stream status response');
    } finally {
      http.close(force: true);
    }
    for (final path in ['/livez', '/readyz', '/startupz']) {
      for (final web in [false, true]) {
        final response = await child.fetch(path, web: web);
        expect(response?.status, 200);
        absent(response!.body, path);
      }
    }
    final console = await child.fetch('/', web: true);
    expect(console?.status, anyOf(200, 503));
    absent(console!.body, 'console');
    expect(await child.closeStdin(), 0);
    for (final delivery in deliveries) {
      absent(delivery, 'webhook delivery');
    }
    expect(
      await connection.execute('SELECT 1 FROM serverpod_session_log'),
      isNotEmpty,
    );
    final tables = await connection.execute(
      "SELECT format('%I.%I',schemaname,tablename) FROM pg_tables WHERE schemaname='public'",
    );
    expect(tables.length, greaterThan(10));
    for (final row in tables) {
      final table = row[0]! as String;
      for (final record in await connection.execute(
        'SELECT to_jsonb(t)::text FROM $table t',
      )) {
        absent(record[0]! as String, table);
      }
    }
    for (final table in [
      'raw_inbox',
      'events',
      'outbox',
      'secret_test_admission',
    ]) {
      final column = table == 'events' || table == 'outbox'
          ? 'payload'
          : 'body';
      for (final row in await connection.execute(
        "SELECT convert_from($column,'UTF8') FROM $table",
      )) {
        final text = row[0]! as String;
        absent(text, table);
        if (table == 'raw_inbox' || table == 'secret_test_admission') {
          final wrapper = jsonDecode(text) as Map<String, Object?>;
          for (final item in (wrapper['items'] as List<Object?>? ?? [])) {
            final map = item! as Map<String, Object?>;
            if (map['line_b64'] case final String line) {
              absent(
                utf8.decode(base64.decode(line), allowMalformed: true),
                '$table decoded line',
              );
            }
            if (map['line'] case final String line) {
              absent(line, '$table line');
              try {
                absent(jsonEncode(jsonDecode(line)), '$table decoded JSON');
              } on FormatException {
                /* malformed line */
              }
            }
          }
        }
      }
    }
    absent(child.output, 'captured output');
    await for (final file in Directory('${dir.path}/logs').list()) {
      if (file is File) absent(await file.readAsString(), 'child log');
    }
  }
}

Future<void> _withFixture(Future<void> Function(_Fixture) run) async {
  final database = await SharedClusterDatabase.create(Directory.current);
  final dir = await Directory.systemTemp.createTemp('stream-secret-e2e-');
  final upstream = await _Upstream.start();
  final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final deliveries = <String>[];
  final firstDelivery = Completer<void>();
  receiver.listen((request) async {
    deliveries.add(await utf8.decoder.bind(request).join());
    request.response.statusCode = 204;
    await request.response.close();
    if (!firstDelivery.isCompleted) firstDelivery.complete();
  });
  final connection = await outputConnection(database);
  final children = <ChildServer>[];
  StreamIterator<Object?>? changes;
  try {
    final bootstrap = await ChildServer.startOnSharedCluster(
      serverDir: Directory.current,
      database: database,
    );
    children.add(bootstrap);
    await bootstrap.waitUntilReady();
    expect(await bootstrap.closeStdin(), 0);
    await connection.execute(
      'CREATE TABLE secret_test_admission (seq bigserial, body bytea NOT NULL)',
    );
    await connection.execute(
      '''CREATE FUNCTION secret_test_notify() RETURNS trigger LANGUAGE plpgsql AS \$\$
      BEGIN
        IF TG_TABLE_NAME = 'raw_inbox' AND TG_OP = 'INSERT' THEN
          INSERT INTO secret_test_admission(body) VALUES (NEW.body);
        END IF;
        PERFORM pg_notify('secret_test_change', TG_TABLE_NAME);
        RETURN NULL;
      END \$\$''',
    );
    await connection.execute(
      'CREATE TRIGGER secret_test_raw AFTER INSERT OR UPDATE OR DELETE ON raw_inbox FOR EACH ROW EXECUTE FUNCTION secret_test_notify()',
    );
    await connection.execute(
      'CREATE TRIGGER secret_test_sync AFTER INSERT OR UPDATE ON icinga2_sync_progress FOR EACH ROW EXECUTE FUNCTION secret_test_notify()',
    );
    await connection.execute(
      'CREATE TRIGGER secret_test_event AFTER INSERT ON events FOR EACH ROW EXECUTE FUNCTION secret_test_notify()',
    );
    await connection.execute(
      'CREATE TRIGGER secret_test_status AFTER INSERT OR UPDATE ON icinga2_stream_status FOR EACH ROW EXECUTE FUNCTION secret_test_notify()',
    );
    await connection.execute('LISTEN secret_test_change');
    changes = StreamIterator<Object?>(
      connection.channels.all.where(
        (event) => event.channel == 'secret_test_change',
      ),
    );
    final fixture = _Fixture(
      database,
      dir,
      upstream,
      connection,
      changes,
      receiver,
      deliveries,
      firstDelivery,
    );
    try {
      await run(fixture);
    } finally {
      await tearDownChildren(fixture.children);
    }
  } finally {
    await changes?.cancel();
    await tearDownChildren(children);
    await upstream.close();
    await receiver.close(force: true);
    await connection.close();
    await database.drop();
    await dir.delete(recursive: true);
  }
}

Map<String, Object?> _withOutput(Map<String, Object?> object, String output) {
  final attrs = object['attrs']! as Map<String, Object?>;
  final check = attrs['last_check_result']! as Map<String, Object?>;
  check['output'] = output;
  return object;
}

String _escaped(Object? value) =>
    jsonEncode(value).replaceAll('echo-', r'\u0065cho-');

void main() {
  test(
    'password_echoed_after_a_successful_subscription',
    () => _withFixture((f) async {
      await f.start();
      final ack = capturedStreamEvents(
        streamCaptures.last,
      ).firstWhere((e) => e['type'] == 'AcknowledgementSet');
      ack['comment'] = 'before $_password after';
      await f.upstream.send('{"broken":"$_password');
      await f.upstream.send(jsonEncode(ack));
      f.upstream.releaseSync.complete();
      await f.until(
        () async =>
            (await f.admitted()).length >= 2 &&
            (await f.connection.execute(
              "SELECT 1 FROM raw_inbox WHERE status='failed'",
            )).isNotEmpty &&
            (await f.connection.execute('SELECT 1 FROM events')).isNotEmpty,
      );
      final bodies = await f.admitted();
      expect(
        bodies.where((s) => s.contains('redacted')),
        hasLength(greaterThanOrEqualTo(2)),
      );
      await f.firstDelivery.future.timeout(_deadline);
      await f.scan();
    }),
    timeout: _timeout,
  );

  test(
    'password_echoed_in_a_sync_object',
    () => _withFixture((f) async {
      final object = _withOutput(
        streamDbCheck(DateTime.now().toUtc(), sync: true),
        'before $_password after',
      );
      f.upstream.services = jsonEncode({
        'results': [object],
      });
      await f.start();
      f.upstream.releaseSync.complete();
      await f.until(
        () async => (await f.connection.execute(
          "SELECT 1 FROM icinga2_sync_progress WHERE phase='complete'",
        )).isNotEmpty,
      );
      expect((await f.admitted()).single, contains('redacted'));
      expect(await f.connection.execute('SELECT 1 FROM raw_inbox'), isNotEmpty);
      expect(await f.connection.execute('SELECT 1 FROM events'), isNotEmpty);
      await f.firstDelivery.future.timeout(_deadline);
      await f.scan();
    }),
    timeout: _timeout,
  );

  test(
    'escaped_password_is_redacted_in_stream_and_sync',
    () => _withFixture((f) async {
      final object = _withOutput(
        streamDbCheck(DateTime.now().toUtc(), sync: true, host: 'repair-host'),
        'before $_password after',
      );
      f.upstream.services = _escaped({
        'results': [object],
      });
      await f.start();
      final ack = capturedStreamEvents(
        streamCaptures.last,
      ).firstWhere((e) => e['type'] == 'AcknowledgementSet');
      ack['comment'] = 'before $_password after';
      await f.upstream.send(_escaped(ack));
      f.upstream.releaseSync.complete();
      await f.until(
        () async =>
            (await f.admitted()).length >= 2 &&
            (await f.connection.execute(
              "SELECT 1 FROM icinga2_sync_progress WHERE phase='complete'",
            )).isNotEmpty &&
            ((await f.connection.execute(
                      'SELECT count(*) FROM events',
                    )).single[0]!
                    as int) >=
                2,
      );
      expect(
        (await f.admitted()).where((s) => s.contains('redacted')),
        hasLength(greaterThanOrEqualTo(2)),
      );
      expect(await f.connection.execute('SELECT 1 FROM events'), isNotEmpty);
      await f.firstDelivery.future.timeout(_deadline);
      await f.scan();
    }),
    timeout: _timeout,
  );

  test(
    'escaped_sync_echo_does_not_keep_eventless_rows',
    () => _withFixture((f) async {
      final now = DateTime.now().toUtc();
      final confirm = _withOutput(
        streamDbCheck(now.add(const Duration(milliseconds: 1)), sync: true),
        'before $_password after',
      );
      final invalid = _withOutput(
        streamDbCheck(now, sync: true, host: 'invalid-host'),
        'before $_password after',
      );
      invalid['unknown_field'] = true;
      f.upstream.services = _escaped({
        'results': [confirm, invalid],
      });
      await f.start();
      await f.upstream.syncRequested.future.timeout(_deadline);
      await f.upstream.send(jsonEncode(streamDbCheck(now)));
      await f.until(
        () async =>
            (await f.connection.execute('SELECT 1 FROM alerts')).isNotEmpty,
      );
      f.upstream.releaseSync.complete();
      await f.until(
        () async => (await f.connection.execute(
          """SELECT 1 FROM icinga2_sync_progress
             WHERE ended_at IS NOT NULL AND rows_done+rows_failed=rows_admitted""",
        )).isNotEmpty,
      );
      expect(
        (await f.connection.execute(
          "SELECT counts->>'confirmed' FROM icinga2_sync_progress",
        )).single.single,
        '1',
      );
      final admitted = await f.admitted();
      expect(admitted.where((s) => s.contains('redacted')), hasLength(1));
      expect(admitted.join(), isNot(contains('invalid-host')));
      expect(
        await f.connection.execute(
          "SELECT 1 FROM raw_inbox r JOIN icinga2_raw_origin o ON o.raw_id=r.raw_id WHERE o.origin='sync'",
        ),
        isEmpty,
      );
      await f.scan();
    }),
    timeout: _timeout,
  );

  test(
    'stream_password_and_ca',
    () => _withFixture((f) async {
      await f.start();
      f.upstream.releaseSync.complete();
      await f.upstream.syncRequested.future.timeout(_deadline);
      expect(f.upstream.authorized, greaterThanOrEqualTo(2));
      f.upstream.rejectNext = true;
      f.upstream.sockets.last.destroy();
      await f.upstream.authFailed.future.timeout(_deadline);
      await f.until(
        () async => (await f.connection.execute(
          "SELECT 1 FROM icinga2_stream_status WHERE \"lastErrorClass\"='unauthorized'",
        )).isNotEmpty,
      );
      final records = await f.connection.execute(
        "SELECT algorithm, octet_length(nonce), commitment FROM secret_record WHERE reference IN ('icinga-password','icinga-ca')",
      );
      expect(records, hasLength(2));
      for (final record in records) {
        expect(record[0], 'aes-256-gcm-v1');
        expect(record[1], 12);
        expect(record[2], startsWith('hmac-sha256:'));
      }
      await f.scan();
    }),
    timeout: _timeout,
  );
}
