# Phase 1: Foundations, Contracts, and Database Invariant - Pattern Map

**Mapped:** 2026-06-08
**Files analyzed:** 29 expected new/modified implementation files
**Analogs found:** 0 / 29

## Scope and Search Result

This repository is greenfield for application source. Read-based inspection found no `app/`, `src/`, `tests/`, `migrations/`, or `alembic/` directories at the workspace root. The only existing source-of-truth artifacts for Phase 1 patterns are planning/research documents: `CLAUDE.md`, `.planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md`, `.planning/phases/01-foundations-contracts-and-database-invariant/01-RESEARCH.md`, `.planning/PROJECT.md`, `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md`, and `.planning/research/ARCHITECTURE.md`.

For every expected Phase 1 implementation file below, the closest analog is therefore: **No existing analog — greenfield**. Planner should copy the source-of-truth patterns from the planning/research excerpts in this document, not from existing code.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `pyproject.toml` | config | config | No existing analog — greenfield | none |
| `uv.lock` | config | config | No existing analog — greenfield | none |
| `Makefile` | config | command-dispatch | No existing analog — greenfield | none |
| `alembic.ini` | config | config | No existing analog — greenfield | none |
| `migrations/env.py` | migration | batch | No existing analog — greenfield | none |
| `migrations/script.py.mako` | migration | batch | No existing analog — greenfield | none |
| `migrations/versions/0001_create_incidents.py` | migration | batch | No existing analog — greenfield | none |
| `app/__init__.py` | config | import-boundary | No existing analog — greenfield | none |
| `app/main.py` | route | request-response | No existing analog — greenfield | none |
| `app/api/__init__.py` | config | import-boundary | No existing analog — greenfield | none |
| `app/api/deps.py` | utility | request-response | No existing analog — greenfield | none |
| `app/api/routers/__init__.py` | config | import-boundary | No existing analog — greenfield | none |
| `app/api/routers/health.py` | route | request-response | No existing analog — greenfield | none |
| `app/config/__init__.py` | config | import-boundary | No existing analog — greenfield | none |
| `app/config/settings.py` | config | config | No existing analog — greenfield | none |
| `app/domain/__init__.py` | config | import-boundary | No existing analog — greenfield | none |
| `app/domain/events.py` | model | transform | No existing analog — greenfield | none |
| `app/domain/incidents.py` | model | state-transition | No existing analog — greenfield | none |
| `app/persistence/__init__.py` | config | import-boundary | No existing analog — greenfield | none |
| `app/persistence/database.py` | utility | request-response | No existing analog — greenfield | none |
| `app/persistence/models.py` | model | CRUD | No existing analog — greenfield | none |
| `app/persistence/incidents.py` | service | CRUD | No existing analog — greenfield | none |
| `tests/conftest.py` | test | config | No existing analog — greenfield | none |
| `tests/test_settings.py` | test | config | No existing analog — greenfield | none |
| `tests/test_domain_events.py` | test | transform | No existing analog — greenfield | none |
| `tests/test_domain_incidents.py` | test | state-transition | No existing analog — greenfield | none |
| `tests/test_health.py` | test | request-response | No existing analog — greenfield | none |
| `tests/test_migrations.py` | test | batch | No existing analog — greenfield | none |
| `tests/test_incident_repository.py` | test | CRUD | No existing analog — greenfield | none |

## Pattern Assignments

### `pyproject.toml` (config, config)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** `CLAUDE.md` and `01-RESEARCH.md` lock Python 3.14+, uv, FastAPI, PostgreSQL, SQLAlchemy 2.0+, asyncpg, Alembic, Pydantic v2, pydantic-settings, PyYAML, pytest, pytest-asyncio, httpx, Ruff, mypy, and Testcontainers. Use one uv-managed project and one lockfile; do not create parallel `requirements.txt`.

**Dependency pattern** (`01-RESEARCH.md`, Standard Stack / Installation):
```bash
uv init --python 3.14
uv add fastapi "uvicorn[standard]" sqlalchemy asyncpg alembic pydantic pydantic-settings pyyaml
uv add --dev pytest pytest-asyncio httpx ruff mypy testcontainers
```

