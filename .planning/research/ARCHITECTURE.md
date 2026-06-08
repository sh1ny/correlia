# Architecture Research

**Domain:** API-first infrastructure alert aggregation backend
**Project:** Correlia
**Researched:** 2026-06-08
**Confidence:** HIGH

## Recommendation

Build Correlia as an async Python modular monolith with strict port/adaptor boundaries. Keep the first deployable service in one FastAPI process and one PostgreSQL database, but make inputs, outputs, task execution, and configuration loading swappable behind interfaces. This fits the current contract: Icinga2 first, REST APIs as the product surface, stateless processing logic, durable incident state in PostgreSQL, and a clean future cutover from in-process asyncio tasks to Celery/Redis.

The core architecture should be a one-way alert processing pipeline:

```
HTTP ingress
  -> input plugin normalization
  -> topology enrichment
  -> rule evaluation
  -> incident manager
  -> PostgreSQL atomic upsert / lifecycle state
  -> task runner submission
  -> output plugin dispatch
```

Do not let plugins own incident state, database transactions, or rule decisions. Plugins translate at the edges. The core processor owns normalized semantics and lifecycle behavior. PostgreSQL owns concurrency correctness.

## Standard Architecture

### System Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                   REST API                                   │
│  POST /webhooks/icinga2  GET /incidents  PATCH /incidents/{id}  /healthz     │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                               Input Boundary                                 │
│  InputPlugin registry                                                        │
│    └─ Icinga2InputPlugin: source payload -> NormalizedEvent                  │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ NormalizedEvent only
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Core Processing                                 │
│  EventProcessor                                                              │
│    ├─ TopologyEnricher: hostname patterns first, IP subnet fallback          │
│    ├─ RuleEngine: ordered YAML rules -> matches + grouping keys              │
│    ├─ IncidentManager: PROBLEM upsert, RECOVERY resolution                   │
│    └─ NotificationDispatcher: threshold crossings -> output actions          │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ writes/read state through repositories
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                                Persistence                                   │
│  PostgreSQL                                                                  │
│    ├─ incidents: durable aggregation state                                   │
│    │   └─ UNIQUE (rule_name, group_key) WHERE status = 'OPEN'                │
│    └─ raw_events: optional rotated debugging/audit trail                     │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ async work submission
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                          Async Execution Boundary                            │
│  TaskRunner interface                                                        │
│    ├─ AsyncIOTaskRunner in v1                                                │
│    └─ Celery/Redis runner later, same submit(task_name, payload) contract    │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                               Output Boundary                                │
│  OutputPlugin registry                                                       │
│    └─ email-style output first; future Slack/PagerDuty/Webhook plugins       │
└──────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────┐
│                              Background Loops                                │
│  FastAPI lifespan starts/stops expiration scanner and shared resources       │
│  Expiration scanner: OPEN incidents past rule window -> CLOSED               │
└──────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────┐
│                               Observability                                  │
│  Structured logs, request IDs, processing outcome logs, metrics, traces,      │
│  health/readiness endpoints, plugin error counters, DB conflict/upsert stats │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Boundary Rule |
|-----------|----------------|---------------|
| FastAPI application | Route registration, dependency wiring, lifespan startup/shutdown, OpenAPI surface | No alert business rules in route handlers |
| API routers | Ingress, incident query/mutation, health/readiness, optional config introspection | Convert HTTP concerns into application calls only |
| Input plugin registry | Load configured input plugins and route source-specific payloads | Plugins return `NormalizedEvent`; they do not call the rule engine or database |
| Icinga2 input plugin | Map Icinga2 host/service states to severity and `PROBLEM`/`RECOVERY` | Source-specific parsing stays here |
| Normalized event model | Stable plugin-agnostic event contract: fingerprint, source, host, service, severity, event type, timestamp, tags, message, optional IP | All downstream components depend on this model, not raw payloads |
| Topology enricher | Add/override topology tags from hostname patterns, then IP subnet fallback | Pure transformation: event in, enriched event out |
| Rule loader | Parse and validate YAML rules; sort by priority; expose immutable rule set | Does not process events or touch incidents |
| Rule engine | Match enriched events, compute group keys, produce incident actions | No database writes; returns decisions |
| Incident manager | Atomic open-incident upsert, recovery resolution, acknowledgement/close transitions | Owns incident state transitions and transactions |
| Incident repository | SQLAlchemy Core/ORM access to `incidents` and optional `raw_events` | Contains SQL details, especially `ON CONFLICT` |
| Task runner | Submit named work with serializable payloads | Core code never calls `asyncio.create_task` directly outside the runner |
| Notification dispatcher | Fetch incident, load output plugin, call configured action | Owns output error handling and retry policy boundaries |
| Output plugin registry | Load/cache output plugins from YAML registry | Output plugins receive prepared incident/config; no rule matching |
| Output plugins | Send notifications through one transport | Must be idempotency-aware; no incident mutation except via explicit core APIs |
| Lifecycle expirer | Periodically close stale open incidents based on rule windows | Runs through incident manager/repository, not ad hoc SQL in startup code |
| Observability module | Logging, metrics, tracing integration, request correlation | Cross-cutting but should not change domain results |

