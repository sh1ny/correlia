import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/alertmanager_decoder.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as fixture;
import 'pipeline_test.dart' as pipeline;

/// Members of the raw batch; above the 32 an insertion sort handles stably.
const members = 48;

/// The member that has a same-ID twin appended at the end of the batch.
const twin = 3;

const startsAt = '2026-11-10T12:00:00Z';

/// The batch: [members] distinct alerts, then a second alert with the same
/// identity as member [twin], differing only in its annotation.
List<Object?> batch({required String first, required String second}) => [
  for (var i = 0; i < members; i++)
    payload.alert(
      labels: {'alertname': 'A$i'},
      startsAt: startsAt,
      annotations: {'summary': i == twin ? first : 'other'},
    ),
  payload.alert(
    labels: {'alertname': 'A$twin'},
    startsAt: startsAt,
    annotations: {'summary': second},
  ),
];

/// Whether an unstable sort by event ID alone moves the twin behind its
/// earlier same-ID member: the fixture only proves the ordering when it does.
bool oldSortReorders(List<Object?> alerts) {
  final events = decodeAlertmanager(
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(payload.groupOf(alerts)))),
    sourceInstance: fixture.sourceId,
    excludedLabels: const [],
    rawRef: 'raw:fixture',
    rawSha256: '0' * 64,
    observedAt: EventTimestamp.parse('2026-11-10T12:00:00Z'),
    processedAt: EventTimestamp.parse('2026-11-10T12:00:00Z'),
    configVersion: 'snapshot-1',
  ).events;
  final order = [for (var i = 0; i < events.length; i++) i]
    ..sort((a, b) => events[a].eventId.compareTo(events[b].eventId));
  final id = events[twin].eventId;
  return order.firstWhere((i) => events[i].eventId == id) != twin;
}

void main() {
  withServerpod(
    'same-ID candidate order, Alertmanager batch',
    (builder, _) {
      setUp(() async {
        final session = builder.build();
        await clearPipelineTables(session);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(fixture.input(1));
      });

      Future<void> expectCandidate(String first, String second) async {
        final alerts = batch(first: first, second: second);
        expect(oldSortReorders(alerts), isTrue);
        final session = builder.build();
        await pipeline.seed(session, alerts);
        await processIcinga2(session, pipeline.now);
        expect(await pipeline.count(session, 'events'), members);
        expect(await pipeline.count(session, 'outbox'), members);
        final rows = await queryRows(session, '''
          SELECT (convert_from(e.payload,'UTF8')::jsonb->'data'->'annotations'->>'summary') AS stored,
                 (convert_from(o.payload,'UTF8')::jsonb->'data'->'annotations'->>'summary') AS delivered
          FROM events e JOIN outbox o USING (event_id)
          WHERE convert_from(e.payload,'UTF8')::jsonb->'data'->'labels'->>'alertname' = 'A$twin'
        ''');
        expect(rows.single, {'stored': first, 'delivered': first});
      }

      test('first_input_member_is_the_candidate', () async {
        await expectCandidate('earlier', 'later');
      });

      test('reversed_input_order', () async {
        await expectCandidate('later', 'earlier');
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'same-ID candidate order, Icinga2 stream batch',
    (builder, _) {
      test('stream_copies_straddle_the_future_limit', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
        final snapshot = await publishStreamDb(session);
        final now = streamDbNow;
        final check = streamDbCheck(now.add(const Duration(hours: 25)));
        final raw = await seedStreamDb(
          session,
          snapshot,
          [check, check],
          receipts: [now, now.add(const Duration(hours: 2))],
        );
        await processIcinga2(session, now.add(const Duration(hours: 2)));
        final outcome = await outcomeOf(session, raw);
        expect(outcome, containsPair('future_dated', 1));
        expect(outcome, containsPair('committed', 1));
        expect(outcome, containsPair('duplicate_observation', 0));
        expect(await countRows(session, 'events'), 1);
        expect(await countRows(session, 'outbox'), 1);
        // The first copy is future-dated against its receipt, so the stored
        // and delivered event are the second copy, received two hours later.
        final second = now.add(const Duration(hours: 2)).toUtc();
        final rows = await queryRows(session, '''
          SELECT e.observed_at AS key,
                 convert_from(e.payload,'UTF8')::jsonb->'data'->>'observed_at' AS stored,
                 o.event_observed_at AS outbox_key,
                 o.event_id = e.event_id AS same_event,
                 convert_from(o.payload,'UTF8')::jsonb->'data'->>'observed_at' AS delivered
          FROM events e JOIN outbox o ON o.event_id = e.event_id
        ''');
        final row = rows.single;
        expect((row['key']! as DateTime).toUtc(), second);
        expect((row['outbox_key']! as DateTime).toUtc(), second);
        expect(row['same_event'], isTrue);
        expect(DateTime.parse(row['stored']! as String), second);
        expect(row['delivered'], row['stored']);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
