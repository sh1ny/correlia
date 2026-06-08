# Requirements: Vigilo

**Defined:** 2026-06-08
**Core Value:** Operators receive one accurate, topology-aware incident for a related alert storm instead of many disconnected raw alerts.

## v1 Requirements

Requirements for initial release. Each maps to roadmap phases.

### Foundation

- [ ] **FND-01**: Maintainer can install and run Vigilo with Python 3.13, uv-managed dependencies, and a single locked project environment.
- [ ] **FND-02**: Maintainer can configure Vigilo settings without code changes using validated application settings.
- [ ] **FND-03**: Maintainer can evolve the PostgreSQL schema through Alembic migrations.
- [ ] **FND-04**: Operator can check basic service health through a REST health endpoint.

### Domain Contracts

- [ ] **DOM-01**: Input plugins can convert source payloads into a `NormalizedEvent` with fingerprint, source ID, host, optional service, severity, event type, timestamp, tags, message, and optional IP address.
- [ ] **DOM-02**: Vigilo classifies events as `PROBLEM` or `RECOVERY` independently of the source monitoring system.
- [ ] **DOM-03**: Vigilo represents incidents with stable lifecycle states for active, manually acknowledged, source-resolved, and expired/manually closed incidents.
- [ ] **DOM-04**: Vigilo rejects malformed domain/config data with explicit validation errors instead of accepting partial or coerced state.

### Persistence

- [ ] **PRS-01**: Vigilo persists aggregated incidents in PostgreSQL with rule name, group key, lifecycle status, severity, timestamps, summary, event count, and affected hosts.
- [ ] **PRS-02**: Vigilo enforces one active incident per rule and group key at the database layer.
- [ ] **PRS-03**: Vigilo updates active incidents with an atomic PostgreSQL upsert instead of SELECT-then-INSERT logic.
- [ ] **PRS-04**: Maintainer can optionally persist raw/debug event or decision metadata needed to explain incident behavior.

### Icinga2 Ingress

- [ ] **ING-01**: Icinga2 can POST host and service alert payloads to a Vigilo webhook endpoint.
- [ ] **ING-02**: Vigilo validates Icinga2 webhook payloads before processing.
- [ ] **ING-03**: Vigilo maps Icinga2 host and service states into normalized severity and `PROBLEM`/`RECOVERY` event type values.
- [ ] **ING-04**: Vigilo derives stable fingerprints for Icinga2 events so repeated deliveries are replay-tolerant.
- [ ] **ING-05**: Vigilo returns an API response that identifies the accepted event, event type, enrichment tags, matched rules, incident updates, closures, and notification count.

### Topology Enrichment

- [ ] **TOP-01**: Operator can define hostname pattern enrichment rules in YAML.
- [ ] **TOP-02**: Operator can define IP subnet enrichment rules in YAML.
- [ ] **TOP-03**: Vigilo enriches events with topology tags using hostname matches before IP subnet fallback.
- [ ] **TOP-04**: Vigilo preserves or explicitly resolves conflicts between source-provided tags and enrichment-derived tags.
- [ ] **TOP-05**: Operator can see enrichment diagnostics sufficient to explain which topology rule affected an event.

### Rule Engine

- [ ] **RUL-01**: Operator can define aggregation rules in YAML with name, priority, match criteria, window duration, group-by fields, trigger threshold, output summary, and actions.
- [ ] **RUL-02**: Vigilo validates rule YAML strictly, including references to tags, actions, plugins, window values, and summary placeholders.
- [ ] **RUL-03**: Vigilo evaluates rules in deterministic priority order.
- [ ] **RUL-04**: Vigilo matches events by severity, host/service fields, and tag criteria.
- [ ] **RUL-05**: Vigilo generates deterministic, human-readable group keys from configured group-by fields.
- [ ] **RUL-06**: Vigilo calculates threshold/window aggregation decisions in a way that can be inspected during tests and operator debugging.

### Problem Aggregation

