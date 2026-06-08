# Phase 3: Problem Aggregation and Notification Dispatch - Research

**Researched:** 2026-06-08
**Domain:** Python async incident aggregation, PostgreSQL upsert with threshold transitions, pluggable notification dispatch via asyncio TaskRunner
**Confidence:** HIGH

## Summary

Phase 3 connects the Phase 2 decision pipeline to Phase 1's PostgreSQL incident repository, creating an end-to-end path where `PROBLEM` events become durable topology-aware incidents and threshold crossings dispatch notifications through pluggable output channels. The core challenge is not the individual pieces — upsert, threshold counting, or SMTP — but the concurrency-safe ordering: incident mutation must be durable before notification work is submitted, and the same threshold crossing must never trigger duplicate notifications.

The existing codebase provides three critical seams: `Icinga2DecisionProcessor` returns an `IngressDecisionEnvelope` with incident/closure/notification placeholders; `RuleEngine` produces typed `RuleDecision` and `ThresholdDecision` objects from in-memory window state; and `upsert_open_incident` performs atomic PostgreSQL `INSERT ... ON CONFLICT DO UPDATE` against the partial unique index. Phase 3 must replace the placeholders with real aggregation results, move window state from process memory into durable bounded state associated with the open incident, add a threshold-transition marker to prevent duplicate notifications, introduce an async `TaskRunner` abstraction, load output plugins from a declarative YAML registry, and implement a concrete SMTP/Mailpit email-style output plugin.

**Primary recommendation:** Keep the incident the source of truth for both aggregation state and threshold-transition deduplication. Store bounded window metadata (counted fingerprints, event times, threshold-crossed flag) in PostgreSQL alongside the incident row, updated atomically in the same upsert transaction. Only after the transaction commits should the processor inspect the returned incident to detect a first-time threshold crossing and submit notification work through the `TaskRunner`. This avoids separate aggregation tables, outbox tables, and complex distributed state in v1 while satisfying all Phase 3 requirements.

## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Durable Threshold Transitions
- **D-01:** A rule/group counts as notification-triggering only on the first durable transition from below threshold to crossed for the current open incident. Later events can update the incident but must not repeatedly trigger notification work.
- **D-02:** Notification submission happens after the incident mutation and threshold transition marker are durable. Do not submit notification work before PostgreSQL has accepted the state transition.
- **D-03:** While the same incident remains `OPEN`, there are no repeat notifications. Severity escalation, additional affected hosts, and later events update incident state but do not dispatch another notification in v1.
- **D-04:** The dedupe fact belongs in incident-side durable state: a threshold/notification-triggered marker on incident metadata or incident columns. Do not rely on output plugins to dedupe repeated sends. Do not add a separate durable outbox/attempt log unless research proves the incident-side marker cannot satisfy the requirements.

#### TaskRunner and Output Boundary
- **D-05:** v1 uses an async in-process `TaskRunner` implementation. All notification work must be submitted through the `TaskRunner` seam; processors must not call output plugins directly.
- **D-06:** `TaskRunner` is the clean cutover boundary for future Celery/Redis, but Celery/Redis is out of scope for v1. The asyncio runner should be deterministic and testable.
- **D-07:** Output plugins are loaded as a named registry from YAML using trusted plugin definitions. Cache plugins by configured name and expose safe status/listing data. Avoid hardcoding a single default-only output path.
- **D-08:** YAML must not dynamically import arbitrary untrusted code. Plugin registry config is declarative and should map trusted plugin names/classes/options, preserving the project rule that YAML is not executable plugin code.
- **D-09:** Phase 3 should optimize the concrete v1 email-style output around **Mailpit SMTP**. Implement a generic SMTP/email-envelope output plugin that can point at Mailpit for Docker-based dev/test and later point at Mailu or another SMTP relay without changing Correlia's core processing.
- **D-10:** If notification dispatch fails after the incident is durable, keep the incident mutation. Record/report a notification failure; do not roll back incident state.

#### Processing Outcome Envelope
- **D-11:** The Phase 3 ingest response should extend the Phase 2 decision envelope with a compact incident result: incident id, inserted/updated effect, current status, threshold-crossed/notification-triggered booleans, notification submitted/failed counts, and bounded safe failure reasons.
- **D-12:** Do not return full incident snapshots on every ingest response. Keep the response inspectable but compact and non-secret.
- **D-13:** Incident `decision_context` should store bounded non-secret processing facts: fingerprint, source id, matched rule name, group key, threshold transition facts, counted event/fingerprint facts, output action names, plugin names/status, config hash, and safe failure category/message.
- **D-14:** Do not store raw source payloads, SMTP transcripts, credentials, full exception traces, or rendered notification bodies in `decision_context`.
- **D-15:** Notification failure details exposed to API clients should be typed safe categories such as `missing_plugin`, `missing_incident`, `plugin_exception`, and `dispatch_failed`, with sanitized messages only.
- **D-16:** Accepted `PROBLEM` events that update an incident but do not trigger notification should return an explicit no-dispatch outcome, not just `notification_count=0`. Reasons should distinguish `below_threshold`, `already_notified`, `replay`, and comparable safe explanations.

#### Aggregation State Source
- **D-17:** Threshold/window counting must survive process restarts in v1. Persist bounded window state keyed by `rule_name + group_key` / open incident, including enough fingerprint and event-time facts to evaluate thresholds without raw payload storage.
- **D-18:** Prefer bounded durable window state associated with the open incident over a separate aggregation table unless research shows a table is required for correctness or maintainability.
- **D-19:** Replayed fingerprints already counted in the current open incident/window do not increment `event_count`, do not change affected sets except where genuinely new deterministic content appears, and do not trigger notification.
- **D-20:** `event_count` should represent unique accepted problem fingerprints contributing to the open incident, not raw delivery count.
- **D-21:** Threshold/window state update, incident insert/update, and threshold/notification marker write must be atomic in one PostgreSQL transaction. TaskRunner/output dispatch happens after that durable write boundary.
- **D-22:** Use `NormalizedEvent.timestamp` for window membership. `last_update_time` must not move backward; older/out-of-order events can count only if they are inside the current window and not replayed.

### Claude's Discretion

No selected area was delegated to Claude. Downstream agents should treat the decisions above as locked.

### Deferred Ideas (OUT OF SCOPE)

