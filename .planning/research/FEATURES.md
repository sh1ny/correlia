# Feature Research: Vigilo

**Domain:** Alert aggregation, event correlation, and incident management backend
**Researched:** 2026-06-08
**Confidence:** HIGH for core alert-management patterns; MEDIUM for Vigilo-specific prioritization before user validation

## Feature Landscape

Vigilo should not try to become another full monitoring suite or on-call platform. The useful product boundary is: accept noisy monitoring events, normalize them, enrich them with topology, turn related events into one durable incident, and expose enough API surface for operators and automation to act. Icinga2 is the first source, but the processing model should look more like a small, topology-aware Alertmanager/PagerDuty Event Orchestration core than an Icinga-only adapter.

### Table Stakes (Users Expect These)

Features users assume exist in an alert aggregation / incident backend. Missing these makes the product feel incomplete or unsafe for production.

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Icinga2 webhook ingress | Vigilo starts by ingesting Icinga2 host/service state changes, including Problem and Recovery notifications. | MEDIUM | FastAPI endpoint; Icinga2 input plugin; auth/token config; payload validation; source registry | Icinga2 notification objects support Problem/Recovery type filters and host/service state filters. Treat webhook delivery as a NotificationCommand/script integration, not as a claim that Icinga2 has a first-class generic webhook object. |
| Icinga2 state-to-event mapping | Incident lifecycle depends on distinguishing active problems from recoveries. | LOW | Icinga2 ingress; `NormalizedEvent.event_type`; severity enum | Map host UP/service OK to `RECOVERY`; host DOWN and service WARNING/CRITICAL/UNKNOWN to `PROBLEM`. Preserve host vs service identity. |
| Normalized event model | Aggregation cannot be plugin-ready if rules depend on source payload shapes. | MEDIUM | Input plugins; Pydantic validation; timestamp handling; fingerprinting | Required fields: `fingerprint`, `source_id`, `host`, optional `service`, `severity`, `event_type`, `timestamp`, `tags`, `message`, optional `ip_address`. Unknown source fields should not leak into rule logic except through explicit tags/details. |
| Idempotency and replay tolerance | Alert systems resend, retry, or recover after crashes; duplicate deliveries must not create duplicate incidents. | HIGH | Stable fingerprint; source timestamp; PostgreSQL constraints; raw/debug event trace | Prometheus Alertmanager expects clients to resend firing alerts and resolved alerts for a period after resolution; Vigilo should assume at-least-once delivery from every input. |
| Topology enrichment | The core value is topology-aware aggregation, not raw alert forwarding. | MEDIUM | Normalized host/ip; `topology.yaml`; regex and CIDR matching; deterministic precedence | Hostname pattern tags should win over IP subnet fallback. Preserve explicit source tags unless topology rules intentionally override them. Track unmapped hosts/IPs for operators. |
| YAML rule loading and validation | Operators expect correlation behavior to be configurable without code deploys. | MEDIUM | Rule schema; config loader; startup validation; clear error reporting | Rules need name, priority, match criteria, grouping window, `group_by`, threshold, output summary, and actions. Invalid rules should fail startup or reload atomically, not partially apply. |
| Priority-ordered rule evaluation | Overlapping rules are normal; deterministic order avoids surprise incidents. | MEDIUM | Rule loader; normalized/enriched events; match engine | PagerDuty orchestration and Grafana OnCall routes both use ordered matching semantics. Vigilo should make first-match vs multi-match explicit per rule engine policy; v1 should prefer simple priority ordering. |
| Group key generation | Aggregation quality depends on grouping by the right dimensions. | MEDIUM | Rule `group_by`; enriched tags; host/service fields; stable canonicalization | Keys must be deterministic and visible through the API, e.g. `datacenter=lon|service=http`. Avoid opaque hashes as the only operator-facing grouping value. |
| Threshold/window aggregation | Users expect alert storms to become one actionable incident after a configured signal threshold. | HIGH | Rule evaluation; event counters; incident state; time windows | Alertmanager groups related alerts; PagerDuty supports event-frequency conditions. Vigilo's threshold should count unique affected objects where appropriate, not only raw duplicate events. |
| PostgreSQL-backed open incident state | In-memory aggregation loses correctness across restarts and multiple workers. | HIGH | SQLAlchemy/asyncpg; incident schema; partial unique index; transaction boundaries | One open incident per `(rule_name, group_key)` must be enforced by PostgreSQL, not by application memory. |
| Atomic open-incident upsert | Concurrent bursts are the core workload; race-created duplicate incidents destroy trust. | HIGH | Partial unique index on `(rule_name, group_key) WHERE status = 'OPEN'`; PostgreSQL `ON CONFLICT`; affected-host merge logic | Explicit anti-pattern: SELECT-then-INSERT. Upsert must update severity, last update time, event count, affected hosts, and summary atomically enough for burst conditions. |
| Incident lifecycle states | Operators expect incidents to move through active, acknowledged, resolved, and closed states. | HIGH | Incident table; event_type handling; operator APIs; expiration task | Required states: `OPEN`, `ACKNOWLEDGED`, `RESOLVED`, `CLOSED`. Keep `RESOLVED` for source recovery and `CLOSED` for manual/expiration outcomes so audits explain why the incident ended. |
| Recovery handling | OK/resolved source events should close matching open incidents without human cleanup. | HIGH | Event type mapping; affected-host/service lookup; group key logic; lifecycle transitions | Host-level recovery can resolve host-containing incidents; service-level recovery should narrow to the service when the group key or affected event detail includes service. Recovery notifications are useful but can be v1.x if problem notification works first. |
| Expiration lifecycle | Some sources never send recovery; stale incidents must not stay open forever. | MEDIUM | Rule window duration; background task runner; database session; lifecycle metrics | Alertmanager has `resolve_timeout` semantics when `endsAt` is absent. Vigilo should close stale open incidents after rule-specific inactivity and record that it expired. |
| Notification dispatch through output plugins | Aggregation is only useful if threshold crossings reach operators. | HIGH | TaskRunner; output plugin registry; incident fetch; delivery error handling | v1 should ship one concrete email-style output plugin, but the interface must support Slack/PagerDuty/Opsgenie/webhook later without changing the processor. |
| Notification dedup and delivery records | Operators need to know whether Vigilo sent a page and avoid repeat storms. | MEDIUM | Incident state; dispatcher; delivery log/outbox table or incident notification metadata | Alertmanager has group/repeat intervals; Icinga notifications have notification intervals. Vigilo should at least record notification attempts and avoid resending the same threshold crossing repeatedly. |
| API-first operator workflows | The project has no built-in frontend; REST APIs are the product. | MEDIUM | Incident repository; auth; OpenAPI; pagination/filtering | Minimum APIs: ingest response, list incidents, get incident detail, acknowledge, close, list configured rules/topology summary, health/readiness. Include filters by status, severity, rule, group key, tag, host, and time range. |
| Audit/debug traceability | When aggregation is wrong, operators need to know which event, rule, and group key caused it. | MEDIUM | Optional raw events; processing result; structured logs; incident event samples | Raw event retention can be short/rotated, but every incident should expose enough sampled event context to explain the aggregation. |
| Basic suppression/maintenance awareness | Alerting products commonly provide silences, inhibition, downtimes, or muted routes. | HIGH for full feature; MEDIUM for v1-compatible subset | Rule actions; Icinga2 downtime/ack fields if present; future operator API | Do not build a full Alertmanager silence UI in v1. Do provide a way for rules to drop/suppress notifications and preserve source flags that indicate handled/downtime/acknowledged states if available. |
| Observability and operations endpoints | An alert aggregator becomes critical infrastructure; it must be monitorable itself. | MEDIUM | Logging; metrics; `/healthz`; `/readyz`; config status; DB checks | Follow the Alertmanager pattern of health/readiness endpoints. Metrics should cover accepted/rejected events, per-source failures, rule matches, incident upserts, notification attempts/failures, expiration count, queue/task failures, and config reload status. |
| Configuration reload or restart-safe validation | Operators will tune rules frequently and need safe failure behavior. | MEDIUM | YAML parser; schema validation; atomic config snapshot; readiness status | Alertmanager reloads config and rejects malformed changes. Vigilo can start with restart-only config, but roadmap should include atomic reload before broad production use. |
| Backpressure and input limits | Alert storms are the expected failure mode; unbounded ingestion can take Vigilo down. | MEDIUM | Request body limits; validation errors; DB pool sizing; task runner limits; metrics | Return explicit 4xx for malformed payloads and 503/429-style failures only when the system cannot safely accept work. Do not silently drop accepted events. |

