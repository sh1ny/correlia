# Phase 1: Foundations, Contracts, and Database Invariant - Research

**Researched:** 2026-06-08
**Domain:** Python 3.14+ FastAPI service foundation, strict Pydantic v2 domain contracts, PostgreSQL/Alembic incident invariants
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

Copied verbatim from `.planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md`. [CITED: .planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md]

### Locked Decisions

## Implementation Decisions

### Active Incident Lifecycle
- **D-01:** Model acknowledgement as metadata on an active incident, not as an incident status. Use fields such as `acknowledged_at` and `acknowledged_by`; the incident remains `OPEN` until source recovery, expiration, or manual close changes lifecycle state.
- **D-02:** Lock the Phase 1 incident statuses to `OPEN`, `RESOLVED`, and `CLOSED`. Do not include `ACKNOWLEDGED` in `IncidentStatus`.
- **D-03:** Enforce active incident uniqueness with a PostgreSQL partial unique index on `(rule_name, group_key) WHERE status = 'OPEN'`.
- **D-04:** Phase 1 should define domain transition helpers/invariants for planned lifecycle transitions: `OPEN -> RESOLVED`, `OPEN -> CLOSED`, and no reopening of `RESOLVED`/`CLOSED` incidents. Recovery, expiration, and REST mutation implementations arrive later, but the model should prevent scattered lifecycle logic.
- **D-05:** Incident aggregation identity is exactly `rule_name + group_key`. Source, host, service, and fingerprint are incident content/metadata, not uniqueness identity.
- **D-06:** Incident timestamps should include `start_time`, `last_update_time`, `created_at`, `updated_at`, plus nullable `resolved_at` and `closed_at` from the initial migration.
- **D-07:** Incident severity should store the current maximum severity seen while the incident is `OPEN`, not just the latest event severity.
- **D-08:** Represent affected hosts/services as bounded deterministic JSONB sets (`affected_hosts`, `affected_services`) in v1. Do not introduce a membership table in Phase 1.

### Incident Debug Metadata
- **D-09:** Support compact decision metadata, not full raw source payload storage, in Phase 1.
- **D-10:** Defer a concrete `raw_events` table until Phase 2 ingestion produces real payload/redaction requirements. Phase 1 should define the storage seam and add compact incident-side debug context.
- **D-11:** `decision_context` may contain only non-secret processing facts: normalized fingerprint, source id, rule/group details, matched rule names, enrichment provenance references, event counts, config version/hash, and similar explainability data. It must not contain raw payloads, credentials, plugin config secrets, or arbitrary plugin JSON.
- **D-12:** Use a typed metadata envelope with stable top-level keys/version and JSON-serializable bounded details. Avoid completely free-form JSONB.

### Domain Contract Strictness
- **D-13:** `NormalizedEvent` validation at the plugin/core boundary is strict and fail-fast. Missing, ambiguous, or coerced values should produce explicit validation errors rather than permissive normalization.
- **D-14:** Phase 1 should define explicit enums/literals for `EventType`, `Severity`, and `IncidentStatus`.
- **D-15:** Event tags are a strict `dict[str, str]` style contract with non-empty keys and values and a normalized key format. Do not model tags as a list or free JSON object.
- **D-16:** Event timestamps must be timezone-aware. Reject naive timestamps. Keep source event time distinct from processing/database timestamps.

### Service Bootstrap Surface
- **D-17:** Expose both liveness and readiness basics in Phase 1: `/health` for process liveness and `/readyz` for database/config readiness. Do not add metrics/config-summary endpoints yet.
- **D-18:** Validate application settings only in Phase 1: `DATABASE_URL`, environment/log level, and paths for future rule/topology/plugin config. Concrete rule/topology/plugin YAML loading belongs to later phases.
- **D-19:** Provide Makefile targets in addition to uv commands for common maintainer flows: test, lint, typecheck, and run. uv remains the package manager/source of truth.
- **D-20:** Include full initial Alembic setup and migration for the incidents table, enum/status constraints, JSONB metadata fields, timestamps, and the partial unique index. Do not stop at an Alembic scaffold.

