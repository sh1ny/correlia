import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:correlia_server/src/runtime/role_runtime.dart';
import 'package:correlia_server/src/runtime/serverpod_adapter.dart';
import 'package:correlia_server/src/runtime/startup_state.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/pod_fixture.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as config_fixture;
import 'pipeline_test.dart' as pipeline_fixture;

final class _SchemaPort implements ServerpodPort {
  _SchemaPort(this.session);
  final Session session;
  @override
  void mountRoutes(Subsystem subsystem) {}
  @override
  Future<void> start() => applySchemaSteps(session, [
    const SchemaStep(
      999,
      'CREATE TABLE schema_failure_probe (id integer); SELECT 1 / 0;',
    ),
  ]);
  @override
  void addShutdownTask(Future<void> Function() task) {}
}

final class _Work extends Subsystem {
  bool started = false;
  @override
  String get name => 'work';
  @override
  Set<ProcessRole> get roles => {ProcessRole.all};
  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {}
}

Future<void> _expectCompositeCatalog(Session session) async {
  final keys = await session.db.unsafeQuery('''
SELECT c.relname AS table_name, a.attname AS column_name
FROM pg_constraint p JOIN pg_class c ON c.oid = p.conrelid
JOIN LATERAL unnest(p.conkey) WITH ORDINALITY k(attnum, ordinality) ON true
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
WHERE p.contype = 'p' AND c.relname IN ('raw_inbox', 'events', 'outbox')
ORDER BY c.relname, k.ordinality
''');
  final actual = <String, List<String>>{};
  for (final row in keys) {
    final columns = row.toColumnMap();
    (actual[columns['table_name'] as String] ??= []).add(
      columns['column_name'] as String,
    );
  }
  expect(actual, {
    'raw_inbox': ['observed_at', 'raw_id'],
    'events': ['observed_at', 'event_id', 'disposition'],
    'outbox': ['created_at', 'delivery_id'],
  });
  final refs = await session.db.unsafeQuery("""
SELECT table_name, column_name FROM information_schema.columns
WHERE table_schema = current_schema() AND table_name IN ('events', 'outbox')
""");
  final columns = <String, Set<String>>{};
  for (final row in refs) {
    final values = row.toColumnMap();
    (columns[values['table_name'] as String] ??= {}).add(
      values['column_name'] as String,
    );
  }
  expect(columns['events'], containsAll(['raw_observed_at', 'raw_id']));
  expect(
    columns['outbox'],
    containsAll(['event_observed_at', 'event_id', 'event_disposition']),
  );
}