### Differentiators (Competitive Advantage)

Features that are not all required for the first launch, but strongly align with Vigilo's core value.

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| Topology-aware incident summaries | Turns “500 service alerts” into “London datacenter outage affecting 134 hosts,” which is the product promise. | HIGH | Topology enrichment; affected host/service tracking; summary templates; group keys | Alertmanager groups by labels; Vigilo can differentiate by deriving missing topology from hostnames/subnets for Icinga-heavy environments. |
| Explainable correlation trace | Operators trust aggregation only when they can inspect why an event matched a rule and joined an incident. | MEDIUM | Rule evaluator instrumentation; incident detail API; sampled raw events | Add fields like matched rule, priority, group key components, threshold counter, previous incident status, notification decision. |
| Rule dry-run/simulation API | Lets teams tune YAML safely using captured/sample events before production rollout. | MEDIUM | Rule engine; config parser; raw event samples; API auth | Defer until core processing works, then make this the first operator-experience differentiator. |
| Topology coverage reporting | Surfaces unmapped hosts/subnets and prevents silent “everything grouped as unknown” failures. | LOW-MEDIUM | Enricher metrics; event history; topology config summary API | Useful because topology is both the differentiator and a common misconfiguration point. |
| Plugin-ready inputs without v1 plugin sprawl | Future Prometheus Alertmanager, Zabbix, Sensu, or custom webhooks can reuse the same core model. | MEDIUM | InputPlugin interface; normalized event contract; source registry | Build the seam now, but only one concrete v1 input: Icinga2. |
| Pluggable task runner with clean Celery cutover | Keeps v1 simple with asyncio while protecting architecture from background-work lock-in. | MEDIUM | TaskRunner interface; serializable task payloads; dispatcher boundaries | Do not leak asyncio task objects into business logic. Submit named tasks with plain payloads. |
| Database-enforced correlation correctness | Correctness under concurrent bursts is more defensible than best-effort in-memory deduplication. | HIGH | PostgreSQL partial unique index; upsert design; transaction tests later | This is a backend reliability differentiator, not a visible feature, but it protects the core outcome. |
| API-native incident automation | External clients can acknowledge, close, inspect, and integrate without depending on Vigilo UI choices. | MEDIUM | Auth; REST schema; pagination; webhooks/output plugins | Good fit for environments that already have internal portals, CLIs, or ChatOps bots. |
| Recovery-aware aggregation across sources | Different systems call recovery `OK`, `resolved`, or `closed`; Vigilo can normalize lifecycle semantics. | MEDIUM-HIGH | EventType model; input plugin mappings; incident resolver | Source-agnostic recovery is essential before adding non-Icinga inputs. |
| Minimal, inspectable YAML over workflow-builder complexity | Ops teams can version-control rules and review changes. | LOW-MEDIUM | YAML schemas; examples; validation errors | PagerDuty orchestration supports nested graphs, but their docs warn overly complex orchestrations become hard to maintain. Vigilo should keep rule semantics deliberately boring. |

