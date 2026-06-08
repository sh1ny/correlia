---
phase: 01-foundations-contracts-and-database-invariant
verified: 2026-06-08T14:00:00Z
status: passed
score: 12/12 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: null
  previous_score: null
  gaps_closed: []
  gaps_remaining: []
  regressions: []
gaps: []
deferred: []
human_verification: []
---

# Phase 1: Foundations, Contracts, and Database Invariant Verification Report

**Phase Goal:** As a Correlia maintainer, run the backend with strict startup/config contracts so later alert and incident slices build on a reliable API-first service.
**Verified:** 2026-06-08
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #   | Truth                                                                                                          | Status     | Evidence                                                                                                                                                                                                                                                                                                                                                       |
| --- | -------------------------------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Maintainer can install and run the FastAPI service with Python 3.14+, uv-managed dependencies, validated settings, Alembic migrations, and a REST health endpoint. | ✓ VERIFIED | `pyproject.toml` requires `>=3.14`; `uv.lock` exists and `uv lock --check` passes (50 packages resolved); `Makefile` wraps `test`, `lint`, `typecheck`, `run` via `uv run`; `create_app()` imports and constructs a FastAPI app; `alembic --help` works; `/health` and `/readyz` routes exist and are tested. |
| 2   | Input, config, and persistence code share strict domain contracts for normalized events, event type, incident lifecycle, severity, tags, messages, timestamps, and optional debug metadata. | ✓ VERIFIED | `app/domain/events.py` defines `NormalizedEvent`, `EventType`, `Severity`, `SEVERITY_RANK`, and `max_severity()` with `ConfigDict(strict=True, extra="forbid")`. `app/domain/incidents.py` defines `IncidentStatus`, `Acknowledgement`, `DecisionContext`, and transition helpers. Both are imported by persistence and API layers. |
| 3   | Malformed domain/config data fails with explicit validation errors instead of silently accepting partial or coerced state. | ✓ VERIFIED | Tests in `tests/test_domain_events.py` (17 passed), `tests/test_domain_incidents.py` (28 passed), and `tests/test_settings.py` (10 passed) assert explicit `ValidationError` / `ValueError` for missing fields, extra fields, naive timestamps, invalid tags, string coercion, forbidden metadata keys, invalid environment/log_level values, and empty strings. |
| 4   | PostgreSQL enforces one active incident per rule/group and supports atomic incident upsert without SELECT-then-INSERT behavior. | ✓ VERIFIED | Migration `0001_create_incidents.py` creates partial unique index `incidents_one_open_per_rule_group` on `(rule_name, group_key) WHERE status = 'OPEN'`. `app/persistence/incidents.py` uses `insert(...).on_conflict_do_update(index_where=text(...))` with no `select(` inside `upsert_open_incident` or `build_open_incident_upsert`. `tests/test_migrations.py` (6 passed) and `tests/test_incident_repository.py` (27 passed) verify duplicate OPEN blocking, RESOLVED+OPEN coexistence, max severity, JSONB merge, and 100-item bounds. |

