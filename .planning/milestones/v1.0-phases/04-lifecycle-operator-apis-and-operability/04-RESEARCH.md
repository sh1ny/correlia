# Phase 04: Lifecycle, Operator APIs, and Operability - Research

**Researched:** 2026-06-09
**Domain:** FastAPI/PostgreSQL incident lifecycle, trusted internal REST operator APIs, and operability surfaces
**Confidence:** HIGH for project-constrained architecture; MEDIUM for new Prometheus package adoption because the package legitimacy seam flags PyPI downloads as unknown

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

## Implementation Decisions

### Recovery Matching
- **D-01:** `RECOVERY` events must route to lifecycle resolution and must not enter problem aggregation or threshold/notification dispatch.
- **D-02:** A recovery may affect any `OPEN` incident whose affected object set contains the recovered object. Do not require the recovery event to re-match the original rule/group key; topology/rule config may have changed since the problem event.
- **D-03:** Service-level recovery is host + service exact: resolve/remove only incident membership where `affected_hosts` contains the recovered host and `affected_services` contains the recovered service. Host-only incidents must not be closed by a service recovery.
- **D-04:** Multi-object incidents should remove the recovered object from affected sets first and transition to `RESOLVED` only when no affected objects remain. Do not close a topology-grouped incident just because one host/service recovered while others remain affected.
- **D-05:** When an incident transitions to `RESOLVED`, record compact non-secret recovery context: recovered fingerprint, source_id, host, optional service, recovery timestamp, previous affected counts, and reason `source_recovery`. Do not store raw payloads or source-specific blobs.

### Stale Expiration
- **D-06:** An `OPEN` incident is stale when database current time is greater than `last_update_time + rule.window`. Use rule-specific windows, not a global TTL, and do not wait for a future source event to prove expiry.
- **D-07:** Expiration should use PostgreSQL/database time rather than the application process clock so future multi-worker deployments and tests share one time source.
- **D-08:** v1 expiration runs as one FastAPI lifespan-managed asyncio background task that scans periodically and stops cleanly during shutdown. Do not bend `TaskRunner` into a scheduler in v1.
- **D-09:** Expired incidents transition to `CLOSED`, set `closed_at`, and record compact context with reason `expired`, rule/window facts, and last_update facts. Do not conflate source recovery with stale expiration by marking expired incidents `RESOLVED`.

### Operator REST Workflows
- **D-10:** Phase 4 REST APIs are trusted internal operator APIs with no built-in auth in v1. Deployment is assumed to place Correlia behind a trusted network/proxy. Adding API-key/session auth is deferred unless a later phase explicitly scopes it.
- **D-11:** Use a `/v1` route namespace as a clean cutover. Existing routes should move under `/v1` as part of this phase (`/v1/health`, `/v1/readyz`, `/v1/plugins`, `/v1/icinga2/events`, plus new incident/config/metrics endpoints) rather than keeping parallel legacy aliases, unless planning discovers a hard compatibility constraint.
- **D-12:** Incident listing uses cursor pagination with stable ordering by `last_update_time DESC, id DESC`. Include common filters for status, severity, rule_name, host, service, and updated_since.
- **D-13:** Incident detail responses should expose current status, severity, summary, timestamps, affected hosts/services, acknowledgement metadata, resolution/closure context, and bounded non-secret decision context. Do not expose raw source payloads, plugin secrets, SMTP transcripts, or stack traces.
- **D-14:** Acknowledgement and manual close are explicit idempotent action endpoints. `POST /v1/incidents/{id}/ack` sets acknowledgement metadata while the incident remains `OPEN`; repeated acknowledgement with the same intent should not break retries. `POST /v1/incidents/{id}/close` transitions eligible incidents to `CLOSED` with compact operator/reason context.
- **D-15:** Manual lifecycle mutations must preserve the PostgreSQL invariant that only one `OPEN` incident can exist for `rule_name + group_key`. Closing or resolving an incident frees that rule/group to create a new future `OPEN` incident through the existing partial unique index.

### Operability Signals
- **D-16:** `/v1/readyz` should report ready only when database connectivity, strict config loading, plugin registry status, and lifecycle worker health are good enough for processing. Failure responses must stay non-secret.
- **D-17:** Expose low-cardinality Prometheus text metrics at `/v1/metrics`, covering accepted/rejected events, matched rules, incident inserts/updates/resolutions/expirations, notification attempts/failures, task failures, and lifecycle worker health. Avoid host/service/group_key labels.
- **D-18:** Emit JSON event logs for ingestion, normalization, enrichment, rule matching, incident upsert, notification dispatch, recovery, expiration, operator mutations, readiness failures, and task failures. Logs may include safe identifiers such as event name, incident_id, rule_name, group_key, status, severity, reason/category, and counts; logs must not include raw payloads or secrets.
- **D-19:** Config/status inspection endpoints should expose safe summaries with hashes: rule names/priorities/group_by/action plugin names, topology rule ids/match types/tag keys, plugin names/types/ready status, and non-secret config hashes. Do not expose full rendered config or plugin options that may contain secrets.

### Claude's Discretion
No selected area was delegated to Claude. Downstream agents should treat the decisions above as locked.

### Deferred Ideas (OUT OF SCOPE)