### Anti-Features (Commonly Requested, Often Problematic)

Features that sound attractive but would expand Vigilo beyond its useful v1 boundary or undermine correctness.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Built-in web frontend | Operators want a UI for incidents and acknowledgements. | Project explicitly chooses API-first. A frontend would delay backend correctness and duplicate tools teams already use. | Ship complete REST APIs and OpenAPI docs; allow separate UI/CLI/ChatOps clients. |
| Replacing Icinga2 monitoring/check execution | “If Vigilo handles incidents, let it run checks too.” | Turns an aggregator into a monitoring system and duplicates Icinga2 host/service concepts, retries, hard/soft states, downtimes, and dependencies. | Consume Icinga2 events; do not schedule checks. |
| Full on-call scheduling/escalation platform | Users compare incident tools to PagerDuty/Grafana OnCall. | Scheduling, rotations, notification preferences, SMS/mobile delivery, and escalations are large products. | Dispatch to email/webhook/PagerDuty/Grafana OnCall/Opsgenie plugins. Keep Vigilo focused on correlation and state. |
| Full Alertmanager-compatible silence/inhibition engine in v1 | Silences and inhibition are familiar. | Requires matcher APIs, expiry management, UI/workflows, audits, and tricky interactions with recovery/expiration. | Start with rule-level suppression and source maintenance flags; add API-managed silences only after core incident lifecycle is validated. |
| AI/ML correlation as initial differentiator | “AI can find root cause automatically.” | Needs historical labeled incidents and introduces opaque behavior before deterministic grouping is trusted. | Build deterministic topology/rule correlation first; use explainable traces and coverage metrics. |
| Arbitrary Python code inside YAML rules | Power users want unlimited matching logic. | Unsafe, untestable, hard to reload, and impossible to validate for operators. | Provide a constrained matcher schema with explicit operators and priority. Add named safe functions only when justified. |
| SELECT-then-INSERT incident creation | Easier to implement than PostgreSQL upsert. | Fails under concurrent alert bursts and creates duplicate open incidents. | Use partial unique index plus atomic `ON CONFLICT` upsert. |
| In-memory incident state as source of truth | Lower latency and simpler local prototype. | Loses state on restart, fails with multiple workers, and cannot support API-first incident history. | Keep durable state in PostgreSQL; cache only derived/read data if needed later. |
| Raw event data lake / long-term retention product | Audit and analytics requests often expand. | Storage growth and query requirements distract from aggregation correctness. | Keep optional/rotated raw events for debugging and incident explanation; export to external log/warehouse systems if needed. |
| Multi-input plugin launch | A plugin architecture sounds incomplete with one plugin. | Generalizing before one source works creates wrong abstractions. | Build the plugin contract, ship Icinga2 first, add Alertmanager only after normalized model and lifecycle are proven. |
| Bi-directional Icinga2 mutation as a v1 core feature | Operators may want Vigilo acks/closes to write back to Icinga2. | Requires Icinga API permissions, conflict policy, and source-of-truth decisions for downtime/ack state. | Keep Vigilo incident state independent in v1; consider explicit opt-in output/action plugins later. |
| Real-time dashboard streaming | Feels modern and useful during outages. | Without a built-in frontend, SSE/WebSocket streams add operational complexity before core REST workflows are validated. | Provide pollable APIs, pagination, filters, and metrics. Add streaming only for a concrete client need. |
| Complex nested workflow graph builder | Competes with PagerDuty Event Orchestration. | Hard to maintain and not reviewable in Git; PagerDuty docs explicitly caution against too-complex orchestrations. | Use linear priority rules and simple actions. If nesting is needed later, prefer composable named rule sets. |