**Config expectations:**
- `requires-python = ">=3.14"`.
- Ruff target version: `py314`.
- Use Pydantic v2 APIs only; no v1 compatibility imports.
- Keep package import root as `app` unless the planner deliberately renames the tree everywhere.

---

### `uv.lock` (config, config)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** `CLAUDE.md` and `01-RESEARCH.md` require uv as package manager/source of truth. `uv.lock` is generated by uv from `pyproject.toml`; planner should not hand-author dependency versions except through uv commands.

---

### `Makefile` (config, command-dispatch)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** D-19 in `01-CONTEXT.md`: provide Makefile targets in addition to uv commands for common maintainer flows: `test`, `lint`, `typecheck`, and `run`. uv remains source of truth.

**Command wrapper pattern:**
```makefile
test:
	uv run pytest

lint:
	uv run ruff check .

typecheck:
	uv run mypy app tests

run:
	uv run uvicorn app.main:create_app --factory --reload
```

Planner may add migration targets if useful, but Phase 1 acceptance explicitly requires the four common flows above.

---

### `alembic.ini` (config, config)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** FND-03 and D-20 require full Alembic setup. Configure script location under `migrations/`; database URL should come from settings/environment at runtime, not a checked-in local secret.

---

### `migrations/env.py` (migration, batch)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** `01-RESEARCH.md` says Alembic should be initialized before the first table lands, configured for SQLAlchemy async engines, and use Alembic's async cookbook pattern. Import metadata from `app.persistence.models`; read DB URL through settings or Alembic config without duplicating configuration parsing.

**Async migration pattern** (`01-RESEARCH.md`, FND-03 / Migrations):
```python
# Configure Alembic for SQLAlchemy async engines, using run_sync for migration execution.
# Keep migration bodies synchronous-style unless async cookbook plumbing is needed.
```

---

### `migrations/script.py.mako` (migration, batch)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** Standard Alembic revision template. Keep generated revisions typed and deterministic; hand-review every autogenerated migration. No application logic belongs in the template.

---

### `migrations/versions/0001_create_incidents.py` (migration, batch)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** D-01 through D-08, D-20, PRS-01 through PRS-03, and `01-RESEARCH.md` Code Examples. Migration must create the incidents table, timestamp fields, acknowledgement metadata, bounded JSONB fields, status constraints, and the partial unique index. Do not stop at scaffold.

**Migration excerpt** (`01-RESEARCH.md`, Alembic Migration Snippet):
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

**Invariant:** no `ACKNOWLEDGED` status. Acknowledgement remains metadata on an `OPEN` row.

---

### `app/__init__.py` (config, import-boundary)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** Package marker only. Keep empty unless package-level constants are required later. Do not introduce import side effects.

---

### `app/main.py` (route, request-response)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** `01-RESEARCH.md` and `.planning/research/ARCHITECTURE.md` recommend a FastAPI application factory with lifespan-owned resource setup/teardown and router wiring. Health/readiness routes should live in `app/api/routers/health.py`, not inline, once the router module exists.

**App factory/lifespan excerpt** (`01-RESEARCH.md`, FastAPI App Factory with Health/Readiness):
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

**Planner adjustment:** move inline routes into the health router, keep `create_app()` as the composition root, and do not auto-run migrations at startup unless a later decision explicitly requires it.

---

### `app/api/__init__.py` (config, import-boundary)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** Package marker only. Avoid importing routers here if that creates app startup side effects.

---

### `app/api/deps.py` (utility, request-response)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** `.planning/research/ARCHITECTURE.md` says request-scoped dependencies belong in `api/deps.py` so processors and domain models stay framework-agnostic. Phase 1 needs settings and database session dependencies; auth hooks are later.

**Dependency boundary pattern:**
```python
# API dependencies own FastAPI request wiring only.
# Domain models must not import FastAPI.
# Persistence details should be exposed as AsyncSession/sessionmaker dependencies.
```