Future<void> _expectActivityCatalog(Session session) async {
  final rows = await session.db.unsafeQuery('''
SELECT column_name, data_type, udt_name, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = current_schema() AND table_name = 'activity'
''');
  final columns = {
    for (final row in rows)
      row.toColumnMap()['column_name'] as String: row.toColumnMap(),
  };
  expect(columns.keys.toSet(), {
    'id',
    'txid',
    'occurred_at',
    'entity_kind',
    'entity_id',
    'entity_version',
    'change_kind',
    'actor_kind',
    'actor_ref',
    'cause_event_id',
    'cause_raw_id',
  });
  expect(columns['id']!['data_type'], 'bigint');
  expect(columns['id']!['column_default'], contains('nextval('));
  expect(columns['txid']!['udt_name'], 'xid8');
  expect(columns['txid']!['is_nullable'], 'NO');
  expect(columns['txid']!['column_default'], 'pg_current_xact_id()');
  expect(columns['occurred_at']!['data_type'], 'timestamp with time zone');
  for (final name in [
    'entity_kind',
    'change_kind',
    'actor_kind',
    'actor_ref',
  ]) {
    expect(columns[name]!['data_type'], 'text');
  }
  for (final name in ['entity_id', 'entity_version']) {
    expect(columns[name]!['data_type'], 'bigint');
  }
  for (final name in ['cause_event_id', 'cause_raw_id']) {
    expect(columns[name]!['data_type'], 'uuid');
  }
  final indexes = await session.db.unsafeQuery('''
SELECT i.indisprimary, array_agg(a.attname::text ORDER BY k.ordinality) AS columns
FROM pg_index i
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum, ordinality) ON true
JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
WHERE n.nspname = current_schema() AND t.relname = 'activity'
GROUP BY i.indexrelid, i.indisprimary
''');
  final indexColumns = indexes.map((row) => row.toColumnMap()).toList();
  expect(
    indexColumns,
    contains(
      allOf(
        containsPair('indisprimary', true),
        containsPair('columns', ['id']),
      ),
    ),
  );
  expect(indexColumns, contains(containsPair('columns', ['txid', 'id'])));
  final outcome = await session.db.unsafeQuery('''
SELECT data_type, is_nullable FROM information_schema.columns
WHERE table_schema = current_schema() AND table_name = 'events'
  AND column_name = 'state_outcome'
''');
  expect(outcome.single.toColumnMap(), {
    'data_type': 'text',
    'is_nullable': 'YES',
  });
  final checks = await session.db.unsafeQuery('''
SELECT pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = current_schema() AND t.relname = 'events' AND c.contype = 'c'
''');
  expect(
    checks.map((row) => row.toColumnMap()['definition']),
    contains(
      allOf(contains('state_outcome'), contains('applied'), contains('stale')),
    ),
  );
}

Future<void> insertEvent(
  Session session,
  String id,
  String sourceTime, {
  String? effective,
}) => session.db.unsafeSimpleExecute('''
INSERT INTO events
  (observed_at, event_id, disposition, raw_observed_at, raw_id, source_id,
   config_snapshot_id, source_time, payload${effective == null ? '' : ', effective_source_time'})
VALUES
  ('2026-01-01 12:00:00 UTC', '$id', 'ready', '2026-01-01 12:00:00 UTC',
   '00000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000002', 'snapshot',
   '$sourceTime', decode('01', 'hex')${effective == null ? '' : ", '$effective'"});
''');

Future<Map<String, DateTime>> effectiveTimes(Session session) async {
  final rows = await session.db.unsafeQuery(
    'SELECT event_id::text, events_effective_source_time(e) '
    'FROM events e',
  );
  return {
    for (final row in rows) row[0]! as String: row[1]! as DateTime,
  };
}

