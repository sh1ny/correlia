---
phase: 01-foundations-contracts-and-database-invariant
plan: 3
subsystem: persistence
tags: [alembic, sqlalchemy, postgresql, migrations, testcontainers, jsonb, partial-unique-index]
requires:
  - phase: 01-01
    provides: [Python 3.14 uv environment, Pydantic v2 dependencies, pytest configuration, async SQLAlchemy engine helpers]
  - phase: 01-02
    provides: [IncidentStatus enum values OPEN/RESOLVED/CLOSED, DecisionContext bounded metadata envelope]
provides:
  - Alembic async migration environment with script_location = migrations
  - PostgreSQL incidents table migration with check constraints, JSONB fields, and partial unique index
  - SQLAlchemy 2.0 Incident model matching migration columns and invariants
  - Testcontainers-backed migration and schema invariant verification
affects: [01-04-incident-repository, phase-02-ingestion-rules, incident-upsert-behavior]
tech-stack:
  added: []
  patterns:
    - "Alembic async engine via async_engine_from_config and connection.run_sync"
    - "PostgreSQL partial unique index on (rule_name, group_key) WHERE status = 'OPEN'"
    - "Testcontainers PostgreSQL for migration and constraint verification"
    - "SQLAlchemy 2.0 declarative models with mapped_column and JSONB"
key-files:
  created:
    - alembic.ini
    - migrations/env.py
    - migrations/script.py.mako
    - migrations/versions/__init__.py
    - migrations/versions/0001_create_incidents.py
    - app/persistence/models.py
    - tests/test_migrations.py
  modified: []
key-decisions:
  - "Testcontainers PostgresContainer returns postgresql+psycopg2:// by default; force postgresql+asyncpg:// for SQLAlchemy async compatibility"
patterns-established:
  - "Alembic env.py reads runtime database_url from -x cmd_opts list parsing, falling back to Settings"
  - "SQLAlchemy inspector calls must happen inside conn.run_sync when using AsyncConnection"
requirements-completed: [FND-03, PRS-01, PRS-02, PRS-04]
duration: 10min
completed: 2026-06-08
---

# Phase 1 Plan 3: Alembic Migration Environment, Incident Schema, and PostgreSQL Invariant Summary

**Alembic async migration environment, PostgreSQL incidents table with JSONB metadata and a partial unique index enforcing one OPEN incident per rule/group, and Testcontainers-backed schema verification.**

## Performance

- **Duration:** 10 min
- **Started:** 2026-06-08T13:13:08Z
- **Completed:** 2026-06-08T13:23:40Z
- **Tasks:** 3 completed
- **Files modified:** 7

## Accomplishments

- Created `alembic.ini` with `script_location = migrations` and no embedded database secrets.
- Created `migrations/env.py` using Alembic's async engine pattern: imports `Base.metadata`, reads runtime database URL from `-x database_url=...` or `Settings()`, and runs migrations through `connection.run_sync(do_run_migrations)`.
- Created `migrations/script.py.mako` as a standard typed Alembic revision template.
- Created `migrations/versions/0001_create_incidents.py` with `revision = "0001_create_incidents"` and `down_revision = None`, creating the `incidents` table with:
  - UUID primary key, `rule_name`, `group_key`, `status`, `severity`, `summary`
  - `event_count` with default 1 and check constraint `event_count >= 1`
  - `affected_hosts`, `affected_services`, `decision_context` as PostgreSQL `JSONB` with empty array/object defaults
  - Lifecycle timestamps: `start_time`, `last_update_time`, `acknowledged_at`, `acknowledged_by`, `resolved_at`, `closed_at`, `created_at`, `updated_at`
  - Check constraints `ck_incidents_status` (`OPEN`, `RESOLVED`, `CLOSED` only) and `ck_incidents_severity` (`OK`, `WARNING`, `UNKNOWN`, `CRITICAL`)
  - Partial unique index `incidents_one_open_per_rule_group` on `(rule_name, group_key) WHERE status = 'OPEN'`
- Created `app/persistence/models.py` with `Base(DeclarativeBase)`, `Incident` SQLAlchemy model matching the migration, and constants `OPEN_INCIDENT_UNIQUE_INDEX_NAME` and `OPEN_INCIDENT_UNIQUE_PREDICATE_SQL`.
- Created `tests/test_migrations.py` with Testcontainers PostgreSQL fixture and 6 tests verifying Alembic upgrade, table/column/JSONB introspection, check constraints, partial unique index predicate, duplicate OPEN insertion blocking, and RESOLVED + OPEN coexistence.

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Alembic async migration environment** - `e3227da` (chore)
2. **Task 2 RED: Add failing migration and schema invariant tests** - `e52af68` (test)
3. **Task 2 GREEN: Implement incident migration and SQLAlchemy model** - `4824ae9` (feat)
4. **Task 3: Verify migration constraints and partial index with PostgreSQL** - `1a6faf4` (test)

**Plan metadata:** pending final docs commit

## Files Created/Modified