## Feature Dependencies

```text
Icinga2 webhook ingress
    └──requires──> Icinga2 state-to-event mapping
                       └──requires──> Normalized event model

Normalized event model
    ├──requires──> stable fingerprint/idempotency fields
    ├──feeds─────> topology enrichment
    ├──feeds─────> rule matching
    └──feeds─────> recovery handling

Topology enrichment
    └──feeds─────> group key generation
                       └──feeds─────> threshold/window aggregation
                                           └──requires──> PostgreSQL incident upsert
                                                              └──requires──> incident lifecycle states

YAML rule loading/validation
    ├──feeds─────> priority-ordered rule evaluation
    ├──feeds─────> group key generation
    ├──feeds─────> notification actions
    └──feeds─────> expiration lifecycle

PostgreSQL incident state
    ├──requires──> partial unique index for open incidents
    ├──feeds─────> API-first operator workflows
    ├──feeds─────> notification dispatch
    └──feeds─────> audit/debug traceability

Notification dispatch
    └──requires──> TaskRunner abstraction
                       └──enables──> asyncio v1 now, Celery/Redis later

Observability
    ├──observes──> ingress validation
    ├──observes──> rule evaluation
    ├──observes──> incident upsert/update
    ├──observes──> notifications
    └──observes──> expiration/recovery

Rule dry-run/simulation API
    └──requires──> stable rule engine + explainable correlation trace

Full API-managed silences
    └──should wait for──> core incident lifecycle + operator auth/audit model
```

### Dependency Notes

