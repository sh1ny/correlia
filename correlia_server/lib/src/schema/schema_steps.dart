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

/// The sanitized class of a schema initialization failure.
enum SchemaFailureClass {
  /// A lock was not granted within the step's `lock_timeout` (SQLSTATE 55P03).
  lockTimeout('lock_timeout'),

  /// Any other failure; the cause is not reported.
  failed('failed');

  const SchemaFailureClass(this.label);

  /// The name printed at startup.
  final String label;
}

/// How long a schema transaction waits for any lock in production.
const defaultSchemaLockTimeout = Duration(seconds: 30);

/// A sanitized schema initialization failure.
final class SchemaStepException implements Exception {
  /// Creates a failure identifying only its step and failure class.
  const SchemaStepException(
    this.version, [
    this.failureClass = SchemaFailureClass.failed,
  ]);

  /// The failed step number, or zero for version-table initialization.
  final int version;

  /// The sanitized failure class.
  final SchemaFailureClass failureClass;

  @override
  String toString() => 'Schema step $version failed: ${failureClass.label}';
}

SchemaFailureClass _classify(Object error) =>
    error is DatabaseQueryException && error.code == '55P03'
    ? SchemaFailureClass.lockTimeout
    : SchemaFailureClass.failed;

/// Bounds every lock wait of the transaction, advisory locks included.
///
/// It must be the first statement, before the advisory lock is requested.
Future<void> _setLockTimeout(
  Session session,
  Transaction transaction,
  Duration lockTimeout,
) => session.db.unsafeSimpleExecute(
  "SET LOCAL lock_timeout = '${lockTimeout.inMilliseconds}ms'",
  transaction: transaction,
);

/// The ordered schema scripts shipped with the server package.
List<SchemaStep> get schemaSteps => [
  SchemaStep(1, File('schema/0001_ingest.sql').readAsStringSync()),
  SchemaStep(2, File('schema/0002_activity.sql').readAsStringSync()),
  SchemaStep(3, File('schema/0003_plugin_outputs.sql').readAsStringSync()),
  SchemaStep(4, File('schema/0004_icinga2.sql').readAsStringSync()),
];

/// Applies each missing step under the shared transaction advisory lock.
///
/// Every transaction first sets `lock_timeout` to [lockTimeout], so waiting
/// behind another starter or for a lock on a table fails with
/// [SchemaFailureClass.lockTimeout] and records nothing.
///
/// The caller must provide a session not already bound to a transaction.
Future<void> applySchemaSteps(
  Session session,
  List<SchemaStep> steps, {
  Duration lockTimeout = defaultSchemaLockTimeout,
}) async {
  try {
    await session.db.transaction((transaction) async {
      await _setLockTimeout(session, transaction, lockTimeout);
      await session.db.unsafeQuery(
        'SELECT pg_advisory_xact_lock(1129271885)',
        transaction: transaction,
      );
      await session.db.unsafeSimpleExecute(
        'CREATE TABLE IF NOT EXISTS correlia_schema_versions (version integer PRIMARY KEY)',
        transaction: transaction,
      );
    });
  } catch (error) {
    throw SchemaStepException(0, _classify(error));
  }
  var previous = 0;
  for (final step in steps) {
    if (step.version <= previous) {
      throw ArgumentError('Schema steps must be ordered');
    }
    previous = step.version;
    try {
      await session.db.transaction((transaction) async {
        await _setLockTimeout(session, transaction, lockTimeout);
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
    } catch (error) {
      throw SchemaStepException(step.version, _classify(error));
    }
  }
}

/// Initializes the installed SQL-owned schema.
Future<void> initializeSchema(
  Session session, {
  Duration lockTimeout = defaultSchemaLockTimeout,
}) async {
  final List<SchemaStep> steps;
  try {
    steps = schemaSteps;
  } catch (_) {
    throw const SchemaStepException(1);
  }
  await applySchemaSteps(session, steps, lockTimeout: lockTimeout);
}