- Postal HTTP API output plugin — future production-oriented programmable mail output, after the SMTP/Mailpit seam proves the output boundary.
- Mailu deployment guidance — useful external infrastructure docs, but not part of Correlia's v1 implementation.
- Celery/Redis runner — future replacement behind `TaskRunner`; v1 remains asyncio.
- Periodic reminders/escalation policy — belongs outside Phase 3's one-transition notification dispatch.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AGG-01 | Correlia processes `PROBLEM` events through enrichment, rule matching, group key generation, and incident state mutation. | Wire `Icinga2DecisionProcessor` → `RuleEngine` → aggregation layer → `upsert_open_incident`. The processor must open a DB session, call the rule engine, and feed the resulting `RuleDecision` into the incident repository. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md`] |
| AGG-02 | Correlia creates a new active incident when a matched group has no active incident. | Existing `upsert_open_incident` with `IncidentUpsertInput` already inserts on first `rule_name + group_key` with no open row. Phase 3 must populate `IncidentUpsertInput` from `RuleDecision` + `NormalizedEvent`. [CITED: `app/persistence/incidents.py`] |
| AGG-03 | Correlia updates the existing active incident when a matched group already has one. | Existing `ON CONFLICT DO UPDATE` path in `build_open_incident_upsert` handles updates: `event_count + 1`, `greatest(last_update_time, ...)`, max severity, merged affected sets, and updated summary. Phase 3 must add threshold/window state to the update set. [CITED: `app/persistence/incidents.py`] |
| AGG-04 | Correlia maintains incident severity, last update time, event count, summary, and affected hosts as more events arrive. | Max severity, greatest timestamp, event count increment, summary replacement, and JSONB set merge are already implemented in the upsert. Phase 3 adds `event_count` semantics (unique fingerprints, not raw deliveries) and bounded window state merge. [CITED: `app/persistence/incidents.py`] |
| AGG-05 | Correlia records enough processing outcome data to distinguish inserted, updated, threshold-crossed, and notification-triggered decisions. | Extend `DecisionContext` and `IngressDecisionEnvelope` with threshold-crossed flag, notification-triggered flag, no-dispatch reason, and safe failure categories. The response must distinguish these four outcomes explicitly. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-11, D-16] |
| TSK-01 | Maintainer can register named tasks behind a `TaskRunner` interface. | Define `TaskRunner` Protocol/ABC with `submit(task_name: str, payload: dict[str, Any])` method. Named tasks (e.g., `"notify"`) reference registered handler callables. [CITED: `.planning/research/ARCHITECTURE.md`] |
| TSK-02 | Correlia provides an asyncio-backed `TaskRunner` implementation for v1. | Implement `AsyncIOTaskRunner` that stores registered task handlers and submits work via `asyncio.create_task`. Must track task handles, attach done callbacks for exception logging, and support graceful drain during lifespan shutdown. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-05, D-06] |
| TSK-03 | Correlia submits notification work through `TaskRunner` only after durable incident state transitions. | Processor must commit the DB transaction (or use `await session.commit()` after `upsert_open_incident`) before calling `task_runner.submit("notify", ...)`. Never submit before PostgreSQL accepts the write. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-02, D-21] |
| NOT-01 | Operator can configure output plugins in a YAML plugin registry. | Create `app/config/plugins.py` with Pydantic v2 models for plugin registry YAML: `name`, `plugin_type` (e.g., `"email"`), `class_path` (trusted module path), and `options`. Use `yaml.safe_load()` + `model_validate()`. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-07, D-08] |
| NOT-02 | Correlia can load, cache, and list configured output plugins. | Plugin loader imports trusted classes via `importlib`, validates they implement `OutputPlugin` protocol, caches instances by name, and exposes `list_plugins()` / `get_plugin(name)` / `plugin_status()` safe inspection methods. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-07] |
| NOT-03 | Correlia dispatches incident notifications to an email-style output plugin when configured thresholds are crossed. | Concrete SMTP output plugin using `aiosmtplib` sends email-style notifications with incident summary, affected hosts, and rule metadata. Configure for Mailpit in dev/test (port 1025, no auth). [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-09] |
| NOT-04 | Correlia records or exposes notification failures, missing plugins, missing incidents, and plugin exceptions. | `NotificationResult` typed model with `success: bool`, `category: Literal["missing_plugin", "missing_incident", "plugin_exception", "dispatch_failed"]`, and sanitized `message`. Expose through `IngressDecisionEnvelope` and structured logs. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-15] |
| NOT-05 | Correlia avoids repeated notifications for the same durable threshold/status transition. | Store a `threshold_crossed` or `notified_at` marker in the incident row (or `decision_context`). The processor checks this marker after upsert; only if the marker changed from false→true in this transaction does it submit notification work. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-01, D-03, D-04] |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Problem event aggregation | Database / Storage | Core Processing | PostgreSQL owns the `OPEN` incident uniqueness and atomic upsert; the processor prepares inputs and interprets results. |
| Threshold/window state persistence | Database / Storage | Core Processing | Bounded window state (fingerprints, counts, markers) must survive restarts and concurrent writers; PostgreSQL is the source of truth. |
| Threshold transition detection | Core Processing | Database / Storage | Processor compares pre/post upsert threshold state to decide if this event caused the first crossing. |
| Notification dispatch decision | Core Processing | — | Only the processor knows if this event triggered a durable first-time threshold crossing. |
| Task execution submission | API / Backend | Core Processing | `TaskRunner.submit()` is the async boundary; the processor calls it after DB commit. |
| Task execution implementation | API / Backend | — | `AsyncIOTaskRunner` manages asyncio tasks, done callbacks, and lifespan shutdown. |
| Output plugin registry | Core Processing | — | Declarative YAML loading, trusted class import, and instance caching are config-layer concerns. |
| Output plugin dispatch | Core Processing | — | `NotificationDispatcher` fetches incident, resolves plugin, calls `send_notification`, and wraps errors in typed results. |
| Email-style output transport | Core Processing | — | SMTP plugin is a concrete adapter; it does not own dispatch decisions or incident state. |
| Ingest response assembly | API / Backend | — | FastAPI router returns the extended `IngressDecisionEnvelope` with incident effects and notification outcomes. |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Python | 3.14+ | Runtime | Project locked; required by `pyproject.toml` `requires-python`. [VERIFIED: `pyproject.toml`] |
| FastAPI | 0.136.x | REST API, webhook endpoint | Project locked; async native, dependency injection for sessionmaker and processor. [VERIFIED: `pyproject.toml`] |
| Pydantic | 2.13.x | Request/response/config validation | Project locked; strict mode, `extra="forbid"`, `model_validate` for plugin registry YAML. [VERIFIED: `pyproject.toml`] |
| SQLAlchemy | 2.0.x | Async DB access, PostgreSQL upsert | Project locked; existing `insert(...).on_conflict_do_update(...)` pattern must be extended with threshold state. [VERIFIED: `pyproject.toml`] |
| asyncpg | 0.31.x | Async PostgreSQL driver | Project locked; asyncio-native, supports JSONB and `ON CONFLICT`. [VERIFIED: `pyproject.toml`] |
| PostgreSQL | 18.x (17.x acceptable) | Durable incident + window state | Project locked; partial unique index, JSONB for bounded window metadata, atomic upsert. [VERIFIED: `app/persistence/models.py`] |
| PyYAML | 6.0.x | YAML parser for plugin registry | Project locked; `yaml.safe_load()` then Pydantic validate. [VERIFIED: `pyproject.toml`] |
| Alembic | 1.18.x | Schema migrations | Project locked; migration needed to add threshold/window columns to incidents table. [VERIFIED: `pyproject.toml`] |
| asyncio | Python stdlib | v1 task execution | Project locked; `TaskRunner` abstraction over `asyncio.create_task`. [CITED: `.planning/research/STACK.md`] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| aiosmtplib | 5.1.x | Async SMTP client for email output plugin | Required for the concrete v1 SMTP/Mailpit output plugin. Add when implementing `SmtpOutputPlugin`. [ASSUMED: PyPI] |
| httpx | 0.28.x | ASGI test client | Already in dev dependencies; use for FastAPI endpoint tests. [VERIFIED: `pyproject.toml`] |
| pytest | 9.0.x | Test runner | Already in dev dependencies. [VERIFIED: `pyproject.toml`] |
| pytest-asyncio | 1.4.x | Async test support | Already in dev dependencies. [VERIFIED: `pyproject.toml`] |
| testcontainers | 4.14.x | PostgreSQL integration tests | Already in dev dependencies; required for upsert + threshold transition concurrency tests. [VERIFIED: `pyproject.toml`] |
| Ruff | 0.15.x | Lint/format | Already in dev dependencies. [VERIFIED: `pyproject.toml`] |
| mypy | 2.x | Static typing | Already in dev dependencies. [VERIFIED: `pyproject.toml`] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Incident-side threshold marker | Separate `outbox` / `notification_attempts` table | Adds table and join complexity for v1; incident-side marker satisfies D-04 and D-21 with existing upsert atomicity. Revisit only if multi-instance delivery records become required. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-04] |
| `aiosmtplib` | `smtplib` in thread pool | `smtplib` is sync; thread pool adds overhead and complicates graceful shutdown. `aiosmtplib` is purpose-built for async SMTP. [ASSUMED: ecosystem knowledge] |
| Separate aggregation table | JSONB window state on incident row | Separate table requires additional transaction, join, and cleanup logic. JSONB on the incident row keeps threshold state, incident identity, and notification marker in one atomic write. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-18] |
| FastAPI `BackgroundTasks` | `TaskRunner` abstraction | `BackgroundTasks` is tied to request scope and not a clean cutover point for Celery/Redis. Explicit `TaskRunner` preserves the future boundary. [CITED: `.planning/research/STACK.md`] |

