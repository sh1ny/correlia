<!-- GSD:project-start source:PROJECT.md -->

## Project

**Vigilo**

Vigilo is a modular, API-first event aggregation system for infrastructure alerts. It starts with Icinga2 webhook ingestion, then normalizes events into a plugin-agnostic model, enriches them with topology context, aggregates them into incidents with PostgreSQL-backed state, and dispatches notifications through pluggable output channels. It intentionally ships without a built-in frontend; REST APIs are the product surface.

**Core Value:** Operators receive one accurate, topology-aware incident for a related alert storm instead of many disconnected raw alerts.

### Constraints

- **Tech stack**: Python 3.13+, uv, FastAPI, PostgreSQL, SQLAlchemy 2.0+, asyncpg, Pydantic v2, PyYAML — specified by the idea document and aligned with the backend/API-first goal.
- **Architecture**: No built-in frontend — REST APIs are the interface and keep the backend independently deployable.
- **Plugin boundaries**: Inputs, topology enrichers, outputs, storage-adjacent behavior, and task execution must be modular — future integrations should not require rewriting the core processor.
- **State ownership**: Logic lives in code and YAML rules; durable state lives in PostgreSQL — avoids split-brain state across worker memory or plugin instances.
- **Task execution**: v1 defaults to asyncio, but all task submission must go through `TaskRunner` — keeps a clean cutover path to Celery/Redis.
- **Concurrency**: Open incident aggregation must be database-enforced with a partial unique index and atomic upsert — race conditions create duplicate incidents and break the core value.
- **Topology enrichment**: Enrichment is a plugin boundary; the first concrete plugin is static YAML hostname/IP enrichment with hostname matching before IP subnet fallback.
- **Testing**: PostgreSQL integration and concurrency behavior must be tested with Testcontainers for Python — no SQLite-backed substitute for database-specific invariants.

<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->

## Technology Stack

## Recommendation in One Sentence

## Recommended Stack

### Core Technologies

| Technology | Version family | Confidence | Purpose | Why Recommended |
|------------|----------------|------------|---------|-----------------|
| Python | 3.13.x baseline; allow 3.14.x only after CI proves all dependencies | HIGH | Runtime | Project intent requires Python 3.13+. Python 3.13 and 3.14 are both in bugfix/stable status, but 3.13 is the safer baseline for greenfield dependencies while still modern. |
| uv | 0.11.x | HIGH | Project/dependency manager, lockfile, virtualenv, Python pinning | uv is the current Astral project manager with lockfiles, Python version management, tool execution, and fast resolution. Use one `uv.lock`; do not maintain parallel `requirements.txt` in v1. |
| FastAPI | 0.136.x | HIGH | REST API, OpenAPI, request/response validation | FastAPI is still the standard Python API-first choice for typed async services and is built on Starlette + Pydantic. It directly matches Vigilo's no-frontend REST product surface. |
| Uvicorn | 0.49.x, `uvicorn[standard]` | HIGH | ASGI server | Uvicorn is FastAPI's normal ASGI runtime. `standard` extras add production/dev protocol and reload support where available. Keep process management outside Vigilo. |
| Pydantic | 2.13.x | HIGH | Normalized events, rule config, topology config, API schemas | Pydantic v2 is the current FastAPI data layer. Use `BaseModel`, `model_validate`, `model_dump`, strict fields where ambiguity is dangerous, and `extra="forbid"` for config/rules. |
| pydantic-settings | 2.14.x | HIGH | Environment/application settings | Use for deployment settings (`DATABASE_URL`, plugin config paths, log level). Keep rule/topology/plugin registries as explicit YAML files, not environment blobs. |
| PostgreSQL | 18.x preferred; 17.x acceptable on managed hosting | HIGH | Authoritative incident state | PostgreSQL 18 is the current supported major. Vigilo needs `JSONB`, partial unique indexes, `INSERT ... ON CONFLICT`, row-level transactions, and durable lifecycle state. |
| SQLAlchemy | 2.0.x | HIGH | Database model, query construction, PostgreSQL upsert | SQLAlchemy 2.0 is current and gives typed declarative models plus PostgreSQL-specific Core inserts. Use `sqlalchemy.dialects.postgresql.insert(...).on_conflict_do_update(index_elements=..., index_where=...)` for open-incident upserts. |
| asyncpg | 0.31.x | HIGH | Async PostgreSQL driver | Project intent specifies asyncpg. It is asyncio-native, supports PostgreSQL 18, and integrates with SQLAlchemy's async PostgreSQL dialect. |
| Alembic | 1.18.x | HIGH | Schema migrations | Use Alembic from day one. Hand-author migrations for partial unique indexes, PostgreSQL enum changes, and any non-trivial indexes; autogenerate is a draft, not the final migration. |
| PyYAML | 6.0.x | HIGH | YAML parser for rules/topology/plugin registry | Use only `yaml.safe_load()`/`safe_load_all()` to produce plain data, then validate with Pydantic models. Do not execute arbitrary YAML tags. |
| asyncio | Python stdlib | HIGH | v1 task execution | The v1 runner should be an explicit `TaskRunner` implementation over `asyncio.create_task`/awaited callables. Keep payloads serializable so Celery/Redis can replace the runner later without changing core processing. |