- **Ingress before rules:** A real Icinga2 payload mapped into `NormalizedEvent` is the tracer bullet that prevents abstract plugin design.
- **Topology before aggregation:** Vigilo's main value comes from grouping by derived topology. Rule grouping without enrichment degenerates into ordinary host/service deduplication.
- **PostgreSQL before notification:** Notification should fire from durable incident state, not from transient event processor memory. This avoids sending pages for incidents that were not actually persisted.
- **Lifecycle before broad API:** Acknowledge/close APIs need stable state semantics first; otherwise clients automate against wrong transitions.
- **Observability from the first processing slice:** Alert aggregators fail silently when rules do not match or notifications do not dispatch. Metrics/logs are not a polish item here.
- **Silences after core:** Alertmanager-style silences are valuable, but only after rule matching, recovery, expiry, and auth/audit semantics are stable.

## MVP Definition

### Launch With (v1)

Minimum viable product needed to validate Vigilo's core promise.

- [ ] Icinga2 webhook endpoint with validation/auth — proves the first concrete input path.
- [ ] Icinga2 host/service state mapping to `NormalizedEvent` with `PROBLEM`/`RECOVERY` — prevents lifecycle ambiguity.
- [ ] Stable event fingerprint and idempotency behavior — protects against retries and duplicate deliveries.
- [ ] Hostname/IP topology enrichment from YAML — enables topology-aware grouping.
- [ ] YAML rule loader with priority, match criteria, window, threshold, group_by, summary, actions — makes behavior operator-configurable.
- [ ] Rule evaluator and deterministic group key generation — creates explainable aggregation units.
- [ ] PostgreSQL incident table with partial unique index and atomic open-incident upsert — core correctness requirement.
- [ ] Incident lifecycle: `OPEN`, `ACKNOWLEDGED`, `RESOLVED`, `CLOSED` — gives operators usable state.
- [ ] Recovery event handling and stale incident expiration — avoids permanently open incidents.
- [ ] Email-style output plugin through `TaskRunner` — validates pluggable notification dispatch without building a full on-call stack.
- [ ] REST APIs for incident list/detail, acknowledge, close, rules summary, health/readiness — honors API-first scope.
- [ ] Structured logs and basic metrics for ingest, match, upsert, notification, recovery, expiration, and config validity — makes the backend operable.

### Add After Validation (v1.x)

Add once the end-to-end Icinga2 path is correct under realistic alert bursts.

- [ ] Rule dry-run/simulation endpoint — needed when teams begin tuning many rules.
- [ ] Explainable correlation trace in incident detail — makes false grouping debuggable.
- [ ] Config reload with atomic validation — useful after rules/topology change frequently.
- [ ] Delivery records/outbox table — needed when notification reliability becomes audited.
- [ ] Topology coverage report — needed when hostname/IP conventions are incomplete.
- [ ] Recovery notifications — useful but secondary to closing incidents correctly.
- [ ] Basic API-managed suppressions/silences — only after auth/audit and lifecycle semantics are stable.
- [ ] Additional output plugins: generic webhook, Slack, PagerDuty Events API, Grafana OnCall — demand-driven after first output proves the contract.

### Future Consideration (v2+)

Defer until product behavior and operator workflows are validated.