## Recommended Project Structure

Use domain-oriented packages rather than one generic `core/` dumping ground. The idea document's initial `app/core`, `app/models`, and `app/plugins` layout is acceptable for phase 1, but roadmap work should converge on explicit boundaries like this:

```
app/
├── main.py                    # FastAPI factory, lifespan, router wiring
├── api/
│   ├── deps.py                # request-scoped DB sessions, auth/hooks later
│   └── routers/
│       ├── ingress.py         # POST /webhooks/{source}; Icinga2 route first
│       ├── incidents.py       # incident list/detail/ack/close APIs
│       └── health.py          # liveness/readiness/version endpoints
├── domain/
│   ├── events.py              # NormalizedEvent, EventType, Severity
│   ├── incidents.py           # IncidentStatus, domain DTOs, transition helpers
│   └── rules.py               # Rule, match criteria, window/action schemas
├── processing/
│   ├── event_processor.py     # orchestrates normalization output through core flow
│   ├── enrichment.py          # TopologyEnricher
│   ├── rule_engine.py         # matching + group key generation
│   ├── incident_manager.py    # upsert, recovery, lifecycle transitions
│   ├── notification_dispatcher.py
│   └── lifecycle.py           # expiration scanner loop + single-pass expiration
├── persistence/
│   ├── database.py            # async engine/session factory
│   ├── models.py              # SQLAlchemy tables/models
│   ├── incidents.py           # incident repository/upsert SQL
│   └── raw_events.py          # optional event audit storage
├── plugins/
│   ├── interfaces.py          # InputPlugin, OutputPlugin, TaskRunner protocols/ABCs
│   ├── loader.py              # importlib loading, validation, cache
│   ├── inputs/
│   │   └── icinga2.py
│   ├── outputs/
│   │   └── email.py
│   └── runners/
│       └── asyncio_runner.py
├── config/
│   ├── settings.py            # pydantic-settings app/env config
│   ├── rules.py               # YAML rule loading facade
│   ├── topology.py            # YAML topology loading facade
│   └── plugins.py             # YAML plugin registry loading facade
└── observability/
    ├── logging.py             # structured logging setup
    ├── metrics.py             # counters/gauges/histograms
    └── tracing.py             # OpenTelemetry FastAPI/DB hooks when enabled
```

### Structure Rationale

- **`domain/`** keeps the normalized model and incident lifecycle vocabulary independent of FastAPI, SQLAlchemy, and plugins.
- **`processing/`** owns orchestration and business behavior. This is where roadmap phases will add value.
- **`persistence/`** isolates SQLAlchemy/PostgreSQL details. The atomic upsert is central enough that it deserves a named repository method, not inline SQL inside the processor.
- **`plugins/`** is edge-only. Inputs and outputs are adapters; the `TaskRunner` is also an adapter because execution strategy is explicitly pluggable.
- **`config/`** keeps YAML parsing and validation out of processors. Processors should receive typed settings/rules/topology objects.
- **`observability/`** is explicit because this service will run unattended and must explain why alerts were grouped, ignored, dispatched, resolved, or expired.

## Data Flow

### Problem Event Flow

```
Icinga2 webhook request
    ↓
FastAPI ingress router
    ↓ validates source route + request body size/auth later
InputPlugin.process_payload(payload)
    ↓ raw source state mapped to NormalizedEvent(PROBLEM)
TopologyEnricher.enrich(event)
    ↓ tags include datacenter/environment/service topology
RuleEngine.evaluate(enriched_event)
    ↓ ordered matches with group_key + threshold/action decisions
IncidentManager.apply_problem(event, matches)
    ↓ single transaction per event or per matched rule batch
PostgreSQL INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING
    ↓ exactly one OPEN incident per rule_name + group_key
Threshold crossing detector
    ↓ only on transition below threshold -> at/above threshold
TaskRunner.submit("notify", payload)
    ↓ v1 asyncio task; future external queue
NotificationDispatcher.process(payload)
    ↓ loads incident + output plugin
OutputPlugin.send_notification(incident, config)
```