### Claude's Discretion
No selected area was delegated to Claude. Downstream agents should treat the decisions above as locked.

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| FND-01 | Maintainer can install and run Correlia with Python 3.14+, uv-managed dependencies, and a single locked project environment. [CITED: .planning/REQUIREMENTS.md] | Use `pyproject.toml` + `uv.lock`, `requires-python = ">=3.14"`, uv commands, and Makefile wrappers. [CITED: https://docs.astral.sh/uv/concepts/projects/] |
| FND-02 | Maintainer can configure Correlia settings without code changes using validated application settings. [CITED: .planning/REQUIREMENTS.md] | Use `pydantic-settings.BaseSettings`; validate `DATABASE_URL`, log level/environment, and future config paths at startup. [CITED: https://docs.pydantic.dev/latest/concepts/pydantic_settings/] |
| FND-03 | Maintainer can evolve the PostgreSQL schema through Alembic migrations. [CITED: .planning/REQUIREMENTS.md] | Initialize Alembic async template and hand-author the first migration; Alembic documents async engine integration via `run_sync`. [CITED: https://alembic.sqlalchemy.org/en/latest/cookbook.html#using-asyncio-with-alembic] |
| FND-04 | Operator can check basic service health through a REST health endpoint. [CITED: .planning/REQUIREMENTS.md] | Use FastAPI routers for `/health` liveness and `/readyz` database/config readiness. [CITED: https://fastapi.tiangolo.com/advanced/events/] |
| DOM-01 | Input plugins can convert source payloads into a `NormalizedEvent` with fingerprint, source ID, host, optional service, severity, event type, timestamp, tags, message, and optional IP address. [CITED: .planning/REQUIREMENTS.md] | Define a strict Pydantic v2 `NormalizedEvent` in `domain/events.py`; plugin implementations arrive later but must target this contract. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/] |
| DOM-02 | Correlia classifies events as `PROBLEM` or `RECOVERY` independently of the source monitoring system. [CITED: .planning/REQUIREMENTS.md] | Define `EventType` enum with only `PROBLEM` and `RECOVERY`; never infer lifecycle branch from source-specific severity in core code. [CITED: .planning/research/PITFALLS.md] |
| DOM-03 | Correlia represents incidents with stable lifecycle states for active, manually acknowledged, source-resolved, and expired/manually closed incidents. [CITED: .planning/REQUIREMENTS.md] | Use `IncidentStatus = OPEN | RESOLVED | CLOSED`; represent acknowledgement as metadata on `OPEN`, per locked D-01/D-02. [CITED: .planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md] |
| DOM-04 | Correlia rejects malformed domain/config data with explicit validation errors instead of accepting partial or coerced state. [CITED: .planning/REQUIREMENTS.md] | Use Pydantic strict fields/model config, validators, non-empty tag constraints, and `extra="forbid"` for settings/domain debug envelopes. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/] |
| PRS-01 | Correlia persists aggregated incidents in PostgreSQL with rule name, group key, lifecycle status, severity, timestamps, summary, event count, and affected hosts. [CITED: .planning/REQUIREMENTS.md] | Initial migration must create `incidents` with typed columns plus bounded JSONB sets and decision context. [CITED: .planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md] |
| PRS-02 | Correlia enforces one active incident per rule and group key at the database layer. [CITED: .planning/REQUIREMENTS.md] | Create `CREATE UNIQUE INDEX ... ON incidents (rule_name, group_key) WHERE status = 'OPEN'`; PostgreSQL documents unique partial indexes enforcing uniqueness on predicate-matching rows. [CITED: https://www.postgresql.org/docs/18/indexes-partial.html] |
| PRS-03 | Correlia updates active incidents with an atomic PostgreSQL upsert instead of SELECT-then-INSERT logic. [CITED: .planning/REQUIREMENTS.md] | Use PostgreSQL `INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING`; PostgreSQL documents atomic insert-or-update under high concurrency. [CITED: https://www.postgresql.org/docs/18/sql-insert.html] |
| PRS-04 | Maintainer can optionally persist raw/debug event or decision metadata needed to explain incident behavior. [CITED: .planning/REQUIREMENTS.md] | Phase 1 should add compact typed `decision_context`/debug envelope fields on incidents and defer a concrete `raw_events` table. [CITED: .planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md] |
</phase_requirements>

## Summary

Phase 1 is a greenfield backend foundation: create a Python 3.14+ uv project, wire a minimal FastAPI app, validate settings with `pydantic-settings`, create Alembic/PostgreSQL persistence, and define strict domain contracts before any source-specific ingestion exists. [CITED: .planning/ROADMAP.md] The Roadmap still says Python 3.13 in one success criterion, but `CLAUDE.md`, `.planning/PROJECT.md`, `.planning/REQUIREMENTS.md`, `STATE.md`, and the user assignment all require Python 3.14+; the planner must use Python 3.14+. [CITED: CLAUDE.md]

The core invariant is PostgreSQL-owned, not repository-owned: one `OPEN` incident per `(rule_name, group_key)` through a partial unique index, and active incident mutation through a single `INSERT ... ON CONFLICT ... DO UPDATE` statement targeting that partial index predicate. [CITED: https://www.postgresql.org/docs/18/indexes-partial.html] [CITED: https://www.postgresql.org/docs/18/sql-insert.html] SQLite is not a substitute for any plan, test, or fallback that touches incident correctness. [CITED: CLAUDE.md]

**Primary recommendation:** Build the boring modular-monolith skeleton first, then lock strict Pydantic domain contracts and the PostgreSQL partial-index/upsert invariant with focused unit and Testcontainers-backed integration tests. [CITED: .planning/research/ARCHITECTURE.md]

## Project Constraints (from CLAUDE.md)

| Directive | Planning Impact |
|-----------|-----------------|
| Use Python 3.14+, uv, FastAPI, PostgreSQL, SQLAlchemy 2.0+, asyncpg, Pydantic v2, and PyYAML. [CITED: CLAUDE.md] | Do not plan alternate stack selection. |
| No built-in frontend; REST APIs are the interface. [CITED: CLAUDE.md] | Phase 1 exposes only backend health/readiness REST routes. |
| Inputs, topology enrichers, outputs, storage-adjacent behavior, and task execution must remain modular. [CITED: CLAUDE.md] | Put contracts in `domain/` and adapters in `api/`, `config/`, `persistence/`; do not leak FastAPI/SQLAlchemy into domain models. |
| Durable state lives in PostgreSQL; logic lives in code/YAML rules. [CITED: CLAUDE.md] | Incident lifecycle state and uniqueness belong in schema/migrations, not memory. |
| Open incident aggregation must use a partial unique index and atomic upsert. [CITED: CLAUDE.md] | PRS-02/PRS-03 are phase-critical invariants. |
| PostgreSQL integration and concurrency behavior must use Testcontainers for Python; no SQLite-backed substitute. [CITED: CLAUDE.md] | Planner must include PostgreSQL integration tests for migrations/index/upsert. |
| GSD workflow says avoid direct edits outside GSD unless explicitly bypassed. [CITED: CLAUDE.md] | This research file is explicitly requested by `/gsd-plan-phase` scope. |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|--------------|----------------|-----------|
| Project install/run contract | API / Backend | — | Python runtime, uv lockfile, FastAPI entrypoint, and Makefile targets are backend service ownership. [CITED: CLAUDE.md] |
| Settings validation | API / Backend | OS/env | `BaseSettings` reads environment and validates typed backend config before serving. [CITED: https://docs.pydantic.dev/latest/concepts/pydantic_settings/] |
| Liveness `/health` | API / Backend | — | FastAPI owns HTTP process liveness. [CITED: https://fastapi.tiangolo.com/advanced/events/] |
| Readiness `/readyz` | API / Backend | Database / Storage | Backend checks settings and PostgreSQL reachability; database owns the readiness dependency. [CITED: .planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md] |
| Domain contracts | API / Backend | — | Pydantic models/enums define plugin-core and persistence contracts independent of source systems. [CITED: .planning/research/ARCHITECTURE.md] |
| Incident uniqueness | Database / Storage | API / Backend | PostgreSQL partial unique index enforces the invariant; repository code targets it. [CITED: https://www.postgresql.org/docs/18/indexes-partial.html] |
| Atomic incident upsert | Database / Storage | API / Backend | PostgreSQL guarantees atomic insert/update; SQLAlchemy emits the dialect-specific statement. [CITED: https://www.postgresql.org/docs/18/sql-insert.html] [CITED: https://docs.sqlalchemy.org/en/20/dialects/postgresql.html#insert-on-conflict-upsert] |
| Schema evolution | Database / Storage | API / Backend | Alembic migrations own schema history; app code imports metadata and connection config. [CITED: https://alembic.sqlalchemy.org/en/latest/cookbook.html#using-asyncio-with-alembic] |
| Compact decision metadata | Database / Storage | API / Backend | JSONB stores bounded incident-side explainability data; domain model constrains allowed shape. [CITED: .planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md] |

## Standard Stack

### Core
| Library / Tool | Version | Purpose | Why Standard |
|----------------|---------|---------|--------------|
| Python | 3.14+ | Runtime baseline | Required by project instructions and requirements. [CITED: CLAUDE.md] |
| `uv` [ASSUMED: slopcheck unavailable] | PyPI latest observed 0.11.19; installed locally 0.11.7 | Project manager, lockfile, virtualenv, command runner | uv docs define project management, lock/sync/run flows. [CITED: https://docs.astral.sh/uv/concepts/projects/] |
| `fastapi` [ASSUMED: slopcheck unavailable] | 0.136.3 | REST app, routers, OpenAPI, request/response validation | FastAPI docs support lifespan startup/shutdown and async app testing patterns. [CITED: https://fastapi.tiangolo.com/advanced/events/] |
| `uvicorn[standard]` [ASSUMED: slopcheck unavailable] | 0.49.0 | ASGI runtime | Standard FastAPI deployment server in project canonical stack. [CITED: .planning/research/STACK.md] |
| `pydantic` [ASSUMED: slopcheck unavailable] | 2.13.4 | Domain contracts and validation errors | Pydantic v2 strict mode rejects coercion where strictness is enabled. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/] |
| `pydantic-settings` [ASSUMED: slopcheck unavailable] | 2.14.1 | Environment/application settings | `BaseSettings` reads env/default sources and validates settings models. [CITED: https://docs.pydantic.dev/latest/concepts/pydantic_settings/] |
| PostgreSQL | 18 preferred; 17 acceptable if hosting requires | Authoritative incident state | PostgreSQL supports JSONB, partial unique indexes, and `ON CONFLICT`. [CITED: https://www.postgresql.org/docs/18/indexes-partial.html] |
| `SQLAlchemy` [ASSUMED: slopcheck unavailable] | 2.0.50 | ORM/Core, PostgreSQL DML construction | SQLAlchemy PostgreSQL dialect supports `on_conflict_do_update(index_elements=..., index_where=...)`. [CITED: https://docs.sqlalchemy.org/en/20/dialects/postgresql.html#insert-on-conflict-upsert] |
| `asyncpg` [ASSUMED: slopcheck unavailable] | 0.31.0 | Async PostgreSQL driver | Project stack locks asyncpg with SQLAlchemy async PostgreSQL dialect. [CITED: CLAUDE.md] |
| `alembic` [ASSUMED: slopcheck unavailable] | 1.18.4 | Schema migrations | Alembic docs provide async templates and async engine migration pattern. [CITED: https://alembic.sqlalchemy.org/en/latest/cookbook.html#using-asyncio-with-alembic] |
| `PyYAML` [ASSUMED: slopcheck unavailable] | 6.0.3 | YAML parser for later rules/topology/plugins | PyYAML docs warn unsafe `yaml.load`; `safe_load` limits construction to simple Python objects. [CITED: https://pyyaml.org/wiki/PyYAMLDocumentation] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `pytest` [ASSUMED: slopcheck unavailable] | 9.0.3 | Unit/integration test runner | Domain/settings/unit tests. [CITED: .planning/research/STACK.md] |
| `pytest-asyncio` [ASSUMED: slopcheck unavailable] | 1.4.0 | Async test support | Async service/repository tests; avoid mixed loop ownership. [CITED: .planning/research/STACK.md] |
| `httpx` [ASSUMED: slopcheck unavailable] | 0.28.1 | FastAPI ASGI tests | FastAPI docs use `AsyncClient` + `ASGITransport` for async tests. [CITED: https://fastapi.tiangolo.com/advanced/async-tests/] |
| `testcontainers` [ASSUMED: slopcheck unavailable] | 4.14.2 | PostgreSQL integration containers | Required for partial-index/upsert/migration verification; Docker is available locally. [CITED: CLAUDE.md] |
| `ruff` [ASSUMED: slopcheck unavailable] | 0.15.16 | Lint/format tool | Configure `target-version = "py314"`; do not run project-wide gates during this research. [CITED: .planning/research/STACK.md] |
| `mypy` [ASSUMED: slopcheck unavailable] | 2.1.0 | Static type checking | Useful for domain interfaces; runtime validation and DB tests remain primary. [CITED: .planning/research/STACK.md] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| FastAPI | Django REST Framework | Not recommended: project is API-first without Django admin/frontend needs. [CITED: .planning/research/STACK.md] |
| SQLAlchemy Core/ORM | SQLModel | Not recommended: SQLModel hides the PostgreSQL-specific upsert/index control Phase 1 needs. [CITED: .planning/research/STACK.md] |
| PostgreSQL | SQLite | Forbidden: SQLite cannot substitute for the PostgreSQL partial-index/upsert invariant. [CITED: CLAUDE.md] |
| PyYAML `safe_load` + Pydantic | `yaml.load` or raw dicts | Unsafe or too permissive; PyYAML documents `yaml.load` as unsafe for untrusted sources. [CITED: https://pyyaml.org/wiki/PyYAMLDocumentation] |

**Installation:**
```bash
uv init --python 3.14
uv add fastapi "uvicorn[standard]" sqlalchemy asyncpg alembic pydantic pydantic-settings pyyaml
uv add --dev pytest pytest-asyncio httpx ruff mypy testcontainers
```
[CITED: .planning/research/STACK.md]

**Version verification:** Package versions were queried from PyPI JSON on 2026-06-08; slopcheck could not run because `pip` and `slopcheck` were unavailable in this environment. [VERIFIED: PyPI JSON] [ASSUMED: package legitimacy]

## Package Legitimacy Audit

> Required because Phase 1 installs external Python packages. Slopcheck installation failed: `/usr/bin/python3: No module named pip`; `slopcheck` command was not available. [VERIFIED: local command output]

| Package | Registry | Age / Latest Upload | Downloads | Source Repo | slopcheck | Disposition |
|---------|----------|---------------------|-----------|-------------|-----------|-------------|
| uv | PyPI | 2026-06-03 | unavailable from PyPI JSON | https://pypi.org/project/uv/ | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| fastapi | PyPI | 2026-05-23 | unavailable from PyPI JSON | https://github.com/fastapi/fastapi | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| uvicorn | PyPI | 2026-06-03 | unavailable from PyPI JSON | https://github.com/Kludex/uvicorn | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| SQLAlchemy | PyPI | 2026-05-24 | unavailable from PyPI JSON | https://www.sqlalchemy.org | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| asyncpg | PyPI | 2025-11-24 | unavailable from PyPI JSON | none in PyPI JSON | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| alembic | PyPI | 2026-02-10 | unavailable from PyPI JSON | https://github.com/sqlalchemy/alembic/ | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| pydantic | PyPI | 2026-05-06 | unavailable from PyPI JSON | https://github.com/pydantic/pydantic | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| pydantic-settings | PyPI | 2026-05-08 | unavailable from PyPI JSON | https://github.com/pydantic/pydantic-settings | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| PyYAML | PyPI | 2025-09-25 | unavailable from PyPI JSON | https://github.com/yaml/pyyaml | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| pytest | PyPI | 2026-04-07 | unavailable from PyPI JSON | https://github.com/pytest-dev/pytest | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| pytest-asyncio | PyPI | 2026-05-26 | unavailable from PyPI JSON | https://github.com/pytest-dev/pytest-asyncio | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| httpx | PyPI | 2024-12-06 | unavailable from PyPI JSON | https://github.com/encode/httpx | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| ruff | PyPI | 2026-06-04 | unavailable from PyPI JSON | https://docs.astral.sh/ruff | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| mypy | PyPI | 2026-05-11 | unavailable from PyPI JSON | https://www.mypy-lang.org/ | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |
| testcontainers | PyPI | 2026-03-18 | unavailable from PyPI JSON | https://github.com/testcontainers/testcontainers-python | unavailable | Approved only with human/package verification checkpoint [ASSUMED] |

**Packages removed due to slopcheck [SLOP] verdict:** none — slopcheck unavailable, no verdicts. [VERIFIED: local command output]
**Packages flagged as suspicious [SUS]:** all recommended packages require human/package verification checkpoint before install because slopcheck was unavailable. [ASSUMED]

## Architecture Patterns

### System Architecture Diagram

```text
Maintainer startup
  -> uv sync / uv run / Makefile target
  -> Settings() validates env and config-path settings
  -> FastAPI lifespan initializes app resources
  -> /health returns process liveness
  -> /readyz checks settings + PostgreSQL connectivity

Domain data entering later phases
  -> Input plugin produces NormalizedEvent only
  -> Pydantic strict validation rejects malformed/coerced values
  -> IncidentManager receives rule_name + group_key + event facts
  -> SQLAlchemy PostgreSQL insert(...).on_conflict_do_update(index_where=status == OPEN)
  -> PostgreSQL incidents table + partial unique index enforce one OPEN row
  -> bounded JSONB decision_context stores non-secret explainability metadata
```
[CITED: .planning/research/ARCHITECTURE.md]

### Recommended Project Structure

```text
app/
├── main.py                  # create_app(), lifespan, router wiring [CITED: FastAPI lifespan docs]
├── api/
│   ├── deps.py              # settings/session dependencies [CITED: .planning/research/ARCHITECTURE.md]
│   └── routers/
│       └── health.py        # GET /health and /readyz [CITED: 01-CONTEXT.md]
├── config/
│   └── settings.py          # pydantic-settings app config [CITED: pydantic-settings docs]
├── domain/
│   ├── events.py            # NormalizedEvent, EventType, Severity [CITED: REQUIREMENTS.md]
│   └── incidents.py         # IncidentStatus, transitions, metadata envelope [CITED: 01-CONTEXT.md]
├── persistence/
│   ├── database.py          # async engine/session factory [CITED: SQLAlchemy docs]
│   ├── models.py            # SQLAlchemy incident table mapping [CITED: STACK.md]
│   └── incidents.py         # atomic upsert statement [CITED: PostgreSQL INSERT docs]
└── migrations/              # Alembic env.py + initial incident migration [CITED: Alembic docs]
```

### Pattern 1: Strict Pydantic Contract at Boundaries
**What:** Define strict Pydantic v2 models/enums for normalized events, incident state, decision metadata, and settings. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/]
**When to use:** Any data crossing plugin/core, config/app, API/domain, or persistence/domain boundaries. [CITED: .planning/research/ARCHITECTURE.md]
**Example:** See Code Examples. [CITED: https://docs.pydantic.dev/latest/concepts/validators/]

### Pattern 2: PostgreSQL Owns the Active-Incident Invariant
**What:** Migration creates `incidents_one_open_per_rule_group` partial unique index; repository upsert targets the same predicate. [CITED: https://www.postgresql.org/docs/18/indexes-partial.html]
**When to use:** Every matched `PROBLEM` event that mutates incident state. [CITED: .planning/REQUIREMENTS.md]
**Planner note:** Phase 1 should implement repository SQL and tests even if real rule evaluation arrives later; use a minimal direct repository test fixture, not source-ingestion mocks. [CITED: .planning/research/PITFALLS.md]

### Pattern 3: Alembic Migration Is the Schema Source of Truth
**What:** Create full initial migration, not just scaffold. [CITED: 01-CONTEXT.md]
**When to use:** Before any SQLAlchemy incident model is considered complete. [CITED: .planning/research/STACK.md]
**Planner note:** Hand-author enum/check constraints, JSONB defaults, timestamp defaults, and the partial unique index; autogenerate is review input only. [CITED: .planning/research/STACK.md]

### Anti-Patterns to Avoid
- **SELECT-then-INSERT incident creation:** races under concurrent alert bursts; use one PostgreSQL upsert. [CITED: .planning/research/PITFALLS.md]
- **`ACKNOWLEDGED` incident status:** removes active acknowledged rows from `WHERE status = 'OPEN'` uniqueness; use metadata fields. [CITED: 01-CONTEXT.md]
- **Naive timestamps:** cannot safely distinguish source event time from processing time; reject timezone-naive datetimes. [CITED: 01-CONTEXT.md]
- **Raw/free-form metadata:** can leak secrets and unbounded payloads; use a typed compact envelope. [CITED: 01-CONTEXT.md]
- **Project-wide gate execution during research/planning:** user explicitly said not to run project-wide build/test/lint/format gates. [CITED: user assignment]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Environment settings | Custom `os.environ` parser | `pydantic-settings.BaseSettings` | Handles env/default validation through a typed settings model. [CITED: https://docs.pydantic.dev/latest/concepts/pydantic_settings/] |
| Domain validation | Manual dict checks and coercion | Pydantic v2 strict models/validators | Strict mode errors instead of coercing ambiguous values. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/] |
| Schema migration history | Ad hoc SQL scripts | Alembic | Alembic provides migration environment and async engine integration. [CITED: https://alembic.sqlalchemy.org/en/latest/cookbook.html#using-asyncio-with-alembic] |
| Active incident dedupe | In-memory locks or SELECT-then-INSERT | PostgreSQL partial unique index + `ON CONFLICT` | PostgreSQL guarantees atomic insert/update under high concurrency. [CITED: https://www.postgresql.org/docs/18/sql-insert.html] |
| YAML object parsing | `yaml.load()` | `yaml.safe_load()` + Pydantic | PyYAML warns `yaml.load` is unsafe for untrusted sources. [CITED: https://pyyaml.org/wiki/PyYAMLDocumentation] |
| API server plumbing | Custom ASGI/HTTP layer | FastAPI + Uvicorn | Project stack and docs align with FastAPI lifespan and testing. [CITED: CLAUDE.md] |
| PostgreSQL integration test DB | SQLite | Testcontainers PostgreSQL | Project forbids SQLite substitutes for database-specific invariants. [CITED: CLAUDE.md] |

**Key insight:** The deceptively small Phase 1 invariant is concurrency behavior, not CRUD behavior; only PostgreSQL can prove it in the chosen architecture. [CITED: .planning/research/PITFALLS.md]

## Common Pitfalls

### Pitfall 1: Partial Index Predicate Drift
**What goes wrong:** Migration uses `status = 'OPEN'`, model uses a different enum value/case, or upsert omits `index_where`; conflict inference fails or targets the wrong index. [CITED: .planning/research/PITFALLS.md]
**How to avoid:** Define the index name and predicate once in migration/model conventions; add a focused integration test that verifies two same-rule/group `OPEN` writes yield one row. [CITED: https://docs.sqlalchemy.org/en/20/dialects/postgresql.html#insert-on-conflict-upsert]
**Warning signs:** `on_conflict_do_update(index_elements=[...])` appears without `index_where`. [CITED: .planning/research/PITFALLS.md]

### Pitfall 2: Acknowledgement Modeled as Status
**What goes wrong:** An acknowledged-but-active incident leaves the partial unique set and a new `OPEN` incident can be inserted for the same rule/group. [CITED: .planning/research/ARCHITECTURE.md]
**How to avoid:** Keep `IncidentStatus` to `OPEN`, `RESOLVED`, `CLOSED`; add nullable acknowledgement metadata on the incident. [CITED: 01-CONTEXT.md]
**Warning signs:** `ACKNOWLEDGED` appears in enum, migration check constraint, or partial-index predicate. [CITED: 01-CONTEXT.md]

### Pitfall 3: Pydantic Defaults Still Coerce Unexpectedly
**What goes wrong:** Strings such as `'123'` become ints, YAML booleans become bools, or missing values get defaults where fail-fast behavior is required. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/]
**How to avoid:** Use `ConfigDict(strict=True, extra="forbid")`, field constraints, `StrictStr`/strict fields where needed, and custom validators for tags/timestamps. [CITED: https://docs.pydantic.dev/latest/concepts/validators/]
**Warning signs:** Tests assert accepted coerced values instead of rejected invalid inputs. [CITED: .planning/research/PITFALLS.md]

### Pitfall 4: Readiness Equals Liveness
**What goes wrong:** `/health` returns OK even when config or database connectivity is broken, misleading operators. [CITED: .planning/research/PITFALLS.md]
**How to avoid:** `/health` should be process-only; `/readyz` should verify settings have loaded and the database can execute a cheap query. [CITED: 01-CONTEXT.md]
**Warning signs:** Only one health endpoint exists or readiness never touches PostgreSQL. [CITED: 01-CONTEXT.md]

### Pitfall 5: JSONB Metadata Becomes Raw Payload Storage
**What goes wrong:** Incident rows accumulate secrets, plugin configs, arbitrary payloads, or unbounded arrays. [CITED: 01-CONTEXT.md]
**How to avoid:** Define a versioned `DecisionContext` envelope with stable allowed keys and bounded JSON-serializable details. [CITED: 01-CONTEXT.md]
**Warning signs:** `decision_context: dict[str, Any]` accepts arbitrary plugin/source payloads. [CITED: 01-CONTEXT.md]

## Code Examples

Verified patterns from official sources and project decisions.

### Strict Domain Model with Timezone and Tag Validators
```python
from datetime import datetime
from enum import StrEnum
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, field_validator

class EventType(StrEnum):
    PROBLEM = "PROBLEM"
    RECOVERY = "RECOVERY"

class Severity(StrEnum):
    OK = "OK"
    WARNING = "WARNING"
    CRITICAL = "CRITICAL"
    UNKNOWN = "UNKNOWN"

TagKey = Annotated[str, Field(min_length=1, pattern=r"^[a-z][a-z0-9_.-]*$")]
TagValue = Annotated[str, Field(min_length=1, max_length=256)]

class NormalizedEvent(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    fingerprint: Annotated[str, Field(min_length=1)]
    source_id: Annotated[str, Field(min_length=1)]
    host: Annotated[str, Field(min_length=1)]
    service: str | None = None
    severity: Severity
    event_type: EventType
    timestamp: datetime
    tags: dict[TagKey, TagValue] = Field(default_factory=dict)
    message: Annotated[str, Field(min_length=1, max_length=4096)]
    ip_address: str | None = None

    @field_validator("timestamp", mode="after")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("timestamp must be timezone-aware")
        return value
```
Source: Pydantic strict mode and validators docs; timezone requirement from Phase 1 context. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/] [CITED: https://docs.pydantic.dev/latest/concepts/validators/] [CITED: 01-CONTEXT.md]

### Settings Model
```python
from pathlib import Path
from typing import Literal

from pydantic import Field, PostgresDsn
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="CORRELIA_",
        case_sensitive=False,
        extra="forbid",
    )

    database_url: PostgresDsn = Field(validation_alias="DATABASE_URL")
    environment: Literal["local", "test", "production"] = "local"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    rules_path: Path | None = None
    topology_path: Path | None = None
    plugins_path: Path | None = None
```
Source: Pydantic Settings docs and D-18. [CITED: https://docs.pydantic.dev/latest/concepts/pydantic_settings/] [CITED: 01-CONTEXT.md]

### FastAPI App Factory with Health/Readiness
```python
from contextlib import asynccontextmanager

from fastapi import FastAPI
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Settings/engine/sessionmaker are initialized before serving requests.
    yield
    # Dispose DB engine and other resources here.


def create_app(sessionmaker: async_sessionmaker) -> FastAPI:
    app = FastAPI(lifespan=lifespan)

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz() -> dict[str, str]:
        async with sessionmaker() as session:
            await session.execute(text("select 1"))
        return {"status": "ready"}

    return app
```
Source: FastAPI lifespan docs and D-17. [CITED: https://fastapi.tiangolo.com/advanced/events/] [CITED: 01-CONTEXT.md]

### SQLAlchemy PostgreSQL Partial-Index Upsert
```python
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import insert

stmt = insert(Incident).values(
    rule_name=rule_name,
    group_key=group_key,
    status="OPEN",
    severity=severity,
    start_time=event_time,
    last_update_time=event_time,
    event_count=1,
    affected_hosts=[host],
    decision_context=decision_context,
)

stmt = stmt.on_conflict_do_update(
    index_elements=[Incident.rule_name, Incident.group_key],
    index_where=(Incident.status == "OPEN"),
    set_={
        "event_count": Incident.event_count + 1,
        "last_update_time": func.greatest(Incident.last_update_time, stmt.excluded.last_update_time),
        "severity": func.greatest(Incident.severity, stmt.excluded.severity),
        "updated_at": func.now(),
        # JSONB merge/dedup should be implemented as a bounded deterministic helper or SQL expression.
    },
).returning(Incident)
```
Source: SQLAlchemy PostgreSQL dialect docs and PostgreSQL `INSERT ... ON CONFLICT` docs. [CITED: https://docs.sqlalchemy.org/en/20/dialects/postgresql.html#insert-on-conflict-upsert] [CITED: https://www.postgresql.org/docs/18/sql-insert.html]

### Alembic Migration Snippet for Active Incident Uniqueness
```python
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


def upgrade() -> None:
    op.create_table(
        "incidents",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("rule_name", sa.Text(), nullable=False),
        sa.Column("group_key", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("severity", sa.Text(), nullable=False),
        sa.Column("summary", sa.Text(), nullable=False),
        sa.Column("event_count", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("affected_hosts", postgresql.JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("affected_services", postgresql.JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("decision_context", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("start_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_update_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("acknowledged_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("acknowledged_by", sa.Text(), nullable=True),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.CheckConstraint("status IN ('OPEN', 'RESOLVED', 'CLOSED')", name="ck_incidents_status"),
    )
    op.create_index(
        "incidents_one_open_per_rule_group",
        "incidents",
        ["rule_name", "group_key"],
        unique=True,
        postgresql_where=sa.text("status = 'OPEN'"),
    )
```
Source: PostgreSQL partial unique index docs, SQLAlchemy PostgreSQL docs, and D-01 through D-08. [CITED: https://www.postgresql.org/docs/18/indexes-partial.html] [CITED: 01-CONTEXT.md]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Pydantic v1 `Config`, `.dict()`, `.parse_obj()` | Pydantic v2 `ConfigDict`, `model_dump`, `model_validate`, strict mode | Pydantic v2 era; current docs deprecate v1 `Config` style. [CITED: https://docs.pydantic.dev/latest/concepts/config/] | New code should use v2 APIs only. |
| FastAPI `startup`/`shutdown` decorators | `FastAPI(lifespan=...)` async context manager | FastAPI docs mark event handlers as alternative/deprecated when lifespan is used. [CITED: https://fastapi.tiangolo.com/advanced/events/] | Use lifespan for resource setup/teardown and readiness dependencies. |
| ORM merge/select-then-insert | PostgreSQL `ON CONFLICT ... DO UPDATE` | PostgreSQL docs define UPSERT as atomic under high concurrency. [CITED: https://www.postgresql.org/docs/18/sql-insert.html] | Prevents duplicate active incidents. |
| Syntax-only YAML validation | `yaml.safe_load()` then Pydantic semantic validation | PyYAML docs warn `yaml.load` can call arbitrary Python functions. [CITED: https://pyyaml.org/wiki/PyYAMLDocumentation] | Later config phases must fail fast and safely. |
| SQLite-backed DB tests | Testcontainers/local PostgreSQL | Project explicitly forbids SQLite substitutes. [CITED: CLAUDE.md] | Planner must provision PostgreSQL for invariant tests. |

**Deprecated/outdated:**
- `ACKNOWLEDGED` as a status is out of scope for Phase 1 and conflicts with locked decisions. [CITED: 01-CONTEXT.md]
- `/healthz` naming in prior architecture research is superseded by D-17 `/health` plus `/readyz`. [CITED: 01-CONTEXT.md]
- Roadmap's Python 3.13 mention is stale; use Python 3.14+. [CITED: .planning/STATE.md] [CITED: CLAUDE.md]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | All recommended Python packages are legitimate despite slopcheck being unavailable. | Package Legitimacy Audit / Standard Stack | Supply-chain risk; planner should add human/package verification checkpoint before install. |
| A2 | PostgreSQL 17 is acceptable if PostgreSQL 18 is unavailable. | Standard Stack | Managed hosting or Testcontainers image mismatch could affect exact behavior; rerun invariant tests on chosen major. |
| A3 | A text/check-constraint status column is acceptable instead of a PostgreSQL enum for Phase 1. | Code Examples | If planner chooses native enum, Alembic enum migration complexity increases; invariant is unchanged. |
| A4 | `affected_hosts`/`affected_services` JSONB arrays are sufficient in Phase 1 if bounded/deduplicated. | Architecture / Code Examples | Large incidents may require a membership table later; D-08 explicitly defers that in Phase 1. |

## Open Questions

1. **Should status/severity be native PostgreSQL enums or text plus check constraints?**
   - What we know: D-14 requires explicit enums/literals in domain, and D-20 requires enum/status constraints in migration. [CITED: 01-CONTEXT.md]
   - What's unclear: The context does not explicitly choose PostgreSQL native enum vs text check constraint. [CITED: 01-CONTEXT.md]
   - Recommendation: Use text plus named check constraints for the initial migration unless the planner wants native enum DDL; it keeps early migrations simpler while still enforcing allowed values. [ASSUMED]

2. **What exact severity ordering should `max severity` use?**
   - What we know: D-07 requires current maximum severity while `OPEN`. [CITED: 01-CONTEXT.md]
   - What's unclear: The canonical order among `OK`, `WARNING`, `CRITICAL`, `UNKNOWN` is not specified for incident aggregation. [CITED: .planning/REQUIREMENTS.md]
   - Recommendation: Define an explicit rank mapping in `domain/events.py` and store either ranked integer plus display enum, or use a SQL `CASE` expression in upsert. [ASSUMED]

3. **Should `/readyz` run migrations or only check current DB state?**
   - What we know: D-17 says readiness checks database/config readiness; FND-03 says Alembic evolves schema. [CITED: 01-CONTEXT.md] [CITED: .planning/REQUIREMENTS.md]
   - What's unclear: No decision says the service auto-runs migrations. [CITED: 01-CONTEXT.md]
   - Recommendation: Do not auto-run migrations in app startup; readiness can fail if the DB is unavailable or schema is not at expected revision, while maintainer runs `alembic upgrade head`/Makefile target explicitly. [ASSUMED]

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| uv | FND-01 install/run | ✓ | installed `uv 0.11.7`; PyPI latest observed 0.11.19 | Use installed uv or upgrade via approved project setup. [VERIFIED: local command output] |
| Python 3.14+ | FND-01 runtime | ✗ | local `python3` is 3.12.3 | Use `uv python install 3.14` / uv-managed interpreter before implementation. [VERIFIED: local command output] |
| Docker | Testcontainers PostgreSQL tests | ✓ | Docker 29.4.1, daemon available | — [VERIFIED: local command output] |
| PostgreSQL CLI/server (`psql`, `pg_isready`) | Manual DB checks | ✗ | not installed in PATH | Use Testcontainers for automated tests; optional install for maintainer convenience. [VERIFIED: local command output] |
| Alembic CLI | FND-03 migrations | ✗ | not installed globally | Available after `uv sync`/`uv run alembic`. [VERIFIED: local command output] |
| pytest/ruff/mypy CLIs | Verification/lint/typecheck targets | ✗ | not installed globally | Available after dev dependency install via uv. [VERIFIED: local command output] |
| Context7 `ctx7` CLI | Research docs fallback | ✗ | not installed | Official docs were fetched directly with Read. [VERIFIED: local command output] |
| slopcheck | Package legitimacy | ✗ | no `pip`, no `slopcheck` command | Add human/package verification checkpoint before installing dependencies. [VERIFIED: local command output] |

**Missing dependencies with no fallback:** none for planning; implementation must first provision Python 3.14+ through uv. [ASSUMED]

**Missing dependencies with fallback:** Python 3.14+ via uv-managed interpreter; PostgreSQL via Testcontainers/Docker; project CLIs via uv dev dependencies; Context7 via official docs. [VERIFIED: local command output]

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|------------------|
| V2 Authentication | no for Phase 1 health-only API | Do not add auth scope in Phase 1; later ingress/operator APIs must decide auth before exposure. [CITED: .planning/ROADMAP.md] |
| V3 Session Management | no | No sessions in Phase 1. [CITED: .planning/ROADMAP.md] |
| V4 Access Control | no for Phase 1 health-only API | Do not expose incident/operator mutation APIs in Phase 1. [CITED: .planning/ROADMAP.md] |
| V5 Input Validation | yes | Pydantic strict models, validators, and `extra="forbid"`; malformed domain/config data fails explicitly. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/] |
| V6 Cryptography | no | No custom cryptography in Phase 1. [CITED: .planning/ROADMAP.md] |
| V13 API and Web Service | yes | Keep health/readiness minimal; do not expose config summaries or raw metadata. [CITED: 01-CONTEXT.md] |
| V14 Configuration | yes | Validate `DATABASE_URL`, environment/log level, and future config paths before service readiness. [CITED: https://docs.pydantic.dev/latest/concepts/pydantic_settings/] |

### Known Threat Patterns for This Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Unsafe YAML object construction | Elevation of privilege / Tampering | Use only `yaml.safe_load()` in later YAML phases; Phase 1 should not implement concrete YAML loading. [CITED: https://pyyaml.org/wiki/PyYAMLDocumentation] |
| Secret leakage in incident debug metadata | Information disclosure | Typed `decision_context` envelope excludes raw payloads, credentials, plugin config secrets, and arbitrary plugin JSON. [CITED: 01-CONTEXT.md] |
| Database race creates duplicate active incidents | Tampering / Denial of service | PostgreSQL partial unique index plus atomic `ON CONFLICT DO UPDATE`. [CITED: https://www.postgresql.org/docs/18/sql-insert.html] |
| Over-permissive validation accepts malformed config/domain data | Tampering | Pydantic strict mode, explicit enums, non-empty constrained tags, timezone validators. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/] |
| Readiness false-positive | Denial of service | `/readyz` checks database/config readiness separately from `/health`. [CITED: 01-CONTEXT.md] |

## Sources

### Primary (HIGH confidence)
- `.planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md` — locked Phase 1 decisions D-01 through D-20. [CITED]
- `.planning/REQUIREMENTS.md` — Phase 1 requirement IDs FND-01–FND-04, DOM-01–DOM-04, PRS-01–PRS-04. [CITED]
- `CLAUDE.md` — project constraints, Python 3.14+, stack, PostgreSQL/Testcontainers/SQLite prohibition. [CITED]
- PostgreSQL 18 docs — partial indexes and `INSERT ... ON CONFLICT`. [CITED: https://www.postgresql.org/docs/18/indexes-partial.html] [CITED: https://www.postgresql.org/docs/18/sql-insert.html]
- SQLAlchemy 2.0 docs — PostgreSQL `on_conflict_do_update(index_where=...)`. [CITED: https://docs.sqlalchemy.org/en/20/dialects/postgresql.html#insert-on-conflict-upsert]
- Pydantic docs — strict mode, config, validators, settings management. [CITED: https://docs.pydantic.dev/latest/concepts/strict_mode/] [CITED: https://docs.pydantic.dev/latest/concepts/pydantic_settings/]
- FastAPI docs — lifespan and async test pattern. [CITED: https://fastapi.tiangolo.com/advanced/events/] [CITED: https://fastapi.tiangolo.com/advanced/async-tests/]
- Alembic docs — asyncio migration environment pattern. [CITED: https://alembic.sqlalchemy.org/en/latest/cookbook.html#using-asyncio-with-alembic]
- PyYAML docs — `yaml.load` unsafe, `safe_load` limited construction. [CITED: https://pyyaml.org/wiki/PyYAMLDocumentation]

### Secondary (MEDIUM confidence)
- `.planning/research/STACK.md`, `.planning/research/ARCHITECTURE.md`, `.planning/research/PITFALLS.md` — canonical project research grounding. [CITED]
- PyPI JSON package metadata queried 2026-06-08 — current observed versions and upload timestamps, but not package legitimacy. [VERIFIED: PyPI JSON]

### Tertiary (LOW confidence)
- Assumptions in the Assumptions Log where user/context did not lock a concrete implementation detail. [ASSUMED]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH for stack choice and versions, MEDIUM for package legitimacy because slopcheck was unavailable. [CITED: CLAUDE.md] [VERIFIED: PyPI JSON]
- Architecture: HIGH because locked context, canonical architecture research, and official PostgreSQL/SQLAlchemy docs agree. [CITED: .planning/research/ARCHITECTURE.md]
- Pitfalls: HIGH for partial-index/upsert and validation risks; MEDIUM for exact severity ordering because not yet specified. [CITED: .planning/research/PITFALLS.md]
- Environment: HIGH for observed local availability; implementation must provision Python 3.14+. [VERIFIED: local command output]

**Research date:** 2026-06-08
**Valid until:** 2026-07-08 for stack/API docs; re-check PyPI/package legitimacy before dependency install.