### Supporting Libraries

| Library | Version family | Confidence | Purpose | When to Use |
|---------|----------------|------------|---------|-------------|
| httpx | 0.28.x | HIGH | Async HTTP client and ASGI tests | Use `httpx.AsyncClient` + `ASGITransport` for API tests and future outbound webhook-style output plugins. |
| pytest | 9.0.x | HIGH | Test runner | Use for all unit/integration tests. Prefer behavior tests around normalization, rule matching, upsert semantics, recovery, and expiration. |
| pytest-asyncio | 1.4.x | HIGH | Async test support | Use for pure asyncio service tests. For FastAPI endpoint tests, `pytest.mark.anyio` + HTTPX is also official; do not mix event-loop ownership in the same test module. |
| testcontainers | 4.14.x | MEDIUM | PostgreSQL integration tests | Use when testing partial unique indexes, `ON CONFLICT`, transaction behavior, and migrations. SQLite cannot validate these paths. |
| Ruff | 0.15.x | HIGH | Linting and formatting | Use one tool for lint+format. Set target version to `py313`. |
| mypy | 2.x | MEDIUM | Static typing | Use for core interfaces and event/rule models. It is useful but secondary to runtime validation and integration tests for this domain. |
| aiosmtplib | 5.1.x | MEDIUM | Initial async email-style output plugin | Use only if v1 sends real SMTP mail. If the first output plugin is log/stdout for validation, defer this dependency. |
| orjson | 3.11.x | MEDIUM | Optional high-speed JSON responses | Defer until API payload size or profiling justifies it. FastAPI supports it, but incident aggregation correctness does not depend on it. |

## Prescriptive Implementation Choices

### API / FastAPI

- Use FastAPI route modules with dependency-injected settings, DB sessions, plugin registry, and processor services.
- Use `async def` endpoints for webhook ingestion and API reads because database and notification paths are async.
- Use explicit request models for known API inputs and response models for public REST contracts.
- Keep Icinga2 payload parsing inside the Icinga2 input plugin; the API endpoint should only authenticate/accept the request and hand off to the plugin.
- Do not install `fastapi[standard]` blindly if it pulls unused frontend/form/cloud extras. Prefer explicit packages: `fastapi`, `uvicorn[standard]`, `pydantic-settings`, `httpx`.

### Pydantic / Schemas

- `NormalizedEvent` should be a Pydantic v2 model with concrete container types (`dict[str, str]`, `list[str]`) and explicit enums/literals for severity and `EventType`.
- YAML-backed models (`Rule`, `TopologyRule`, `PluginRegistry`) should use `ConfigDict(extra="forbid")`; unknown keys should fail fast.
- Use strict validation where coercion would hide operator mistakes: rule priority, threshold, window duration, event type, incident status.
- Use `model_validate()` after YAML parse and `model_dump(mode="json")` for payloads crossing task/plugin boundaries.
- Do not use Pydantic v1 compatibility imports or `.dict()` / `.parse_obj()` in new code.