---

### `app/api/routers/__init__.py` (config, import-boundary)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** Package marker. Router registration should happen in `app/main.py` to keep application composition explicit.

---

### `app/api/routers/health.py` (route, request-response)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** D-17: expose `/health` for liveness and `/readyz` for database/config readiness. Do not add metrics or config-summary endpoints in Phase 1.

**Endpoint pattern** (`01-RESEARCH.md`, FastAPI App Factory with Health/Readiness):
```python
@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}

@app.get("/readyz")
async def readyz() -> dict[str, str]:
    async with sessionmaker() as session:
        await session.execute(text("select 1"))
    return {"status": "ready"}
```

**Planner adjustment:** implement with `APIRouter`, dependency-injected session/sessionmaker, and HTTP error behavior for readiness failures. Keep `/health` process-only.

---

### `app/config/__init__.py` (config, import-boundary)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** Package marker only. Concrete YAML loaders for rules/topology/plugins are deferred; do not add them in Phase 1.

---

### `app/config/settings.py` (config, config)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** D-18 and FND-02 require validated settings for `DATABASE_URL`, environment/log level, and paths for future rule/topology/plugin config. Concrete YAML loading belongs later.

**Settings excerpt** (`01-RESEARCH.md`, Settings Model):
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

---

### `app/domain/__init__.py` (config, import-boundary)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** Package marker or minimal explicit re-export of stable domain contracts only. Do not import FastAPI, SQLAlchemy, settings, or persistence.

---

### `app/domain/events.py` (model, transform)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** DOM-01 through DOM-04, D-13 through D-16, and `01-RESEARCH.md` Code Examples. This is the strict plugin/core boundary for normalized events.

**Strict domain model excerpt** (`01-RESEARCH.md`, Strict Domain Model with Timezone and Tag Validators):
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

**Invariant:** reject naive timestamps and ambiguous/coerced values; event tags are strict `dict[str, str]` with normalized non-empty keys and values.

---

### `app/domain/incidents.py` (model, state-transition)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** D-01 through D-12 and DOM-03. Define `IncidentStatus` as exactly `OPEN`, `RESOLVED`, `CLOSED`; acknowledgement is metadata. Add transition helpers for `OPEN -> RESOLVED`, `OPEN -> CLOSED`, and no reopening of terminal states. Define a typed compact decision metadata envelope, not free-form raw payload storage.

**Transition pattern from locked decisions:**
```python
class IncidentStatus(StrEnum):
    OPEN = "OPEN"
    RESOLVED = "RESOLVED"
    CLOSED = "CLOSED"

# Allowed transitions in Phase 1 domain helpers:
# OPEN -> RESOLVED
# OPEN -> CLOSED
# RESOLVED/CLOSED -> no reopen
```

**Decision metadata constraints:**
- Allowed facts: normalized fingerprint, source id, rule/group details, matched rule names, enrichment provenance references, event counts, config version/hash, similar explainability data.
- Forbidden facts: raw payloads, credentials, plugin config secrets, arbitrary plugin JSON.
- Use stable top-level keys/version and bounded JSON-serializable details.

---

### `app/persistence/__init__.py` (config, import-boundary)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** Package marker. Persistence package may expose stable factory/repository symbols later; avoid importing models in ways that create engine/session side effects.

---

### `app/persistence/database.py` (utility, request-response)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** `.planning/research/ARCHITECTURE.md` isolates SQLAlchemy/PostgreSQL details in persistence. Create async engine and async sessionmaker from validated settings. Keep transaction/session lifecycle explicit and do not hold DB sessions during output plugin/network work.

**Boundary pattern:**
```python
# database.py owns:
# - create_async_engine(settings.database_url)
# - async_sessionmaker(..., expire_on_commit=False)
# - connection/readiness helpers used by /readyz
# It must not own domain transition decisions.
```

---