- API-key/session authentication for operator APIs — future phase if Correlia is exposed beyond a trusted internal network/proxy.
- Public internet hardening and user management — outside v1 Phase 4.
- Bidirectional Icinga2 acknowledgement/mutation — explicitly out of scope for v1.
- Reminder/escalation policy and repeated notification behavior — future notification policy work, not Phase 4 lifecycle.
- Celery/Redis scheduling or durable outbox execution — remains deferred behind existing seams.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| LCY-01 | Correlia routes `RECOVERY` events to lifecycle resolution instead of problem aggregation. | Branch in `Icinga2DecisionProcessor.process_payload` before aggregation; `RuleEngine.evaluate` already returns no-op for `RECOVERY`; route recovery to a separate lifecycle manager. [VERIFIED: app/processing/ingress.py:79-88] [VERIFIED: app/processing/rule_engine.py:16-18] |
| LCY-02 | Correlia resolves active incidents containing the recovered host. | Query `OPEN` incidents where `affected_hosts` contains the host and shrink/resolve under PostgreSQL transaction. [VERIFIED: app/persistence/models.py:31-36] |
| LCY-03 | Correlia resolves only matching service-level incidents when a service recovery event arrives. | Match host + service membership; never close host-only incidents from service recovery. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25] |
| LCY-04 | Correlia appends or records resolution context when incidents move to `RESOLVED`. | Extend `DecisionContext.notes` with bounded non-secret lifecycle fields or add typed lifecycle response/context models. [VERIFIED: app/domain/incidents.py:48-78] |
| LCY-05 | Correlia expires stale active incidents after the configured rule window when no further events arrive. | Use DB time and rule-specific `window_seconds`; current incident rows store `last_update_time` and `window_state.window_seconds`. [VERIFIED: app/persistence/models.py:40-46] [VERIFIED: app/domain/incidents.py:80-90] |
| LCY-06 | Correlia starts and stops lifecycle background work through FastAPI lifespan handling. | Existing app already uses `FastAPI(lifespan=lifespan)` and drains `TaskRunner`; add a distinct lifecycle worker object started before `yield` and stopped in `finally`. [VERIFIED: app/main.py:18-67] [CITED: https://fastapi.tiangolo.com/advanced/events/] |
| API-01 | Operator can list incidents through REST with pagination and useful filters. | Add `/v1/incidents` router backed by keyset pagination over `last_update_time DESC, id DESC`, with strict Pydantic query model. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-39] |
| API-02 | Operator can view incident details, including affected hosts, timestamps, current status, summary, and decision context. | `Incident` model already stores required columns; response must redact raw/source/plugin-secret material. [VERIFIED: app/persistence/models.py:24-50] |
| API-03 | Operator can acknowledge an active incident without allowing duplicate active incidents for the same rule/group. | Acknowledgement is metadata on `OPEN`, not status; use idempotent update on same row. [VERIFIED: .planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md:18-24] |
| API-04 | Operator can manually close an incident through REST. | Use `validate_incident_transition(OPEN, CLOSED)` and PostgreSQL update returning; closure frees the partial unique index. [VERIFIED: app/domain/incidents.py:115-118] [VERIFIED: app/persistence/models.py:13-14] |
| API-05 | Operator can inspect loaded rules, topology configuration summaries, and plugin registry status through REST without exposing secrets. | Existing plugin list exposes only name/type/status/ready; add rule/topology summary loaders with hashes, not full options. [VERIFIED: app/plugins/loader.py:33-46] |
| OPS-01 | Correlia emits structured logs for ingestion, normalization, enrichment, rule matching, incident upsert, notification dispatch, recovery, expiration, and task failures. | Use stdlib logging with JSON formatter and safe `extra` fields; current task runner already logs failure category without payload. [VERIFIED: app/processing/task_runner.py:64-77] |
| OPS-02 | Correlia exposes readiness signals for database connectivity, config validity, plugin registry load, and background task health. | Extend existing `/readyz` DB check to include settings/config/plugin/lifecycle worker status. [VERIFIED: app/api/routers/health.py:18-33] |
| OPS-03 | Correlia exposes low-cardinality metrics for accepted events, rejected events, matched rules, incident inserts/updates/resolutions/expirations, notification attempts/failures, and task failures. | Use Prometheus client counters/gauges without host/service/group_key labels; package is official but legitimacy seam flags unknown downloads. [CITED: https://prometheus.github.io/client_python/] [VERIFIED: package-legitimacy seam] |
| OPS-04 | Maintainer can run automated tests that cover domain models, config validation, Icinga2 mapping, topology enrichment, rule evaluation, notification dispatch, recovery, and expiration, with PostgreSQL integration/concurrency paths exercised through Testcontainers for Python instead of SQLite. | Existing tests already use `uv run pytest`, HTTPX ASGITransport, Alembic, Testcontainers PostgreSQL 18, and no SQLite. [VERIFIED: tests/test_incident_repository.py:1-53] [VERIFIED: tests/test_ingress_router.py:1-66] |
</phase_requirements>

## Project Constraints (from AGENTS.md)

No `AGENTS.md` was present in the repo root listing inspected during research. [VERIFIED: repo root read]

Additional assignment constraints that the planner must honor: backend-only; no built-in frontend; PostgreSQL only; SQLite substitutes prohibited; route/operator surfaces are REST and observability endpoints; tooling references should use `uv run <tool>` patterns; subagents must skip all gates, tests, lint, and formatters. [VERIFIED: user assignment]

## Summary

Phase 4 should be planned as a clean lifecycle/API/operability cutover around the existing PostgreSQL-backed incident core. [VERIFIED: .planning/ROADMAP.md:98-110] The central design is a separate lifecycle manager/repository path for recovery, expiration, acknowledgement, and manual close, while keeping `IncidentManager.apply_problem` focused on `PROBLEM` aggregation and first-threshold notification dispatch. [VERIFIED: app/processing/incident_manager.py:60-133]

Recovery must be object-membership driven, not rule-rematch driven. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25] The planner should allocate repository work for host recovery, service recovery, multi-object affected-set shrinking, and final `OPEN -> RESOLVED` transition only when no affected objects remain. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25] Expiration is a distinct `OPEN -> CLOSED` path driven by PostgreSQL time and rule/window facts, started and stopped by the FastAPI lifespan. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:27-31] [CITED: https://fastapi.tiangolo.com/advanced/events/]

Operator APIs should be trusted internal `/v1` REST APIs with strict response models, keyset cursor pagination, idempotent action endpoints, and non-secret envelopes. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-45] Operability should be implemented as production surfaces, not polish: `/v1/readyz` must include DB/config/plugins/lifecycle worker health; `/v1/metrics` must use low-cardinality labels; JSON logs must carry safe IDs/reasons/counts but never raw payloads, plugin options, SMTP transcripts, credentials, or stack traces. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:41-45]