**Installation:**
```bash
# Core packages already installed via uv
# Add when implementing SMTP output plugin:
uv add aiosmtplib
```

**Version verification:**
```bash
# Core packages already in pyproject.toml and uv.lock
# New package for Phase 3:
python3 -c "import aiosmtplib; print(aiosmtplib.__version__)" 2>/dev/null || echo "aiosmtplib not yet installed"
```

## Package Legitimacy Audit

> Phase 3 introduces one new external package: `aiosmtplib`. All other dependencies are already locked in `uv.lock`.

| Package | Registry | Age / Latest | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-------------|-----------|-------------|---------|-------------|
| aiosmtplib | PyPI | 2025-02-16 (v5.1.0) | ~1.5M/mo | https://github.com/cole/aiosmtplib | [ASSUMED: PyPI] | Flagged — planner must add `checkpoint:human-verify` before installing [ASSUMED] |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** `aiosmtplib` — requires human verification checkpoint before install because package legitimacy seam (`slopcheck` / `pip index`) was unavailable in this environment. [ASSUMED]

*All other packages are already installed and verified through the project's existing `uv.lock` and dependency resolution.*

## Architecture Patterns

### System Architecture Diagram

```text
HTTP POST /webhooks/icinga2
  -> FastAPI ingress router
       -> Icinga2DecisionProcessor.process_payload(payload)
            -> Icinga2InputPlugin.process_payload (NORMALIZED)
            -> StaticTopologyEnricher.enrich (ENRICHED)
            -> RuleEngine.evaluate (RULE DECISION)
            -> IncidentManager.apply_problem(event, rule_decision)
                 -> open DB session
                 -> build IncidentUpsertInput from event + decision
                 -> build_open_incident_upsert (INSERT ... ON CONFLICT)
                      -> SET event_count, last_update_time, severity,
                         affected_hosts, affected_services, summary,
                         decision_context, window_state, threshold_crossed
                 -> await session.execute(stmt)
                 -> await session.commit()
                 -> inspect returned incident
                      -> was threshold_crossed already true?
                         -> no: first crossing -> submit notify task
                         -> yes: already notified -> no dispatch
                 -> close session
            -> TaskRunner.submit("notify", payload)
                 -> AsyncIOTaskRunner creates asyncio task
                 -> NotificationDispatcher.process(payload)
                      -> load incident by id
                      -> resolve output plugin by name
                      -> call OutputPlugin.send_notification(incident, config)
                           -> SmtpOutputPlugin.send via aiosmtplib
                      -> catch exceptions -> typed NotificationResult
            -> return IngressDecisionEnvelope
                 -> incident_effects: inserted/updated
                 -> threshold_crossed: bool
                 -> notification_triggered: bool
                 -> notification_count / failure_count
                 -> no_dispatch_reason: below_threshold | already_notified | replay
```

### Recommended Project Structure

```
app/
├── main.py                    # FastAPI factory; lifespan wires TaskRunner, plugin registry
├── api/
│   ├── deps.py                # add: get_task_runner, get_plugin_registry
│   └── routers/
│       ├── health.py          # existing
│       ├── ingress.py         # modified: extended envelope with incident effects
│       └── plugins.py         # NEW: GET /plugins status/list endpoint
├── domain/
│   ├── events.py              # existing
│   ├── incidents.py           # modified: extend DecisionContext with threshold/notification facts
│   └── rules.py               # modified: extend IngressDecisionEnvelope with notification outcomes
├── processing/
│   ├── ingress.py             # modified: wire incident manager + task runner
│   ├── enrichment.py          # existing
│   ├── rule_engine.py         # existing (in-memory window state becomes advisory only)
│   ├── incident_manager.py    # NEW: aggregation logic, upsert input builder, transition detection
│   ├── notification_dispatcher.py  # NEW: fetch incident, resolve plugin, send, wrap errors
│   └── task_runner.py         # NEW: AsyncIOTaskRunner + TaskRunner protocol
├── persistence/
│   ├── database.py            # existing
│   ├── models.py              # modified: add window_state JSONB, threshold_crossed bool
│   └── incidents.py           # modified: upsert sets window_state + threshold_crossed
├── plugins/
│   ├── interfaces.py          # modified: add OutputPlugin, TaskRunner protocols
│   ├── loader.py              # NEW: importlib-based trusted plugin loading
│   ├── inputs/
│   │   └── icinga2.py         # existing
│   └── outputs/
│       └── email.py           # NEW: SmtpOutputPlugin (aiosmtplib)
├── config/
│   ├── settings.py            # modified: add plugins_path, smtp defaults
│   ├── rules.py               # existing
│   ├── topology.py            # existing
│   └── plugins.py             # NEW: plugin registry YAML loader
└── migrations/
    └── versions/
        └── 0002_add_threshold_state.py   # NEW: window_state JSONB, threshold_crossed bool
```