**Score:** 12/12 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
| -------- | -------- | ------ | ------- |
| `pyproject.toml` | Python 3.14+ uv-managed project contract | ✓ VERIFIED | `requires-python = ">=3.14"`, runtime + dev dependencies listed, `pythonpath = ["."]` for pytest, Ruff target `py314`, mypy strict on `app` |
| `uv.lock` | Single locked project environment | ✓ VERIFIED | 147.8KB lockfile present, `uv lock --check` exits 0, `requirements.txt` absent |
| `Makefile` | uv-backed maintainer command wrappers | ✓ VERIFIED | Targets `test`, `lint`, `typecheck`, `run` all prefixed with `uv run` |
| `app/config/settings.py` | Strict application settings | ✓ VERIFIED | `BaseSettings` with `env_prefix="CORRELIA_"`, `extra="forbid"`, `DATABASE_URL` alias via `PostgresDsn`, literal env/log_level fields, optional config paths |
| `app/persistence/database.py` | Async PostgreSQL engine/session/readiness helpers | ✓ VERIFIED | `create_engine`, `create_sessionmaker`, `check_database_ready` with fixed `text("select 1")`, no URL logging |
| `app/domain/events.py` | Strict NormalizedEvent, EventType, Severity, and severity ordering | ✓ VERIFIED | `StrEnum` types, `SEVERITY_RANK`, `TagKey`/`TagValue` constraints, timezone validator, no `.dict()`/`.parse_obj()` |
| `app/domain/incidents.py` | IncidentStatus, lifecycle transition helpers, acknowledgement metadata, DecisionContext | ✓ VERIFIED | Exactly `OPEN`, `RESOLVED`, `CLOSED`; `Acknowledgement` with timezone validator; `DecisionContext` rejects secret-shaped keys and raw payloads |
| `alembic.ini` | Alembic configuration for `migrations/` | ✓ VERIFIED | `script_location = migrations`, no embedded secrets |
| `migrations/env.py` | Async Alembic environment | ✓ VERIFIED | Imports `Base.metadata`, reads runtime DB URL from `-x` or Settings, uses `async_engine_from_config` + `connection.run_sync` |
| `migrations/versions/0001_create_incidents.py` | Initial incident migration | ✓ VERIFIED | `revision = "0001_create_incidents"`, creates `incidents` table with check constraints, JSONB fields, timestamps, partial unique index |
| `app/persistence/models.py` | SQLAlchemy model metadata matching migration | ✓ VERIFIED | `Base(DeclarativeBase)`, `Incident` model with `DateTime(timezone=True)` on all timestamps, `JSONB` columns with server defaults, index-name constants |
| `app/persistence/incidents.py` | Atomic open-incident upsert repository | ✓ VERIFIED | `IncidentUpsertInput` frozen dataclass with `__post_init__` validation; `build_open_incident_upsert` uses `on_conflict_do_update` with literal `index_where`; `upsert_open_incident` returns fresh `Incident(**mapping)` |
| `app/main.py` | FastAPI app factory and lifespan wiring | ✓ VERIFIED | `create_app(settings, sessionmaker)` with lifespan-managed engine/sessionmaker disposal; stores resources on `app.state` |
| `app/api/deps.py` | Request dependencies for settings and sessionmaker | ✓ VERIFIED | `get_app_settings` and `get_sessionmaker` read from `request.app.state` |
| `app/api/routers/health.py` | Health and readiness API routes | ✓ VERIFIED | `GET /health` returns `{"status":"ok"}` without DB; `GET /readyz` calls `check_database_ready` and returns `503 {"detail":"not ready"}` on failure with sanitized body |
| `tests/test_settings.py` | Settings validation tests | ✓ VERIFIED | 10 passed — covers valid defaults, model config, explicit validation errors, fixed `select 1` SQL, Makefile target checks |
| `tests/test_domain_events.py` | NormalizedEvent TDD tests | ✓ VERIFIED | 17 passed — covers enum contracts, valid events, missing fields, extra fields, coercion rejection, naive timestamps, tag validation |
| `tests/test_domain_incidents.py` | Incident lifecycle TDD tests | ✓ VERIFIED | 28 passed — covers status values, acknowledgement, transitions, terminal-state blocking, DecisionContext acceptance/rejection of secrets and bounds |
| `tests/test_migrations.py` | Testcontainers-backed migration tests | ✓ VERIFIED | 6 passed — Alembic upgrade, table/column/JSONB introspection, check constraints, partial unique index predicate, duplicate OPEN blocking, RESOLVED+OPEN coexistence |
| `tests/test_incident_repository.py` | PostgreSQL upsert/index behavior tests | ✓ VERIFIED | 27 passed — insert, update, uniqueness, terminal-status coexistence, max severity, JSONB set merge, 100-item bounds, decision context persistence, SQL injection literal persistence, secret metadata rejection, no SELECT inside upsert |
| `tests/test_health.py` | HTTPX/ASGI health and readiness tests | ✓ VERIFIED | 4 passed — `/health` success, `/readyz` success, `/readyz` sanitized 503 failure, out-of-scope route exclusion |

### Key Link Verification

| From | To | Via | Status | Details |
| ---- | -- | --- | ------ | ------- |
| `app/config/settings.py` | `app/persistence/database.py` | Validated `DATABASE_URL` feeds async engine creation | ✓ WIRED | `create_engine(str(settings.database_url))` |
| `app/main.py` | `app/api/routers/health.py` | Router include | ✓ WIRED | `app.include_router(health_router)` |
| `app/api/routers/health.py` | `app/persistence/database.py` | Readiness dependency executes SELECT 1 | ✓ WIRED | `await check_database_ready(sessionmaker)` inside `/readyz` |
| `app/persistence/incidents.py` | `app/persistence/models.py` | Incident model and partial-index constants | ✓ WIRED | Imports `Incident`, `OPEN_INCIDENT_UNIQUE_INDEX_NAME` |
| `app/persistence/incidents.py` | `app/domain/events.py` | Severity max ranking | ✓ WIRED | Imports `Severity`, `SEVERITY_RANK` via `_severity_rank_expr` |
| `app/persistence/incidents.py` | `app/domain/incidents.py` | IncidentStatus.OPEN and DecisionContext | ✓ WIRED | Imports `IncidentStatus`, `DecisionContext`; uses `.model_dump(mode="json")` |
| `migrations/versions/0001_create_incidents.py` | `app/persistence/models.py` | Matching incidents columns and index name | ✓ WIRED | Same columns, constraints, JSONB defaults, timestamp semantics, partial index name and predicate |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
| -------- | ------------- | ------ | ------------------ | ------ |
| `app/persistence/incidents.py` | `IncidentUpsertInput.decision_context` | `DecisionContext.model_dump(mode="json")` | Yes — typed Pydantic model validated in `__post_init__` | ✓ FLOWING |
| `app/api/routers/health.py` | `readyz` response | `check_database_ready(sessionmaker)` | Yes — executes actual `select 1` against PostgreSQL | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
| -------- | ------- | ------ | ------ |
| FastAPI app imports | `uv run python -c "from app.main import create_app; create_app()"` | `create_app ok` | ✓ PASS |
| uv lock valid | `uv lock --check` | `Resolved 50 packages` | ✓ PASS |
| Lint clean | `uv run ruff check .` | `All checks passed!` | ✓ PASS |
| Typecheck clean | `uv run mypy app` | `Success: no issues found in 15 source files` | ✓ PASS |
| Full test suite | `uv run pytest -q` | `92 passed in 9.18s` | ✓ PASS |