**Primary recommendation:** Plan four vertical backend slices: lifecycle mutation core, `/v1` operator API cutover, safe config/status + readiness, then metrics/logging + targeted verification. [VERIFIED: .planning/ROADMAP.md:98-110]

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|--------------|----------------|-----------|
| `RECOVERY` routing | API / Backend | Database / Storage | Ingress processing owns event-type branching; PostgreSQL owns durable lifecycle mutation. [VERIFIED: app/processing/ingress.py:79-88] |
| Object-level recovery and affected-set shrinking | Database / Storage | API / Backend | Correctness depends on atomic row updates and row-returning results; manager code owns transition semantics. [VERIFIED: app/persistence/incidents.py:433-484] [CITED: https://docs.sqlalchemy.org/en/20/tutorial/data_update.html] |
| Stale expiration | API / Backend | Database / Storage | FastAPI lifespan owns the worker process; expiration predicates use database time and stored rule/window facts. [VERIFIED: app/main.py:18-67] [CITED: https://www.postgresql.org/docs/current/functions-datetime.html] |
| Incident list/detail/ack/close APIs | API / Backend | Database / Storage | FastAPI routers expose trusted internal REST contracts; persistence functions enforce state transitions. [VERIFIED: app/api/deps.py:12-29] |
| `/v1` namespace cutover | API / Backend | — | Existing routers are included directly from `create_app`; planner should move prefixes at router/app inclusion boundaries. [VERIFIED: app/main.py:89-91] |
| Rules/topology/plugin status APIs | API / Backend | Config files | Runtime-loaded config/plugin objects produce safe summaries; no frontend tier exists. [VERIFIED: app/plugins/loader.py:33-46] |
| Readiness | API / Backend | Database / Storage | Health router already does DB readiness; extend with config, plugin registry, lifecycle worker state. [VERIFIED: app/api/routers/health.py:18-33] |
| Metrics | API / Backend | — | `/v1/metrics` is an HTTP exposition surface over in-process counters/gauges. [CITED: https://prometheus.github.io/client_python/] |
| Structured logs | API / Backend | — | Logs are emitted at processing/task/lifecycle boundaries; high-cardinality identifiers belong in logs, not metric labels. [VERIFIED: .planning/research/ARCHITECTURE.md:525-559] |

## Standard Stack

### Core

| Library / Component | Version | Purpose | Why Standard |
|---------------------|---------|---------|--------------|
| Python | 3.14.4 installed | Runtime | Project requires Python 3.14+ and current environment provides it. [VERIFIED: environment audit] |
| uv | 0.11.7 installed | Project/dependency/tool runner | Existing project uses uv lock and `uv run <tool>` workflows. [VERIFIED: pyproject.toml:1-41] [VERIFIED: environment audit] |
| FastAPI | 0.136.3 installed | REST API and lifespan | Existing `create_app()` uses FastAPI lifespan; official docs recommend lifespan for startup/shutdown setup and cleanup. [VERIFIED: app/main.py:18-76] [CITED: https://fastapi.tiangolo.com/advanced/events/] |
| Pydantic | 2.13.4 installed | Strict domain/API schemas | Existing domain/config models use `ConfigDict(strict=True, extra="forbid")`. [VERIFIED: app/domain/events.py:39-58] |
| SQLAlchemy | 2.0.50 installed | PostgreSQL DML and async sessions | Current repository uses Core/ORM update/upsert/returning patterns; SQLAlchemy docs support UPDATE/RETURNING. [VERIFIED: app/persistence/incidents.py:337-404] [CITED: https://docs.sqlalchemy.org/en/20/tutorial/data_update.html] |
| asyncpg | 0.31.0 installed | Async PostgreSQL driver | Existing DB URLs and tests use `postgresql+asyncpg://`. [VERIFIED: tests/test_incident_repository.py:31-37] |
| PostgreSQL | 18 container in tests | Durable incident state | Testcontainers uses `postgres:18-alpine`; SQLite is prohibited by requirements. [VERIFIED: tests/test_incident_repository.py:31-37] [VERIFIED: .planning/REQUIREMENTS.md:124-138] |
| Alembic | 1.18.4 installed | Schema migrations | Existing tests run `uv run python -m alembic` equivalent via current interpreter and migrations define PostgreSQL JSONB/partial index. [VERIFIED: tests/test_incident_repository.py:18-25] [VERIFIED: migrations/versions/0001_create_incidents.py:80-86] |
| PyYAML | 6.0.3 installed | YAML rules/topology/plugins parser | Existing loaders use `yaml.safe_load()` before strict Pydantic validation. [VERIFIED: app/config/rules.py:158-167] [VERIFIED: app/config/topology.py:97-101] |

### Supporting

| Library / Component | Version | Purpose | When to Use |
|---------------------|---------|---------|-------------|
| httpx | 0.28.1 installed | ASGI API tests | Existing ingress tests use `AsyncClient` + `ASGITransport`. [VERIFIED: tests/test_ingress_router.py:10-66] |
| pytest / pytest-asyncio | pytest 9.0.3 / pytest-asyncio 1.4.0 installed | Unit/integration/async tests | Use targeted `uv run pytest tests/<file>.py -q` commands in plan verification, not project-wide gates for subagents. [VERIFIED: pyproject.toml:30-32] |
| testcontainers | 4.14.2 installed | PostgreSQL integration tests | Use for lifecycle repository, expiration, and concurrency paths; do not use SQLite. [VERIFIED: tests/test_incident_repository.py:1-53] |
| prometheus-client | 0.25.0 current on PyPI; not installed | Prometheus text metrics | Use for `/v1/metrics` if adding a dependency is acceptable; official docs identify package but package-legitimacy seam flags unknown downloads. [CITED: https://prometheus.github.io/client_python/] [VERIFIED: PyPI JSON] [VERIFIED: package-legitimacy seam] |
| Python stdlib `logging` + JSON formatter | stdlib | Structured JSON logs | Prefer stdlib formatter over adding `structlog`; current code already uses logging with safe `extra`. [VERIFIED: app/processing/task_runner.py:64-77] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| FastAPI lifespan worker | APScheduler/Celery/Redis | Locked out of v1; simple DB-backed sweep does not need scheduler/broker state. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:27-31] |
| PostgreSQL time | Application `datetime.now()` | Locked out; DB time keeps tests and future multi-worker deployments on one authority. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:27-31] |
| `prometheus-client` | Hand-written Prometheus text | Hand-written exposition risks invalid escaping/types and duplicates standard client behavior; package needs one explicit legitimacy decision because seam returned `SUS`. [CITED: https://prometheus.github.io/client_python/] [VERIFIED: package-legitimacy seam] |
| stdlib JSON logging | `structlog` / `python-json-logger` | Extra dependency is unnecessary for current safe-field logging requirements. [ASSUMED] |
| Offset pagination | Cursor/keyset pagination | Offset is unstable under incident updates; locked order is `last_update_time DESC, id DESC`. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-39] |

**Installation:**

```bash
uv add prometheus-client
```

Only needed if the planner accepts the flagged package for `/v1/metrics`; otherwise metric implementation must still avoid hand-rolled high-cardinality labels and should be revisited before execution. [VERIFIED: package-legitimacy seam]

## Package Legitimacy Audit

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| prometheus-client | PyPI | Existing project; current release 0.25.0 uploaded 2026-04-09 | Unknown from seam | https://github.com/prometheus/client_python | SUS | Flagged — official Prometheus docs cite this package, but planner must account for seam warning. [CITED: https://prometheus.github.io/client_python/] [VERIFIED: package-legitimacy seam] |

**Packages removed due to [SLOP] verdict:** none. [VERIFIED: package-legitimacy seam]
**Packages flagged as suspicious [SUS]:** `prometheus-client` because the seam reported `unknown-downloads`; it did confirm existence and source repo. [VERIFIED: package-legitimacy seam]

## Architecture Patterns

### System Architecture Diagram

```text
Icinga2 / trusted REST client / Prometheus scraper
        |
        v
FastAPI app (/v1 routers + lifespan)
        |
        +--> /v1/icinga2/events
        |       |
        |       v
        |   Icinga2InputPlugin -> NormalizedEvent
        |       |
        |       +-- event_type == PROBLEM --> topology -> rule engine -> IncidentManager.apply_problem -> PostgreSQL upsert -> TaskRunner notify
        |       |
        |       +-- event_type == RECOVERY --> topology for diagnostics only -> LifecycleManager.resolve_for_event -> PostgreSQL affected-set shrink / RESOLVED
        |
        +--> lifespan LifecycleWorker
        |       |
        |       v
        |   periodic scan -> PostgreSQL DB-time stale predicate -> CLOSED expired rows
        |
        +--> /v1/incidents, /v1/rules, /v1/topology, /v1/plugins
        |       |
        |       v
        |   strict request/response schemas -> repositories -> non-secret envelopes
        |
        +--> /v1/readyz and /v1/metrics
                |
                v
            DB/config/plugin/worker probes + low-cardinality counters/gauges
```

### Recommended Project Structure

```text
app/
├── api/
│   └── routers/
│       ├── health.py          # move health/readyz under /v1 and broaden readiness
│       ├── incidents.py       # list/detail/ack/close trusted internal APIs
│       ├── config_status.py   # safe rules/topology summaries
│       ├── metrics.py         # Prometheus text exposition
│       └── ingress.py         # move Icinga2 route to /v1/icinga2/events
├── domain/
│   ├── incidents.py           # lifecycle context/transition helpers
│   └── rules.py               # response envelope extensions
├── persistence/
│   └── incidents.py           # lifecycle repository functions and keyset queries
├── processing/
│   ├── lifecycle.py           # LifecycleManager + expiration worker
│   ├── ingress.py             # event-type branch to problem vs recovery
│   ├── incident_manager.py    # problem-only aggregation remains separate
│   ├── metrics.py             # metric names/label helpers if using prometheus-client
│   └── logging.py             # JSON formatter/safe extra helpers
└── main.py                    # lifespan worker wiring and /v1 router inclusion
```

### Pattern 1: Separate Lifecycle Manager from Problem Aggregation

**What:** Add `LifecycleManager` with `resolve_for_event`, `acknowledge`, `manual_close`, and `expire_stale_batch`; keep `IncidentManager.apply_problem` problem-only. [VERIFIED: app/processing/incident_manager.py:60-66]

**When to use:** Every lifecycle transition except PROBLEM upsert/notification dispatch. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-31]

**Example:**

```python
# Source: project pattern + locked Phase 4 decisions
if event.event_type is EventType.PROBLEM:
    incident_result = await self._apply_problem(event, decision)
elif event.event_type is EventType.RECOVERY:
    lifecycle_result = await self._resolve_recovery(event)
```

### Pattern 2: PostgreSQL-Atomic Affected-Set Shrinking

**What:** Use repository functions that select candidate `OPEN` rows with row locks or perform single-statement updates with `RETURNING`, then map returned rows into typed lifecycle results. [CITED: https://docs.sqlalchemy.org/en/20/tutorial/data_update.html]

**When to use:** Recovery, manual close, acknowledgement, and expiration all need idempotent, retry-safe mutation results. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-39]

**Example:**

```python
# Source: SQLAlchemy UPDATE RETURNING docs + existing repository style
stmt = (
    update(Incident)
    .where(Incident.status == IncidentStatus.OPEN.value)
    .where(Incident.id == incident_id)
    .values(status=IncidentStatus.CLOSED.value, closed_at=func.now(), updated_at=func.now())
    .returning(*Incident.__table__.columns)
)
row = (await session.execute(stmt)).mappings().one_or_none()
```

### Pattern 3: Lifespan-Owned Expiration Worker

**What:** Start one async background loop during FastAPI lifespan startup, expose health state, cancel/stop it in shutdown, and keep the sweep idempotent because in-memory tasks can be lost on crash. [CITED: https://fastapi.tiangolo.com/advanced/events/] [VERIFIED: .planning/research/STACK.md:90-97]

**When to use:** Stale expiration only. Do not reuse `TaskRunner` as a scheduler in v1. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:27-31]

**Example:**

```python
# Source: FastAPI lifespan docs + app/main.py pattern
worker = LifecycleWorker(sessionmaker=app.state.sessionmaker, interval_seconds=30)
app.state.lifecycle_worker = worker
await worker.start()
try:
    yield
finally:
    await worker.stop()
```

### Pattern 4: Cursor Pagination with Locked Stable Order

**What:** Encode the last row's `(last_update_time, id)` into an opaque cursor and fetch the next page with `(last_update_time, id) < (:cursor_time, :cursor_id)` under `ORDER BY last_update_time DESC, id DESC`. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-39]

**When to use:** `/v1/incidents` listing under any filter combination. [VERIFIED: .planning/REQUIREMENTS.md:85-91]

**Example:**

```python
# Source: locked Phase 4 pagination decision
stmt = select(Incident).order_by(Incident.last_update_time.desc(), Incident.id.desc()).limit(limit + 1)
if cursor is not None:
    stmt = stmt.where(
        tuple_(Incident.last_update_time, Incident.id) < (cursor.last_update_time, cursor.id)
    )
```

### Anti-Patterns to Avoid

- **Recovery through problem aggregation:** `RECOVERY` should never update threshold/window state or notification dispatch. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25]
- **Rule rematch for recovery:** topology/rules may have changed; match existing affected object membership instead. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25]
- **Closing multi-object topology incidents on first recovery:** shrink affected sets first; resolve only when empty. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25]
- **Application-clock expiration:** use PostgreSQL current time for stale predicates. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:27-31]
- **Parallel legacy `/health` and `/v1/health` aliases by default:** locked decision prefers clean `/v1` cutover unless hard compatibility is found. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-36]
- **Metric labels for host/service/group_key/fingerprint/incident_id:** these are high cardinality and explicitly forbidden. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:41-45] [VERIFIED: .planning/research/ARCHITECTURE.md:545-559]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Incident lifecycle correctness | In-memory locks/caches or SELECT-then-act races | PostgreSQL transactions, row locks, `UPDATE ... RETURNING`, partial unique index | Database already owns one-open invariant and burst correctness. [VERIFIED: .planning/PROJECT.md:40-54] |
| Expiration scheduling | APScheduler/Celery/Redis scheduler | One FastAPI lifespan-managed asyncio loop | Locked v1 decision; no broker/scheduler state needed. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:27-31] |
| Metrics exposition | Custom Prometheus text formatting | `prometheus-client` if package warning accepted | Official package handles metric types/exposition; manual output risks invalid Prometheus text. [CITED: https://prometheus.github.io/client_python/] |
| JSON API validation | Raw query/body dict parsing | Pydantic v2 strict request/response models | Existing codebase pattern rejects malformed domain/config input. [VERIFIED: app/domain/events.py:39-58] |
| Secret redaction by convention | Free-form JSON responses/logs | Typed safe envelopes and allowlisted fields | Decisions prohibit raw payloads, plugin secrets, SMTP transcripts, stack traces. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-45] |
| Cursor tokens | Client-visible SQL offsets or mutable page numbers | Opaque keyset cursor containing `last_update_time` + `id` | Locked ordering remains stable under incident updates. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-39] |

