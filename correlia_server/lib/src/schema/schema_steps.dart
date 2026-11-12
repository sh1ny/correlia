import 'dart:io';

import 'package:serverpod/serverpod.dart';

/// A forward-only, independently committed schema step.
final class SchemaStep {
  /// Creates a step from its version and SQL statements.
  const SchemaStep(this.version, this.sql);

  /// The monotonically increasing step version.
  final int version;

  /// The complete PostgreSQL script.
  final String sql;
}

/// A sanitized schema initialization failure.
final class SchemaStepException implements Exception {
  /// Creates a failure identifying only its step.
  const SchemaStepException(this.version);

  /// The failed step number, or zero for version-table initialization.
  final int version;

  @override
  String toString() => 'Schema step $version failed';
}

/// The ordered schema scripts shipped with the server package.
List<SchemaStep> get schemaSteps => [
  SchemaStep(1, File('schema/0001_ingest.sql').readAsStringSync()),
  SchemaStep(2, File('schema/0002_activity.sql').readAsStringSync()),
  SchemaStep(3, File('schema/0003_plugin_outputs.sql').readAsStringSync()),
];

/// Applies each missing step under the shared transaction advisory lock.
///
/// The caller must provide a session not already bound to a transaction.
Future<void> applySchemaSteps(Session session, List<SchemaStep> steps) async {
  try {
    await session.db.transaction((transaction) async {
      await session.db.unsafeQuery(
        'SELECT pg_advisory_xact_lock(1129271885)',
        transaction: transaction,
      );
      await session.db.unsafeSimpleExecute(
        'CREATE TABLE IF NOT EXISTS correlia_schema_versions (version integer PRIMARY KEY)',
        transaction: transaction,
      );
    });
  } catch (_) {
    throw const SchemaStepException(0);
  }
  var previous = 0;
  for (final step in steps) {
    if (step.version <= previous) {
      throw ArgumentError('Schema steps must be ordered');
    }
    previous = step.version;
    try {
      await session.db.transaction((transaction) async {
        await session.db.unsafeQuery(
          'SELECT pg_advisory_xact_lock(1129271885)',
          transaction: transaction,
        );
        final existing = await session.db.unsafeQuery(
          'SELECT version FROM correlia_schema_versions WHERE version = @version',
          parameters: QueryParameters.named({'version': step.version}),
          transaction: transaction,
        );
        if (existing.isNotEmpty) return;
        await session.db.unsafeSimpleExecute(
          step.sql,
          transaction: transaction,
        );
        await session.db.unsafeExecute(
          'INSERT INTO correlia_schema_versions (version) VALUES (@version)',
          parameters: QueryParameters.named({'version': step.version}),
          transaction: transaction,
        );
      });
    } catch (_) {
      throw SchemaStepException(step.version);
    }
  }
}

/// Initializes the installed SQL-owned schema.
Future<void> initializeSchema(Session session) async {
  final List<SchemaStep> steps;
  try {
    steps = schemaSteps;
  } catch (_) {
    throw const SchemaStepException(1);
  }
  await applySchemaSteps(session, steps);
}