### `app/persistence/models.py` (model, CRUD)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** PRS-01, D-01 through D-08, and `01-RESEARCH.md` migration snippet. SQLAlchemy model/table fields must match the initial migration and domain enums exactly. Keep query-critical fields as typed columns and bounded sets/context as JSONB.

**Incident column pattern** (`.planning/research/ARCHITECTURE.md`, Incident Columns):
```text
id UUID PK
rule_name, group_key
status
severity
start_time, last_update_time
summary
event_count
affected_hosts JSONB
affected_services JSONB
last_fingerprint
acknowledged_at, acknowledged_by
resolved_at, closed_at
created_at, updated_at
```

**Invariant:** model status values and migration/check constraint must not drift from `IncidentStatus`.

---

### `app/persistence/incidents.py` (service, CRUD)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** PRS-02 and PRS-03. This repository/service owns the SQLAlchemy PostgreSQL upsert targeting the partial index. Do not implement SELECT-then-INSERT.

**Upsert excerpt** (`01-RESEARCH.md`, SQLAlchemy PostgreSQL Partial-Index Upsert):
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

**Pitfall to avoid:** `on_conflict_do_update(index_elements=[...])` without `index_where` can drift from the partial unique index target.

---

### `tests/conftest.py` (test, config)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** `CLAUDE.md` and `01-RESEARCH.md` require Testcontainers for PostgreSQL integration and prohibit SQLite substitutes. Provide fixtures for settings overrides, FastAPI app/client construction, async sessions, and PostgreSQL containers for DB-specific tests.

**Testing boundary:** use HTTPX `AsyncClient` + `ASGITransport` for FastAPI endpoint tests; use Testcontainers PostgreSQL for migrations/index/upsert behavior.

---

### `tests/test_settings.py` (test, config)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** FND-02, D-18, and the settings model excerpt. Test accepted valid settings and rejected invalid/missing `DATABASE_URL`, invalid environment/log level, and extra env/config fields where applicable.

---

### `tests/test_domain_events.py` (test, transform)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** DOM-01 through DOM-04 and D-13 through D-16. Test strict `NormalizedEvent` validation, explicit `EventType`/`Severity`, rejected naive timestamps, rejected empty/invalid tag keys and values, and rejected coercion/extra fields.

---

### `tests/test_domain_incidents.py` (test, state-transition)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** D-01 through D-12. Test `IncidentStatus` values exactly `OPEN`, `RESOLVED`, `CLOSED`; verify acknowledgement metadata does not change status; verify allowed `OPEN -> RESOLVED` and `OPEN -> CLOSED`; verify no reopening of `RESOLVED` or `CLOSED`; verify decision context rejects raw/secret/unbounded payload shapes.

---

### `tests/test_health.py` (test, request-response)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** D-17 and FND-04. Test `/health` returns liveness without DB dependency; test `/readyz` succeeds with reachable DB/config and fails explicitly when readiness dependency fails. Do not add metrics/config-summary endpoint tests in Phase 1.

---

### `tests/test_migrations.py` (test, batch)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** FND-03, D-20, PRS-01, PRS-02. Use PostgreSQL via Testcontainers; run Alembic upgrade and inspect that `incidents` exists with required columns/checks/JSONB defaults and the partial unique index `incidents_one_open_per_rule_group`. No SQLite fallback.

---

### `tests/test_incident_repository.py` (test, CRUD)

**Analog:** No existing analog — greenfield

**Source-of-truth pattern:** PRS-02 and PRS-03. Use PostgreSQL via Testcontainers to verify two writes for the same `(rule_name, group_key)` while `OPEN` produce one row updated atomically; different `rule_name` or `group_key` can produce separate open rows; resolved/closed rows do not block a new open incident; repository uses `ON CONFLICT` rather than SELECT-then-INSERT behavior.

## Shared Patterns

### Greenfield Source Layout

**Source:** `01-RESEARCH.md` Recommended Project Structure and `.planning/research/ARCHITECTURE.md` Recommended Project Structure