- [ ] Prometheus Alertmanager input plugin — good second input because it validates source-agnostic labels, starts/ends timestamps, and resolved semantics.
- [ ] Celery/Redis task runner — needed when notification throughput or retry durability exceed asyncio's fit.
- [ ] HA deployment guidance — PostgreSQL already owns state, but multi-instance ingestion needs operational patterns and idempotency proof.
- [ ] API-managed maintenance windows and inhibition rules — useful, but large enough to deserve a dedicated phase.
- [ ] Bidirectional source actions, such as writing acknowledgements back to Icinga2 — only with explicit source-of-truth policy.
- [ ] Streaming event/incident API — only for a concrete frontend/ChatOps consumer.
- [ ] ML-assisted grouping recommendations — only after enough deterministic incident history exists.

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Icinga2 webhook ingress | HIGH | MEDIUM | P1 |
| Icinga2 state-to-event mapping | HIGH | LOW | P1 |
| Normalized event model | HIGH | MEDIUM | P1 |
| Idempotency/replay tolerance | HIGH | HIGH | P1 |
| Topology enrichment | HIGH | MEDIUM | P1 |
| YAML rule loading/validation | HIGH | MEDIUM | P1 |
| Priority rule evaluation | HIGH | MEDIUM | P1 |
| Group key generation | HIGH | MEDIUM | P1 |
| Threshold/window aggregation | HIGH | HIGH | P1 |
| PostgreSQL incident state | HIGH | HIGH | P1 |
| Atomic open incident upsert | HIGH | HIGH | P1 |
| Incident lifecycle states | HIGH | HIGH | P1 |
| Recovery handling | HIGH | HIGH | P1 |
| Expiration lifecycle | HIGH | MEDIUM | P1 |
| Output plugin dispatch | HIGH | HIGH | P1 |
| API-first operator workflows | HIGH | MEDIUM | P1 |
| Observability endpoints/metrics/logs | HIGH | MEDIUM | P1 |
| Audit/debug traceability | MEDIUM | MEDIUM | P2 |
| Notification delivery records/outbox | MEDIUM | MEDIUM | P2 |
| Config reload | MEDIUM | MEDIUM | P2 |
| Rule dry-run/simulation | MEDIUM | MEDIUM | P2 |
| Topology coverage reporting | MEDIUM | LOW-MEDIUM | P2 |
| API-managed suppressions/silences | MEDIUM | HIGH | P3 |
| Additional input plugins | MEDIUM | MEDIUM-HIGH | P3 |
| Celery/Redis task runner | MEDIUM | MEDIUM | P3 |
| Bidirectional Icinga2 mutation | LOW-MEDIUM | HIGH | P3 |
| Built-in frontend | LOW for this project | HIGH | Anti-feature |

**Priority key:**

- P1: Must have for launch / core validation
- P2: Should have after the core path works
- P3: Future consideration, only after usage proves demand

## Competitor / Reference Feature Analysis

| Feature Area | Icinga2 | Prometheus Alertmanager | PagerDuty Event Orchestration | Grafana OnCall | Vigilo Approach |
|--------------|---------|-------------------------|-------------------------------|----------------|-----------------|
| Source model | Native hosts/services with UP/DOWN and OK/WARNING/CRITICAL/UNKNOWN states, hard/soft states, notifications, dependencies, downtimes. | Alert labels/annotations with startsAt/endsAt and client resend expectations. | Events transformed toward PagerDuty Common Event Format, with routing and dedup fields. | Integration-specific unique URLs and templates. | Start with Icinga2 host/service payloads, normalize to source-agnostic events, then later add Alertmanager-style input. |
| Grouping / correlation | Dependencies suppress child notifications when parents fail; notifications can be filtered by type/state. | Groups alerts by configured labels and routing tree. | Dedup key merges events; routing/orchestration rules can set incident fields and thresholds. | Grouping ID templates create alert groups. | Group by rule-defined fields after topology enrichment; one durable incident per rule/group key. |
| Suppression / muting | Downtime, acknowledgement, dependencies, flapping controls. | Silences and inhibition. | Suppress/drop/pause incident creation in orchestration rules. | Routes/escalations can resolve automatically, silence alert groups, and choose notification paths. | v1: rule-level suppression and source maintenance awareness. Full API-managed silences later. |
| Notification routing | Notification objects select users/user groups, periods, states, types, intervals, commands. | Receivers and routing tree; group/repeat intervals. | Routes to services/escalation policies; can override priorities and add context. | Routes choose escalation chains and ChatOps channels. | v1: output plugin actions from rules through TaskRunner. Do not build schedules/escalation platform. |
| Incident lifecycle | Source object state plus acknowledgements/downtime/comments. | Firing/resolved alerts based on EndsAt/resolve_timeout; Alertmanager itself is not an incident database. | Trigger/ack/resolve-style event semantics and incident creation. | Alert groups can be acknowledged, resolved, silenced, escalated. | Explicit PostgreSQL incident states: OPEN, ACKNOWLEDGED, RESOLVED, CLOSED. |
| API / automation | Icinga2 REST API supports object queries, actions, event streams, status, config management with auth/permissions. | Alerts API, management API health/readiness/reload, config. | Integration HTTP endpoints and event orchestration APIs. | Integration URLs, routes, escalation APIs/UI. | REST APIs are the product surface: ingestion, incident operations, config visibility, health/readiness. |
| Observability | Logging and status/API features; multiple writer components for metrics/logs. | Health/readiness endpoints and operational metrics/limits. | SaaS operational visibility not directly comparable. | SaaS/OSS app observability not the aggregator's core pattern. | First-class metrics/logs for every stage of event processing and notification dispatch. |
| Differentiation opportunity | Strong source monitoring model, not a topology-aware aggregator backend. | Mature alert grouping/routing, Prometheus-label centric. | Rich SaaS orchestration, not lightweight self-hosted YAML/Postgres backend. | On-call workflow product, not a generic API-first correlation backend. | Lightweight Python API backend with Icinga2-first normalization, topology enrichment, durable incident upsert, and pluggable outputs. |

