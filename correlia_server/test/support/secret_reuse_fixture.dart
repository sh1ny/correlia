import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:serverpod/serverpod.dart';

/// Installs the old schema and clears inventory state in this test database.
Future<void> prepareHistoricalReuse(Session session) async {
  const cutoverVersion = 5;
  await applySchemaSteps(
    session,
    schemaSteps.where((step) => step.version < cutoverVersion).toList(),
  );
  await session.db.unsafeSimpleExecute('''
    DELETE FROM correlia_schema_versions WHERE version IN ($cutoverVersion, 10);
    DROP FUNCTION IF EXISTS correlia_require_publisher_version() CASCADE;
    DROP FUNCTION IF EXISTS correlia_keep_retired_credential_digest() CASCADE;
    DROP FUNCTION IF EXISTS test_interrupt_inventory(), test_check_inventory_batch(), test_gate_inventory() CASCADE;
    DROP TABLE IF EXISTS secret_reuse_digest,secret_reuse_backfill,secret_reuse_retired_credential;
    TRUNCATE ingest_source_credential,ingest_source,secret_record,ingest_active_config,
      ingest_config_snapshot,ingest_secret_commitment,raw_inbox,outbox RESTART IDENTITY CASCADE;
  ''');
}
