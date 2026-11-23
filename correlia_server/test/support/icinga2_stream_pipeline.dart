import 'dart:convert';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:serverpod/serverpod.dart';

import 'icinga2_pipeline.dart';
import 'icinga2_stream_decode_fixture.dart';
import 'icinga2_stream_fixture.dart';
import 'secret_fixture.dart';

final streamDbNow = DateTime.utc(2026, 11, 23, 12);
const streamDbSyncId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

/// Publishes a stream source with one loopback output to inspect in the outbox.
Future<String> publishStreamDb(
  Session session, {
  int revision = 1,
  String policy = 'soft_and_hard',
  bool shared = false,
  bool routed = true,
  String apiUrl = 'https://icinga.example:5665',
}) async {
  final source = streamSource(icinga2DbSourceId)
    ..['state_type_policy'] = policy
    ..['output_ids'] = routed ? [icinga2DbOutputIds.first] : <String>[];
  (source['api']! as Map<String, Object?>)['url'] = apiUrl;
  if (shared) source['namespace'] = icinga2SharedNamespace;
  final config = streamBootstrap(revision, [
    source,
    if (shared)
      {
        'id': icinga2OtherDbSourceId,
        'kind': 'icinga2',
        'enabled': true,
        'namespace': icinga2SharedNamespace,
        'credentials': [
          {'ref': 'stream-fixture-webhook', 'type': 'bearer'},
        ],
        'output_ids': [icinga2DbOutputIds.first],
      },
  ]);
  if (shared) config['namespaces'] = [icinga2SharedNamespace];
  config['outputs'] = [
    {
      'id': icinga2DbOutputIds.first,
      'kind': 'webhook',
      'url': 'http://127.0.0.1:9191/events',
      'signing_key_ref': 'stream-output-key',
    },
  ];
  final snapshot =
      await IngestConfigRepository(
        session,
        secretStore: testSecretStore,
      ).publishConfig(
        config,
        {
          ...streamMaterial(),
          'stream-output-key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          if (shared)
            'stream-fixture-webhook':
                'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE',
        },
        runMode: 'test',
        clock: () => streamDbNow,
      );
  return snapshot.snapshotId;
}

/// Makes a check with controlled state and timing over the captured wire shape.
Map<String, Object?> streamDbCheck(
  DateTime time, {
  int state = 2,
  int stateType = 1,
  String host = 'stream-host',
  String? service = 'stream-service',
  bool sync = false,
}) {
  final fixture = capturedStreamEvents(streamCaptures.last).first;
  final seconds = time.microsecondsSinceEpoch / 1000000;
  final check = {
    ...fixture['check_result']! as Map<String, Object?>,
    'execution_start': seconds,
    'execution_end': seconds,
    'vars_after': {'state': state, 'state_type': stateType, 'reachable': true},
  };
  if (sync) {
    return {
      'type': service == null ? 'Host' : 'Service',
      'name': service == null ? host : '$host!$service',
      'joins': {},
      'meta': {},
      'attrs': {
        'name': service ?? host,
        if (service != null) 'host_name': host,
        'last_check_result': check,
      },
    };
  }
  return {
    ...fixture,
    'timestamp': seconds,
    'host': host,
    'service': ?service,
    'check_result': check,
  };
}

/// Seeds the trusted admission record; these tests start at the pipeline boundary.
Future<String> seedStreamDb(
  Session session,
  String snapshot,
  List<Map<String, Object?>> values, {
  bool sync = false,
  DateTime? observed,
  String syncId = streamDbSyncId,
  String Function(Map<String, Object?>) encodeLine = jsonEncode,
}) async {
  final receipt = observed ?? streamDbNow;
  final origin = sync ? 'sync' : 'stream';
  final raw = await seedIcinga2(session, {
    'format': 'correlia.icinga2.stream.v1',
    'origin': origin,
    'connection': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    if (sync) 'sync': syncId,
    'items': [
      for (final value in values)
        {'received': receipt.microsecondsSinceEpoch, 'line': encodeLine(value)},
    ],
  }, receipt);
  await session.db.unsafeExecute(
    '''INSERT INTO icinga2_raw_origin
    (raw_id,origin,sync_id,admission_snapshot_id)
    VALUES (CAST(@raw AS uuid),@origin,CAST(@sync AS uuid),@snapshot)''',
    parameters: QueryParameters.named({
      'raw': raw,
      'origin': origin,
      'sync': sync ? syncId : null,
      'snapshot': snapshot,
    }),
  );
  return raw;
}