### Recovery Event Flow

```
Icinga2 OK/UP webhook
    ↓
InputPlugin.process_payload(payload)
    ↓ NormalizedEvent(RECOVERY)
TopologyEnricher.enrich(event)
    ↓ preserves enough tags/grouping context for resolution logs
EventProcessor branches on event.event_type
    ↓
IncidentManager.resolve_for_event(event)
    ↓ finds OPEN incidents containing host/service/fingerprint context
PostgreSQL transaction updates status OPEN -> RESOLVED
    ↓ optional recovery notification through TaskRunner if rule action says so
API response includes incidents_closed
```

Recovery handling should not re-run normal threshold aggregation as if `OK` were another low-severity problem. `RECOVERY` is a lifecycle command derived from an event, not an alert to aggregate.

### Expiration Flow

```
FastAPI lifespan startup
    ↓
TaskRunner or lifecycle supervisor starts expiration scanner
    ↓ every configured interval
LifecycleExpirer.expire_stale_incidents(now)
    ↓ loads OPEN incidents + rule windows
IncidentManager.expire(incident)
    ↓ status OPEN -> CLOSED when last_update_time + window < now
Structured log + metric for each closure batch
    ↓
FastAPI lifespan shutdown cancels scanner cleanly
```

FastAPI official docs recommend lifespan async context managers for startup/shutdown resource setup and cleanup. Use lifespan for plugin registry initialization, database readiness checks, and lifecycle scanner start/stop. Avoid mixing deprecated `startup`/`shutdown` event handlers with lifespan.

### API Read/Mutation Flow

```
REST client
    ↓
FastAPI router dependency opens AsyncSession
    ↓
Incident API service/repository query
    ↓
PostgreSQL
    ↓
Pydantic response model
```

Manual acknowledgement and closure APIs should go through `IncidentManager` transition methods so API mutations, recovery mutations, and expiration mutations share the same state-transition validation.

## Core Patterns to Follow

### Pattern 1: Ports and Adapters for Plugin Boundaries

**What:** Define small interfaces for input normalization, output dispatch, and task submission. Load concrete implementations from plugin YAML through a registry.

**When:** Required from v1 because input/output/task execution are explicit extension points.

**Trade-offs:** Slight upfront interface cost, but avoids source-specific payloads leaking into aggregation and avoids direct asyncio calls that block the Celery/Redis cutover.

```python
class InputPlugin(Protocol):
    async def process_payload(self, payload: Mapping[str, Any]) -> NormalizedEvent: ...

class OutputPlugin(Protocol):
    async def send_notification(self, incident: IncidentView, config: Mapping[str, Any]) -> None: ...

class TaskRunner(Protocol):
    async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None: ...
```

**Implementation note:** Keep payloads to `TaskRunner.submit()` JSON-serializable from day one. Passing ORM instances to asyncio tasks is convenient but blocks future queueing and can outlive DB sessions.

### Pattern 2: Pipeline Orchestrator with Pure Decisions Before Writes

**What:** Split processing into deterministic stages: enrich, match, group, then mutate state. The rule engine returns decisions; the incident manager applies them.

**When:** Use for all incoming normalized events.

**Trade-offs:** More explicit objects between stages, but much easier to test and reason about. It also prevents YAML rules from becoming hidden database behavior.

```python
async def process(event: NormalizedEvent) -> ProcessingResult:
    enriched = topology.enrich(event)
    if enriched.event_type is EventType.RECOVERY:
        return await incident_manager.resolve_for_event(enriched)

    decisions = rule_engine.evaluate(enriched)
    incidents = await incident_manager.apply_problem(enriched, decisions)
    await dispatcher.submit_threshold_notifications(incidents)
    return ProcessingResult(event=enriched, incidents=incidents)
```

### Pattern 3: Database-Enforced Incident Singularity

**What:** Enforce one open incident per `(rule_name, group_key)` in PostgreSQL with a partial unique index and update through `INSERT ... ON CONFLICT ... DO UPDATE`.

**When:** Every `PROBLEM` event matched to an aggregation rule.

**Trade-offs:** PostgreSQL-specific, but the project already chooses PostgreSQL for authoritative state. This is the right place to enforce the invariant because concurrent alert bursts are the normal case, not an edge case.