**Key insight:** Phase 4's hard problems are state transitions and safe surfaces, not route scaffolding. [VERIFIED: .planning/ROADMAP.md:98-110] Keep transition authority in PostgreSQL-backed repositories and expose only bounded, non-secret API/log/metric facts. [VERIFIED: .planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md:28-33]

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Incident rows store statuses, affected sets, decision context, window state, notification marker, and timestamps; no stored route namespace found in database model. [VERIFIED: app/persistence/models.py:24-56] | Code edits only for new lifecycle context; no data migration required unless planner adds new columns. |
| Live service config | External Icinga2 webhook definitions may point at current `/webhooks/icinga2`, but live Icinga2 config is outside the repo and not tool-visible. [ASSUMED] | Plan a cutover note for operators to repoint to `/v1/icinga2/events`; no legacy alias unless compatibility is explicitly discovered. |
| OS-registered state | No OS-level registrations are represented in repo planning or source files inspected. [VERIFIED: repo root read] | None. |
| Secrets/env vars | Settings expose DB URL and config paths; no route names or API auth secrets are configured in env settings. [VERIFIED: app/config/settings.py:8-24] | None for `/v1` cutover; do not add auth env vars in Phase 4. |
| Build artifacts | Python bytecode caches exist; no installed package metadata or generated clients embed route names in source paths inspected. [VERIFIED: tests directory read] | None. |

