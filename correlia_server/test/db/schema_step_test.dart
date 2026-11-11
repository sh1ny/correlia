import 'dart:io';

import 'package:correlia_server/src/schema/schema_steps.dart';
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
        expect(versions.map((row) => row.toColumnMap()['version']), [1, 2]);
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