```sql
CREATE UNIQUE INDEX incidents_one_open_per_rule_group
    ON incidents (rule_name, group_key)
    WHERE status = 'OPEN';
```

SQLAlchemy's PostgreSQL dialect supports `Insert.on_conflict_do_update()` with `index_elements` and `index_where`, matching PostgreSQL's partial-index conflict target support.

```python
stmt = insert(Incident).values(...)
stmt = stmt.on_conflict_do_update(
    index_elements=[Incident.rule_name, Incident.group_key],
    index_where=(Incident.status == IncidentStatus.OPEN),
    set_={
        "event_count": Incident.event_count + 1,
        "last_update_time": event.timestamp,
        "severity": greatest(Incident.severity, event.severity),
        "affected_hosts": merge_unique_hosts(Incident.affected_hosts, event.host),
    },
).returning(Incident)
```

**Do not** implement open incident aggregation as `SELECT existing -> INSERT or UPDATE`. It will race under concurrent alert storms and violates the project's core value.

### Pattern 4: Typed YAML Configuration at the Edge

**What:** Load YAML into Pydantic v2 models once, validate, sort rules by priority, and pass typed config into processors.

**When:** Rules, topology, and plugin registry.

**Trade-offs:** Operators can edit YAML without Python changes, but invalid YAML must fail fast at startup or explicit reload time. Do not lazily discover invalid rule shape during a live alert.

**Implication:** If runtime reload is added later, treat it as an atomic config snapshot swap. Do not mutate a shared rule list while events are being processed.

### Pattern 5: Lifespan-Owned Background Work

**What:** Start the expiration scanner during FastAPI lifespan and cancel/drain it during shutdown.

**When:** v1 expiration lifecycle.

**Trade-offs:** Simple and dependency-light for v1. In multi-process deployments each process may run a scanner, so expiration updates must be idempotent and database-guarded. If scanner duplication becomes noisy, move expiration to the task runner or a single scheduled worker later.

### Pattern 6: Observability as Domain Events, Not Just HTTP Logs

**What:** Log and measure each processing decision: normalized, enriched, matched rule count, group key, upsert inserted/updated, threshold crossed, notification submitted/sent/failed, recovery resolved count, expiration closed count.

**When:** From the first end-to-end slice. Alert aggregation failures are often semantic, not just exceptions.

**Trade-offs:** More instrumentation points, but faster operations debugging. Keep labels low-cardinality in metrics; put high-cardinality fields such as host and fingerprint in structured logs/traces, not metric labels.

## Incident State Model

### Recommended Status Transitions

```
                acknowledge
OPEN ─────────────────────────► ACKNOWLEDGED
 │                                  │
 │ recovery                         │ recovery/manual close
 ▼                                  ▼
RESOLVED                         RESOLVED
 │                                  │
 │ retention/manual close           │ retention/manual close
 ▼                                  ▼
CLOSED ◄──────────── expiration/manual close
```

Practical v1 rules:

- `OPEN` receives problem-event aggregation updates.
- `ACKNOWLEDGED` means an operator has seen the incident. Decide early whether acknowledged incidents still receive event_count/last_update updates; recommended: yes, but they should not create duplicate open rows. If the partial unique index only covers `OPEN`, acknowledged incidents need a clear rule: either stay outside aggregation or keep status `OPEN` with an `acknowledged_at` field. For v1 simplicity, prefer an `acknowledged_at` field over moving active incidents out of `OPEN`.
- `RESOLVED` is an automatic recovery outcome.
- `CLOSED` is manual close or stale-window expiration.

### Important Design Adjustment

The idea document lists `ACKNOWLEDGED` as a status while also requiring uniqueness only where `status = 'OPEN'`. That combination can create a second `OPEN` row for the same rule/group if an acknowledged but still-active incident is removed from the partial unique set. Roadmap should decide one of these before implementation:

1. **Recommended:** model acknowledgement as metadata (`acknowledged_at`, `acknowledged_by`) while status remains `OPEN` until recovery/expiration/close. This preserves the partial unique invariant.
2. Alternative: include `ACKNOWLEDGED` in the partial unique predicate (`WHERE status IN ('OPEN', 'ACKNOWLEDGED')`). This preserves singular active incidents but makes the index predicate and conflict target more complex.

Do not keep `ACKNOWLEDGED` outside the uniqueness predicate unless acknowledged incidents are intentionally no longer active aggregation targets.

## PostgreSQL Persistence Design

### Tables