### Pattern 1: Atomic Upsert with Durable Window State

**What:** Extend the existing `INSERT ... ON CONFLICT DO UPDATE` to atomically merge bounded window state and update a threshold-crossed marker. The returned row tells the processor whether this event caused the first crossing.

**When to use:** Every `PROBLEM` event matched to a rule with a threshold > 1.

**Why:** PostgreSQL guarantees that concurrent events for the same group see the same incident row; the last writer wins on window state, and the RETURNING clause gives the processor the definitive post-write state.

**Example:**
```python
# Source: project conventions from Phase 1, extended for Phase 3
stmt = insert(Incident).values(
    id=uuid4(),
    rule_name=input.rule_name,
    group_key=input.group_key,
    # ... existing fields ...
    window_state=input.window_state,          # NEW: bounded fingerprint set + timestamps
    threshold_crossed=input.threshold_crossed, # NEW: bool
)

stmt = stmt.on_conflict_do_update(
    index_elements=[Incident.rule_name, Incident.group_key],
    index_where=text(f"status = '{IncidentStatus.OPEN.value}'"),
    set_={
        # ... existing updates ...
        Incident.window_state: merge_window_state(
            Incident.window_state, stmt.excluded.window_state
        ),
        Incident.threshold_crossed: case(
            (Incident.threshold_crossed == False, stmt.excluded.threshold_crossed),
            else_=Incident.threshold_crossed,
        ),
        Incident.updated_at: func.now(),
    },
).returning(*Incident.__table__.columns)
```

### Pattern 2: Incident as Threshold-Transition Source of Truth

**What:** Store `threshold_crossed` as a boolean column on the incident (or inside `decision_context`). The processor sets it to `True` the first time `counted >= threshold`. Later events see `True` and do not dispatch.

**When to use:** All threshold-driven notification decisions in v1.

**Why:** Avoids separate tables, outbox complexity, and distributed state. The partial unique index already serializes writers for the same group; adding a boolean to the same row is atomic and restart-safe.

**Example:**
```python
# Source: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-04
class IncidentManager:
    async def apply_problem(
        self, event: NormalizedEvent, decision: RuleDecision
    ) -> IncidentResult:
        td = decision.threshold_decision
        input = IncidentUpsertInput(
            # ... existing fields ...
            window_state=self._build_window_state(td),
            threshold_crossed=td.crossed,
        )
        incident = await upsert_open_incident(self._session, input)
        await self._session.commit()

        # Transition detection: was it already crossed before this write?
        # If the returned row says crossed=True and this event's counted
        # reached threshold, it may be the first crossing.
        # Use a more precise check: compare old vs new via a subquery
        # or store `notified_at` timestamp.
        return IncidentResult(
            incident=incident,
            inserted=...,  # derive from xmax or RETURNING metadata
            threshold_crossed=td.crossed,
        )
```

**Planner note:** The exact "was this the first crossing" detection requires either:
- A `notified_at` timestamp that starts `NULL` and is set on first crossing (detect via `IS NULL` before upsert, or use a secondary update).
- Or an `xmax` check on the RETURNING row to distinguish INSERT from UPDATE.
- Or a two-step approach: upsert, then in the same session check if `threshold_crossed` changed. Since the session/transaction is committed before notification dispatch, the simplest v1 approach is: set `threshold_crossed` in the upsert, but only dispatch if `td.crossed is True` AND the event's `counted` reached threshold at exactly this event (i.e., `counted_before + (1 if not replay else 0) < threshold <= counted_after`). The in-memory `RuleEngine` can provide `counted_before` in the `ThresholdDecision`.

### Pattern 3: TaskRunner with Serializable Payloads

**What:** Define `TaskRunner` as a protocol with `submit(task_name: str, payload: dict[str, Any])`. The asyncio implementation stores handlers and submits via `create_task`. Payloads are plain dicts (incident id, rule name, plugin name, config hash), never ORM instances or closures.

**When to use:** All notification dispatch and future background work.

**Why:** Keeps the Celery/Redis cutover path open; a broker-backed runner can serialize the same payload without code changes.

**Example:**
```python
# Source: `.planning/research/ARCHITECTURE.md` Pattern 1
class TaskRunner(Protocol):
    async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None: ...

class AsyncIOTaskRunner:
    def __init__(self) -> None:
        self._handlers: dict[str, Callable[..., Awaitable[Any]]] = {}
        self._tasks: set[asyncio.Task[Any]] = set()

    def register(self, task_name: str, handler: Callable[..., Awaitable[Any]]) -> None:
        self._handlers[task_name] = handler

    async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None:
        handler = self._handlers.get(task_name)
        if handler is None:
            raise ValueError(f"unknown task: {task_name}")
        task = asyncio.create_task(handler(**payload))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        task.add_done_callback(self._log_exceptions)

    def _log_exceptions(self, task: asyncio.Task[Any]) -> None:
        exc = task.exception()
        if exc is not None:
            logger.exception("task failed: %s", exc)
```

### Pattern 4: Declarative Plugin Registry with Trusted Imports

**What:** YAML maps `name -> {type, module, class, options}`. Loader uses `importlib.import_module` on the declared module and validates the class implements the `OutputPlugin` protocol. No dynamic code execution from YAML.

**When to use:** Output plugin loading at startup.

**Why:** Satisfies D-08 (YAML is not executable) while allowing operators to configure which trusted plugins are active.

**Example:**
```python
# Source: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-07, D-08
class PluginRegistryEntry(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    name: str
    plugin_type: Literal["email", "webhook", "slack"]
    module: str  # e.g., "app.plugins.outputs.email"
    class_name: str  # e.g., "SmtpOutputPlugin"
    options: dict[str, Any] = Field(default_factory=dict)

class PluginRegistryConfig(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    outputs: list[PluginRegistryEntry] = Field(default_factory=list)

def load_plugin_registry(path: Path) -> dict[str, OutputPlugin]:
    data = yaml.safe_load(path.read_text())
    config = PluginRegistryConfig.model_validate(data or {"outputs": []})
    registry: dict[str, OutputPlugin] = {}
    for entry in config.outputs:
        mod = importlib.import_module(entry.module)
        cls = getattr(mod, entry.class_name)
        # Validate protocol conformance (duck-type check)
        if not hasattr(cls, "send_notification"):
            raise ValueError(f"{entry.name} does not implement OutputPlugin")
        registry[entry.name] = cls(**entry.options)
    return registry
```