```text
app/
├── main.py                  # create_app(), lifespan, router wiring
├── api/
│   ├── deps.py              # settings/session dependencies
│   └── routers/
│       └── health.py        # GET /health and /readyz
├── config/
│   └── settings.py          # pydantic-settings app config
├── domain/
│   ├── events.py            # NormalizedEvent, EventType, Severity
│   └── incidents.py         # IncidentStatus, transitions, metadata envelope
├── persistence/
│   ├── database.py          # async engine/session factory
│   ├── models.py            # SQLAlchemy incident table mapping
│   └── incidents.py         # atomic upsert statement
└── migrations/              # Alembic env.py + initial incident migration
```

### Domain/Persistence Separation

**Source:** `.planning/research/ARCHITECTURE.md`, Component Responsibilities and Structure Rationale

Apply to all `app/domain/*`, `app/persistence/*`, `app/api/*` files:
- Domain models do not import FastAPI, SQLAlchemy, or settings.
- API routers convert HTTP concerns into application/dependency calls only.
- Persistence code owns SQLAlchemy/PostgreSQL details, especially the partial-index upsert.
- Incident lifecycle transitions are centralized in domain/incident manager helpers, not scattered through route/repository code.

### Strict Pydantic v2 Validation

**Source:** `01-RESEARCH.md`, Pattern 1 / Strict Domain Model / Settings Model

Apply to `app/domain/events.py`, `app/domain/incidents.py`, `app/config/settings.py`, and related tests:
```python
model_config = ConfigDict(strict=True, extra="forbid")
# or SettingsConfigDict(..., extra="forbid") for settings
```

Use `model_validate()` / `model_dump(mode="json")`; do not use Pydantic v1 `.dict()` / `.parse_obj()` patterns.

### Health vs Readiness

**Source:** D-17 in `01-CONTEXT.md`, `01-RESEARCH.md` Pitfall 4

Apply to `app/main.py`, `app/api/routers/health.py`, and `tests/test_health.py`:
- `/health`: process liveness only; no database dependency.
- `/readyz`: settings + PostgreSQL reachability/readiness; cheap query such as `select 1` is sufficient for Phase 1.
- No metrics/config-summary endpoints in Phase 1.

### PostgreSQL Active-Incident Invariant

**Source:** D-03, D-05, PRS-02, PRS-03, `01-RESEARCH.md` SQLAlchemy upsert and migration snippets

Apply to `migrations/versions/0001_create_incidents.py`, `app/persistence/models.py`, `app/persistence/incidents.py`, `tests/test_migrations.py`, and `tests/test_incident_repository.py`:
```sql
CREATE UNIQUE INDEX incidents_one_open_per_rule_group
    ON incidents (rule_name, group_key)
    WHERE status = 'OPEN';
```

Repository conflict target must match:
```python
stmt.on_conflict_do_update(
    index_elements=[Incident.rule_name, Incident.group_key],
    index_where=(Incident.status == "OPEN"),
    set_={...},
)
```

### Acknowledgement Metadata, Not Status

**Source:** D-01 and D-02 in `01-CONTEXT.md`

Apply to `app/domain/incidents.py`, `app/persistence/models.py`, migration, and tests:
```python
class IncidentStatus(StrEnum):
    OPEN = "OPEN"
    RESOLVED = "RESOLVED"
    CLOSED = "CLOSED"
```

Columns: `acknowledged_at`, `acknowledged_by`. Do not add `ACKNOWLEDGED` to domain enum, check constraint, or index predicate.

### Compact Decision Metadata

**Source:** D-09 through D-12 in `01-CONTEXT.md`

Apply to `app/domain/incidents.py`, `app/persistence/models.py`, migration, repository upsert, and tests:
- Store a typed metadata envelope with stable top-level keys/version.
- Allow only non-secret processing facts.
- Reject or avoid raw payloads, credentials, plugin config secrets, arbitrary plugin JSON, and unbounded details.

### Test Strategy

**Source:** `CLAUDE.md`, `.planning/REQUIREMENTS.md`, and `01-RESEARCH.md` Test Strategy

