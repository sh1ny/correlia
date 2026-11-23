import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/event.dart' show CloudEvent;
import 'package:postgres/postgres.dart';

import '../../test/support/child_server.dart';
import '../../test/support/shared_cluster.dart';
import 'lab.dart';

const _source = '33333333-3333-4333-8333-333333333333';
const _deadline = Duration(seconds: 18);
const _syncOutput = 'correlia release matrix initial state';
const _streamOutput = 'correlia release matrix live recovery';

typedef _ObservedCheck = ({
  String fingerprint,
  String status,
  String id,
  Map<String, Object?> timing,
});

/// Captures the real Correlia worker against the Icinga lab and its exact grants.
Future<Map<String, Object?>> captureBuiltConsumer({
  required IcingaLab lab,
  required String executable,
  required List<String> grants,
  required Map<String, Object?> upstreamDenials,
}) async {
  final ca = await lab.readFile('/var/lib/icinga2/certs/ca.crt');
  await _submit(lab, 0, 'correlia release matrix baseline');
  final observed = await _withWorker(lab, executable, ca, 'correlia-stream', (
    db,
    child,
  ) async {
    await _firstSync(db, child);
    await _submit(lab, 2, _syncOutput);
    return _event(db, child, 'stream', _syncOutput);
  });
  final positive = await _withWorker(lab, executable, ca, 'correlia-stream', (
    db,
    child,
  ) async {
    await _firstSync(db, child);
    final sync = await _event(db, child, 'sync', _syncOutput);
    await _submit(lab, 0, _streamOutput);
    final recovery = await _event(db, child, 'stream', _streamOutput);
    if (sync.fingerprint != observed.fingerprint ||
        sync.id != observed.id ||
        sync.fingerprint != recovery.fingerprint ||
        sync.status != 'firing' ||
        recovery.status != 'resolved') {
      throw StateError(
        'The same check did not yield one identity through stream and sync: '
        'stream=$observed, sync=$sync, recovery=$recovery',
      );
    }
    return {
      'consumer_status': 'connected',
      'first_sync': 'complete',
      'before_recovery': sync.status,
      'after_recovery': recovery.status,
      'paired_service': {
        'sync': {'fingerprint': sync.fingerprint, 'event_id': sync.id},
        'stream': {
          'fingerprint': observed.fingerprint,
          'event_id': observed.id,
        },
      },
    };
  });

  final missing = <String, Object?>{};
  for (final (i, grant) in grants.indexed) {
    final upstream = upstreamDenials[grant]! as Map<String, Object?>;
    final phase = upstream['phase']! as String;
    final code = upstream['status']! as int;
    final expected = switch (code) {
      403 => 'forbidden',
      404 => 'http_status',
      _ => throw StateError(
        'Unexpected upstream status for omitted $grant: $code',
      ),
    };
    missing[grant] = await _withWorker(lab, executable, ca, 'omit-$i', (
      db,
      child,
    ) async {
      // A fast first refusal can already be followed by a reconnect when
      // readiness returns. Verify the logged transition and its durable effects.
      final backoff = RegExp(
        'icinga2-stream source=$_source backoff ([a-z_]+)',
      );
      late String error;
      late ResultRow proof;
      await _wait(child, () async {
        final rows = await db.execute(
          Sql.named('''
            SELECT s."gapCount",
              (SELECT count(*) FROM icinga2_sync_progress),
              (SELECT count(*) FROM icinga2_sync_progress WHERE phase='complete'),
              (SELECT count(*) FROM icinga2_sync_progress WHERE phase='failed' AND read_problem=@expected)
            FROM icinga2_stream_status s
          '''),
          parameters: {'expected': expected},
        );
        final transition = backoff.firstMatch(child.output);
        if (rows.isEmpty || transition == null) return false;
        proof = rows.single;
        error = transition.group(1)!;
        return true;
      }, 'backoff on omitted $grant');
      final started = proof[1]! as int;
      final complete = proof[2]! as int;
      final failedWithClass = proof[3]! as int;
      if (error != expected ||
          proof[0] == 0 ||
          complete != 0 ||
          (phase == 'subscription'
              ? started != 0
              : started == 0 || failedWithClass != started)) {
        throw StateError(
          'Omitted $grant ($phase HTTP $code) gave $error and ${proof.toList()}, expected $expected with no successful first sync',
        );
      }
      return {
        'phase': phase,
        'upstream_status': code,
        'error_class': error,
        'sync_started': started > 0,
        'successful_first_sync': false,
      };
    });
  }
  return {...positive, 'permission_denials': missing};
}

Future<void> _firstSync(Connection db, ChildServer child) => _wait(
  child,
  () async => (await db.execute('''
      SELECT 1 FROM icinga2_stream_status s JOIN icinga2_sync_progress p ON p.sync_id=s."lastSyncId"
      WHERE s.state='connected' AND p.phase='complete' AND p.rows_done=p.rows_admitted
    ''')).isNotEmpty,
  'first sync completed',
);