- `alembic.ini` - Alembic configuration with script_location = migrations, no DB secrets.
- `migrations/__init__.py` - Package marker.
- `migrations/env.py` - Async Alembic environment importing Base metadata, runtime DB URL from -x or Settings.
- `migrations/script.py.mako` - Standard Alembic revision template.
- `migrations/versions/__init__.py` - Package marker.
- `migrations/versions/0001_create_incidents.py` - Initial migration creating incidents table with constraints, JSONB, timestamps, and partial unique index.
- `app/persistence/models.py` - SQLAlchemy 2.0 Base and Incident model with index-name constants.
- `tests/test_migrations.py` - Testcontainers-backed PostgreSQL migration and schema invariant tests.

## Decisions Made

- Followed plan-specified column names, constraints, and index exactly; no drift between migration and model.
- Used `mapped_column(JSONB)` with `server_default` in the model to match migration defaults.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed Alembic `-x` option parsing in env.py**
- **Found during:** Task 2 (GREEN verification)
- **Issue:** `config.cmd_opts.x` is a list of strings, not a dict; `.get("database_url")` raised `AttributeError: 'list' object has no attribute 'get'`.
- **Fix:** Iterated the list and split on `database_url=` prefix to extract the runtime URL.
- **Files modified:** `migrations/env.py`
- **Verification:** `uv run pytest tests/test_migrations.py -x` passed after fix.
- **Committed in:** `4824ae9`

**2. [Rule 3 - Blocking] Fixed Testcontainers driver replacement in test fixture**
- **Found during:** Task 2 (GREEN verification)
- **Issue:** `PostgresContainer.get_connection_url()` returns `postgresql+psycopg2://` by default, but the project uses `asyncpg`. A naive `.replace("postgresql://", "postgresql+asyncpg://")` missed the psycopg2 variant.
- **Fix:** Replaced both `postgresql+psycopg2://` and `postgresql://` prefixes with `postgresql+asyncpg://`.
- **Files modified:** `tests/test_migrations.py`
- **Verification:** Alembic subprocess upgrade succeeded against Testcontainers PostgreSQL.
- **Committed in:** `4824ae9`

**3. [Rule 1 - Bug] Fixed SQLAlchemy inspect on AsyncConnection**
- **Found during:** Task 2 (GREEN verification)
- **Issue:** `sa.inspect(conn)` where `conn` is an `AsyncConnection` raises `NoInspectionAvailable`. Inspection must happen on a sync connection.
- **Fix:** Restructured tests to call `sa.inspect(sync_conn)` inside `conn.run_sync(...)` lambdas.
- **Files modified:** `tests/test_migrations.py`
- **Verification:** `test_migration_creates_incidents_table` and `test_incidents_columns_and_types` passed after fix.
- **Committed in:** `4824ae9`

---

**Total deviations:** 3 auto-fixed (1 bug, 1 blocking, 1 bug)
**Impact on plan:** All fixes were local to reliable plan execution and did not change product scope.

## Issues Encountered

- Task 2 RED test run failed as expected with `ModuleNotFoundError: No module named 'app.persistence.models'` before implementation.
- No auth gates encountered.

## Verification Results

- `uv run alembic --help` — PASS (Task 1)
- `uv run pytest tests/test_migrations.py -x` — PASS: `6 passed` (Task 2 GREEN, Task 3)
- Task 1 acceptance checks — PASS: script_location, no secrets, Base import, async_engine_from_config + run_sync, no auto-run in app/main.py
- Task 2 acceptance checks — PASS: create_table, create_index, status check text without ACKNOWLEDGED, timestamps in migration+model, JSONB in migration+model, no raw_events table
- Task 3 acceptance checks — PASS: Testcontainers import, no sqlite, exact index name and OPEN predicate, duplicate OPEN blocked, RESOLVED+OPEN allowed
- Stub scan — PASS: no TODO/FIXME/placeholder/coming-soon/not-available stubs in created implementation files.
- Threat surface scan — PASS: no new routes, auth paths, or YAML loading introduced. Migration DDL uses fixed names; no user input reaches DDL.

## User Setup Required

None - no external service configuration required.

## Known Stubs

None.

## TDD Gate Compliance

- RED commit exists for Task 2: `e52af68`
- GREEN commit exists after RED: `4824ae9`
- No refactor commit was needed.

## Next Phase Readiness

Plan 01-04 can consume `app.persistence.models.Incident`, `Base.metadata`, and `OPEN_INCIDENT_UNIQUE_INDEX_NAME` for the incident repository and atomic upsert implementation. Plan 02 can rely on the PostgreSQL schema being migration-managed. No blockers remain.

## Self-Check: PASSED

- Found SUMMARY and key implementation/test files on disk.
- Found task commits `e3227da`, `e52af68`, `4824ae9`, and `1a6faf4` in git history.
- Plan-local verification passed with `6 passed`.

---
*Phase: 01-foundations-contracts-and-database-invariant*
*Completed: 2026-06-08*