### Probe Execution

No phase-declared or conventional probes found. Phase 1 does not include migration/tooling probes; verification relies on the test suite and static checks above.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
| ----------- | ----------- | ----------- | ------ | -------- |
| **FND-01** | 01-01 | Python 3.14+, uv-managed dependencies, locked environment | ✓ SATISFIED | `pyproject.toml` requires `>=3.14`, `uv.lock` present and valid, no `requirements.txt` |
| **FND-02** | 01-01 | Validated application settings without code changes | ✓ SATISFIED | `Settings` with `extra="forbid"`, `CORRELIA_` prefix, `DATABASE_URL` alias, literal field validation |
| **FND-03** | 01-03 | Alembic migrations | ✓ SATISFIED | `alembic.ini`, `migrations/env.py`, `migrations/versions/0001_create_incidents.py`, verified with Testcontainers |
| **FND-04** | 01-05 | REST health endpoint | ✓ SATISFIED | `/health` and `/readyz` routes in `app/api/routers/health.py`, tested via HTTPX/ASGI |
| **DOM-01** | 01-02 | NormalizedEvent with all required fields | ✓ SATISFIED | `NormalizedEvent` in `app/domain/events.py` with fingerprint, source_id, host, service, severity, event_type, timestamp, tags, message, ip_address |
| **DOM-02** | 01-02 | PROBLEM/RECOVERY event classification | ✓ SATISFIED | `EventType(StrEnum)` with exactly `PROBLEM` and `RECOVERY` |
| **DOM-03** | 01-02 | Incident lifecycle states | ✓ SATISFIED | `IncidentStatus.OPEN`, `RESOLVED`, `CLOSED`; acknowledgement as metadata via `Acknowledgement` |
| **DOM-04** | 01-02 | Explicit validation errors for malformed data | ✓ SATISFIED | `strict=True`, `extra="forbid"`, timezone validators, forbidden-key validators; 55 domain tests assert explicit errors |
| **PRS-01** | 01-03, 01-04 | PostgreSQL incidents table with required fields | ✓ SATISFIED | Migration and model define all columns; repository upserts persist them |
| **PRS-02** | 01-03, 01-04 | One active incident per rule/group at DB layer | ✓ SATISFIED | Partial unique index `incidents_one_open_per_rule_group`; duplicate OPEN blocked, RESOLVED+OPEN allowed |
| **PRS-03** | 01-04 | Atomic PostgreSQL upsert without SELECT-then-INSERT | ✓ SATISFIED | `insert(...).on_conflict_do_update(...)` in `build_open_incident_upsert`; test asserts no `select(` in upsert source |
| **PRS-04** | 01-02, 01-03, 01-04 | Optional raw/debug event or decision metadata | ✓ SATISFIED | `decision_context` JSONB column in migration/model; `DecisionContext` bounded metadata envelope with secret rejection |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| ---- | ---- | ------- | -------- | ------ |
| *(none)* | — | — | — | — |

Scan results: no `TBD`, `FIXME`, `XXX`, `TODO`, `HACK`, `PLACEHOLDER`, `placeholder`, `coming soon`, `will be here`, `not yet implemented`, `not available`, `return null`, `return {}`, `return []`, or `=> {}` patterns found in modified/created files.

### Human Verification Required

None. Phase 1 is entirely backend infrastructure, domain contracts, database schema, and automated tests. No visual appearance, user flow completion, real-time behavior, external service integration, or performance feel requires human testing.

### Gaps Summary

No gaps found. All 12 requirement IDs mapped to Phase 1 are satisfied. All 92 automated tests pass. Lint and typecheck are clean. The phase goal is achieved.

---

_Verified: 2026-06-08_
_Verifier: Claude (gsd-verifier)_
