# Walking Skeleton — Correlia

**Phase:** 1
**Generated:** 2026-06-08

## Capability Proven End-to-End

A maintainer can run the API-first backend, call health/readiness routes, migrate PostgreSQL, and perform one real incident upsert/read through the repository against the database-enforced open-incident invariant.

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Framework | FastAPI app factory with lifespan-managed resources | Correlia is API-first with no built-in frontend; FastAPI matches async REST, Pydantic v2 validation, and OpenAPI needs. |
| Runtime/package manager | Python 3.14+ with uv and one `uv.lock` | Project constraints require Python 3.14+ and uv as the single environment source of truth. |
| Config | `pydantic-settings` `Settings` model | `DATABASE_URL`, environment, log level, and future config paths validate before readiness without custom env parsing. |
| Data layer | PostgreSQL plus SQLAlchemy 2.0 asyncpg | Incident correctness depends on PostgreSQL JSONB, partial unique indexes, and `ON CONFLICT` upsert semantics. |
| Migrations | Alembic under `migrations/` | Schema evolution starts with a full initial migration, not ad hoc SQL or app-start migration side effects. |
| Auth | None added in Phase 1; only `/health` and `/readyz` are exposed | Phase 1 has health/readiness only. Ingestion and operator mutation APIs arrive in later phases with explicit auth decisions. |
| Debug metadata | Typed `DecisionContext` stored on incidents; no `raw_events` table | Locked decisions require compact non-secret explainability metadata and defer concrete raw event retention until real ingestion payloads exist. |
| Incident identity | `rule_name + group_key` | Source, host, service, and fingerprint are content/metadata; active uniqueness is `(rule_name, group_key) WHERE status = 'OPEN'`. |
| Incident lifecycle | `OPEN`, `RESOLVED`, `CLOSED`; acknowledgement metadata on open rows | Keeps acknowledged incidents inside the open partial unique index and prevents duplicate active incidents. |
| Deployment target | Local dev full-stack command path | Phase 1 proves local backend + PostgreSQL via uv, Uvicorn, Alembic, and Testcontainers-backed verification; production deployment is outside this phase. |
| Directory layout | `app/api`, `app/config`, `app/domain`, `app/persistence`, `migrations`, `tests` | Keeps API, config, domain, persistence, schema history, and verification boundaries separate from the first slice. |

## Stack Touched in Phase 1

- [x] Project scaffold (framework, dependency lock, command wrappers, test runner config)
- [x] Routing — `/health` and `/readyz`
- [x] Database — Alembic migration plus repository upsert/read against PostgreSQL
- [x] API interaction — HTTPX/ASGI tests and local Uvicorn run command exercise the REST routes
- [x] Deployment — documented local full-stack run commands:
  - `uv sync`
  - `DATABASE_URL=postgresql+asyncpg://user:pass@localhost:5432/correlia uv run alembic upgrade head`
  - `DATABASE_URL=postgresql+asyncpg://user:pass@localhost:5432/correlia make run`
  - `curl http://127.0.0.1:8000/health`
  - `curl http://127.0.0.1:8000/readyz`

## Out of Scope (Deferred to Later Slices)

- Icinga2 webhook payload parsing and normalization.
- Topology YAML loading/enrichment and plugin registry loading.
- Rule YAML loading/evaluation and threshold/window decisions.
- Notification dispatch, output plugins, and TaskRunner implementation.
- Recovery event routing, expiration loops, acknowledgement REST API, manual close REST API, and incident list/detail APIs.
- Metrics, config-summary endpoints, production auth, and production deployment automation.
- Concrete `raw_events` table or long-term raw payload retention.
- SQLite substitutes for any incident correctness path.

## Subsequent Slice Plan

Each later phase adds one vertical API/backend slice on top of this skeleton without changing the architectural decisions above:

- Phase 2: Icinga2 host/service alerts normalize into strict `NormalizedEvent`, enrich through static topology YAML, evaluate rules deterministically, and return inspectable rule/incident effects.
- Phase 3: Problem events mutate durable incidents through the Phase 1 upsert invariant and dispatch threshold-crossing notifications through pluggable tasks/outputs.
- Phase 4: Recovery, expiration, operator REST workflows, readiness extensions, logs, metrics, and operational verification complete the v1 surface.
