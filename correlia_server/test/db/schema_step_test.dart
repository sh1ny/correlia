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
          for (final name in ['raw_inbox', 'events', 'outbox']) {
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
