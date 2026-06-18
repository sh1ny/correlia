# Phase 4: Lifecycle, Operator APIs, and Operability - Context

**Gathered:** 2026-06-09
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 4 completes Correlia's v1 operational surface. Recovery events and stale-window expiration must move incidents out of `OPEN`; operators must be able to inspect and mutate incidents through trusted internal REST APIs; and maintainers must get readiness, metrics, structured logs, and safe config/status inspection without a built-in frontend.

In scope: routing `RECOVERY` events to lifecycle handling instead of problem aggregation; object-level recovery against existing affected host/service sets; stale incident expiration from FastAPI lifespan-managed background work; cursor-paginated incident list/detail APIs; idempotent acknowledgement and manual close APIs; `/v1` route namespace cutover; safe rules/topology/plugin status APIs; readiness checks for database/config/plugins/lifecycle worker health; Prometheus metrics; JSON event logs; and verification for recovery/expiration/operator API/operability behavior.

Not in scope: built-in web frontend, public internet exposure/auth hardening, bidirectional Icinga2 acknowledgement/mutation, reminder/escalation notification policy, Celery/Redis scheduling, durable outbox semantics, additional input plugins, additional output transports, raw payload retention, or AI-driven correlation/enrichment.

</domain>

<decisions>
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

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project Scope and Requirements
- `.planning/PROJECT.md` — Product definition, API-first/no-frontend constraint, active Phase 4 requirements, plugin-boundary decisions, PostgreSQL-owned incident correctness, and v1 out-of-scope boundaries.
- `.planning/REQUIREMENTS.md` — Requirement IDs and traceability for Phase 4: LCY-01–LCY-06, API-01–API-05, OPS-01–OPS-04.
- `.planning/ROADMAP.md` — Phase 4 goal, dependencies, success criteria, and boundary against already-completed Phase 3 aggregation/dispatch.
- `.planning/STATE.md` — Accumulated decisions and Phase 4 concern that recovery matching behavior and operator API exposure/auth assumptions must be settled.
- `.planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md` — Locked decisions for lifecycle statuses, acknowledgement-as-metadata, incident identity, compact decision metadata, and PostgreSQL partial unique index/upsert invariants.
- `.planning/phases/02-icinga2-ingress-topology-and-rule-decisions/02-CONTEXT.md` — Locked decisions for Icinga2 `RECOVERY` mapping, HARD-only processing, topology tags/provenance, first-match rules, human-readable group keys, event-time windows, and replay dedupe.
- `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` — Locked decisions for durable problem aggregation, bounded window state, first-threshold notification submission, TaskRunner/output boundaries, compact response/context envelopes, and safe plugin listing.

### Existing Source Contracts
- `app/domain/events.py` — `EventType.PROBLEM` / `RECOVERY`, `Severity.OK`, strict `NormalizedEvent`, source event timestamps, tags, host/service, and fingerprint fields used by recovery lifecycle handling.
- `app/domain/incidents.py` — `IncidentStatus.OPEN` / `RESOLVED` / `CLOSED`, acknowledgement metadata, `DecisionContext`, `IncidentWindowState`, and `validate_incident_transition` helper to extend for lifecycle invariants.
- `app/domain/rules.py` — `IngressDecisionEnvelope`, `IncidentEffectSummary`, `NotificationResult`, and response fields (`closure_count`, incident/notification data) that Phase 4 should extend without replacing the envelope style.
- `app/persistence/models.py` — `Incident` table columns for affected hosts/services, decision context, window state, threshold marker, acknowledged/resolved/closed timestamps, and the `incidents_one_open_per_rule_group` partial unique index.
- `app/persistence/incidents.py` — Current atomic problem aggregation repository, durable window state, notification result recording, and PostgreSQL transaction patterns that lifecycle repository functions must preserve.
- `app/processing/ingress.py` — Current Icinga2 pipeline; `RECOVERY` events currently evaluate to no-op and `closure_count=0`, which Phase 4 must replace with lifecycle handling.
- `app/processing/rule_engine.py` — Current rule engine bypasses `RECOVERY` events with a no-op; lifecycle handling should not accidentally send recoveries through problem aggregation.
- `app/processing/incident_manager.py` — Problem-only aggregation manager and notification submission boundary; useful pattern for adding a separate lifecycle manager without mixing problem and recovery code paths.
- `app/main.py` — FastAPI lifespan currently wires settings, DB sessionmaker, plugin registry, task runner, notification dispatcher, and Icinga2 processor; Phase 4 should add lifecycle background worker startup/shutdown here.
- `app/api/routers/health.py` — Existing `/health` and `/readyz` pattern; Phase 4 should migrate under `/v1` and broaden readiness checks safely.
- `app/api/routers/plugins.py` — Existing safe plugin listing route; Phase 4 should migrate under `/v1` and align config/status summaries with its non-secret pattern.
- `app/api/routers/ingress.py`, `app/api/deps.py` — Existing router/dependency style for adding `/v1/icinga2/events`, incident APIs, config/status APIs, and metrics endpoints.