| Table | Purpose | Notes |
|-------|---------|-------|
| `incidents` | Authoritative incident lifecycle and aggregation state | Required in v1 |
| `raw_events` | Optional debugging/audit trail of normalized or source payloads | Rotated/bounded; not core product value |
| `notification_attempts` | Recommended once output dispatch exists | Enables idempotency, retries, failure inspection |
| `schema_migrations` | Migration tool state | Alembic or equivalent if selected later |

### Incident Columns

Keep the project-specified columns, but add fields that support correctness and observability:

| Column | Why |
|--------|-----|
| `id` UUID PK | Stable API and task payload identifier |
| `rule_name`, `group_key` | Aggregation identity |
| `status` | Lifecycle state |
| `severity` | Current max/current severity |
| `start_time`, `last_update_time` | Windowing, expiration, APIs |
| `summary` | Rule-rendered operator-facing summary |
| `event_count` | Thresholds and impact |
| `affected_hosts` JSONB | Recovery lookup and API impact display |
| `affected_services` JSONB or structured JSON | Recovery precision for service-level alerts |
| `last_fingerprint` | Debugging and idempotency signals |
| `acknowledged_at`, `acknowledged_by` | Prefer over `ACKNOWLEDGED` active status if possible |
| `resolved_at`, `closed_at` | Lifecycle audit |
| `created_at`, `updated_at` | Operational audit |

### Transaction Boundary

Recommended transaction boundary: one database transaction per incoming event after normalization/enrichment. Within it:

1. Optionally write `raw_events` if enabled.
2. For `PROBLEM`: apply every matched rule upsert and return incident rows.
3. For `RECOVERY`: update matching open incidents to resolved.
4. Commit state changes.
5. After commit, submit notifications to task runner.

Submitting notifications after commit avoids sending notifications for rolled-back incidents. If notification submission fails after commit, record a `notification_attempts` row or emit a durable error signal; do not roll back the incident update.

## REST API Boundaries

### Recommended Routers

| Router | Endpoints | Owns |
|--------|-----------|------|
| `ingress` | `POST /webhooks/icinga2` initially; later `POST /webhooks/{source}` | Source authentication, request parsing, processor call, response summary |
| `incidents` | `GET /incidents`, `GET /incidents/{id}`, `PATCH /incidents/{id}/ack`, `PATCH /incidents/{id}/close` | Incident read/mutation API through manager/repository |
| `health` | `GET /healthz`, `GET /readyz` | Process liveness and DB/config/plugin readiness |
| `config` optional | `GET /rules`, `GET /topology`, `GET /plugins` redacted | Operator introspection without exposing secrets |

FastAPI `APIRouter` should be used to separate route groups, prefixes, tags, and router-level dependencies. Keep request-scoped dependencies in `api/deps.py` so processors remain framework-agnostic.

### API Response Principle

Ingress responses should report processing outcomes, not raw internals:

- normalized fingerprint
- source/host/service/severity/event_type
- matched rule names/count
- incidents inserted/updated/resolved/closed counts
- notifications submitted count
- correlation/request ID

Do not return full raw payloads or plugin secrets.

## Task Runner and Output Dispatch

### Task Runner Boundary

`TaskRunner` should accept a task name and a serializable payload. The task registry maps names to callables in v1. Future Celery/Redis implementation maps names to queue tasks without changing `EventProcessor`.

Recommended task names:

| Task | Payload | Trigger |
|------|---------|---------|
| `notify` | `incident_id`, `plugin`, `rule_name`, `trigger_event_fingerprint` | Threshold crossed or recovery notification |
| `expire_incidents` optional | `now` or empty payload | Scheduled lifecycle worker if moved out of lifespan loop |

### Output Dispatch Boundary

`NotificationDispatcher` should load the incident fresh by ID. This avoids passing stale ORM instances to background tasks and keeps future external workers independent of request-local sessions.

Output plugins should receive:

- immutable incident view/DTO
- plugin-specific config with secrets resolved/redacted appropriately
- correlation ID / notification attempt ID

Output plugins should not receive SQLAlchemy sessions.

## Topology Enrichment Architecture

Use deterministic precedence:

1. Preserve explicit tags from the input plugin unless a topology rule is configured to override them.
2. Apply hostname pattern mappings first.
3. Apply IP subnet mappings as fallback for tags not already set by hostname.
4. Record enrichment provenance in debug logs or optional metadata, not necessarily in the public event model.

`TopologyEnricher` should compile regexes and parse CIDRs at config-load time, not on every event. Per-event work should be linear over already-validated matchers. If topology grows large later, introduce indexed subnet lookup/trie only after measurement.