**Nothing found in category:** OS-registered state and env-var route state are none from repo-visible evidence. [VERIFIED: app/config/settings.py:8-24]

## Common Pitfalls

### Pitfall 1: Recovery Events Accidentally Re-enter Aggregation

**What goes wrong:** OK/UP events update threshold windows, create incidents, or produce notification side effects. [VERIFIED: .planning/research/PITFALLS.md:62-84]
**Why it happens:** Severity and lifecycle semantics are conflated. [VERIFIED: .planning/research/PITFALLS.md:62-84]
**How to avoid:** Branch on `EventType.RECOVERY` in the ingress processor and call lifecycle handling directly. [VERIFIED: app/domain/events.py:10-13]
**Warning signs:** `severity == "OK"` appears in incident upsert tests or recovery responses show `incident_effects.updated > 0`. [VERIFIED: .planning/research/PITFALLS.md:77-81]

### Pitfall 2: Service Recovery Closes Host Incidents

**What goes wrong:** A service OK resolves a host-level/topology incident even though only one service healed. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25]
**Why it happens:** Matching only by host ignores service granularity. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25]
**How to avoid:** Service recovery requires both `affected_hosts` containing host and `affected_services` containing service; host-only incident rows are ineligible. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25]
**Warning signs:** Tests do not include host-only incident plus service recovery. [VERIFIED: .planning/research/PITFALLS.md:77-81]

