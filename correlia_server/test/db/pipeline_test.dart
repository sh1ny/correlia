import '../support/secret_fixture.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/generated/protocol.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart';
import '../support/icinga2_pipeline.dart';
import '../support/ingest_schema.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as fixture;

final now = DateTime.utc(2026, 11, 10, 12);

Future<void> seed(
  Session session,
  List<Object?> alerts, {
  DateTime? observed,
}) async {
  final body = Uint8List.fromList(
    utf8.encode(jsonEncode(payload.groupOf(alerts))),
  );
  await session.db.unsafeExecute(
    '''INSERT INTO raw_inbox
(observed_at,raw_id,source_id,body,body_sha256,content_type)
VALUES (@time,CAST(@id AS uuid),CAST(@source AS uuid),@body,@digest,'application/json')''',
    parameters: QueryParameters.named({
      'time': observed ?? now,
      'id': const Uuid().v4(),
      'source': fixture.sourceId,
      'body': body,
      'digest': sha256.convert(body).toString(),
    }),
  );
}

Future<int> count(Session session, String table) async =>
    (await session.db.unsafeQuery(
          'SELECT count(*) AS n FROM "$table"',
        )).single.toColumnMap()['n']
        as int;

void main() {
  withServerpod(
    'atomic processing',
    (builder, _) {
      setUp(() async {
        final session = builder.build();
        await initializeIngestSchema(session);
        for (final table in [
          'activity',
          'alerts',
          'pipeline_failures',
          'observation_keys',
          'outbox',
          'events',
          'raw_inbox',
          'ingest_active_config',
          'ingest_source',
          'ingest_config_snapshot',
          'ingest_secret_commitment',
          'secret_record',
          'ingest_source_credential',
        ]) {
          await session.db.unsafeSimpleExecute('DELETE FROM "$table"');
        }
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(fixture.input(1));
      });

      PipelineRepository repo() =>
          PipelineRepository(builder.build(), clock: () => now);
      Future<void> process() async {
        await repo().pinOne();
        await repo().processOne();
      }

      final alert = payload.alert(startsAt: '2026-11-10T12:00:00Z');

      test('concurrent_claiming', () async {
        final session = builder.build();
        await seed(session, [alert]);
        await seed(session, [
          payload.alert(
            startsAt: '2026-11-10T12:00:00Z',
            labels: {'alertname': 'Other'},
          ),
        ]);
        await Future.wait([repo().pinOne(), repo().pinOne()]);
        await Future.wait([repo().processOne(), repo().processOne()]);
        expect(await count(session, 'events'), 2);
        expect(await count(session, 'observation_keys'), 2);
        expect(await count(session, 'outbox'), 2);
      });

      test('dur_1_outbox_failure_rolls_back_event_work', () async {
        final session = builder.build();
        await seed(session, [alert]);
        await repo().pinOne();
        await session.db.unsafeSimpleExecute(
          '''CREATE FUNCTION pipeline_test_transient() RETURNS trigger
LANGUAGE plpgsql AS \$\$ BEGIN RAISE EXCEPTION 'test failure' USING ERRCODE='40001'; END \$\$''',
        );
        await session.db.unsafeSimpleExecute(
          'CREATE TRIGGER pipeline_test_transient BEFORE INSERT ON outbox FOR EACH ROW EXECUTE FUNCTION pipeline_test_transient()',
        );
        try {
          for (var i = 0; i < 7; i++) {
            await repo().processOne();
            expect(await count(session, 'events'), 0);
            expect(await count(session, 'observation_keys'), 0);
            expect(await count(session, 'outbox'), 0);
            expect(await count(session, 'alerts'), 0);
            expect(await count(session, 'activity'), 0);
            final row = (await session.db.unsafeQuery(
              'SELECT status,attempt_count,config_snapshot_id FROM raw_inbox',
            )).single;
            expect(row[0], 'pending');
            expect(row[1], 0);
            expect(row[2], fixture.input(1).snapshotId);
            await session.db.unsafeSimpleExecute(
              'UPDATE raw_inbox SET next_attempt_at=NULL',
            );
          }
        } finally {
          await session.db.unsafeSimpleExecute(
            'DROP TRIGGER pipeline_test_transient ON outbox',
          );
          await session.db.unsafeSimpleExecute(
            'DROP FUNCTION pipeline_test_transient()',
          );
        }
        await repo().processOne();
        expect(await count(session, 'events'), 1);
        expect(await count(session, 'alerts'), 1);
        expect(await count(session, 'activity'), 1);
      });

      test('invalid_member_after_valid_member', () async {
        final session = builder.build();
        await seed(session, [alert, payload.alert(startsAt: 'invalid')]);
        await process();
        expect(await count(session, 'events'), 0);
        expect(await count(session, 'observation_keys'), 0);
        expect(await count(session, 'outbox'), 0);
        expect(await count(session, 'alerts'), 0);
        expect(await count(session, 'activity'), 0);
        expect(await count(session, 'pipeline_failures'), 1);
        final failure = (await session.db.unsafeQuery(
          'SELECT "rawId"::text,"configSnapshotId","errorClass","fieldPath" FROM pipeline_failures',
        )).single;
        expect(failure[0], isNotNull);
        expect(failure[1], fixture.input(1).snapshotId);
        expect(failure[2], 'invalid_timestamp');
        expect(failure[3], 'alerts[1].startsAt');
        expect(
          (await session.db.unsafeQuery(
            'SELECT status FROM raw_inbox',
          )).single[0],
          'failed',
        );
      });

      for (final year in [2000, 2100]) {
        test('raw_failure_uses_database_time_$year', () async {
          final session = builder.build();
          await seed(session, [payload.alert(startsAt: 'invalid')]);
          final repository = PipelineRepository(
            session,
            clock: () => DateTime.utc(year),
            elapsedForTest: () => Duration.zero,
          );
          expect(await repository.pinOne(), isTrue);
          expect(await repository.processOne(), isTrue);
          final operations = QueueOperations(session);
          final failure = (await operations.list(
            QueueFailureFilter(kind: QueueFailureKind.raw),
          )).failures.single;
          expect(failure.errorClass, 'invalid_timestamp');
          expect(
            (await session.db.unsafeQuery('''
              SELECT "createdAt" AT TIME ZONE 'UTC' FROM pipeline_failures
            ''')).single[0],
            failure.failedAt,
          );
          expect(
            (await operations.replayOne(
              QueueFailureKind.raw,
              failure.occurrence,
              'operator',
            )).queued,
            1,
          );
        });
      }

      test('ord_5b_rebatching_and_expired_transport_window', () async {
        final session = builder.build();
        await seed(session, [alert]);
        await seed(session, [alert, alert]);
        await Future.wait([repo().pinOne(), repo().pinOne()]);
        await Future.wait([repo().processOne(), repo().processOne()]);
        expect(await count(session, 'events'), 1);
        expect(await count(session, 'observation_keys'), 1);
        expect(await count(session, 'outbox'), 1);
      });

      test('future_quarantine_does_not_poison_dedup', () async {
        final session = builder.build();
        final future = payload.alert(startsAt: '2026-11-13T12:00:00Z');
        await seed(session, [future, future]);
        await process();
        await seed(session, [future]);
        await process();
        expect(await count(session, 'events'), 1);
        expect(await count(session, 'observation_keys'), 0);
        expect(await count(session, 'outbox'), 0);
        expect(await count(session, 'alerts'), 0);
        expect(await count(session, 'activity'), 0);
        final outcomes = await session.db.unsafeQuery(
          'SELECT outcome_json FROM raw_inbox',
        );
        expect(
          outcomes.map(
            (row) =>
                (jsonDecode(row[0] as String)
                    as Map<String, Object?>)['duplicate_quarantine'],
          ),
          contains(greaterThan(0)),
        );
        await seed(session, [future], observed: DateTime.utc(2026, 11, 13));
        await process();
        expect(await count(session, 'observation_keys'), 1);
        expect(await count(session, 'outbox'), 1);
        expect(await count(session, 'alerts'), 1);
        expect(await count(session, 'activity'), 1);
      });

      test('concurrent_equal_observed_quarantine_collision', () async {
        final session = builder.build();
        final future = payload.alert(startsAt: '2026-11-13T12:00:00Z');
        await seed(session, [future]);
        await seed(session, [future]);
        await Future.wait([repo().pinOne(), repo().pinOne()]);
        await Future.wait([repo().processOne(), repo().processOne()]);
        expect(await count(session, 'events'), 1);
        expect(await count(session, 'observation_keys'), 0);
        final rows = await session.db.unsafeQuery(
          'SELECT status,attempt_count,outcome_json FROM raw_inbox',
        );
        expect(rows.map((row) => row[0]), everyElement('done'));
        expect(rows.map((row) => row[1]), everyElement(0));
        expect(
          rows.map(
            (row) =>
                (jsonDecode(row[2] as String)
                    as Map<String, Object?>)['duplicate_quarantine'],
          ),
          contains(1),
        );
        await seed(session, [future], observed: DateTime.utc(2026, 11, 13));
        await process();
        expect(await count(session, 'observation_keys'), 1);
        expect(await count(session, 'outbox'), 1);
      });

      test('late_observation_evidence', () async {
        final session = builder.build();
        await seed(session, [payload.alert(startsAt: '2026-11-01T00:00:00Z')]);
        await process();
        expect(
          (await session.db.unsafeQuery(
            'SELECT disposition FROM events',
          )).single[0],
          'late',
        );
        expect(await count(session, 'observation_keys'), 1);
        expect(await count(session, 'outbox'), 0);
        expect(await count(session, 'alerts'), 0);
        expect(await count(session, 'activity'), 0);
      });

      test('source_omitted_at_first_pin_fails_without_effects', () async {
        final session = builder.build();
        await seed(session, [alert]);
        final disabled = fixture.input(2, includeSource: false);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(disabled);
        await process();
        expect(
          (await session.db.unsafeQuery(
            'SELECT status,config_snapshot_id FROM raw_inbox',
          )).single.toList(),
          ['failed', disabled.snapshotId],
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT "errorClass" FROM pipeline_failures',
          )).single[0],
          'source_not_configured',
        );
        expect(await count(session, 'events'), 0);
        expect(await count(session, 'observation_keys'), 0);
        expect(await count(session, 'outbox'), 0);
      });

      Future<void> seedFiringAt(Session session, String sourceTime) =>
          seed(session, [payload.alert(startsAt: sourceTime)]);

      Future<
        ({
          Object? stored,
          Object? effective,
          Map<String, Object?> outcome,
          String time,
        })
      >
      processedEvent(Session session) async {
        final row = (await session.db.unsafeQuery(
          'SELECT effective_source_time, events_effective_source_time(e), '
          'payload FROM events e',
        )).single;
        final outcome = (await session.db.unsafeQuery(
          'SELECT outcome_json FROM raw_inbox',
        )).single[0];
        final published =
            jsonDecode(utf8.decode(row[2] as List<int>))
                as Map<String, Object?>;
        return (
          stored: row[0],
          effective: row[1],
          outcome: jsonDecode(outcome as String) as Map<String, Object?>,
          time: published['time'] as String,
        );
      }

      test('ord_4_future_source_time_beyond_the_skew_limit', () async {
        final session = builder.build();
        // An Icinga2 firing observation whose source time is 3 hours after
        // its observed time.
        final changed = DateTime.utc(2026, 11, 10, 15);
        await publishIcinga2Config(session, revision: 2);
        await seedIcinga2(
          session,
          delivery(
            set: {
              'last_state_change': timeText(changed),
              'notification_time': timeText(changed),
            },
          ),
          now,
        );
        await process();
        final result = await processedEvent(session);
        final expected = DateTime.utc(2026, 11, 10, 12, 5);
        expect(result.stored, expected);
        expect(result.effective, expected);
        expect(result.outcome['clamped'], 1);
        expect(result.outcome['applied'], 1);
        expect(result.time, startsWith('2026-11-10T15:00:00'));
        expect(await count(session, 'alerts'), 1);
      });

      test('source_time_within_the_skew_allowance', () async {
        final session = builder.build();
        await seedFiringAt(session, '2026-11-10T12:02:00Z');
        await process();
        final result = await processedEvent(session);
        final expected = DateTime.utc(2026, 11, 10, 12, 2);
        expect(result.stored, expected);
        expect(result.effective, expected);
        expect(result.outcome['clamped'], 0);
        expect(result.time, startsWith('2026-11-10T12:02:00'));
      });

      test('processing_budget_exhaustion', () async {
        final session = builder.build();
        await seed(session, [alert]);
        await repo().pinOne();
        await session.db.unsafeSimpleExecute(
          'ALTER TABLE outbox ADD CONSTRAINT test_reject_output CHECK (false)',
        );
        try {
          for (var i = 0; i < 5; i++) {
            await repo().processOne();
            await session.db.unsafeSimpleExecute(
              'UPDATE raw_inbox SET next_attempt_at=NULL',
            );
          }
        } finally {
          await session.db.unsafeSimpleExecute(
            'ALTER TABLE outbox DROP CONSTRAINT test_reject_output',
          );
        }
        final raw = (await session.db.unsafeQuery(
          'SELECT status,attempt_count,config_snapshot_id,body FROM raw_inbox',
        )).single;
        expect(raw[0], 'failed');
        expect(raw[1], 5);
        expect(raw[2], fixture.input(1).snapshotId);
        expect(raw[3], isNotNull);
        expect(await count(session, 'events'), 0);
        expect(
          (await session.db.unsafeQuery(
            'SELECT "errorClass" FROM pipeline_failures',
          )).single[0],
          'processing_exhausted',
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