## Rule Engine Architecture

### Rule Evaluation

Rules should be loaded as typed objects:

```
Rule
  name
  priority
  match criteria
  window(duration_seconds, group_by, trigger_threshold)
  output_summary template
  actions
```

Evaluation output should be explicit:

```
RuleDecision
  rule_name
  group_key
  threshold
  actions
  rendered_summary_context
```

### Matching Semantics

- Sort by priority descending.
- Decide whether rules are multi-match or first-match. Recommended v1: **multi-match with explicit priorities only for evaluation order**, because the idea document includes both datacenter aggregation and single-host deduplication; those can be useful simultaneously. If the roadmap wants first-match semantics, add `stop_processing: true` to rule config instead of making priority imply exclusivity.
- Wildcards and tag matching should be centralized in the rule engine, not duplicated in plugins.
- Group key generation must be stable and escaped/canonicalized, e.g. `datacenter=lon|service=http`, not ad hoc string concatenation that can collide.

## Observability Architecture

### Structured Logs

Log one event-processing summary per ingress request:

| Field | Example |
|-------|---------|
| `correlation_id` | request/task ID |
| `source_id` | `icinga-prod-1` |
| `fingerprint` | normalized fingerprint |
| `host`, `service` | source entity |
| `event_type`, `severity` | lifecycle classification |
| `topology_tags` | low-size tag map |
| `matched_rules` | names/count |
| `incident_ids` | affected incident IDs |
| `notifications_submitted` | count |
| `processing_ms` | latency |
| `error_type` | plugin/config/db/notification |

### Metrics

Recommended low-cardinality metrics:

- `correlia_ingress_events_total{source,event_type,severity}`
- `correlia_rule_matches_total{rule}` if rule cardinality is bounded by config
- `correlia_incident_upserts_total{rule,outcome}` where outcome is inserted/updated
- `correlia_open_incidents{rule}` gauge if rule count is bounded
- `correlia_recoveries_total{outcome}`
- `correlia_expired_incidents_total{rule}`
- `correlia_notifications_total{plugin,outcome}`
- `correlia_processing_duration_seconds`
- `correlia_plugin_errors_total{plugin,type}`

Avoid host, fingerprint, group key, or incident ID as metric labels.

### Tracing

OpenTelemetry FastAPI instrumentation can instrument HTTP requests and supports request/response hooks. If tracing is added, create spans for:

- ingress request
- input normalization
- topology enrichment
- rule evaluation
- incident upsert transaction
- notification dispatch

Sanitize captured headers and exclude health endpoints from tracing noise.

## Build Order and Dependency Implications

### Suggested Build Order

1. **Package skeleton, settings, domain models**
   - Build `NormalizedEvent`, `EventType`, rule/topology/plugin config schemas, incident status vocabulary.
   - Dependency implication: every later component depends on these contracts; changes here are expensive later.

2. **PostgreSQL schema and incident repository**
   - Create `incidents` table and the partial unique index before writing the processor.
   - Implement the atomic upsert repository method early.
   - Dependency implication: rule engine and notification dispatch can be thin if the repository returns inserted/updated incident state correctly.

3. **Input plugin interface and Icinga2 concrete plugin**
   - Prove raw Icinga2 payloads map into normalized `PROBLEM` and `RECOVERY` events.
   - Dependency implication: topology, rules, and incidents should never need Icinga2-specific fields.

4. **Topology enricher**
   - Compile hostname regex and IP subnet configs at startup.
   - Dependency implication: rules can match enriched tags only after this exists.

5. **Rule loader and rule engine**
   - Parse YAML, sort priorities, evaluate match criteria, generate canonical group keys.
   - Dependency implication: incident upsert needs rule name, group key, threshold, and actions from this stage.

6. **Event processor + incident manager for PROBLEM events**
   - Wire enrichment, rule decisions, and PostgreSQL upsert end to end.
   - Dependency implication: this is the first true product slice; output dispatch can wait until threshold transitions are observable.

7. **Task runner abstraction and output plugin dispatch**
   - Add `AsyncIOTaskRunner`, task registry, notification dispatcher, and initial email-style plugin.
   - Dependency implication: task payload shape must be serializable now to preserve future Celery/Redis compatibility.

8. **Recovery handling**
   - Branch on `EventType.RECOVERY`, resolve matching open incidents, include resolution outcome in ingress response.
   - Dependency implication: recovery correctness depends on `affected_hosts`, service/group key design, and active incident uniqueness.

