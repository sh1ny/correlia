import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/admission.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import 'generic_webhook_fixture.dart';
import 'secret_fixture.dart';

/// The source UUID used by generic pipeline tests.
const genericPipelineSource = '11111111-1111-4111-8111-111111111111';

/// Publishes the supplied mapping with one generic bearer source.
Future<IngestBootstrap> publishGenericConfig(
  Session session, {
  required DateTime now,
  int revision = 1,
  Map<String, Object?>? mapping,
  bool enabled = true,
  bool includeSource = true,
  int bearer = 1,
  List<Map<String, Object?>> outputs = const [],
  Map<String, Object?> outputSecrets = const {},
}) =>
    IngestConfigRepository(session, secretStore: testSecretStore).publishConfig(
      {
        'format_version': 2,
        'revision': revision,
        'mappings': [mapping ?? checkMapping()],
        'sources': [
          if (includeSource)
            {
              ...genericSource(genericPipelineSource, 'key-$bearer'),
              'enabled': enabled,
              'output_ids': [for (final output in outputs) output['id']],
            },
        ],
        'outputs': outputs,
      },
      {'key-$bearer': genericTestToken(bearer), ...outputSecrets},
      runMode: 'test',
      clock: () => now,
    );

/// Encodes deterministic key material for an isolated test database.
String genericTestToken(int byte) =>
    base64Url.encode(List<int>.filled(32, byte)).replaceAll('=', '');

/// Admits a delivery through the persisted source, without pinning it.
Future<String> admitGeneric(
  Session session,
  IngestBootstrap input,
  String body,
  DateTime now,
) async {
  final admitted = await IngestAdmission(session).admit(
    sourceId: genericPipelineSource,
    kind: 'generic',
    credential: input.sources.single.credentials.single,
    pathToken: false,
    body: utf8.encode(body),
    contentType: 'application/json',
    observedAt: now,
  );
  expect(admitted, AdmissionOutcome.accepted);
  return (await session.db.unsafeQuery(
        'SELECT raw_id::text FROM raw_inbox WHERE observed_at=@observed',
        parameters: QueryParameters.named({'observed': now}),
      )).single[0]!
      as String;
}

/// A payload covered by [checkMapping], with optional per-observation fields.
Map<String, Object?> genericAlert(
  DateTime time, {
  String host = 'api',
  String state = 'PROBLEM',
  String? changeId,
}) => {
  'host': host,
  'time': time.toIso8601String(),
  'state': state,
  'summary': 'Check status',
  'changeId': ?changeId,
};

/// The canonical events committed in receipt order.
Future<List<CanonicalEvent>> genericEvents(Session session) async => [
  for (final row in await session.db.unsafeQuery(
    'SELECT payload FROM events ORDER BY observed_at, event_id',
  ))
    CloudEvent.decode(row[0]! as Uint8List).event,
];