### Pattern 5: Typed Notification Result with Safe Failure Categories

**What:** Every notification dispatch returns a `NotificationResult` with `success`, `category`, and `message`. Categories are a closed set of literals; messages are sanitized (no exception traces, no credentials).

**When to use:** Every output plugin invocation and every ingest response that includes notification outcomes.

**Why:** Satisfies D-15 (typed safe categories) and D-16 (explicit no-dispatch reasons). Prevents secret leakage through error messages.

**Example:**
```python
# Source: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-15, D-16
class NotificationResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    success: bool
    category: Literal[
        "dispatched",
        "below_threshold",
        "already_notified",
        "replay",
        "missing_plugin",
        "missing_incident",
        "plugin_exception",
        "dispatch_failed",
    ]
    message: str = Field(default="", max_length=256)
```

### Anti-Patterns to Avoid

- **Submitting notification work before DB commit:** If the transaction rolls back after task submission, operators receive notifications for non-existent or stale incidents. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-02]
- **Relying on output plugins to dedupe:** Plugins may not have durable state; duplicate sends can happen across restarts. Deduplicate at the incident level. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-04]
- **Passing ORM instances to TaskRunner payloads:** ORM instances are not serializable and outlive their session. Pass incident IDs and plain dicts. [CITED: `.planning/research/ARCHITECTURE.md`]
- **Storing raw payloads or credentials in `decision_context`:** Violates D-14 and leaks secrets to API clients. Store only bounded non-secret facts. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-14]
- **Using `FastAPI.BackgroundTasks` as the runner:** Tied to request scope; not a clean cutover for Celery/Redis. Use explicit `TaskRunner.submit()`. [CITED: `.planning/research/STACK.md`]
- **Per-event plugin loading:** Import and instantiate plugins at startup; cache instances. Per-event import causes latency and side effects. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-07]
- **Arbitrary code execution from YAML:** Never use `yaml.load()`, `eval()`, or dynamic imports based on unvalidated strings. YAML maps to trusted module/class paths only. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-08]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Async SMTP sending | Custom asyncio socket code around SMTP | `aiosmtplib` | Purpose-built async SMTP library with STARTTLS, auth, and connection pooling. [ASSUMED: ecosystem standard] |
| Task execution abstraction | Raw `asyncio.create_task` scattered in business logic | `TaskRunner` Protocol + `AsyncIOTaskRunner` | Keeps Celery/Redis cutover path open; centralizes exception handling and shutdown. [CITED: `.planning/research/ARCHITECTURE.md`] |
| Plugin loading | `eval()` or dynamic `exec()` from YAML | `importlib.import_module` on trusted module paths | Safe, testable, and preserves the "YAML is declarative" rule. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-08] |
| Notification deduplication | In-memory sets or cache | Incident-side `threshold_crossed` / `notified_at` marker | Survives restarts and works across multiple workers because PostgreSQL owns it. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-04] |
| Threshold/window state storage | In-memory dict (Phase 2 `_window_state`) | JSONB column on incident row or bounded separate table | Process memory is lost on restart; PostgreSQL JSONB is restart-safe and updated atomically in the upsert. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-17, D-18] |
| Failure message sanitization | String `repr(exc)` in API responses | Typed `NotificationResult` with closed category literals and bounded message field | Prevents secret leakage and gives API clients stable error handling. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-15] |

**Key insight:** The hardest part of Phase 3 is ordering and atomicity, not individual algorithms. PostgreSQL already solves concurrency; the processor must not defeat it by submitting async work inside the transaction or by splitting state across tables unnecessarily.

## Common Pitfalls

### Pitfall 1: Notification Storm from Threshold Re-evaluation

**What goes wrong:** Every event after threshold crossing dispatches another notification. A 500-event alert storm produces 500 emails/pages instead of one.

**Why it happens:** The processor checks `threshold_decision.crossed` and dispatches unconditionally, without tracking whether a notification was already sent for this incident.

**How to avoid:** Store `threshold_crossed` (or `notified_at`) on the incident row. Only dispatch when the upsert transitions this marker from false→true. If the incident already has the marker, update state but do not submit notification work. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-01, D-03, D-04]

**Warning signs:** `notification_count` grows with `event_count` after the first crossing; operators receive identical notifications with different timestamps.

### Pitfall 2: Phantom Notifications for Rolled-Back Incidents

**What goes wrong:** The processor submits a notification task, then the DB transaction rolls back (e.g., connection lost). The notification is sent for an incident that was never persisted.

**Why it happens:** `task_runner.submit()` is called before `await session.commit()`.

**How to avoid:** Strict ordering: upsert → commit → inspect result → submit task. Never submit inside an uncommitted transaction. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-02, D-21]

**Warning signs:** Notification references an incident ID that does not exist in the database; `TaskRunner.submit` appears before `session.commit` in the same `async def`.

### Pitfall 3: Lost Task Exceptions After Ingress Returns 200

**What goes wrong:** The API returns success, but the asyncio task fails silently (exception never retrieved). Operators see `notification_triggered: true` but no message arrives.

**Why it happens:** `asyncio.create_task` schedules work but does not make failures visible. The task object is dropped after submission.

**How to avoid:** `AsyncIOTaskRunner` must keep a `weakref.WeakSet` or `set` of task objects, attach `add_done_callback` that logs exceptions, and drain/cancel gracefully during FastAPI lifespan shutdown. [CITED: `.planning/research/PITFALLS.md` Pitfall 8]

**Warning signs:** Logs contain "Task exception was never retrieved"; `notification_triggered` is true but no send attempt record exists.

### Pitfall 4: Plugin Registry Accepts Arbitrary Code

**What goes wrong:** A crafted YAML file causes Correlia to import and execute arbitrary Python modules, leading to RCE.

**Why it happens:** Plugin loader uses `eval()`, `exec()`, `yaml.unsafe_load()`, or `__import__(user_string)` without validation.

**How to avoid:** YAML is `safe_load()` only. Registry entries declare `module` and `class_name` strings, but the loader validates them against an allowlist or trusted package prefix (e.g., `app.plugins.outputs.`). Reject paths outside the trusted namespace. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-08]

**Warning signs:** `eval`, `exec`, `__import__`, or `yaml.load` appear in plugin loader source.