### PostgreSQL / SQLAlchemy

- PostgreSQL is the only v1 incident state backend.
- Use SQLAlchemy 2.0 declarative models for tables and Core statements for concurrency-critical writes.
- Implement open incident uniqueness with a partial unique index, e.g. `(rule_name, group_key) WHERE status = 'OPEN'`.
- Implement aggregation writes with one atomic PostgreSQL upsert. Do not perform SELECT-then-INSERT.
- Use PostgreSQL `JSONB` for bounded incident metadata like affected hosts/tags/snapshots; keep query-critical fields (`rule_name`, `group_key`, `status`, severity, timestamps) as typed columns.
- Keep a short transaction boundary around incident mutation and task enqueue/outbox state. Do not hold DB sessions while output plugins perform network I/O.

### Migrations

- Create Alembic before the first table lands.
- Configure Alembic for SQLAlchemy async engines, but keep migration bodies synchronous-style unless the async cookbook pattern is needed.
- Review every autogen migration. Hand-write:
- Migration tests should run against PostgreSQL, not SQLite.

### YAML Rules / Topology / Plugins

- Use PyYAML as a parser only: `safe_load()` -> plain Python data -> Pydantic model validation.
- Keep rule evaluation in Python, not a YAML expression language. YAML should describe match criteria, grouping, thresholds, summaries, and actions.
- Do not use YAML anchors/aliases as a core product feature in v1; they complicate validation and operator debugging.
- If future UX needs round-trip editing that preserves comments/order exactly, revisit `ruamel.yaml`; do not carry that dependency in v1.

### Task Execution

- Define a `TaskRunner` protocol/ABC now. The v1 implementation is asyncio.
- Task payloads should be JSON-serializable dictionaries: incident ID, action/plugin name, rule name, correlation metadata.
- The runner should not accept ORM instances, DB sessions, open connections, or function closures as durable payloads.
- Recovery handling and expiration sweeps should be idempotent and backed by PostgreSQL state, because asyncio tasks can be lost on process crash.
- Celery/Redis is a later runner implementation, not a v1 dependency.

### Test Strategy

- Unit tests: Icinga2 normalization, severity/event-type mapping, topology enrichment, rule matching, group-key generation, YAML validation failures.
- Integration tests: PostgreSQL partial unique index, atomic open-incident upsert under concurrent inserts, recovery state transitions, expiration lifecycle, Alembic migrations.
- API tests: FastAPI webhook/API behavior with HTTPX `AsyncClient` + `ASGITransport`.
- Plugin tests: use fake in-process plugin implementations at interface boundaries, but do not mock PostgreSQL for concurrency tests.
- Do not use SQLite as a substitute for PostgreSQL in tests that assert incident correctness.

## Installation

## Alternatives Considered

| Recommended | Alternative | Decision |
|-------------|-------------|----------|
| FastAPI | Django REST Framework | Do not use for v1. Vigilo is API-first without a frontend/admin surface; Django adds a synchronous framework, ORM assumptions, and project weight that do not help alert aggregation. |
| FastAPI | Flask | Do not use for v1. Flask is viable for small sync APIs, but Vigilo benefits from native async endpoints, OpenAPI generation, and Pydantic integration. |
| FastAPI | Litestar | Possible later, but not recommended. FastAPI has stronger project alignment, existing idea-doc fit, and broader ecosystem familiarity. |
| SQLAlchemy 2.0 | SQLModel | Do not use for core persistence. SQLModel is convenient for CRUD schemas but obscures SQLAlchemy Core control needed for PostgreSQL partial-index upserts. |
| SQLAlchemy + asyncpg | Tortoise ORM / GINO | Do not use. Vigilo needs explicit PostgreSQL DML, migrations, and long-lived maintainability more than a lighter async ORM. |
| asyncpg | psycopg3 async | psycopg3 is viable, but project intent and SQLAlchemy asyncpg dialect support make asyncpg the v1 choice. Revisit only if deployment or driver bugs require it. |
| PostgreSQL | SQLite | Never for incident state. SQLite cannot validate Vigilo's required partial unique index + concurrent `ON CONFLICT` behavior. |
| PyYAML + Pydantic | ruamel.yaml | Use ruamel only if preserving comments/format during write-back becomes a requirement. Vigilo v1 reads config; it does not need a YAML editor. |
| asyncio TaskRunner | Celery/Redis | Keep out of v1. The abstraction should permit Celery later, but adding broker operations now increases deployment and failure modes before the product proves value. |
| Ruff | Black + isort + Flake8 stack | Use Ruff. One fast tool reduces config surface and matches modern Python project practice. |