### Pitfall 3: Multi-object Incident Closes Too Early

**What goes wrong:** Topology-grouped incident moves to terminal state while other affected hosts/services remain down. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25]
**Why it happens:** Recovery code treats an incident as a single object. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25]
**How to avoid:** Update JSONB affected sets first; transition to `RESOLVED` only when remaining host/service membership is empty under the selected object model. [VERIFIED: app/persistence/models.py:31-36]
**Warning signs:** `closure_count` increments after one host recovery from a two-host incident. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:20-25]

### Pitfall 4: Expiration Uses the Wrong Clock or Wrong Window

**What goes wrong:** Incidents close/reopen around deployments, event delays, or process clock skew. [VERIFIED: .planning/research/PITFALLS.md:290-298]
**Why it happens:** Expiration uses app clock/global TTL instead of DB time and rule-specific window. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:27-31]
**How to avoid:** Compare PostgreSQL time to `last_update_time + rule.window`; use conservative idempotent update predicates. [CITED: https://www.postgresql.org/docs/current/functions-datetime.html]
**Warning signs:** Closed incidents immediately reopen with same `rule_name + group_key`. [VERIFIED: .planning/research/PITFALLS.md:290-298]

### Pitfall 5: Operability Surfaces Leak Secrets or High-cardinality Data

**What goes wrong:** `/v1/metrics`, status endpoints, logs, or incident details expose raw payloads, plugin options, SMTP transcripts, stack traces, host/service labels, group keys, or fingerprints as metric labels. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-45]
**Why it happens:** Debuggability is implemented as dumping internal objects. [VERIFIED: .planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md:28-33]
**How to avoid:** Use allowlisted response/log fields and low-cardinality metric labels. [VERIFIED: .planning/research/ARCHITECTURE.md:525-559]
**Warning signs:** `plugin_config`, `raw_payload`, `password`, `token`, or `secret` appears in response tests. [VERIFIED: app/domain/incidents.py:23-31]

## Code Examples

Verified patterns from official/project sources:

### Recovery Branch in Ingress

```python
# Source: app/processing/ingress.py event pipeline + Phase 4 D-01
if isinstance(decision, RuleDecision):
    if event.event_type is EventType.PROBLEM:
        incident_result = await self._apply_problem(event, decision)
    else:
        lifecycle_result = await self._apply_recovery(event)
```

### Idempotent Acknowledgement Update

```python
# Source: SQLAlchemy UPDATE RETURNING docs + Phase 1 acknowledgement metadata decision
stmt = (
    update(Incident)
    .where(Incident.id == incident_id)
    .where(Incident.status == IncidentStatus.OPEN.value)
    .values(
        acknowledged_at=func.coalesce(Incident.acknowledged_at, func.now()),
        acknowledged_by=operator,
        updated_at=func.now(),
    )
    .returning(*Incident.__table__.columns)
)
```

### Expiration Predicate Using Database Time

```python
# Source: PostgreSQL datetime docs + stored window_state.window_seconds
stmt = (
    update(Incident)
    .where(Incident.status == IncidentStatus.OPEN.value)
    .where(func.now() > Incident.last_update_time + func.make_interval(0, 0, 0, 0, 0, 0, window_seconds))
    .values(status=IncidentStatus.CLOSED.value, closed_at=func.now(), updated_at=func.now())
    .returning(*Incident.__table__.columns)
)
```