## Roadmap Implications

Recommended phase ordering from feature dependencies:

1. **Source-to-normalized event tracer bullet** — Icinga2 webhook, validation, state mapping, fingerprinting.
2. **Topology and rules** — enrichment YAML, rule YAML, deterministic match/group behavior.
3. **Durable incident core** — PostgreSQL schema, partial unique index, atomic upsert, incident API reads.
4. **Lifecycle and notification** — recovery, expiration, TaskRunner, output plugin, notification dedup.
5. **Operator APIs and observability** — ack/close, filters, rule/topology status, health/readiness, metrics/logs.
6. **Experience hardening** — dry-run, explainability, config reload, topology coverage, delivery records.
7. **Ecosystem expansion** — more plugins, silences, Celery/Redis, HA docs, bidirectional source actions only if demanded.

Do not start with plugin breadth, silence engines, or frontend work. Those defer the only validation that matters: one Icinga2 alert storm becomes one accurate, topology-aware incident with a durable lifecycle and a delivered notification.

## Sources

- Vigilo project context: `.planning/PROJECT.md` — HIGH confidence, source of product intent.
- Vigilo idea document: `idea.md` — HIGH confidence, source of stack, model, schema, and phase intent.
- Prometheus Alertmanager overview — grouping, inhibition, silences, HA, alert limits: https://prometheus.io/docs/alerting/latest/alertmanager/ — HIGH confidence, official docs fetched 2026-06-08.
- Prometheus Alertmanager configuration — routing tree, grouping, group/repeat intervals, receivers, inhibition, reload behavior: https://prometheus.io/docs/alerting/latest/configuration/ — HIGH confidence, official docs fetched 2026-06-08.
- Prometheus Alertmanager Alerts API — labels/annotations, startsAt/endsAt, resend expectations, resolve timeout: https://prometheus.io/docs/alerting/latest/alerts_api/ — HIGH confidence, official docs fetched 2026-06-08.
- Prometheus Alertmanager Management API — health/readiness/reload endpoints: https://prometheus.io/docs/alerting/latest/management_api/ — HIGH confidence, official docs fetched 2026-06-08.
- Icinga2 monitoring basics — host/service states, state mapping, hard/soft states, custom variables: https://icinga.com/docs/icinga-2/latest/doc/03-monitoring-basics/ — HIGH confidence, official docs fetched 2026-06-08.
- Icinga2 object types — notifications, notification commands, users, state/type filters, service runtime attributes, API listener/logging features: https://icinga.com/docs/icinga-2/latest/doc/09-object-types/ — HIGH confidence, official docs fetched 2026-06-08.
- Icinga2 REST API — HTTPS, auth, permissions, object queries/actions/event streams/status/config management: https://icinga.com/docs/icinga-2/latest/doc/12-icinga2-api/ — HIGH confidence, official docs fetched 2026-06-08.
- PagerDuty Event Orchestration — routing rules, nested rules, event fields, dedup key, suppression/drop actions, threshold conditions, maintainability caution: https://support.pagerduty.com/main/docs/event-orchestration — MEDIUM-HIGH confidence, official support docs fetched 2026-06-08.
- Grafana OnCall integrations — unique integration URLs, grouping ID templates, routes, escalation, ack/resolve behavior: https://grafana.com/docs/oncall/latest/configure/integrations/ — HIGH confidence, official docs fetched 2026-06-08.
- Grafana OnCall escalation chains and routes — first matching route, escalation steps, notification policies, threshold-based escalation: https://grafana.com/docs/oncall/latest/configure/escalation-chains-and-routes/ — HIGH confidence, official docs fetched 2026-06-08.

---
*Feature research for: Vigilo alert aggregation backend*
*Researched: 2026-06-08*