- [ ] **AGG-01**: Vigilo processes `PROBLEM` events through enrichment, rule matching, group key generation, and incident state mutation.
- [ ] **AGG-02**: Vigilo creates a new active incident when a matched group has no active incident.
- [ ] **AGG-03**: Vigilo updates the existing active incident when a matched group already has one.
- [ ] **AGG-04**: Vigilo maintains incident severity, last update time, event count, summary, and affected hosts as more events arrive.
- [ ] **AGG-05**: Vigilo records enough processing outcome data to distinguish inserted, updated, threshold-crossed, and notification-triggered decisions.

### Task Execution and Notifications

- [ ] **TSK-01**: Maintainer can register named tasks behind a `TaskRunner` interface.
- [ ] **TSK-02**: Vigilo provides an asyncio-backed `TaskRunner` implementation for v1.
- [ ] **TSK-03**: Vigilo submits notification work through `TaskRunner` only after durable incident state transitions.
- [ ] **NOT-01**: Operator can configure output plugins in a YAML plugin registry.
- [ ] **NOT-02**: Vigilo can load, cache, and list configured output plugins.
- [ ] **NOT-03**: Vigilo dispatches incident notifications to an email-style output plugin when configured thresholds are crossed.
- [ ] **NOT-04**: Vigilo records or exposes notification failures, missing plugins, missing incidents, and plugin exceptions.
- [ ] **NOT-05**: Vigilo avoids repeated notifications for the same durable threshold/status transition.

### Incident Lifecycle

- [ ] **LCY-01**: Vigilo routes `RECOVERY` events to lifecycle resolution instead of problem aggregation.
- [ ] **LCY-02**: Vigilo resolves active incidents containing the recovered host.
- [ ] **LCY-03**: Vigilo resolves only matching service-level incidents when a service recovery event arrives.
- [ ] **LCY-04**: Vigilo appends or records resolution context when incidents move to `RESOLVED`.
- [ ] **LCY-05**: Vigilo expires stale active incidents after the configured rule window when no further events arrive.
- [ ] **LCY-06**: Vigilo starts and stops lifecycle background work through FastAPI lifespan handling.

### Operator REST API

- [ ] **API-01**: Operator can list incidents through REST with pagination and useful filters.
- [ ] **API-02**: Operator can view incident details, including affected hosts, timestamps, current status, summary, and decision context.
- [ ] **API-03**: Operator can acknowledge an active incident without allowing duplicate active incidents for the same rule/group.
- [ ] **API-04**: Operator can manually close an incident through REST.
- [ ] **API-05**: Operator can inspect loaded rules, topology configuration summaries, and plugin registry status through REST without exposing secrets.

### Operability

- [ ] **OPS-01**: Vigilo emits structured logs for ingestion, normalization, enrichment, rule matching, incident upsert, notification dispatch, recovery, expiration, and task failures.
- [ ] **OPS-02**: Vigilo exposes readiness signals for database connectivity, config validity, plugin registry load, and background task health.
- [ ] **OPS-03**: Vigilo exposes low-cardinality metrics for accepted events, rejected events, matched rules, incident inserts/updates/resolutions/expirations, notification attempts/failures, and task failures.
- [ ] **OPS-04**: Maintainer can run automated tests that cover domain models, config validation, Icinga2 mapping, topology enrichment, rule evaluation, PostgreSQL upsert concurrency, notification dispatch, recovery, and expiration.

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Additional Inputs

- **INP-01**: Operator can ingest Prometheus Alertmanager firing/resolved events through a dedicated input plugin.
- **INP-02**: Operator can register additional input plugins without modifying the core event processor.

### Distributed Execution

- **RUN-01**: Maintainer can replace the asyncio runner with a Celery/Redis task runner without changing core processing logic.
- **RUN-02**: Vigilo can retry notification tasks with durable outbox semantics suitable for multi-instance deployments.

### Advanced Operations