Planner note: verify the exact SQLAlchemy `func.make_interval` argument form in implementation; PostgreSQL supports interval arithmetic and `now()`, but SQLAlchemy expression spelling should be tested against PostgreSQL. [CITED: https://www.postgresql.org/docs/current/functions-datetime.html] [ASSUMED]

### Metrics Route Shape

```python
# Source: Prometheus client_python docs; exact imports verified during implementation
@router.get("/v1/metrics")
async def metrics() -> Response:
    body = generate_latest(registry)
    return Response(content=body, media_type=CONTENT_TYPE_LATEST)
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| FastAPI `@app.on_event("startup")` / `shutdown` | `FastAPI(lifespan=asynccontextmanager_fn)` | Official FastAPI docs mark alternative events deprecated when lifespan is provided. [CITED: https://fastapi.tiangolo.com/advanced/events/] | Plan worker startup/shutdown in existing lifespan, not event handlers. |
| Offset pagination | Cursor/keyset pagination | Locked in Phase 4 context. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-39] | Cursor must encode `(last_update_time, id)` and preserve filters. |
| Recovery as OK severity | Recovery as lifecycle command | Locked since `EventType.PROBLEM/RECOVERY` domain model. [VERIFIED: app/domain/events.py:10-13] | Recovery bypasses rule threshold/notification dispatch. |
| App-clock stale checks | PostgreSQL/database-time stale checks | Locked in Phase 4 context. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:27-31] | Expiration tests must assert DB-time behavior against PostgreSQL. |
| Built-in frontend/admin panel | REST/OpenAPI plus observability endpoints | Project scope fixed as API-first backend. [VERIFIED: .planning/PROJECT.md:3-6] | No frontend tasks in Phase 4. |

**Deprecated/outdated:** FastAPI startup/shutdown event handlers are not the right pattern for new app-wide lifecycle code when the app already uses lifespan. [CITED: https://fastapi.tiangolo.com/advanced/events/]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | External Icinga2 webhook definitions may point at current `/webhooks/icinga2`, but live Icinga2 config is outside the repo and not tool-visible. | Runtime State Inventory | Operators may need a migration note or temporary alias if a hard compatibility constraint exists. |
| A2 | `structlog` / `python-json-logger` are unnecessary for current JSON log requirements. | Standard Stack Alternatives | If logging format requirements become richer, planner may need a package legitimacy audit for a logging package. |
| A3 | SQLAlchemy expression spelling for `make_interval` should be verified during implementation. | Code Examples | Expiration query may need `text()` or a simpler second-comparison expression in PostgreSQL tests. |

## Open Questions

1. **Should `prometheus-client` be added despite the seam `SUS` verdict?**
   - What we know: Official Prometheus Python docs install `prometheus-client`, PyPI shows 0.25.0 and source repo `prometheus/client_python`; seam verdict is `SUS` only because downloads are unknown. [CITED: https://prometheus.github.io/client_python/] [VERIFIED: package-legitimacy seam]
   - What's unclear: Whether the planner may add a package under the assignment's no-gate/subagent constraints. [VERIFIED: user assignment]
   - Recommendation: Prefer `prometheus-client`; if planning rules require a human checkpoint for `SUS`, make metrics implementation a main-agent task rather than a subagent gate. [ASSUMED]
2. **Can `/v1` cutover remove legacy routes immediately?**
   - What we know: D-11 says clean cutover and no parallel aliases unless planning discovers a hard compatibility constraint. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-36]
   - What's unclear: Live Icinga2/webhook clients outside repo are not visible. [ASSUMED]
   - Recommendation: Plan clean cutover plus operator migration note; do not implement aliases by default. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-36]
3. **Where should lifecycle context live?**
   - What we know: `decision_context` exists, is bounded, and rejects obvious raw/secret fragments; no dedicated lifecycle_context column exists. [VERIFIED: app/domain/incidents.py:23-78] [VERIFIED: app/persistence/models.py:37-42]
   - What's unclear: Whether compact recovery/closure context fits cleanly in existing `DecisionContext.notes` or needs a typed schema extension. [ASSUMED]
   - Recommendation: Extend typed `DecisionContext` with explicit lifecycle fields before considering a migration; add a migration only if Pydantic field limits or query needs require it. [ASSUMED]

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| uv | All tool commands | ✓ | 0.11.7 | None needed. [VERIFIED: environment audit] |
| Python | Runtime/tests | ✓ | 3.14.4 | None needed. [VERIFIED: environment audit] |
| Docker daemon | Testcontainers PostgreSQL | ✓ | 29.4.1 | No SQLite fallback; install/start Docker if unavailable. [VERIFIED: environment audit] |
| pytest | Targeted verification | ✓ | 9.0.3 | None needed. [VERIFIED: environment audit] |
| Alembic | Migration/Testcontainers setup | ✓ | 1.18.4 | None needed. [VERIFIED: environment audit] |
| Ruff | Existing project lint command | ✓ | 0.15.16 | Subagents must not run lint gates. [VERIFIED: environment audit] [VERIFIED: user assignment] |
| mypy | Existing project typecheck command | ✓ | 2.1.0 | Subagents must not run typecheck gates. [VERIFIED: environment audit] [VERIFIED: user assignment] |
| prometheus-client | `/v1/metrics` if accepted | ✗ | 0.25.0 available on PyPI | Add via `uv add prometheus-client` only after resolving `SUS` warning. [VERIFIED: PyPI JSON] |

**Missing dependencies with no fallback:** `prometheus-client` if the planner chooses standard Prometheus client exposition. [VERIFIED: PyPI JSON]

**Missing dependencies with fallback:** None acceptable for PostgreSQL/Testcontainers; SQLite is prohibited. [VERIFIED: .planning/REQUIREMENTS.md:124-138]

## Verification Strategy (Nyquist validation disabled in config)

`workflow.nyquist_validation` is explicitly `false`, so no separate `## Validation Architecture` section is emitted. [VERIFIED: .planning/config.json:60-90] The planner still needs targeted verification tasks because OPS-04 requires automated coverage and the assignment asks for verification strategy. [VERIFIED: .planning/REQUIREMENTS.md:93-98]

### Existing Test Infrastructure

| Property | Value |
|----------|-------|
| Framework | pytest 9.0.3 + pytest-asyncio 1.4.0 [VERIFIED: environment audit] |
| Config file | `pyproject.toml` with `asyncio_mode = "auto"` and `pythonpath = ["."]` [VERIFIED: pyproject.toml:30-32] |
| API test pattern | `httpx.AsyncClient` + `ASGITransport` + explicit app lifespan context [VERIFIED: tests/test_ingress_router.py:62-66] |
| PostgreSQL pattern | Testcontainers `postgres:18-alpine`, Alembic upgrade, asyncpg URL conversion, truncate cleanup [VERIFIED: tests/test_incident_repository.py:18-53] |
| Targeted command pattern | `uv run pytest tests/<file>.py -q` [VERIFIED: user assignment] |

### Requirement → Targeted Verification Map

| Req ID | Behavior | Test Type | Suggested Targeted Command |
|--------|----------|-----------|----------------------------|
| LCY-01 | `RECOVERY` bypasses aggregation/notification | API + processing | `uv run pytest tests/test_ingress_router.py::test_recovery_routes_to_lifecycle_without_problem_upsert -q` |
| LCY-02 | Host recovery resolves matching active incidents | PostgreSQL integration | `uv run pytest tests/test_lifecycle_repository.py::test_host_recovery_resolves_open_host_incident -q` |
| LCY-03 | Service recovery matches host+service only | PostgreSQL integration | `uv run pytest tests/test_lifecycle_repository.py::test_service_recovery_does_not_close_host_only_incident -q` |
| LCY-04 | Resolution context is compact/non-secret | Unit + DB integration | `uv run pytest tests/test_lifecycle_repository.py::test_resolution_context_is_non_secret -q` |
| LCY-05 | Stale expiration uses DB time/rule window | PostgreSQL integration | `uv run pytest tests/test_lifecycle_expiration.py::test_expiration_uses_database_time_and_rule_window -q` |
| LCY-06 | Lifespan starts/stops worker cleanly | API/lifespan unit | `uv run pytest tests/test_lifecycle_worker.py::test_lifespan_starts_and_stops_lifecycle_worker -q` |
| API-01 | List incidents with filters/cursor | API + DB integration | `uv run pytest tests/test_incidents_api.py::test_list_incidents_filters_and_cursor_pagination -q` |
| API-02 | Detail response safe complete fields | API + DB integration | `uv run pytest tests/test_incidents_api.py::test_incident_detail_excludes_raw_payloads_and_secrets -q` |
| API-03 | Acknowledge idempotent metadata | API + DB integration | `uv run pytest tests/test_incidents_api.py::test_ack_is_idempotent_and_keeps_incident_open -q` |
| API-04 | Manual close idempotent transition | API + DB integration | `uv run pytest tests/test_incidents_api.py::test_manual_close_is_idempotent_and_frees_open_slot -q` |
| API-05 | Rules/topology/plugins status safe | API unit/integration | `uv run pytest tests/test_config_status_api.py -q` |
| OPS-01 | JSON structured logs safe fields | Unit/API capture | `uv run pytest tests/test_structured_logging.py -q` |
| OPS-02 | Readiness spans DB/config/plugins/worker | API test | `uv run pytest tests/test_health.py::test_readyz_reports_dependency_failures_without_secrets -q` |
| OPS-03 | Low-cardinality metrics exposed | API unit | `uv run pytest tests/test_metrics_api.py -q` |
| OPS-04 | PostgreSQL/Testcontainers coverage exists | Integration suite | targeted Testcontainers files above; do not add SQLite substitutes. |

Planner note: these commands are planning targets; subagents under this assignment must not run gates/tests/lint/formatters. [VERIFIED: user assignment]

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|------------------|
| V2 Authentication | No for built-in Phase 4 auth | Trusted network/proxy assumption; API-key/session auth deferred. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-39] |
| V3 Session Management | No | No sessions in v1 operator API. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-39] |
| V4 Access Control | Limited | Do not expose public authz model; keep APIs internal and non-secret. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-45] |
| V5 Input Validation | Yes | Pydantic v2 strict models for filters/action bodies and response schemas. [VERIFIED: app/domain/events.py:39-58] |
| V6 Cryptography | Limited | Use non-secret hashes for config summaries; do not expose credentials or plugin options. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:41-45] |
| V7 Error Handling and Logging | Yes | Sanitized HTTP errors and JSON logs without raw payloads, secrets, stack traces, or SMTP transcripts. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-45] |
| V10 Malicious Code | Yes for YAML/plugin boundaries | YAML remains declarative; plugin class loading stays constrained to trusted modules. [VERIFIED: app/plugins/loader.py:58-69] |