### Pitfall 5: Window State Drift Between RuleEngine and Database

**What goes wrong:** The in-memory `RuleEngine._window_state` counts fingerprints differently from the durable JSONB window state. Replays are handled inconsistently, and threshold decisions differ between process restarts.

**Why it happens:** Phase 2's `RuleEngine` maintains `_window_state` in memory. Phase 3 must either replace this with DB-backed state or make the in-memory state strictly advisory (read from DB before evaluation).

**How to avoid:** For v1, the simplest correct approach is to make `RuleEngine` stateless with respect to threshold counting: it produces a `ThresholdDecision` based on the event alone, and the `IncidentManager` merges the fingerprint into the durable incident window state during upsert. The returned incident row tells the processor whether the threshold is now crossed. This eliminates dual state sources. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-17, D-18, D-19]

**Warning signs:** `RuleEngine` maintains a mutable `_window_state` dict that is never persisted; test behavior differs before and after process restart.

### Pitfall 6: JSONB Window State Grows Without Bound

**What goes wrong:** The `window_state` JSONB accumulates every fingerprint ever seen for the incident, causing write amplification and large row sizes.

**Why it happens:** Fingerprints are added but old ones outside the window are never pruned.

**How to avoid:** Store fingerprints with timestamps in a bounded dict (e.g., `{"fingerprints": {"fp1": "2026-06-08T10:00:00Z", ...}, "counted": 3}`). During upsert, prune fingerprints older than `window_end - window_duration`. Cap the stored fingerprint count (e.g., 1000) to prevent unbounded growth. The exact pruning can be done in Python before building the upsert input. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-17, D-18]

**Warning signs:** `window_state` JSONB length grows linearly with event count; incident update latency increases over time.

### Pitfall 7: Leaking Secrets Through Notification Failure Messages

**What goes wrong:** A failed SMTP connection includes the full exception traceback with server credentials, or a `missing_plugin` error reveals internal module paths.

**Why it happens:** Error messages propagate raw exception strings to API responses and logs.

**How to avoid:** `NotificationDispatcher` catches all exceptions and maps them to `NotificationResult` with a closed category literal and a sanitized bounded message (max 256 chars). Never include exception traces, SMTP transcripts, or config values in the result. [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-14, D-15]

**Warning signs:** `str(exc)` or `traceback.format_exc()` appears in API response models or log messages at INFO level.

## Code Examples

### Extending the Incident Model with Threshold State

```python
# Source: project conventions from Phase 1, extended per D-17/D-18
class Incident(Base):
    __tablename__ = "incidents"
    # ... existing columns ...
    window_state: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default="'{}'::jsonb"
    )
    threshold_crossed: Mapped[bool] = mapped_column(
        nullable=False, default=False, server_default="false"
    )
    notified_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
```

### IncidentManager with Atomic Upsert and Transition Detection

```python
# Source: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-01 through D-22
@dataclass(frozen=True, slots=True)
class IncidentResult:
    incident_id: UUID
    effect: Literal["inserted", "updated"]
    threshold_crossed: bool
    notification_triggered: bool
    no_dispatch_reason: str | None = None

class IncidentManager:
    def __init__(
        self,
        session: AsyncSession,
        task_runner: TaskRunner,
        plugin_registry: dict[str, OutputPlugin],
    ) -> None:
        self._session = session
        self._task_runner = task_runner
        self._plugin_registry = plugin_registry

    async def apply_problem(
        self, event: NormalizedEvent, decision: RuleDecision
    ) -> IncidentResult:
        td = decision.threshold_decision
        was_crossed_before = await self._is_threshold_crossed(
            decision.rule_name, decision.group_key
        )

        input = self._build_upsert_input(event, decision)
        incident = await upsert_open_incident(self._session, input)
        await self._session.commit()

        now_crossed = incident.threshold_crossed
        first_crossing = now_crossed and not was_crossed_before

        if first_crossing:
            for action in decision.actions:
                await self._task_runner.submit(
                    "notify",
                    {
                        "incident_id": str(incident.id),
                        "rule_name": decision.rule_name,
                        "group_key": decision.group_key,
                        "plugin_name": action,  # or resolve action->plugin mapping
                        "config_hash": input.decision_context.config_hash,
                    },
                )

        return IncidentResult(
            incident_id=incident.id,
            effect="inserted" if ... else "updated",  # detect via xmax or RETURNING
            threshold_crossed=now_crossed,
            notification_triggered=first_crossing,
            no_dispatch_reason=self._reason(first_crossing, td),
        )

    def _reason(
        self, triggered: bool, td: ThresholdDecision
    ) -> str | None:
        if triggered:
            return None
        if not td.crossed:
            return "below_threshold"
        if td.replay_or_skip_reasons:
            return "replay"
        return "already_notified"
```

### SMTP Output Plugin with Mailpit Defaults

```python
# Source: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-09
import aiosmtplib
from email.message import EmailMessage

class SmtpOutputPlugin:
    def __init__(
        self,
        host: str = "localhost",
        port: int = 1025,
        from_addr: str = "correlia@localhost",
    ) -> None:
        self._host = host
        self._port = port
        self._from_addr = from_addr

    async def send_notification(
        self, incident: IncidentView, config: Mapping[str, Any]
    ) -> None:
        msg = EmailMessage()
        msg["From"] = self._from_addr
        msg["To"] = config.get("to_addr", "ops@localhost")
        msg["Subject"] = f"[{incident.severity}] {incident.summary}"
        msg.set_content(
            f"Incident {incident.id}\n"
            f"Rule: {incident.rule_name}\n"
            f"Group: {incident.group_key}\n"
            f"Affected hosts: {', '.join(incident.affected_hosts)}\n"
        )
        await aiosmtplib.send(
            msg,
            hostname=self._host,
            port=self._port,
        )
```

### Extended IngressDecisionEnvelope