9. **Expiration lifecycle**
   - Add lifespan-started scanner that closes stale open incidents based on rule windows.
   - Dependency implication: rule loader must expose lookup by rule name; incident manager must own close transitions.

10. **REST read/mutation APIs and observability hardening**
    - Add incident list/detail/ack/close, health/readiness, structured logs, metrics, and optional tracing.
    - Dependency implication: manual transitions should reuse incident manager; health checks should verify DB/config/plugin readiness without processing alerts.

### Dependency Graph

```
Domain models
  ├─ Input plugins
  ├─ Topology config/enricher
  ├─ Rule config/engine
  └─ Persistence schemas

Persistence schemas + atomic repository
  └─ IncidentManager
       ├─ EventProcessor
       ├─ Recovery handling
       ├─ Expiration lifecycle
       └─ Incident REST mutations

Plugin registry
  ├─ Input plugin loading -> ingress
  ├─ Output plugin loading -> NotificationDispatcher
  └─ TaskRunner loading -> EventProcessor/Dispatcher

Rule loader
  ├─ RuleEngine
  ├─ IncidentManager summaries/actions
  └─ LifecycleExpirer window lookup

Observability
  └─ wraps API, processor, repository, task runner, plugins
```

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| Local / first users | Single FastAPI app process, PostgreSQL, asyncio runner, one expiration scanner. Focus on correctness and clear logs. |
| Small production | Multiple ASGI workers are acceptable if incident upsert and expiration are idempotent. Add connection pool sizing, notification attempt records, and metrics. |
| High alert volume | Move output dispatch to external queue runner; consider batching raw event writes; tune indexes on `status`, `rule_name`, `group_key`, `last_update_time`; keep incident upsert atomic. |
| Very large topology/rule sets | Precompile matchers; index topology lookups; consider rule partitioning by source/tag. Do not split services before measuring rule evaluation and DB contention. |
| Multi-tenant/federated later | Add tenant/source namespace to incident uniqueness key and APIs before onboarding tenants. Retrofitting tenant isolation after incidents exist is costly. |

### First Bottlenecks to Watch

1. **PostgreSQL write contention on hot incidents.** Alert storms for one group will repeatedly update one row. Mitigate by keeping updates minimal, avoiding large JSON rewrites if they grow, and measuring lock wait time.
2. **Notification fan-out latency.** Keep notifications out of request transaction; move from asyncio to queue runner when output latency affects ingress.
3. **Rule evaluation cost.** Precompile rules/topology; avoid reparsing YAML per request.
4. **Raw event retention growth.** If enabled, rotate or partition raw events; do not let optional audit logs dominate the core incident workload.

## Anti-Patterns to Avoid

### Anti-Pattern 1: Source Payloads Leaking Past Input Plugins

**What people do:** Pass raw Icinga2 JSON into rule matching or incident summaries.

**Why it is wrong:** Future inputs such as Alertmanager would require rewriting core logic. It also makes recovery semantics source-specific.

**Do this instead:** Normalize once to `NormalizedEvent`; downstream components only use normalized fields and tags.

### Anti-Pattern 2: SELECT-Then-INSERT Incident Aggregation

**What people do:** Query for an open incident, then insert if missing.

**Why it is wrong:** Concurrent alert bursts can create duplicate open incidents.

**Do this instead:** Use PostgreSQL partial unique index plus `ON CONFLICT DO UPDATE` with a matching conflict target.

### Anti-Pattern 3: Treating `OK` as a Low-Severity Problem

**What people do:** Feed recovery/OK events through normal problem aggregation.

**Why it is wrong:** It can increment incident counts, trigger irrelevant notifications, and fail to close active incidents.

**Do this instead:** Input plugins classify `EventType.RECOVERY`; the processor branches to recovery lifecycle handling.

### Anti-Pattern 4: In-Memory Incident State

**What people do:** Cache open incidents in worker memory for deduplication.

**Why it is wrong:** Multiple ASGI workers or restarts split state and create duplicates.

**Do this instead:** Keep durable incident state and uniqueness in PostgreSQL. Use caches only for read-through config or plugin instances.

### Anti-Pattern 5: Direct Background Task Calls from Business Logic

**What people do:** Call `asyncio.create_task()` directly in `EventProcessor` or output plugins.

**Why it is wrong:** Future Celery/Redis migration becomes invasive, task payloads may capture request-local resources, and errors become invisible.

**Do this instead:** Submit through `TaskRunner` with task name and serializable payload.

### Anti-Pattern 6: Metrics with Host/Fingerprint Labels