Apply to all tests:
- Unit-test strict domain/settings behavior.
- API-test FastAPI endpoints with HTTPX ASGI transport.
- Integration-test migrations/index/upsert with Testcontainers PostgreSQL.
- Never use SQLite as a substitute for database-specific invariants.
- Do not run project-wide build/test/lint/format gates during this pattern-mapping assignment.

## No Analog Found

All expected Phase 1 implementation files have no existing code analog in this repository. Planner should use `01-CONTEXT.md`, `01-RESEARCH.md`, `CLAUDE.md`, `.planning/PROJECT.md`, `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md`, and `.planning/research/ARCHITECTURE.md` as the source-of-truth pattern set.

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `pyproject.toml` | config | config | No application/build source exists yet; use uv/Python 3.14+ research pattern. |
| `uv.lock` | config | config | No lockfile exists yet; generate with uv. |
| `Makefile` | config | command-dispatch | No maintainer command wrapper exists yet; use D-19 target list. |
| `alembic.ini` | config | config | No Alembic setup exists yet; use FND-03/D-20. |
| `migrations/env.py` | migration | batch | No migrations tree exists yet; use Alembic async pattern. |
| `migrations/script.py.mako` | migration | batch | No migrations tree exists yet; use Alembic standard template. |
| `migrations/versions/0001_create_incidents.py` | migration | batch | No migration exists yet; use D-20 and migration snippet. |
| `app/main.py` | route | request-response | No app tree exists yet; use FastAPI factory/lifespan pattern. |
| `app/api/deps.py` | utility | request-response | No API tree exists yet; use architecture dependency boundary. |
| `app/api/routers/health.py` | route | request-response | No API tree exists yet; use D-17 health/readiness split. |
| `app/config/settings.py` | config | config | No config tree exists yet; use pydantic-settings pattern. |
| `app/domain/events.py` | model | transform | No domain tree exists yet; use strict NormalizedEvent pattern. |
| `app/domain/incidents.py` | model | state-transition | No domain tree exists yet; use D-01 through D-12. |
| `app/persistence/database.py` | utility | request-response | No persistence tree exists yet; use SQLAlchemy async session boundary. |
| `app/persistence/models.py` | model | CRUD | No persistence tree exists yet; mirror migration columns/invariants. |
| `app/persistence/incidents.py` | service | CRUD | No repository exists yet; use PostgreSQL partial-index upsert. |
| `tests/conftest.py` | test | config | No test tree exists yet; use pytest/Testcontainers/httpx patterns. |
| `tests/test_settings.py` | test | config | No test analog exists yet; test FND-02/D-18. |
| `tests/test_domain_events.py` | test | transform | No test analog exists yet; test DOM-01 through DOM-04. |
| `tests/test_domain_incidents.py` | test | state-transition | No test analog exists yet; test incident lifecycle invariants. |
| `tests/test_health.py` | test | request-response | No test analog exists yet; test D-17. |
| `tests/test_migrations.py` | test | batch | No test analog exists yet; test PostgreSQL migration invariant. |
| `tests/test_incident_repository.py` | test | CRUD | No test analog exists yet; test PostgreSQL atomic upsert invariant. |
| package marker `__init__.py` files | config | import-boundary | No app packages exist yet; keep marker files side-effect-free. |

## Metadata

**Analog search scope:** workspace root (`.`), `.planning/`, phase directory, explicit source directories `app`, `src`, `tests`, `migrations`, `alembic`, and project skill directories `.claude/skills`, `.agents/skills`.

**Files/directories inspected:** `CLAUDE.md`, `01-CONTEXT.md`, `01-RESEARCH.md`, `.planning/PROJECT.md`, `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md`, `.planning/research/ARCHITECTURE.md`, root directory listing, `.planning` directory listing, phase directory listing, missing source directory checks for `app`, `src`, `tests`, `migrations`, and `alembic`.

**Existing source analog files scanned:** 0, because no app/test/migration source tree exists.

**Pattern extraction date:** 2026-06-08
