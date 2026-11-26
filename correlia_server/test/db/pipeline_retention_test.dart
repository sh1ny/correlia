import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

final _now = DateTime.utc(2026, 10, 1);
const _source = 'e1000000-0000-4000-8000-000000000001';
const _output = 'e2000000-0000-4000-8000-000000000001';
const _old = '2026-01-01 UTC';

String _id(int n) => 'e0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

Future<int> _maintain(Session session, String lane, {int cap = 3}) async =>
    (await session.db.unsafeQuery(
          'SELECT correlia_maintain(@lane,@now,@cap)',
          parameters: QueryParameters.named({
            'lane': lane,
            'now': _now,
            'cap': cap,
          }),
        )).single[0]!
        as int;

Future<void> _raw(Session session, int id, String status) async {
  await session.db.unsafeSimpleExecute('''
    INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type,status)
    VALUES ('$_old','${_id(id)}','$_source',decode('ff','hex'),'digest','application/json','$status');
  ''');
}

Future<void> _event(Session session, int id) async {
  await session.db.unsafeSimpleExecute('''
    INSERT INTO events(observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,
      config_snapshot_id,source_time,payload)
    VALUES ('$_old','${_id(id)}','ready','$_old','${_id(99)}','$_source','fixture','$_old',
      convert_to('{"subject":"fixture"}','UTF8'))
  ''');
}

Future<void> _intent(
  Session session,
  int id,
  String status, {
  String? terminal = _old,
}) async {
  await session.db.unsafeSimpleExecute('''
    INSERT INTO outbox(created_at,delivery_id,event_observed_at,event_id,event_disposition,
      output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,terminal_at)
    VALUES ('$_old','${_id(100 + id)}','$_old','${_id(id)}','ready','$_output','fixture',
      'https://example.com','key','commitment',decode('ffaa','hex'),'$status',
      ${terminal == null ? 'NULL' : "'$terminal'"})
  ''');
}

Future<void> _failure(Session session, int id, {String seen = _old}) async {
  await session.db.unsafeSimpleExecute('''
    INSERT INTO pipeline_failures ("rawObservedAt","rawId","errorClass","createdAt")
    VALUES ('$_old','${_id(id)}','invalid_json','$seen');
    SELECT correlia_record_raw_failure('$_old','${_id(id)}','$_source',NULL,'invalid_json',NULL,'$seen');
    UPDATE raw_inbox SET status='failed' WHERE raw_id='${_id(id)}';
  ''');
}

Future<List<String>> _column(Session session, String sql) async => [
  for (final row in await session.db.unsafeQuery(sql)) row[0]! as String,
];

Future<int> _count(Session session, String table) async =>
    (await session.db.unsafeQuery('SELECT count(*) FROM $table')).single[0]!
        as int;