- **ADV-01**: Operator can dry-run rule and topology changes against captured/sample events before activating them.
- **ADV-02**: Operator can atomically reload valid YAML config while retaining the last-known-good config on validation failure.
- **ADV-03**: Operator can configure API-managed suppressions, silences, or maintenance windows.
- **ADV-04**: Operator can send notifications through additional output plugins such as Slack, generic webhook, PagerDuty Events API, or Grafana OnCall.
- **ADV-05**: API clients can subscribe to streaming incident/event updates.
- **ADV-06**: Vigilo can assist with root-cause hints after enough deterministic incident history exists.

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Built-in web frontend | Vigilo is API-first; UI can be a separate client after backend behavior is proven. |
| Full on-call scheduling or escalation platform | Vigilo dispatches to output integrations rather than replacing PagerDuty/Grafana OnCall. |
| Celery/Redis runner in v1 | The task runner seam is required, but broker-backed execution waits for measured need. |
| Multiple input plugins at launch | Icinga2 must prove the normalized-event and lifecycle contracts first. |
| Bidirectional Icinga2 acknowledgement/mutation | Requires source-of-truth and permissions decisions outside v1 aggregation scope. |
| ML/AI correlation in v1 | Deterministic, explainable correlation must exist before probabilistic assistance is useful. |
| SQLite incident state | Required PostgreSQL partial indexes/upserts are core to correctness. |
| Unsafe YAML execution or raw plugin code from config | YAML is declarative configuration only; plugins must be trusted Python modules. |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| FND-01 | TBD | Pending |
| FND-02 | TBD | Pending |
| FND-03 | TBD | Pending |
| FND-04 | TBD | Pending |
| DOM-01 | TBD | Pending |
| DOM-02 | TBD | Pending |
| DOM-03 | TBD | Pending |
| DOM-04 | TBD | Pending |
| PRS-01 | TBD | Pending |
| PRS-02 | TBD | Pending |
| PRS-03 | TBD | Pending |
| PRS-04 | TBD | Pending |
| ING-01 | TBD | Pending |
| ING-02 | TBD | Pending |
| ING-03 | TBD | Pending |
| ING-04 | TBD | Pending |
| ING-05 | TBD | Pending |
| TOP-01 | TBD | Pending |
| TOP-02 | TBD | Pending |
| TOP-03 | TBD | Pending |
| TOP-04 | TBD | Pending |
| TOP-05 | TBD | Pending |
| RUL-01 | TBD | Pending |
| RUL-02 | TBD | Pending |
| RUL-03 | TBD | Pending |
| RUL-04 | TBD | Pending |
| RUL-05 | TBD | Pending |
| RUL-06 | TBD | Pending |
| AGG-01 | TBD | Pending |
| AGG-02 | TBD | Pending |
| AGG-03 | TBD | Pending |
| AGG-04 | TBD | Pending |
| AGG-05 | TBD | Pending |
| TSK-01 | TBD | Pending |
| TSK-02 | TBD | Pending |
| TSK-03 | TBD | Pending |
| NOT-01 | TBD | Pending |
| NOT-02 | TBD | Pending |
| NOT-03 | TBD | Pending |
| NOT-04 | TBD | Pending |
| NOT-05 | TBD | Pending |
| LCY-01 | TBD | Pending |
| LCY-02 | TBD | Pending |
| LCY-03 | TBD | Pending |
| LCY-04 | TBD | Pending |
| LCY-05 | TBD | Pending |
| LCY-06 | TBD | Pending |
| API-01 | TBD | Pending |
| API-02 | TBD | Pending |
| API-03 | TBD | Pending |
| API-04 | TBD | Pending |
| API-05 | TBD | Pending |
| OPS-01 | TBD | Pending |
| OPS-02 | TBD | Pending |
| OPS-03 | TBD | Pending |
| OPS-04 | TBD | Pending |

**Coverage:**
- v1 requirements: 56 total
- Mapped to phases: 0
- Unmapped: 56 ⚠️

---
*Requirements defined: 2026-06-08*
*Last updated: 2026-06-08 after initial definition*
