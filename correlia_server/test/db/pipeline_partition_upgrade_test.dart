import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';

const _parents = ['events', 'outbox', 'raw_inbox'];
const _predecessorVersion = 14;
const _cutoverVersion = 15;

Future<List<Object?>> _partitionedParents(Session session) async => [
  for (final row in await session.db.unsafeQuery('''
    SELECT relname FROM pg_class
    WHERE oid IN ('events'::regclass,'outbox'::regclass,'raw_inbox'::regclass)
      AND relkind='p' ORDER BY relname
  '''))
    row[0],
];

Future<void> _predecessor(Session session) => applySchemaSteps(session, [
  for (final step in schemaSteps)
    if (step.version <= _predecessorVersion) step,
]);

Future<void> _seed(Session session) async {
  await session.db.unsafeSimpleExecute('''
    INSERT INTO raw_inbox (observed_at,raw_id,source_id,body,body_sha256,content_type,status,config_snapshot_id)
    SELECT '2020-01-01 UTC',id::uuid,'a0000000-0000-4000-8000-000000000001',
      decode('0102ff','hex'),'digest','application/json',status,'fixture-pin'
    FROM (VALUES
      ('a0000000-0000-4000-8000-000000000010','pending'),
      ('a0000000-0000-4000-8000-000000000011','failed'),
      ('a0000000-0000-4000-8000-000000000012','done')) AS r(id,status);
    INSERT INTO events (observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,
      config_snapshot_id,source_time,payload,state_outcome)
    VALUES ('2020-01-01 UTC','a0000000-0000-4000-8000-000000000020','ready',
      '2020-01-01 UTC','a0000000-0000-4000-8000-000000000012',
      'a0000000-0000-4000-8000-000000000001','fixture-pin', '2020-01-01 06:00 UTC',
      convert_to('{"subject":"upgrade","data":{}}','UTF8'),'applied');
    INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,
      output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status)
    SELECT '2020-01-02 UTC',gen_random_uuid(),observed_at,event_id,disposition,
      'a0000000-0000-4000-8000-000000000002',config_snapshot_id,'https://example.com/events',
      'historical-key','historical-commitment',payload,state
    FROM events CROSS JOIN unnest(ARRAY['queued','dead','delivered']) state;
    INSERT INTO pipeline_failures
      ("rawObservedAt","rawId","configSnapshotId","errorClass","createdAt")
    SELECT observed_at,raw_id,config_snapshot_id,'invalid_json',clock_timestamp()
    FROM raw_inbox WHERE status='failed';
  ''');
}

Future<Map<String, List<List<Object?>>>> _evidence(Session session) async => {
  for (final (table, sql) in [
    (
      'raw_inbox',
      'SELECT tableoid::bigint,observed_at,raw_id::text,source_id::text,'
          'encode(body,\'hex\'),status,config_snapshot_id FROM raw_inbox ORDER BY raw_id',
    ),
    (
      'events',
      'SELECT tableoid::bigint,observed_at,event_id::text,disposition,'
          'raw_observed_at,raw_id::text,encode(payload,\'hex\'),state_outcome FROM events',
    ),
    (
      'outbox',
      'SELECT tableoid::bigint,created_at,delivery_id::text,event_id::text,'
          'encode(payload,\'hex\'),status,config_snapshot_id FROM outbox ORDER BY delivery_id',
    ),
  ])
    table: [for (final row in await session.db.unsafeQuery(sql)) row.toList()],
};

void main() {
  withServerpod(
    'pipeline partition cutover',
    (builder, _) {
      test('partition_cutover_fresh_and_populated', () async {
        final session = builder.build();
        await _predecessor(session);
        await _seed(session);
        final before = await _evidence(session);
        await applySchemaSteps(session, schemaSteps);
        expect(await _partitionedParents(session), _parents);
        expect(await _evidence(session), before);
        final inserted = await session.db.unsafeQuery('''
          INSERT INTO raw_inbox (observed_at,raw_id,source_id,body,body_sha256,content_type)
          VALUES (clock_timestamp(),gen_random_uuid(),gen_random_uuid(),decode('aa','hex'),
            'digest','application/json') RETURNING tableoid::bigint
        ''');
        expect(inserted.single[0], isNot(before['raw_inbox']!.first[0]));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'pipeline partition catalog',
    (builder, _) {
      test('parent_indexes_helper_and_cross_child_cutoff', () async {
        final session = builder.build();
        await _predecessor(session);
        await _seed(session);
        await applySchemaSteps(session, schemaSteps);
        expect(await _partitionedParents(session), _parents);
        final indexes = await session.db.unsafeQuery('''
          SELECT p.relname,count(*) FROM pg_inherits h
          JOIN pg_class p ON p.oid=h.inhparent
          WHERE p.relname IN ('raw_pending_receipt_idx','raw_stream_retained_idx',
            'events_subject_idx','outbox_definition_status_idx')
          GROUP BY p.relname ORDER BY p.relname
        ''');
        expect(indexes.map((row) => row[0]), [
          'events_subject_idx',
          'outbox_definition_status_idx',
          'raw_pending_receipt_idx',
          'raw_stream_retained_idx',
        ]);
        expect(indexes.map((row) => row[1]), everyElement(greaterThan(1)));
        final times = await session.db.unsafeQuery(
          'SELECT events_effective_source_time(e) FROM events e',
        );
        expect(times.single[0], DateTime.utc(2020, 1, 1, 0, 5));
        await session.db.unsafeExecute('''
          UPDATE raw_admission_cutoff SET cutoff='2020-01-01 00:01 UTC'
          WHERE singleton=1
        ''');
        await expectLater(
          session.db.unsafeQuery('''
            INSERT INTO raw_inbox (observed_at,raw_id,source_id,body,body_sha256,content_type)
            SELECT receipt,gen_random_uuid(),gen_random_uuid(),decode('02','hex'),
              'digest','application/json' FROM unnest(ARRAY[
              '2020-01-01 00:00 UTC'::timestamptz,clock_timestamp()]) receipt
          '''),
          throwsA(
            isA<DatabaseQueryException>().having(
              (e) => e.code,
              'code',
              'CR001',
            ),
          ),
        );
        expect((await _evidence(session))['raw_inbox'], hasLength(3));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'pipeline partition transaction',
    (builder, _) {
      test('partition_cutover_rollback_and_retry', () async {
        final session = builder.build();
        await _predecessor(session);
        await _seed(session);
        final before = await _evidence(session);
        final step = schemaSteps
            .where((step) => step.version == _cutoverVersion)
            .singleOrNull;
        expect(
          step,
          isNotNull,
          reason: 'the partition cutover must be present',
        );
        await expectLater(
          applySchemaSteps(session, [
            SchemaStep(_cutoverVersion, '${step!.sql}\nSELECT 1 / 0;'),
          ]),
          throwsA(
            isA<SchemaStepException>().having(
              (e) => e.version,
              'version',
              _cutoverVersion,
            ),
          ),
        );
        expect(await _partitionedParents(session), isEmpty);
        expect(await _evidence(session), before);
        final failed = await session.db.unsafeQuery('''
          SELECT version FROM correlia_schema_versions WHERE version=$_cutoverVersion
        ''');
        expect(failed, isEmpty);
        await applySchemaSteps(session, schemaSteps);
        expect(await _partitionedParents(session), _parents);
        expect(await _evidence(session), before);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'pipeline partitions on fresh install',
    (builder, _) {
      test('fresh schema has the same partitioned parents', () async {
        final session = builder.build();
        await initializeSchema(session);
        expect(await _partitionedParents(session), _parents);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