```python
# Source: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-11, D-16
class IngressDecisionEnvelope(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    # ... existing Phase 2 fields ...
    incident_effects: IncidentEffectSummary = Field(
        default_factory=lambda: IncidentEffectSummary(inserted=0, updated=0)
    )
    closure_count: int = Field(default=0, ge=0)
    notification_count: int = Field(default=0, ge=0)
    notification_failed: int = Field(default=0, ge=0)
    threshold_crossed: bool = Field(default=False)
    notification_triggered: bool = Field(default=False)
    no_dispatch_reason: str | None = Field(default=None, max_length=64)
    notification_results: list[NotificationResult] = Field(default_factory=list)
    rejection: dict[str, object] | None = None
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| In-memory `_window_state` in `RuleEngine` | Durable JSONB `window_state` on incident row, updated atomically in upsert | Phase 3 | Restart-safe threshold counting; concurrent-writer-safe fingerprint deduplication. |
| Placeholder `incident_effects=IncidentEffectSummary(inserted=0, updated=0)` in ingress response | Real incident effects populated after `upsert_open_incident` RETURNING | Phase 3 | Ingest response now identifies actual incident mutation outcomes. |
| No notification dispatch | `TaskRunner.submit("notify", ...)` after durable commit | Phase 3 | Threshold crossings reach operators; pluggable output boundary validated. |
| No plugin registry | Declarative YAML plugin registry with trusted imports | Phase 3 | Operators can configure output channels without code changes. |

**Deprecated/outdated:**
- `RuleEngine._window_state` as authoritative threshold state: replaced by PostgreSQL-backed state per D-17/D-18. The in-memory dict may remain for advisory pre-checks or be removed entirely.
- `notification_count=0` as silent no-op: replaced by explicit `no_dispatch_reason` per D-16.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `aiosmtplib` v5.1.x is the standard async SMTP library for Python and supports Mailpit on port 1025 without authentication. | Standard Stack | If `aiosmtplib` has compatibility issues with Mailpit or Python 3.14, the SMTP plugin may need alternative implementation or a different library. |
| A2 | Storing `threshold_crossed` as a boolean column on the incident row (plus `notified_at` optional) is sufficient for v1 deduplication without a separate outbox/attempts table. | Architecture Patterns | If operational requirements later demand audit records of every notification attempt, the incident-side marker will need supplementation with an outbox table. D-04 explicitly defers this decision. |
| A3 | The `RuleEngine` can remain stateless for threshold counting in v1, with the `IncidentManager` owning durable window state merge. | Common Pitfalls | If rule evaluation needs pre-upsert threshold knowledge (e.g., to skip the DB write entirely), the engine may need to read incident state, adding a DB round-trip. |
| A4 | `importlib.import_module` on trusted module paths (e.g., `app.plugins.outputs.*`) is an acceptable security boundary for plugin loading. | Architecture Patterns | If the project later requires untrusted third-party plugins, the allowlist approach will need sandboxing or separate process isolation. |
| A5 | JSONB `window_state` with bounded fingerprint pruning (e.g., cap at 1000 entries) will not cause performance issues in v1. | Common Pitfalls | If incidents receive tens of thousands of unique fingerprints, JSONB updates may become slow. A separate aggregation table would then be justified. |

## Open Questions

1. **How exactly should "inserted vs updated" be detected in the upsert RETURNING path?**
   - What we know: PostgreSQL `xmax = 0` indicates INSERT; `xmax != 0` indicates UPDATE. SQLAlchemy RETURNING can include `func.xmax`.
   - What's unclear: Whether the project prefers `xmax` detection or a follow-up query, and whether `xmax` semantics are stable across PostgreSQL versions.
   - Recommendation: Use `xmax` in the RETURNING clause for atomic detection, with a fallback comment explaining the semantics. Add a test that asserts INSERT vs UPDATE detection.

2. **Should `RuleEngine` still maintain in-memory `_window_state` for advisory purposes, or be made completely stateless?**
   - What we know: Phase 2's `RuleEngine` has `_window_state` for threshold decisions. Phase 3 needs durable state.
   - What's unclear: Whether the engine should read DB state before evaluating, or whether the manager should drive all counting.
   - Recommendation: Make `RuleEngine` stateless for threshold counting in v1. The manager builds `ThresholdDecision`-like metadata from the post-upsert incident row. This eliminates dual-state consistency issues.

3. **What is the exact mapping from rule `actions` to output plugin names?**
   - What we know: `RuleAction` has `name` and `plugin` fields. `load_rules_config` validates actions against `known_actions` and plugins against `known_plugins`.
   - What's unclear: Whether the action name (e.g., `"create_incident"`) maps to a task name, or whether the `plugin` field is the direct plugin registry key.
   - Recommendation: The `plugin` field on `RuleAction` should be the direct registry key for the output plugin. The `name` field is a human-readable action label. `NotificationDispatcher` resolves `plugin` -> `plugin_registry[name]`.

4. **Should `window_state` pruning happen in Python before upsert, or in PostgreSQL via JSONB operators?**
   - What we know: PostgreSQL has JSONB operators for deletion, but pruning by timestamp inside JSONB is complex.
   - What's unclear: Performance and correctness tradeoffs of Python-side pruning vs. a PostgreSQL stored function.
   - Recommendation: Prune in Python before building the upsert input. This keeps logic testable and avoids PostgreSQL-specific stored procedures in v1.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Python 3.14+ | Runtime | ✓ | 3.14.0 | — |
| uv | Package manager | ✓ | 0.11.x | — |
| PostgreSQL | Incident state, upsert tests | ✓ | 18.x (via Testcontainers) | Local PostgreSQL service if Docker unavailable |
| Docker | Testcontainers | ✓ | 24.x | Manual PostgreSQL install for tests |
| aiosmtplib | SMTP output plugin | ✗ | — | Use `smtplib` in thread pool for tests only (not production) |
| Mailpit | Dev/test SMTP target | ✗ | — | Skip SMTP integration tests; test plugin with mock transport |

**Missing dependencies with no fallback:**
- None that block core Phase 3 implementation. `aiosmtplib` can be added as a dependency when the SMTP plugin is implemented.

**Missing dependencies with fallback:**
- `aiosmtplib`: Can implement the `OutputPlugin` protocol and `TaskRunner` first, then add `aiosmtplib` for the concrete transport. Unit tests can use a fake in-memory output plugin.
- Mailpit: Not a code dependency. Docker Compose or manual run for integration tests.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | pytest 9.0.x + pytest-asyncio |
| Config file | `pyproject.toml` (`[tool.pytest.ini_options]`) |
| Quick run command | `uv run pytest tests/test_<module>.py -x` |
| Full suite command | `uv run pytest -x` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AGG-01 | PROBLEM event → enrichment → rule match → incident mutation | integration | `uv run pytest tests/test_ingress_router.py -x` | ✅ |
| AGG-02 | New active incident created for first matching group | integration | `uv run pytest tests/test_incident_repository.py -x` | ✅ |
| AGG-03 | Existing active incident updated for same group | integration | `uv run pytest tests/test_incident_repository.py -x` | ✅ |
| AGG-04 | Severity, last_update_time, event_count, summary, affected hosts maintained | integration | `uv run pytest tests/test_incident_repository.py -x` | ✅ |
| AGG-05 | Distinguish inserted/updated/threshold-crossed/notification-triggered | integration | `uv run pytest tests/test_incident_manager.py -x` | ❌ Wave 0 |
| TSK-01 | Named tasks registerable behind TaskRunner interface | unit | `uv run pytest tests/test_task_runner.py -x` | ❌ Wave 0 |
| TSK-02 | AsyncIO-backed TaskRunner implementation | unit | `uv run pytest tests/test_task_runner.py -x` | ❌ Wave 0 |
| TSK-03 | Notification work submitted only after durable commit | integration | `uv run pytest tests/test_incident_manager.py -x` | ❌ Wave 0 |
| NOT-01 | Output plugins configurable in YAML registry | unit | `uv run pytest tests/test_plugin_registry.py -x` | ❌ Wave 0 |
| NOT-02 | Load, cache, list configured output plugins | unit | `uv run pytest tests/test_plugin_registry.py -x` | ❌ Wave 0 |
| NOT-03 | Dispatch to email-style output plugin on threshold cross | integration | `uv run pytest tests/test_notification_dispatch.py -x` | ❌ Wave 0 |
| NOT-04 | Record/expose missing_plugin, missing_incident, plugin_exception, dispatch_failed | unit + integration | `uv run pytest tests/test_notification_dispatch.py -x` | ❌ Wave 0 |
| NOT-05 | No repeated notifications for same threshold transition | integration | `uv run pytest tests/test_incident_manager.py -x` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `uv run pytest tests/test_<relevant_module>.py -x`
- **Per wave merge:** `uv run pytest tests/ -x`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `tests/test_incident_manager.py` — covers AGG-01 through AGG-05, TSK-03, NOT-05
- [ ] `tests/test_task_runner.py` — covers TSK-01, TSK-02
- [ ] `tests/test_plugin_registry.py` — covers NOT-01, NOT-02
- [ ] `tests/test_notification_dispatch.py` — covers NOT-03, NOT-04
- [ ] `tests/test_smtp_output.py` — covers concrete SMTP plugin (optional if mock plugin suffices for core reqs)
- [ ] `tests/conftest.py` — may need shared fixtures for TaskRunner, plugin registry, and fake output plugin
- [ ] Alembic migration `0002_add_threshold_state.py` — adds `window_state` JSONB, `threshold_crossed` bool to incidents table

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | v1 has no auth on ingest or APIs yet (Phase 4 may add) |
| V3 Session Management | No | Stateless async service; no user sessions |
| V4 Access Control | No | No RBAC or resource-level ACL in v1 |
| V5 Input Validation | Yes | Pydantic v2 strict models for all ingress, config, and envelope boundaries; YAML `safe_load` only |
| V6 Cryptography | No | No custom crypto; SMTP TLS handled by `aiosmtplib` |
| V7 Error Handling | Yes | Typed `NotificationResult` with closed categories; sanitized messages (max 256 chars); no exception traces in API responses |
| V8 Data Protection | Yes | `decision_context` rejects raw payloads, credentials, secrets; `FORBIDDEN_NOTE_FRAGMENTS` guard in `DecisionContext` validator |
| V12 File Upload | No | No file uploads in v1 |
| V13 API | Yes | FastAPI automatic request/response validation; strict envelope models with `extra="forbid"` |

### Known Threat Patterns for Python Async / PostgreSQL / SMTP Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| SQL injection via rule_name/group_key | Tampering | SQLAlchemy bound values only; injection-shaped strings are persisted as literals [CITED: `tests/test_incident_repository.py`] |
| Notification storm from missing dedupe | Denial of Service | Incident-side `threshold_crossed` / `notified_at` marker; dispatch only on false→true transition [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-04] |
| Arbitrary code execution from plugin YAML | Elevation of Privilege | `yaml.safe_load()` + trusted module path allowlist (`app.plugins.outputs.*`); reject `eval`/`exec`/`__import__` [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-08] |
| Secret leakage through SMTP errors | Information Disclosure | `NotificationResult` with bounded sanitized messages; no exception traces in API responses [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-14, D-15] |
| Phantom notifications for rolled-back incidents | Repudiation | Strict ordering: DB commit before `TaskRunner.submit()` [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-02] |
| Unbounded JSONB growth | Denial of Service | Bounded `window_state` fingerprint pruning; cap at 1000 entries [CITED: `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-17] |