Future<void> _submit(IcingaLab lab, int state, String output) async {
  final at = DateTime.now().microsecondsSinceEpoch / 1000000;
  final result = await lab.ok(
    'POST',
    '/v1/actions/process-check-result',
    body: {
      'type': 'Service',
      'filter':
          'host.name == "stream-host" && service.name == "stream-service"',
      'exit_status': state,
      'plugin_output': output,
      'execution_start': at,
      'execution_end': at,
    },
  );
  if (result['code'] != 200)
    throw StateError('Icinga did not apply the matrix check');
}

Future<_ObservedCheck> _event(
  Connection db,
  ChildServer child,
  String origin,
  String marker,
) async {
  late ResultRow event;
  await _wait(child, () async {
    final rows = await db.execute(
      Sql.named('''
      SELECT d.payload, d.raw
      FROM (
        SELECT e.payload, convert_from(e.payload,'UTF8')::jsonb AS item, convert_from(r.body,'UTF8') AS raw
        FROM events e JOIN icinga2_raw_origin o ON e.raw_id=o.raw_id
        JOIN raw_inbox r ON r.raw_id=e.raw_id AND r.observed_at=e.raw_observed_at
        WHERE o.origin=@origin
      ) d WHERE d.item->'data'->>'description'=@marker
    '''),
      parameters: {'origin': origin, 'marker': marker},
    );
    if (rows.isEmpty) return false;
    event = rows.single;
    return true;
  }, '$origin event through Correlia');
  final canonical = CloudEvent.decode(event[0]! as Uint8List).event;
  final raw = jsonDecode(event[1]! as String) as Map<String, Object?>;
  final items = (raw['items']! as List<Object?>).cast<Map<String, Object?>>();
  final checks = items.map((item) {
    final wire = jsonDecode(item['line']! as String) as Map<String, Object?>;
    return (origin == 'sync'
            ? (wire['attrs']! as Map<String, Object?>)['last_check_result']
            : wire['check_result'])
        as Map<String, Object?>?;
  });
  final check = checks.singleWhere((check) => check?['output'] == marker)!;
  return (
    fingerprint: canonical.fingerprint,
    status: canonical.status.name,
    id: canonical.eventId,
    timing: {
      'execution_start': check['execution_start'],
      'execution_end': check['execution_end'],
      'vars_after': check['vars_after'],
    },
  );
}

Future<void> _wait(
  ChildServer child,
  Future<bool> Function() action,
  String label,
) async {
  final watch = Stopwatch()..start();
  while (!await action()) {
    if (child.hasExited || watch.elapsed >= _deadline) {
      throw StateError('Did not observe $label:\n${child.output}');
    }
  }
}

String _unpadded(List<int> value) => base64UrlEncode(value).replaceAll('=', '');

Future<T> _withWorker<T>(
  IcingaLab lab,
  String executable,
  String ca,
  String user,
  Future<T> Function(Connection, ChildServer) action,
) async {
  final server = Directory.current;
  final db = await SharedClusterDatabase.create(server);
  final files = Directory.systemTemp.createTempSync('correlia-release-stream-');
  ChildServer? child;
  Connection? connection;
  try {
    final config = File('${files.path}/ingest.json')
      ..writeAsStringSync(
        jsonEncode({
          'format_version': 2,
          'revision': 1,
          'outputs': <Object?>[],
          'sources': [
            {
              'id': _source,
              'kind': 'icinga2',
              'mode': 'event_streams',
              'enabled': true,
              'output_ids': <String>[],
              'state_type_policy': 'soft_and_hard',
              'api': {
                'url': 'https://localhost:${lab.apiPort}',
                'username': user,
                'password_ref': 'matrix-password',
                'ca_ref': 'matrix-ca',
              },
            },
          ],
        }),
      );
    final secret = File('${files.path}/secrets.json')
      ..writeAsStringSync(
        jsonEncode({
          'matrix-password': {'bytes': _unpadded(utf8.encode(lab.apiPassword))},
          'matrix-ca': {'bytes': _unpadded(utf8.encode(ca))},
        }),
      );
    if ((await Process.run('chmod', ['600', secret.path])).exitCode != 0) {
      throw StateError('Could not protect the capture secrets file');
    }
    child = await ChildServer.startOnSharedCluster(
      serverDir: server,
      database: db,
      executable: executable,
      args: [
        '--mode',
        'test',
        '--apply-migrations',
        '--process-role',
        'worker',
      ],
      environment: {
        'CORRELIA_INGEST_CONFIG': config.path,
        'CORRELIA_INGEST_SECRETS': secret.path,
      },
    );
    await child.waitUntilReady();
    connection = await Connection.open(
      Endpoint(
        host: socketHostFor(db.socketPath, workingDirectory: server.path),
        port: db.port,
        database: db.name,
        username: 'postgres',
        isUnixSocket: true,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    return await action(connection, child);
  } finally {
    try {
      if (child != null) await tearDownChildren([child]);
    } finally {
      try {
        await connection?.close();
      } finally {
        try {
          await db.drop();
        } finally {
          files.deleteSync(recursive: true);
        }
      }
    }
  }
}