### Research Grounding
- `.planning/research/ARCHITECTURE.md` — Modular-monolith boundaries, plugin/core separation, pipeline shape, persistence isolation, and API/router guidance from project research.
- `.planning/research/FEATURES.md` — Feature expectations for alert aggregation, incident lifecycle, operator APIs, and observability surfaces.
- `.planning/research/PITFALLS.md` — Pitfalls to avoid: recovery-as-alert mistakes, duplicate open incidents, plugin boundary leakage, poor grouping semantics, and metadata/audit blind spots.
- `.planning/research/STACK.md` — Locked stack: Python 3.14+, uv, FastAPI, Pydantic v2 strict validation, SQLAlchemy 2.0, asyncpg, PostgreSQL, Alembic, PyYAML, pytest, Ruff, mypy, and Testcontainers.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `NormalizedEvent` and `EventType.RECOVERY` in `app/domain/events.py` already carry host, optional service, fingerprint, source_id, severity, and timezone-aware timestamp needed for recovery matching.
- `Incident` columns in `app/persistence/models.py` already include `affected_hosts`, `affected_services`, `acknowledged_at`, `acknowledged_by`, `resolved_at`, `closed_at`, and `decision_context`, so Phase 4 can implement lifecycle without a large initial schema rewrite unless research finds missing context fields.
- `validate_incident_transition` in `app/domain/incidents.py` already encodes `OPEN -> RESOLVED/CLOSED` and no reopening; lifecycle APIs should centralize around this rather than scattering status strings.
- `record_problem_incident` and `record_notification_result` in `app/persistence/incidents.py` show the existing repository pattern: row-level locking, compact JSONB context validation, `RETURNING` rows mapped back to `Incident`, and PostgreSQL-specific behavior tested with Testcontainers.
- `Icinga2DecisionProcessor` in `app/processing/ingress.py` is the main integration point for branching `PROBLEM` to aggregation and `RECOVERY` to lifecycle handling.
- `app/main.py` lifespan is the natural place to create and stop the v1 lifecycle expiration worker alongside the existing TaskRunner drain and engine disposal.
- Existing `/plugins` listing and `/readyz` implementation provide safe response patterns for non-secret status surfaces.

### Established Patterns
- Strict Pydantic v2 models validate domain/config/API boundary data; avoid permissive coercion for lifecycle mutation bodies and filters.
- PostgreSQL owns lifecycle correctness. Do not implement lifecycle mutations with SELECT-then-act races that can violate the one-open-incident invariant or lose affected-set updates.
- Decision/debug context remains compact, bounded, typed, and non-secret. No raw Icinga2 payloads, plugin options, SMTP transcripts, credentials, or stack traces in API responses/logs/context.
- Plugin/config summaries expose safe status and names, not implementation internals or secret-bearing options.
- Behavior-focused tests already cover domain contracts, route wiring, Testcontainers-backed PostgreSQL behavior, notification dispatch, and no-secret responses; Phase 4 should extend these patterns for recovery, expiration, incident APIs, metrics, and readiness.

### Integration Points
- Add lifecycle repository functions for object-level recovery, object-set shrinking, `RESOLVED` transition when empty, manual close, acknowledgement metadata, and stale expiration.
- Add a lifecycle manager separate from `IncidentManager.apply_problem` so recovery/expiration/operator mutations do not mix with threshold/notification dispatch.
- Update `Icinga2DecisionProcessor.process_payload` to branch `RECOVERY` events into lifecycle handling and populate closure/lifecycle fields in `IngressDecisionEnvelope`.
- Add incident REST router and migrate existing routers under `/v1` as a clean namespace cutover.
- Add a lifespan-managed expiration worker with readiness-visible health state and clean shutdown behavior.
- Add low-cardinality metrics collection in processing/lifecycle/API paths and expose Prometheus text at `/v1/metrics`.
- Add structured JSON logging at pipeline and lifecycle boundaries using safe IDs/reasons only.

</code_context>

<specifics>
## Specific Ideas

- Recovery matching is based on existing incident affected object membership, not on re-evaluating the current rule/group for the recovery event.
- Multi-object incident recovery should shrink affected sets first; resolution happens only when no affected objects remain.
- Expiration closure is semantically distinct from source recovery: expired incidents become `CLOSED` with reason `expired`, while source recoveries become `RESOLVED` with reason `source_recovery`.
- `/v1` is a clean route namespace cutover for both new and existing endpoints.
- Metrics must stay low-cardinality; do not add labels for host, service, fingerprint, group_key, or incident summary.

</specifics>

<deferred>
## Deferred Ideas

- API-key/session authentication for operator APIs — future phase if Correlia is exposed beyond a trusted internal network/proxy.
- Public internet hardening and user management — outside v1 Phase 4.
- Bidirectional Icinga2 acknowledgement/mutation — explicitly out of scope for v1.
- Reminder/escalation policy and repeated notification behavior — future notification policy work, not Phase 4 lifecycle.
- Celery/Redis scheduling or durable outbox execution — remains deferred behind existing seams.

</deferred>

---

*Phase: 4-Lifecycle, Operator APIs, and Operability*
*Context gathered: 2026-06-09*