## What NOT to Use in v1

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Celery, Redis, RQ, Dramatiq as shipped dependencies | Violates the v1 constraint and adds broker reliability/deployment questions before the core product is validated | `TaskRunner` abstraction with an asyncio implementation |
| In-memory incident state | Multi-worker/process restarts will duplicate incidents and lose lifecycle state | PostgreSQL as authoritative state with database constraints |
| SELECT-then-INSERT incident creation | Races under alert storms; duplicate open incidents break the product value | PostgreSQL partial unique index + atomic `ON CONFLICT DO UPDATE` |
| SQLite-backed tests for incident aggregation | Does not exercise PostgreSQL concurrency, JSONB, or partial unique indexes accurately | PostgreSQL via testcontainers/local service |
| Pydantic v1 compatibility mode | New FastAPI/Pydantic ecosystem is v2; v1 APIs are deprecated for new code | Pydantic v2 `BaseModel`, `ConfigDict`, `model_validate`, `model_dump` |
| `yaml.load()` | Can construct arbitrary Python objects from config input | `yaml.safe_load()` + Pydantic validation |
| YAML as a programming language | Hidden control flow makes rules hard to validate, test, and explain | Small typed YAML schema plus Python rule evaluator |
| FastAPI `BackgroundTasks` as the task abstraction | Tied to request/response lifecycle and not a clean cutover point for Celery/Redis | Explicit `TaskRunner.submit(task_name, payload)` |
| SQLModel for incident persistence | Optimized for model/schema convenience, not PostgreSQL-specific conflict handling | SQLAlchemy 2.0 ORM/Core directly |
| APScheduler for expiration in v1 | Cron semantics are unnecessary for a simple stale-incident sweep and add scheduler state | Async lifecycle task that runs an idempotent DB-backed expiration query |
| Prometheus Alertmanager ingestion in v1 | Out of scope; premature generalization delays proving Icinga2 | Icinga2 concrete input plugin behind a generic input interface |
| Built-in frontend/admin panel | Out of scope and distracts from API contracts | REST API + OpenAPI docs |

## Version Compatibility

| Component | Compatible With | Notes |
|-----------|-----------------|-------|
| Python 3.13 | FastAPI 0.136.x, Pydantic 2.13.x, asyncpg 0.31.x, pytest 9.x, PyYAML 6.0.x | Verified from primary package metadata/classifiers. |
| FastAPI 0.136.x | Pydantic >=2.9.0, Starlette >=0.46.0 | FastAPI package metadata declares Pydantic v2 dependency range; keep Pydantic in v2. |
| SQLAlchemy 2.0.x | asyncpg via `postgresql+asyncpg://` dialect | SQLAlchemy package exposes `postgresql-asyncpg` extra and docs cover asyncpg dialect behavior. |
| PostgreSQL 18.x | asyncpg 0.31.x | asyncpg metadata states support for PostgreSQL 9.5 through 18. |
| Alembic 1.18.x | SQLAlchemy >=1.4.23; Python >=3.10 | Compatible with SQLAlchemy 2.0 and Python 3.13. |
| pytest-asyncio 1.4.x | pytest >=8.4,<10 | pytest 9.0.x is compatible. |
| Ruff 0.15.x | Python target `py313` | Configure target explicitly; do not rely on default `py310`. |

## Stack Patterns by Variant