## Sources

### Primary (HIGH confidence)
- `app/persistence/incidents.py` — Atomic open-incident upsert repository; `IncidentUpsertInput`, `build_open_incident_upsert`, `upsert_open_incident` [VERIFIED: codebase read]
- `app/persistence/models.py` — Incident SQLAlchemy model, partial unique index constants [VERIFIED: codebase read]
- `app/domain/incidents.py` — `IncidentStatus`, `DecisionContext`, acknowledgement metadata [VERIFIED: codebase read]
- `app/domain/rules.py` — `RuleDecision`, `ThresholdDecision`, `IngressDecisionEnvelope` [VERIFIED: codebase read]
- `app/processing/ingress.py` — `Icinga2DecisionProcessor`, `build_icinga2_processor` [VERIFIED: codebase read]
- `app/processing/rule_engine.py` — `RuleEngine.evaluate`, `_window_state`, threshold logic [VERIFIED: codebase read]
- `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` — All locked decisions D-01 through D-22 [CITED: context file]
- `.planning/research/ARCHITECTURE.md` — Modular monolith boundaries, TaskRunner abstraction, output plugin pattern [CITED: research file]
- `.planning/research/PITFALLS.md` — Duplicate incidents, notification storms, async task failures, YAML safety [CITED: research file]
- `.planning/research/STACK.md` — Recommended stack, asyncio TaskRunner, aiosmtplib note [CITED: research file]

### Secondary (MEDIUM confidence)
- `https://mailpit.axllent.org/docs/install/` — Mailpit default ports (SMTP 1025, UI 8025), Docker support [CITED: CONTEXT.md external reference]
- `https://mailpit.axllent.org/docs/api-v1/` — Mailpit REST API for integration test message inspection [CITED: CONTEXT.md external reference]
- PostgreSQL `INSERT ... ON CONFLICT` documentation — Atomic upsert semantics under concurrency [CITED: Phase 1 research]
- SQLAlchemy PostgreSQL dialect upsert documentation — `on_conflict_do_update(index_where=...)` [CITED: Phase 1 research]

### Tertiary (LOW confidence)
- `aiosmtplib` PyPI and GitHub — Async SMTP client for Python; assumed compatible with Python 3.14 and Mailpit [ASSUMED: not verified in session]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all core packages are project-locked and verified in `pyproject.toml`/`uv.lock`. `aiosmtplib` is the only new dependency and is flagged for verification.
- Architecture: HIGH — derived directly from existing codebase patterns and locked CONTEXT.md decisions.
- Pitfalls: HIGH — based on existing PITFALLS.md research and concrete Phase 2/Phase 1 code patterns.

**Research date:** 2026-06-08
**Valid until:** 2026-07-08 (30 days for stable stack; revisit if `aiosmtplib` or Mailpit compatibility issues arise)
