# Requirements: Correlia

**Defined:** 2026-06-08
**Core Value:** Operators receive one accurate, topology-aware incident for a related alert storm instead of many disconnected raw alerts.

## v1 Requirements

Requirements for initial release. Each maps to roadmap phases.

### Foundation

- [x] **FND-01**: Maintainer can install and run Correlia with Python 3.14+, uv-managed dependencies, and a single locked project environment.
- [x] **FND-02**: Maintainer can configure Correlia settings without code changes using validated application settings.
- [x] **FND-03**: Maintainer can evolve the PostgreSQL schema through Alembic migrations.
- [x] **FND-04**: Operator can check basic service health through a REST health endpoint.

### Domain Contracts

- [x] **DOM-01**: Input plugins can convert source payloads into a `NormalizedEvent` with fingerprint, source ID, host, optional service, severity, event type, timestamp, tags, message, and optional IP address.
- [x] **DOM-02**: Correlia classifies events as `PROBLEM` or `RECOVERY` independently of the source monitoring system.
- [x] **DOM-03**: Correlia represents incidents with stable lifecycle states for active, manually acknowledged, source-resolved, and expired/manually closed incidents.
- [x] **DOM-04**: Correlia rejects malformed domain/config data with explicit validation errors instead of accepting partial or coerced state.

### Persistence

- [x] **PRS-01**: Correlia persists aggregated incidents in PostgreSQL with rule name, group key, lifecycle status, severity, timestamps, summary, event count, and affected hosts.
- [x] **PRS-02**: Correlia enforces one active incident per rule and group key at the database layer.
- [x] **PRS-03**: Correlia updates active incidents with an atomic PostgreSQL upsert instead of SELECT-then-INSERT logic.
- [x] **PRS-04**: Maintainer can optionally persist raw/debug event or decision metadata needed to explain incident behavior.

### Icinga2 Ingress

- [x] **ING-01**: Icinga2 can POST host and service alert payloads to a Correlia webhook endpoint.
- [x] **ING-02**: Correlia validates Icinga2 webhook payloads before processing.
- [x] **ING-03**: Correlia maps Icinga2 host and service states into normalized severity and `PROBLEM`/`RECOVERY` event type values.
- [x] **ING-04**: Correlia derives stable fingerprints for Icinga2 events so repeated deliveries are replay-tolerant.
- [x] **ING-05**: Correlia returns an API response that identifies the accepted event, event type, enrichment tags, matched rules, incident updates, closures, and notification count.

### Topology Enrichment

- [x] **TOP-01**: Operator can define hostname pattern enrichment rules in YAML.
- [x] **TOP-02**: Operator can define IP subnet enrichment rules in YAML.
- [x] **TOP-03**: Correlia enriches events with topology tags using hostname matches before IP subnet fallback.
- [x] **TOP-04**: Correlia preserves or explicitly resolves conflicts between source-provided tags and enrichment-derived tags.
- [x] **TOP-05**: Operator can see enrichment diagnostics sufficient to explain which topology rule affected an event.
- [x] **TOP-06**: Maintainer can add new topology enricher implementations behind a topology enrichment plugin interface without changing rule evaluation or incident processing.

### Rule Engine

- [x] **RUL-01**: Operator can define aggregation rules in YAML with name, priority, match criteria, window duration, group-by fields, trigger threshold, output summary, and actions.
- [x] **RUL-02**: Correlia validates rule YAML strictly, including references to tags, actions, plugins, window values, and summary placeholders.
- [x] **RUL-03**: Correlia evaluates rules in deterministic priority order.
- [x] **RUL-04**: Correlia matches events by severity, host/service fields, and tag criteria.
- [x] **RUL-05**: Correlia generates deterministic, human-readable group keys from configured group-by fields.
- [x] **RUL-06**: Correlia calculates threshold/window aggregation decisions in a way that can be inspected during tests and operator debugging.

### Problem Aggregation

- [x] **AGG-01**: Correlia processes `PROBLEM` events through enrichment, rule matching, group key generation, and incident state mutation.
- [x] **AGG-02**: Correlia creates a new active incident when a matched group has no active incident.
- [x] **AGG-03**: Correlia updates the existing active incident when a matched group already has one.
- [x] **AGG-04**: Correlia maintains incident severity, last update time, event count, summary, and affected hosts as more events arrive.
- [x] **AGG-05**: Correlia records enough processing outcome data to distinguish inserted, updated, threshold-crossed, and notification-triggered decisions.

### Task Execution and Notifications

- [x] **TSK-01**: Maintainer can register named tasks behind a `TaskRunner` interface.
- [x] **TSK-02**: Correlia provides an asyncio-backed `TaskRunner` implementation for v1.
- [x] **TSK-03**: Correlia submits notification work through `TaskRunner` only after durable incident state transitions.
- [x] **NOT-01**: Operator can configure output plugins in a YAML plugin registry.
- [x] **NOT-02**: Correlia can load, cache, and list configured output plugins.
- [x] **NOT-03**: Correlia dispatches incident notifications to an email-style output plugin when configured thresholds are crossed.
- [x] **NOT-04**: Correlia records or exposes notification failures, missing plugins, missing incidents, and plugin exceptions.
- [x] **NOT-05**: Correlia avoids repeated notifications for the same durable threshold/status transition.

### Incident Lifecycle

- [x] **LCY-01**: Correlia routes `RECOVERY` events to lifecycle resolution instead of problem aggregation.
- [x] **LCY-02**: Correlia resolves active incidents containing the recovered host.
- [x] **LCY-03**: Correlia resolves only matching service-level incidents when a service recovery event arrives.
- [x] **LCY-04**: Correlia appends or records resolution context when incidents move to `RESOLVED`.
- [x] **LCY-05**: Correlia expires stale active incidents after the configured rule window when no further events arrive.
- [x] **LCY-06**: Correlia starts and stops lifecycle background work through FastAPI lifespan handling.