- Run Uvicorn/FastAPI with one application process initially.
- Keep all correctness in PostgreSQL, not process memory.
- Use asyncio `TaskRunner` for notification dispatch and expiration sweeps.
- Keep the same stack, but assume each worker has its own asyncio runner.
- Use DB constraints/idempotency for every incident mutation.
- Avoid any in-memory deduplication, rate-limit, or scheduler state that assumes a singleton process.
- Use PostgreSQL 17.x, not SQLite/MySQL.
- Re-run migration/upsert integration tests against the exact managed major version.
- Store dispatch intent/attempts in PostgreSQL and let the asyncio runner process persisted work.
- Do not smuggle durability into in-memory tasks.

## Confidence Assessment

| Area | Confidence | Reason |
|------|------------|--------|
| Python/FastAPI/Pydantic | HIGH | Project intent plus FastAPI/Pydantic official docs and PyPI metadata agree on Python 3.13+ and Pydantic v2 support. |
| PostgreSQL/SQLAlchemy/asyncpg | HIGH | PostgreSQL and SQLAlchemy docs explicitly support partial indexes and `ON CONFLICT`; asyncpg metadata supports PostgreSQL 18. |
| YAML config stack | HIGH | PyYAML 6.0.x supports Python 3.13/3.14; safe parser + Pydantic validation is the conservative pattern. |
| Task execution | HIGH | Project explicitly constrains v1 to asyncio with a replaceable `TaskRunner`; Celery/Redis is a known non-goal. |
| Test tooling | MEDIUM-HIGH | pytest/HTTPX patterns are official/common. testcontainers is appropriate but depends on Docker availability in CI. |
| Optional email/JSON optimization | MEDIUM | aiosmtplib/orjson are credible current packages, but should be pulled only when the corresponding v1 feature/performance need exists. |

## Sources

- `.planning/PROJECT.md` and `idea.md` — project constraints and product intent.
- Python Developer's Guide, Status of Python versions — Python 3.13/3.14 support status: https://devguide.python.org/versions/
- uv docs and PyPI — project manager capabilities and latest 0.11.x package: https://docs.astral.sh/uv/ and https://pypi.org/project/uv/
- FastAPI official docs and PyPI — FastAPI purpose, Pydantic/Starlette dependencies, async test pattern, latest 0.136.x: https://fastapi.tiangolo.com/ and https://pypi.org/project/fastapi/
- Context7 `/fastapi/fastapi` — FastAPI docs lookup for Pydantic v2 and async testing patterns.
- Pydantic official docs and PyPI — v2 model APIs, strict/extra behavior, latest 2.13.x: https://docs.pydantic.dev/ and https://pypi.org/project/pydantic/
- Context7 `/pydantic/pydantic` — Pydantic v2 model and strict-mode docs lookup.
- PostgreSQL docs — version policy, PostgreSQL 18 support, partial indexes, `INSERT ... ON CONFLICT`: https://www.postgresql.org/support/versioning/, https://www.postgresql.org/docs/18/indexes-partial.html, https://www.postgresql.org/docs/18/sql-insert.html
- SQLAlchemy docs and PyPI — 2.0.50 current docs, PostgreSQL `on_conflict_do_update(index_where=...)`, asyncpg extras: https://docs.sqlalchemy.org/en/20/dialects/postgresql.html and https://pypi.org/project/SQLAlchemy/
- Context7 `/websites/sqlalchemy_en_20` — SQLAlchemy PostgreSQL upsert docs lookup.
- asyncpg PyPI — latest 0.31.x, Python/PostgreSQL support: https://pypi.org/project/asyncpg/
- Alembic docs and PyPI — migrations, async cookbook, latest 1.18.x: https://alembic.sqlalchemy.org/ and https://pypi.org/project/alembic/
- PyYAML PyPI — latest 6.0.x and Python support: https://pypi.org/project/PyYAML/
- pytest, pytest-asyncio, HTTPX, testcontainers, Ruff, mypy, aiosmtplib, orjson PyPI pages — supporting tool versions and compatibility.

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
