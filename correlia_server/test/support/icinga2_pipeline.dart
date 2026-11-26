import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import '../db/ingest_config_test.dart' show token;
import 'icinga2_delivery.dart';
import 'ingest_schema.dart';
import 'secret_fixture.dart';

/// The Icinga2 source the db tests deliver to.
const icinga2DbSourceId = '33333333-3333-4333-8333-333333333333';

/// A second Icinga2 source, published only when a test asks for it.
const icinga2OtherDbSourceId = '55555555-5555-4555-8555-555555555555';

/// The namespace both sources share when a test asks for two.
const icinga2SharedNamespace = 'shared-icinga2';

/// The two outputs that source routes to.
const icinga2DbOutputIds = [
  '22222222-2222-4222-8222-222222222222',
  '44444444-4444-4444-8444-444444444444',
];

/// Unix seconds with six fraction digits, the webhook's fixed time form.
String timeText(DateTime time) {
  final micros = time.toUtc().microsecondsSinceEpoch;
  return '${micros ~/ 1000000}.${(micros % 1000000).toString().padLeft(6, '0')}';
}

/// The tables the pipeline writes, emptied between tests.
Future<void> clearPipelineTables(Session session) async {
  await initializeIngestSchema(session);
  await session.db.unsafeSimpleExecute(
    '''TRUNCATE activity,alerts,pipeline_failures,observation_keys,outbox,
        events,raw_inbox,transport_keys,ingest_active_config,
        ingest_source_credential,ingest_source,ingest_config_snapshot,
        matcher_content_digest,matcher_content_digest_fill,
        ingest_secret_commitment,secret_record,icinga2_sync_progress,icinga2_raw_origin CASCADE;
        UPDATE raw_admission_cutoff SET cutoff='-infinity', cursor_seconds=0, cursor_nanos=0, cursor_id=0''',
  );
}

/// Publishes a format version 2 snapshot whose only source is the Icinga2 one.
Future<void> publishIcinga2Config(
  Session session, {
  int revision = 1,
  bool routed = true,
  bool sharedNamespace = false,
}) async {
  await IngestConfigRepository(
    session,
    secretStore: testSecretStore,
  ).publishConfig(
    {
      'format_version': 2,
      'revision': revision,
      if (sharedNamespace) 'namespaces': [icinga2SharedNamespace],
      'outputs': [
        for (final (i, id) in icinga2DbOutputIds.indexed)
          {
            'id': id,
            'kind': 'webhook',
            'url': 'http://127.0.0.1:9099/events/$i',
            'signing_key_ref': 'icinga2-key-$i',
          },
      ],
      'sources': [
        {
          'id': icinga2DbSourceId,
          'kind': 'icinga2',
          'enabled': true,
          'credentials': [
            {'ref': 'icinga2-token', 'type': 'bearer'},
          ],
          if (sharedNamespace) 'namespace': icinga2SharedNamespace,
          'output_ids': routed ? icinga2DbOutputIds : <Object?>[],
        },
        if (sharedNamespace)
          {
            'id': icinga2OtherDbSourceId,
            'kind': 'icinga2',
            'enabled': true,
            'credentials': [
              {'ref': 'icinga2-token-2', 'type': 'bearer'},
            ],
            'namespace': icinga2SharedNamespace,
            'output_ids': routed ? icinga2DbOutputIds : <Object?>[],
          },
      ],
    },
    <String, Object?>{
      'icinga2-token': token(7),
      'icinga2-token-2': token(10),
      'icinga2-key-0': token(8),
      'icinga2-key-1': token(9),
    },
    runMode: 'test',
    clock: () => DateTime.utc(2026, 11, 10),
  );
}

/// Stores one raw delivery observed at [observed] and returns its raw id.
///
/// [document] is a JSON value, or already the exact body bytes.
Future<String> seedIcinga2(
  Session session,
  Object? document,
  DateTime observed, {
  String source = icinga2DbSourceId,
}) async {
  final bytes = document is Uint8List ? document : body(document);
  final id = const Uuid().v4();
  await session.db.unsafeExecute(
    '''INSERT INTO raw_inbox
(observed_at,raw_id,source_id,body,body_sha256,content_type)
VALUES (@time,CAST(@id AS uuid),CAST(@source AS uuid),@body,@digest,'application/json')''',
    parameters: QueryParameters.named({
      'time': observed,
      'id': id,
      'source': source,
      'body': bytes,
      'digest': sha256.convert(bytes).toString(),
    }),
  );
  return id;
}

/// Pins and processes the one pending row, with the worker clock at [observed].
Future<void> processIcinga2(Session session, DateTime observed) async {
  final repo = PipelineRepository(session, clock: () => observed);
  await repo.pinOne();
  await repo.processOne();
}

/// Seeds and processes one delivery; returns its raw id.
Future<String> deliverIcinga2(
  Session session,
  Object? document,
  DateTime observed, {
  String source = icinga2DbSourceId,
}) async {
  final id = await seedIcinga2(session, document, observed, source: source);
  await processIcinga2(session, observed);
  return id;
}

/// The rows of [sql] as column maps.
Future<List<Map<String, Object?>>> queryRows(
  Session session,
  String sql,
) async => (await session.db.unsafeQuery(
  sql,
)).map((row) => row.toColumnMap()).toList();

/// The number of rows in [table].
Future<int> countRows(Session session, String table) async =>
    (await queryRows(
          session,
          'SELECT count(*) AS n FROM "$table"',
        )).single['n']!
        as int;

/// The outcome counters the pipeline stored on raw row [rawId].
Future<Map<String, Object?>> outcomeOf(Session session, String rawId) async =>
    jsonDecode(
          (await queryRows(
                session,
                "SELECT outcome_json FROM raw_inbox WHERE raw_id=CAST('$rawId' AS uuid)",
              )).single['outcome_json']!
              as String,
        )
        as Map<String, Object?>;

/// The one alert row.
Future<Map<String, Object?>> theAlert(Session session) async =>
    (await queryRows(session, 'SELECT * FROM alerts')).single;

/// The event id the decoder derives for [document] on the db tests' source.
String eventIdOf(Object? document) =>
    decodeOne(document, sourceInstance: icinga2DbSourceId).eventId;

/// The stored envelope of the event [eventId].
Future<Map<String, Object?>> storedEvent(
  Session session,
  String eventId,
) async {
  final row = (await queryRows(
    session,
    "SELECT payload, disposition, state_outcome FROM events WHERE event_id=CAST('$eventId' AS uuid)",
  )).single;
  return {
    ...(jsonDecode(utf8.decode(row['payload']! as List<int>))
        as Map<String, Object?>),
    '_disposition': row['disposition'],
    '_state_outcome': row['state_outcome'],
  };
}
