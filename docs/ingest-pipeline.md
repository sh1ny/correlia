# Ingest pipeline schema ownership

Serverpod migrations own source and configuration snapshots, the active pointer, secret commitments, transport and observation keys, pipeline failures and delivery attempts. Correlia's ordered `correlia_server/schema/*.sql` steps exclusively own `raw_inbox`, `events` and `outbox`. These tables have no generated table models. They are ordinary PostgreSQL tables with time-qualified composite primary keys; future partition maintenance remains with the SQL schema owner. References to SQL-owned identities always include their time component. Managed tables do not have foreign keys to SQL-owned tables.

## Fresh databases and upgrades

Start the server from `correlia_server`, with its `schema/` directory deployed alongside the package. Serverpod applies managed migrations first. Each process role then initializes the schema before starting its subsystems, even if ingest is not configured. A transaction advisory lock serializes starters, and each step and its version record commit together. Existing steps are immutable: append a new numbered script and register it in the runner for every forward change. Both a fresh installation and an upgrade need the schema steps because Serverpod fresh installs use its latest managed definition rather than replaying every migration SQL file.

The database test helper `test/support/ingest_schema.dart` must receive a non-rollback session and run after managed migrations. Do not change generated test tools or hand-edit generated migration definitions. Failure of a schema step rolls back that step and prevents subsystem startup; fix the underlying problem and restart. The reported error names the step without exposing database details.

## Repair migrations

Serverpod's repair diff sees SQL-owned tables as extraneous and may propose destructive changes. Before applying any generated repair, inspect its entire SQL against the current schema and **remove all operations that drop or alter** `raw_inbox`, `events`, `outbox`, `correlia_schema_versions`, their indexes, constraints and time-qualified references. Review related cascades as well. Preserve data and the version table; never force a destructive repair merely to silence drift. Inspect any other unmanaged exceptions individually. If the desired SQL-owned schema itself needs correction, write a new forward schema step, not an edit to an applied step or a generated definition. Review the resulting repair and schema step together on a populated copy before production use.

## Identity evidence

Alertmanager's upstream fingerprint is retained in raw input and, when present, the `correlia.io/alertmanager_fingerprint` extension. It is not a label or an identity input. Original selected labels determine identity; see ADR 0024. Source-side setup screenshots have not been collected.