### Known Threat Patterns for FastAPI/PostgreSQL Internal APIs

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| SQL injection through filters/cursors | Tampering | SQLAlchemy expression building and strict parsed filter models; never interpolate raw filter strings. [VERIFIED: app/persistence/incidents.py:433-471] |
| Secret leakage in incident/config/status APIs | Information Disclosure | Allowlisted response fields; no raw payloads/plugin options/SMTP transcripts/stack traces. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-45] |
| High-cardinality metric DoS | Denial of Service | Exclude host/service/group_key/fingerprint/incident_id labels; put IDs in logs. [VERIFIED: .planning/research/ARCHITECTURE.md:545-559] |
| Lifecycle race causes duplicate active incidents | Tampering | Preserve PostgreSQL partial unique index and transition rows out of `OPEN` atomically. [VERIFIED: app/persistence/models.py:13-14] |
| Operator mutation replay | Repudiation/Tampering | Idempotent action endpoints and compact operator/reason context. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md:33-39] |

## Sources

### Primary (HIGH confidence)

- `.planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md` — locked Phase 4 decisions and scope. [VERIFIED]
- `.planning/REQUIREMENTS.md` — LCY/API/OPS requirements and no-SQLite constraint. [VERIFIED]
- `.planning/ROADMAP.md` — Phase 4 goal, dependencies, success criteria. [VERIFIED]
- `.planning/STATE.md` — accumulated decisions and Phase 4 concerns. [VERIFIED]
- `.planning/PROJECT.md` — API-first/no-frontend, PostgreSQL, Testcontainers constraints. [VERIFIED]
- Phase 1/2/3 context files — locked upstream decisions. [VERIFIED]
- Existing source files under `app/` and tests under `tests/` cited inline. [VERIFIED]

### Secondary (MEDIUM confidence)

- FastAPI lifespan docs — startup/shutdown async context manager and deprecated events warning: https://fastapi.tiangolo.com/advanced/events/ [CITED]
- SQLAlchemy 2.0 update/delete/RETURNING docs: https://docs.sqlalchemy.org/en/20/tutorial/data_update.html [CITED]
- PostgreSQL date/time functions and interval arithmetic docs: https://www.postgresql.org/docs/current/functions-datetime.html [CITED]
- Prometheus Python client docs: https://prometheus.github.io/client_python/ and https://prometheus.github.io/client_python/exporting/http/ [CITED]

### Tertiary (LOW confidence)

- Cursor pagination implementation pattern beyond the locked `(last_update_time DESC, id DESC)` order. [ASSUMED]
- Exact need for `prometheus-client` package under no-gate constraints. [ASSUMED]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH for existing stack, MEDIUM for `prometheus-client` because legitimacy seam returned `SUS` due unknown downloads. [VERIFIED: package-legitimacy seam]
- Architecture: HIGH because it follows locked decisions and existing code seams. [VERIFIED: .planning/phases/04-lifecycle-operator-apis-and-operability/04-CONTEXT.md]
- Pitfalls: HIGH because they are grounded in project research and locked decisions. [VERIFIED: .planning/research/PITFALLS.md]
- Verification: HIGH for existing test conventions; commands for new tests are planning targets, not observed files. [VERIFIED: tests/test_incident_repository.py] [ASSUMED]

**Research date:** 2026-06-09
**Valid until:** 2026-07-09 for project architecture; 2026-06-16 for package/version decisions.