void main() {
  test('fresh_and_populated_schema_paths normal startup', () async {
    final fixture = await PodFixture.create([]);
    try {
      await ServerpodAdapter(fixture.pod).start();
      final session = await fixture.pod.createSession(enableLogging: false);
      try {
        final rows = await session.db.unsafeQuery(
          "SELECT to_regclass('raw_inbox') AS raw, to_regclass('events') AS events, to_regclass('outbox') AS outbox",
        );
        expect(rows.single.toColumnMap().values, everyElement(isNotNull));
      } finally {
        await session.close();
      }
    } finally {
      await fixture.shutdown();
    }
  }, tags: ['db']);
  withServerpod(
    'Fresh schema',
    (sessionBuilder, _) {
      test('fresh_and_populated_schema_paths', () async {
        final session = sessionBuilder.build();
        await initializeIngestSchema(session);
        await _expectCompositeCatalog(session);
        await _expectActivityCatalog(session);
        final pluginColumns = await session.db.unsafeQuery(
          "SELECT column_name FROM information_schema.columns WHERE table_schema=current_schema() AND table_name='outbox' AND column_name IN ('output_kind','definition_digest')",
        );
        expect(
          pluginColumns.map((row) => row[0]),
          containsAll(['output_kind', 'definition_digest']),
        );
        final rows = await session.db.unsafeQuery(
          "SELECT to_regclass('raw_inbox') AS raw, to_regclass('events') AS events, to_regclass('outbox') AS outbox",
        );
        final tables = rows.single.toColumnMap();
        expect(tables['raw'], isNotNull);
        expect(tables['events'], isNotNull);
        expect(tables['outbox'], isNotNull);
        final versions = await session.db.unsafeQuery(
          'SELECT version FROM correlia_schema_versions',
        );
        expect(versions.length, schemaSteps.length);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
  withServerpod(
    'Populated M1 source registry',
    (sessionBuilder, _) {
      test('source credentials migration preserves registered UUIDs', () async {
        final session = sessionBuilder.build();
        // Reconstruct the previous managed baseline in this group's database.
        await session.db.unsafeSimpleExecute('''
DROP TABLE ingest_source_credential, secret_record;
ALTER TABLE ingest_source DROP COLUMN "kind";
ALTER TABLE ingest_source ADD COLUMN "tokenDigest" text NOT NULL;
UPDATE serverpod_migrations SET version = '20261112105628203-plugin-configure-diagnostics'
  WHERE module = 'correlia';
INSERT INTO ingest_source ("sourceId", enabled, "allowPathToken", "tokenDigest")
VALUES ('11111111-1111-4111-8111-111111111111', true, false, repeat('a', 64)),
       ('22222222-2222-4222-8222-222222222222', false, true, repeat('b', 64));
''');
        await session.db.unsafeSimpleExecute(
          await File(
            'migrations/20261118163655466-source-secrets/migration.sql',
          ).readAsString(),
        );
        final rows = await session.db.unsafeQuery('''
SELECT "sourceId"::text, kind, enabled, "allowPathToken"
FROM ingest_source ORDER BY "sourceId"
''');
        expect(rows.map((row) => row.toList()), [
          ['11111111-1111-4111-8111-111111111111', 'alertmanager', true, false],
          ['22222222-2222-4222-8222-222222222222', 'alertmanager', false, true],
        ]);
        final credentials = await session.db.unsafeQuery(
          'SELECT 1 FROM ingest_source_credential',
        );
        expect(credentials, isEmpty);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
  withServerpod(
    'Populated previous release',
    (sessionBuilder, _) {
      test('fresh_and_populated_schema_paths upgrade', () async {
        final session = sessionBuilder.build();
        // This group has its own ephemeral database. Reconstruct the prior
        // managed baseline before replaying the generated forward migration.
        await session.db.unsafeSimpleExecute('''
DROP TABLE delivery_attempts, ingest_active_config, ingest_config_snapshot,
  ingest_secret_commitment, ingest_source, observation_keys,
  pipeline_failures, transport_keys;
UPDATE serverpod_migrations SET version = '20261103184038320'
  WHERE module = 'correlia';
CREATE TABLE baseline_marker (value text NOT NULL);
INSERT INTO baseline_marker VALUES ('preserved');
''');
        final migration = await File(
          'migrations/20261111210905779-ingest/migration.sql',
        ).readAsString();
        await session.db.unsafeSimpleExecute(migration);
        await initializeIngestSchema(session);
        await _expectCompositeCatalog(session);
        final marker = await session.db.unsafeQuery(
          'SELECT value FROM baseline_marker',
        );
        expect(marker.single.toColumnMap()['value'], 'preserved');
        final result = await session.db.unsafeQuery(
          "SELECT to_regclass('raw_inbox') AS raw, to_regclass('events') AS events, to_regclass('outbox') AS outbox",
        );
        expect(result.single.toColumnMap().values, everyElement(isNotNull));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
  withServerpod(
    'Populated version 1 schema',
    (sessionBuilder, _) {
      test('activity_schema_populated_v1_upgrade', () async {
        final session = sessionBuilder.build();
        await applySchemaSteps(session, [schemaSteps.first]);
        await session.db.unsafeSimpleExecute('''
INSERT INTO raw_inbox
  (observed_at, raw_id, source_id, body, body_sha256, content_type)
VALUES
  ('2026-01-01 UTC', '00000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000002', decode('01', 'hex'), 'digest', 'application/json');
INSERT INTO events
  (observed_at, event_id, disposition, raw_observed_at, raw_id, source_id,
   config_snapshot_id, source_time, payload)
VALUES
  ('2026-01-01 UTC', '00000000-0000-0000-0000-000000000003', 'ready',
   '2026-01-01 UTC', '00000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000002', 'snapshot',
   '2026-01-01 UTC', decode('01', 'hex'));
''');
        await applySchemaSteps(session, schemaSteps);
        await _expectActivityCatalog(session);
        final events = await session.db.unsafeQuery(
          'SELECT state_outcome FROM events',
        );
        expect(events.single.toColumnMap()['state_outcome'], isNull);
        for (final value in ['applied', 'stale']) {
          await session.db.unsafeExecute(
            'UPDATE events SET state_outcome = @value',
            parameters: QueryParameters.named({'value': value}),
          );
        }
        await expectLater(
          session.db.unsafeExecute(
            "UPDATE events SET state_outcome = 'invalid'",
          ),
          throwsA(anything),
        );
        final raw = await session.db.unsafeQuery(
          'SELECT raw_id FROM raw_inbox',
        );
        expect(raw, hasLength(1));
        final versions = await session.db.unsafeQuery(
          'SELECT version FROM correlia_schema_versions ORDER BY version',
        );
        expect(versions.map((row) => row.toColumnMap()['version']), [
          1,
          2,
          3,
          4,
        ]);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
  withServerpod(
    'Schema step 4',
    (sessionBuilder, _) {
      test('events_stored_before_the_upgrade', () async {
        final session = sessionBuilder.build();
        await applySchemaSteps(session, schemaSteps.take(3).toList());
        const id = '00000000-0000-0000-0000-0000000000a1';
        await insertEvent(session, id, '2026-01-01 15:00:00 UTC');
        Future<Object?> fileNode() async => (await session.db.unsafeQuery(
          "SELECT relfilenode::text FROM pg_class WHERE oid = 'events'::regclass",
        )).single[0];
        final before = await fileNode();
        await applySchemaSteps(session, schemaSteps);
        expect(await fileNode(), before, reason: 'step 4 rewrote events');
        final stored = await session.db.unsafeQuery(
          'SELECT effective_source_time FROM events',
        );
        expect(stored.single[0], isNull);
        expect(await effectiveTimes(session), {
          id: DateTime.utc(2026, 1, 1, 12, 5),
        });
        final versions = await session.db.unsafeQuery(
          'SELECT version FROM correlia_schema_versions WHERE version = 4',
        );
        expect(versions, hasLength(1));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
  withServerpod(
    'Schema step 4 sub-microsecond evidence',
    (sessionBuilder, _) {
      test('sub_microsecond_evidence', () async {
        final session = sessionBuilder.build();
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
        ).publish(config_fixture.input(1));
        final repo = PipelineRepository(
          sessionBuilder.build(),
          clock: () => pipeline_fixture.now,
        );
        var observed = pipeline_fixture.now;
        Future<Map<String, Object?>> observe(String name, int nanos) async {
          observed = observed.add(const Duration(seconds: 1));
          await pipeline_fixture.seed(session, [
            payload.alert(
              startsAt:
                  '2026-11-10T11:59:00.000000${nanos.toString().padLeft(3, '0')}Z',
              labels: {'alertname': name, 'severity': 'warning'},
            ),
          ], observed: observed);
          await repo.pinOne();
          await repo.processOne();
          final outcome = (await session.db.unsafeQuery(
            'SELECT outcome_json FROM raw_inbox ORDER BY observed_at DESC '
            'LIMIT 1',
          )).single[0];
          return jsonDecode(outcome! as String) as Map<String, Object?>;
        }

        Future<List<Object?>> fence() async => (await session.db.unsafeQuery(
          'SELECT "fenceEffectiveSeconds", "fenceEffectiveNanos", '
          '"fenceEventId" FROM alerts',
        )).single.toList();

        // Before the upgrade: the fence of an alert at t + 900 ns, and its
        // event row as the previous release stored it, without the column
        // step 4 adds. The release before step 4 is rebuilt around them.
        expect((await observe('Reversed', 900))['applied'], 1);
        await session.db.unsafeSimpleExecute('''
DROP FUNCTION events_effective_source_time(events);
ALTER TABLE events DROP COLUMN effective_source_time;
DELETE FROM correlia_schema_versions WHERE version = 4;
''');
        final before = await fence();
        expect(before[1], 900);
        await applySchemaSteps(session, schemaSteps);
        expect(await fence(), before, reason: 'step 4 changed the fence');

        // After the upgrade: t + 800 ns, received later, is decided against
        // that same fence and is stale.
        final reversed = await observe('Reversed', 800);
        expect((reversed['applied'], reversed['stale']), (0, 1));
        expect(await fence(), before);
        // t + 800 ns first: t + 900 ns is newer, so applied.
        expect((await observe('InOrder', 800))['applied'], 1);
        final inOrder = await observe('InOrder', 900);
        expect((inOrder['applied'], inOrder['stale']), (1, 0));

        // Every effective time reads as t truncated to the microsecond: the
        // pre-upgrade row through the step's expression, the others from the
        // column.
        final t = DateTime.utc(2026, 11, 10, 11, 59);
        final times = await session.db.unsafeQuery(
          'SELECT event_id::text, effective_source_time, '
          'events_effective_source_time(e) FROM events e',
        );
        expect(times, hasLength(4));
        for (final row in times) {
          final upgraded = row[0] == before[2];
          expect([row[1], row[2]], [upgraded ? null : t, t]);
        }
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
  withServerpod(
    'Plugin output schema upgrade',
    (sessionBuilder, _) {
      test('plugin_schema_preserves_webhooks_and_enforces_kinds', () async {
        final session = sessionBuilder.build();
        await applySchemaSteps(session, schemaSteps.take(2).toList());
        await session.db.unsafeSimpleExecute('''
INSERT INTO outbox
 (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
  config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload)
VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',gen_random_uuid(),
 'old','https://example.com/events','key','digest',decode('01','hex'));
''');
        await applySchemaSteps(session, schemaSteps);
        final old = (await session.db.unsafeQuery(
          'SELECT output_kind,definition_digest,target_url FROM outbox',
        )).single;
        expect(old[0], 'webhook');
        expect(old[1], isNull);
        expect(old[2], 'https://example.com/events');
        await session.db.unsafeSimpleExecute('''
INSERT INTO outbox
 (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
  config_snapshot_id,output_kind,definition_digest,payload)
VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',gen_random_uuid(),
 'new','plugin','digest',decode('01','hex'));
''');
        for (final sql in [
          "UPDATE outbox SET output_kind='invalid' WHERE output_kind='plugin'",
          "UPDATE outbox SET definition_digest=NULL WHERE output_kind='plugin'",
          "UPDATE outbox SET target_url=NULL WHERE output_kind='webhook'",
          "UPDATE outbox SET signing_key_ref=NULL WHERE output_kind='webhook'",
          "UPDATE outbox SET signing_key_commitment=NULL WHERE output_kind='webhook'",
        ]) {
          await expectLater(
            session.db.unsafeSimpleExecute(sql),
            throwsA(anything),
          );
        }
        final index = await session.db.unsafeQuery(
          "SELECT indexdef FROM pg_indexes WHERE schemaname=current_schema() AND indexname='outbox_definition_status_idx'",
        );
        expect(
          index.single[0],
          contains('(output_id, definition_digest, status)'),
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
  withServerpod(
    'Schema steps',
    (sessionBuilder, _) {
      test('fresh_and_populated_schema_paths', () async {
        final first = sessionBuilder.build();
        final second = sessionBuilder.build();
        await first.db.unsafeSimpleExecute(
          'CREATE TABLE baseline_marker (value text NOT NULL)',
        );
        await first.db.unsafeSimpleExecute(
          "INSERT INTO baseline_marker VALUES ('preserved')",
        );
        await Future.wait([
          initializeIngestSchema(first),
          initializeIngestSchema(second),
        ]);
        final baseline = await first.db.unsafeQuery(
          'SELECT value FROM baseline_marker',
        );
        expect(baseline.single.toColumnMap()['value'], 'preserved');
        final versions = await first.db.unsafeQuery(
          'SELECT version FROM correlia_schema_versions',
        );
        expect(versions.length, schemaSteps.length);
        final keys = await first.db.unsafeQuery('''
SELECT c.relname AS table_name, a.attname AS column_name, k.ordinality AS position
FROM pg_constraint p JOIN pg_class c ON c.oid = p.conrelid
JOIN LATERAL unnest(p.conkey) WITH ORDINALITY k(attnum, ordinality) ON true
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
WHERE p.contype = 'p' AND c.relname IN ('raw_inbox', 'events', 'outbox')
ORDER BY c.relname, k.ordinality
''');
        final actual = <String, List<String>>{};
        for (final row in keys) {
          final columns = row.toColumnMap();
          (actual[columns['table_name'] as String] ??= []).add(
            columns['column_name'] as String,
          );
        }
        expect(actual, {
          'raw_inbox': ['observed_at', 'raw_id'],
          'events': ['observed_at', 'event_id', 'disposition'],
          'outbox': ['created_at', 'delivery_id'],
        });
        final references = await first.db.unsafeQuery(
          "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name IN ('events', 'outbox')",
        );
        final columns = references.map((row) => row.toColumnMap()).toList();
        expect(
          columns,
          containsAll([
            containsPair('column_name', 'raw_observed_at'),
            containsPair('column_name', 'raw_id'),
            containsPair('column_name', 'event_observed_at'),
            containsPair('column_name', 'event_id'),
            containsPair('column_name', 'event_disposition'),
          ]),
        );
        for (final file
            in Directory('migrations')
                .listSync(recursive: true)
                .whereType<File>()
                .where(
                  (f) =>
                      f.path.endsWith('definition.json') ||
                      f.path.endsWith('definition_project.json'),
                )) {
          final definition = await file.readAsString();
          for (final name in ['raw_inbox', 'events', 'outbox', 'activity']) {
            expect(definition, isNot(contains('"name": "$name"')));
          }
        }
      });

      test('failed_schema_step', () async {
        final session = sessionBuilder.build();
        await expectLater(
          applySchemaSteps(session, [
            const SchemaStep(
              999,
              'CREATE TABLE schema_failure_probe (id integer); SELECT 1 / 0;',
            ),
          ]),
          throwsA(
            isA<SchemaStepException>().having((e) => e.version, 'version', 999),
          ),
        );
        final rows = await session.db.unsafeQuery(
          "SELECT to_regclass('schema_failure_probe') AS probe",
        );
        expect(rows.single.toColumnMap()['probe'], isNull);
        final versions = await session.db.unsafeQuery(
          'SELECT version FROM correlia_schema_versions WHERE version = 999',
        );
        expect(versions, isEmpty);
        final work = _Work();
        final startup = StartupState();
        final runtime = RoleRuntime(
          role: ProcessRole.all,
          registry: [work],
          port: _SchemaPort(session),
          startup: startup,
          log: (_) {},
        );
        final result = await runtime.start();
        expect(result, isA<StartFailed>());
        expect(
          (result as StartFailed).message,
          contains('Schema step 999 failed'),
        );
        expect(work.started, isFalse);
        expect(startup.subsystemsStarted, isFalse);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