void main() {
  withServerpod(
    'pipeline retention',
    (builder, _) {
      late Session session;
      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute('''
        TRUNCATE raw_inbox,events,outbox,delivery_attempts,activity,pipeline_failures,
          observation_keys,transport_keys,icinga2_raw_origin,pipeline_retention_cursor,
          pipeline_retired_delivery;
        UPDATE raw_admission_cutoff SET cutoff='-infinity';
      ''');
      });

      test('dur_10_retention_keeps_unfinished_work', () async {
        await _raw(session, 1, 'done');
        await _raw(session, 2, 'pending');
        await _raw(session, 3, 'pending');
        await _failure(session, 3, seen: '2026-09-30');
        expect(await _maintain(session, 'raw'), 1);
        expect(
          await _column(
            session,
            'SELECT status FROM raw_inbox ORDER BY raw_id',
          ),
          ['pending', 'failed'],
        );
        expect(await _count(session, 'pipeline_failures'), 1);
      });

      test('unfinished_outbox_keys_protect_old_events', () async {
        for (var id = 1; id <= 4; id++) {
          await _event(session, id);
        }
        await _intent(session, 1, 'dead');
        await _intent(session, 2, 'delivering', terminal: null);
        await _intent(session, 3, 'delivered');
        expect(await _maintain(session, 'events', cap: 4), 2);
        expect(
          await _column(
            session,
            'SELECT event_id::text FROM events ORDER BY event_id',
          ),
          [_id(1), _id(2)],
        );
      });

      test('dur_12_expiry_discards_and_ledgers_atomically', () async {
        await _raw(session, 1, 'pending');
        await _failure(session, 1);
        await _intent(session, 2, 'dead');
        expect(await _maintain(session, 'expiry'), 2);
        expect(
          await _column(
            session,
            'SELECT status FROM raw_inbox UNION ALL SELECT status FROM outbox',
          ),
          ['discarded', 'discarded'],
        );
        expect(await _count(session, 'pipeline_failures'), 0);
        expect(await _count(session, 'pipeline_dead_letter'), 0);
        final ledger = (await session.db.unsafeQuery(
          "SELECT sum(entity_version)::bigint FROM activity WHERE change_kind='dead_letter_expired'",
        )).single;
        expect(ledger[0], 2);
        expect(await _maintain(session, 'raw'), 1);
      });

      test('failed_batch_reports_no_uncommitted_counts', () async {
        await _raw(session, 1, 'pending');
        await _failure(session, 1);
        await _intent(session, 2, 'dead');
        await expectLater(
          session.db.transaction((tx) async {
            await session.db.unsafeQuery(
              "SELECT correlia_maintain('expiry','2026-10-01',3)",
              transaction: tx,
            );
            await session.db.unsafeQuery('SELECT 1/0', transaction: tx);
          }),
          throwsA(isA<DatabaseQueryException>()),
        );
        expect(
          await _column(
            session,
            'SELECT status FROM raw_inbox UNION ALL SELECT status FROM outbox',
          ),
          ['failed', 'dead'],
        );
        expect(await _count(session, 'pipeline_dead_letter'), 2);
        expect(await _count(session, 'activity'), 0);
      });

      test('reclamation_advances_past_protected_pages', () async {
        for (var id = 1; id <= 7; id++) {
          await _event(session, id);
          if (id < 7) await _intent(session, id, 'queued', terminal: null);
        }
        expect(await _maintain(session, 'events'), 0);
        expect(await _maintain(session, 'events'), 0);
        expect(await _maintain(session, 'events'), 1);
        expect(await _count(session, 'events'), 6);
      });

      test('delivered_retention_reclaims_only_matching_attempts', () async {
        await _intent(session, 1, 'delivered');
        await _intent(session, 2, 'queued', terminal: null);
        await session.db.unsafeSimpleExecute('''
        INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
        SELECT created_at,delivery_id,1,gen_random_uuid(),created_at,'acknowledged' FROM outbox
      ''');
        expect(await _maintain(session, 'outbox'), 1);
        expect(await _maintain(session, 'attempts'), 1);
        expect(
          await _column(
            session,
            'SELECT "deliveryId"::text FROM delivery_attempts',
          ),
          [_id(102)],
        );
      });

      test('new_terminal_time_overrides_old_creation_age', () async {
        await _intent(session, 1, 'delivered', terminal: '2026-09-30 UTC');
        expect(await _maintain(session, 'outbox'), 0);
        expect(await _count(session, 'outbox'), 1);
      });

      test('retired_intent_attempts_reclaim_across_batches', () async {
        await _event(session, 1);
        await _event(session, 2);
        await _intent(session, 1, 'discarded');
        await _intent(session, 2, 'queued', terminal: null);
        await session.db.unsafeSimpleExecute('''
        INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
        SELECT created_at,delivery_id,n,gen_random_uuid(),created_at,'retryable'
        FROM outbox CROSS JOIN generate_series(1,8) n
      ''');
        expect(await _maintain(session, 'outbox'), 1);
        expect(await _maintain(session, 'events'), 1);
        expect(await _maintain(session, 'attempts'), 3);
        expect(await _maintain(session, 'attempts'), 3);
        expect(await _maintain(session, 'attempts'), 2);
        expect(await _count(session, 'pipeline_retired_delivery'), 0);
        expect(await _count(session, 'delivery_attempts'), 8);
      });

      test('replayable_work_protects_ordering_evidence', () async {
        await _raw(session, 1, 'pending');
        await _failure(session, 1, seen: '2026-09-30 UTC');
        await session.db.unsafeSimpleExecute('''
        UPDATE raw_admission_cutoff SET cutoff='2026-09-30 UTC';
        INSERT INTO observation_keys ("eventId",fingerprint,"sourceTime","firstSeenAt",disposition)
        VALUES ('${_id(5)}','fp','$_old','$_old','ready');
        INSERT INTO transport_keys ("sourceId",key,"bodySha256","firstSeenAt","expiresAt","rawObservedAt","rawId")
        VALUES ('$_source','expired','digest','$_old','2026-09-29','$_old','${_id(1)}'),
          ('$_source','still-live','digest','$_old','2026-10-02','$_old','${_id(1)}');
      ''');
        expect(await _maintain(session, 'observation'), 0);
        expect(await _maintain(session, 'transport'), 1);
        expect(await _column(session, 'SELECT key FROM transport_keys'), [
          'still-live',
        ]);
        await session.db.unsafeExecute("UPDATE raw_inbox SET status='done'");
        expect(await _maintain(session, 'observation'), 1);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