### Operator REST API

- [ ] **API-01**: Operator can list incidents through REST with pagination and useful filters.
- [ ] **API-02**: Operator can view incident details, including affected hosts, timestamps, current status, summary, and decision context.
- [x] **API-03**: Operator can acknowledge an active incident without allowing duplicate active incidents for the same rule/group.
- [x] **API-04**: Operator can manually close an incident through REST.
- [ ] **API-05**: Operator can inspect loaded rules, topology configuration summaries, and plugin registry status through REST without exposing secrets.

### Operability

- [ ] **OPS-01**: Correlia emits structured logs for ingestion, normalization, enrichment, rule matching, incident upsert, notification dispatch, recovery, expiration, and task failures.
- [x] **OPS-02**: Correlia exposes readiness signals for database connectivity, config validity, plugin registry load, and background task health.
- [ ] **OPS-03**: Correlia exposes low-cardinality metrics for accepted events, rejected events, matched rules, incident inserts/updates/resolutions/expirations, notification attempts/failures, and task failures.
- [x] **OPS-04**: Maintainer can run automated tests that cover domain models, config validation, Icinga2 mapping, topology enrichment, rule evaluation, notification dispatch, recovery, and expiration, with PostgreSQL integration/concurrency paths exercised through Testcontainers for Python instead of SQLite.

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Additional Inputs

- **INP-01**: Operator can ingest Prometheus Alertmanager firing/resolved events through a dedicated input plugin.
- **INP-02**: Operator can register additional input plugins without modifying the core event processor.

### Distributed Execution

- **RUN-01**: Maintainer can replace the asyncio runner with a Celery/Redis task runner without changing core processing logic.
- **RUN-02**: Correlia can retry notification tasks with durable outbox semantics suitable for multi-instance deployments.

### Advanced Operations

- **ADV-01**: Operator can dry-run rule and topology changes against captured/sample events before activating them.
- **ADV-02**: Operator can atomically reload valid YAML config while retaining the last-known-good config on validation failure.
- **ADV-03**: Operator can configure API-managed suppressions, silences, or maintenance windows.
- **ADV-04**: Operator can send notifications through additional output plugins such as Slack, generic webhook, PagerDuty Events API, or Grafana OnCall.
- **ADV-05**: API clients can subscribe to streaming incident/event updates.
- **ADV-06**: Correlia can assist with root-cause hints after enough deterministic incident history exists.
- **ADV-07**: Operator can enable an AI-driven topology enricher plugin after the static YAML topology plugin and plugin boundary are stable.

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Built-in web frontend | Correlia is API-first; UI can be a separate client after backend behavior is proven. |
| Full on-call scheduling or escalation platform | Correlia dispatches to output integrations rather than replacing PagerDuty/Grafana OnCall. |
| Celery/Redis runner in v1 | The task runner seam is required, but broker-backed execution waits for measured need. |
| Multiple input plugins at launch | Icinga2 must prove the normalized-event and lifecycle contracts first. |
| Bidirectional Icinga2 acknowledgement/mutation | Requires source-of-truth and permissions decisions outside v1 aggregation scope. |
| ML/AI incident correlation in v1 | Deterministic, explainable incident correlation must exist before probabilistic assistance is useful. |
| AI-driven topology enrichment in the initial topology phase | The plugin seam belongs in v1, but the AI implementation should wait until the static YAML enricher proves the contract. |
| SQLite incident state | Required PostgreSQL partial indexes/upserts are core to correctness. |
| Unsafe YAML execution or raw plugin code from config | YAML is declarative configuration only; plugins must be trusted Python modules. |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| FND-01 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| FND-02 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| FND-03 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| FND-04 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| DOM-01 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| DOM-02 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| DOM-03 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| DOM-04 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| PRS-01 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| PRS-02 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| PRS-03 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| PRS-04 | Phase 1: Foundations, Contracts, and Database Invariant | Complete |
| ING-01 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| ING-02 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| ING-03 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| ING-04 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| ING-05 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| TOP-01 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| TOP-02 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| TOP-03 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| TOP-04 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| TOP-05 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| TOP-06 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| RUL-01 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| RUL-02 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| RUL-03 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| RUL-04 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| RUL-05 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| RUL-06 | Phase 2: Icinga2 Ingress, Topology, and Rule Decisions | Complete |
| AGG-01 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| AGG-02 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| AGG-03 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| AGG-04 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| AGG-05 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| TSK-01 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| TSK-02 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| TSK-03 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| NOT-01 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| NOT-02 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| NOT-03 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| NOT-04 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| NOT-05 | Phase 3: Problem Aggregation and Notification Dispatch | Complete |
| LCY-01 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |
| LCY-02 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |
| LCY-03 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |
| LCY-04 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |
| LCY-05 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |
| LCY-06 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |
| API-01 | Phase 4: Lifecycle, Operator APIs, and Operability | Pending |
| API-02 | Phase 4: Lifecycle, Operator APIs, and Operability | Pending |
| API-03 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |
| API-04 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |
| API-05 | Phase 4: Lifecycle, Operator APIs, and Operability | Pending |
| OPS-01 | Phase 4: Lifecycle, Operator APIs, and Operability | Pending |
| OPS-02 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |
| OPS-03 | Phase 4: Lifecycle, Operator APIs, and Operability | Pending |
| OPS-04 | Phase 4: Lifecycle, Operator APIs, and Operability | Complete |

**Coverage:**

- v1 requirements: 57 total
- Mapped to phases: 57
- Unmapped: 0 ✓

---
*Requirements defined: 2026-06-08*
*Last updated: 2026-06-08 after roadmap creation*