**What people do:** Add host, service, incident ID, or fingerprint as Prometheus/OpenTelemetry metric labels.

**Why it is wrong:** Alerting systems produce high-cardinality values; metrics storage becomes noisy and expensive.

**Do this instead:** Use low-cardinality metric labels and put high-cardinality context in structured logs/traces.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| Icinga2 | HTTP webhook -> `Icinga2InputPlugin` -> `NormalizedEvent` | First concrete input; maps host/service states to severity and event type |
| PostgreSQL | SQLAlchemy async engine + asyncpg; repository methods own SQL | Required for atomic upsert and durable lifecycle state |
| SMTP/email-style output | `OutputPlugin.send_notification()` via task runner | First concrete output; keep plugin config in registry YAML |
| Future Celery/Redis | Replacement `TaskRunner` implementation | Preserve serializable task payloads now |
| Future monitoring sources | New `InputPlugin` implementations | Must not require changing rule engine or incident manager |
| Observability backend | OpenTelemetry/metrics/log collector | Optional transport; instrumentation points should exist early |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| API -> processor | Typed application call | API handles HTTP only |
| Input plugin -> processor | `NormalizedEvent` | No raw payload downstream |
| Processor -> rule engine | Enriched `NormalizedEvent` | Pure decision stage |
| Rule engine -> incident manager | `RuleDecision` list | No SQL in rule engine |
| Incident manager -> repository | Explicit transaction/repository methods | Centralize upsert and state transitions |
| Incident manager -> task runner | Serializable task payloads after commit | Avoid ORM/session leakage |
| Task runner -> dispatcher | Task name + payload | Enables queue backend later |
| Dispatcher -> output plugin | Incident DTO + plugin config | Plugins do not mutate incidents |
| Lifecycle -> incident manager | Close/expire commands | Same transition path as API/manual close |

## Confidence and Research Notes

| Area | Confidence | Basis |
|------|------------|-------|
| FastAPI modular routing/lifespan | HIGH | FastAPI official docs and Context7 docs confirm `APIRouter` structure and lifespan async context manager pattern |
| PostgreSQL atomic upsert/partial index | HIGH | PostgreSQL 18 docs confirm partial unique indexes and `ON CONFLICT` atomic insert/update; SQLAlchemy 2.0 docs confirm `on_conflict_do_update(index_where=...)` |
| Plugin/task architecture | HIGH | Directly required by project context and idea document; ports/adapters is the simplest architecture that satisfies future inputs/outputs/runners |
| Incident lifecycle | MEDIUM-HIGH | Project docs specify statuses and recovery/expiration; acknowledgement status needs the design adjustment noted above |
| Observability | MEDIUM-HIGH | OpenTelemetry FastAPI instrumentation docs confirm HTTP tracing hooks; domain-specific metrics/log recommendations are architectural synthesis |

## Sources

- `.planning/PROJECT.md` — Correlia product intent, constraints, active requirements, and concurrency invariant.
- `idea.md` — Correlia technical design v1.2, normalized event model, PostgreSQL schema, plugin/task abstractions, processing phases, recovery and expiration lifecycle.
- `.claude/gsd-core/templates/research-project/ARCHITECTURE.md` — expected architecture research structure.
- FastAPI official docs: Bigger Applications / `APIRouter` — https://fastapi.tiangolo.com/tutorial/bigger-applications/
- FastAPI official docs: Lifespan Events — https://fastapi.tiangolo.com/advanced/events/
- Context7 FastAPI docs lookup: `/fastapi/fastapi`, topics `APIRouter lifespan dependency injection`.
- SQLAlchemy 2.0 PostgreSQL dialect docs: `INSERT ... ON CONFLICT`, partial index inference with `index_where` — https://docs.sqlalchemy.org/en/20/dialects/postgresql.html#insert-on-conflict-upsert
- Context7 SQLAlchemy docs lookup: `/websites/sqlalchemy_en_20`, topics `PostgreSQL insert on_conflict_do_update index_where asyncpg partial index`.
- PostgreSQL current docs: Partial Indexes — https://www.postgresql.org/docs/current/indexes-partial.html
- PostgreSQL current docs: `INSERT` / `ON CONFLICT` atomic upsert — https://www.postgresql.org/docs/current/sql-insert.html
- OpenTelemetry Python contrib docs: FastAPI instrumentation — https://opentelemetry-python-contrib.readthedocs.io/en/latest/instrumentation/fastapi/fastapi.html

---
*Architecture research for: Correlia API-first alert aggregation backend*
*Researched: 2026-06-08*
