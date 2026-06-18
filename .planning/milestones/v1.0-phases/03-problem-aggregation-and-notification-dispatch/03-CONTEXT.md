# Phase 3: Problem Aggregation and Notification Dispatch - Context

**Gathered:** 2026-06-08
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 3 turns accepted `PROBLEM` events into durable topology-aware incidents and dispatches threshold-transition notifications through pluggable task/output boundaries.

In scope: connecting the existing Icinga2 decision processor, topology enrichment, rule decisions, threshold/window facts, and PostgreSQL incident repository into an end-to-end problem aggregation path; persisting bounded aggregation/window state needed for restart-safe threshold decisions; creating/updating the single active incident per `rule_name + group_key`; submitting notification work only after durable state transitions; loading named output plugins from YAML; and proving a v1 Mailpit-backed SMTP email-style output path.

Not in scope: `RECOVERY` lifecycle resolution, stale incident expiration, operator incident REST APIs, built-in frontend, Celery/Redis execution, production escalation policy/reminders, raw payload retention, arbitrary plugin code from YAML, or making Mailu/Postal part of Correlia itself.

</domain>

<decisions>
## Implementation Decisions

### Durable Threshold Transitions
- **D-01:** A rule/group counts as notification-triggering only on the first durable transition from below threshold to crossed for the current open incident. Later events can update the incident but must not repeatedly trigger notification work.
- **D-02:** Notification submission happens after the incident mutation and threshold transition marker are durable. Do not submit notification work before PostgreSQL has accepted the state transition.
- **D-03:** While the same incident remains `OPEN`, there are no repeat notifications. Severity escalation, additional affected hosts, and later events update incident state but do not dispatch another notification in v1.
- **D-04:** The dedupe fact belongs in incident-side durable state: a threshold/notification-triggered marker on incident metadata or incident columns. Do not rely on output plugins to dedupe repeated sends. Do not add a separate durable outbox/attempt log unless research proves the incident-side marker cannot satisfy the requirements.

### TaskRunner and Output Boundary
- **D-05:** v1 uses an async in-process `TaskRunner` implementation. All notification work must be submitted through the `TaskRunner` seam; processors must not call output plugins directly.
- **D-06:** `TaskRunner` is the clean cutover boundary for future Celery/Redis, but Celery/Redis is out of scope for v1. The asyncio runner should be deterministic and testable.
- **D-07:** Output plugins are loaded as a named registry from YAML using trusted plugin definitions. Cache plugins by configured name and expose safe status/listing data. Avoid hardcoding a single default-only output path.
- **D-08:** YAML must not dynamically import arbitrary untrusted code. Plugin registry config is declarative and should map trusted plugin names/classes/options, preserving the project rule that YAML is not executable plugin code.
- **D-09:** Phase 3 should optimize the concrete v1 email-style output around **Mailpit SMTP**. Implement a generic SMTP/email-envelope output plugin that can point at Mailpit for Docker-based dev/test and later point at Mailu or another SMTP relay without changing Correlia's core processing.
- **D-10:** If notification dispatch fails after the incident is durable, keep the incident mutation. Record/report a notification failure; do not roll back incident state.

### Processing Outcome Envelope
- **D-11:** The Phase 3 ingest response should extend the Phase 2 decision envelope with a compact incident result: incident id, inserted/updated effect, current status, threshold-crossed/notification-triggered booleans, notification submitted/failed counts, and bounded safe failure reasons.
- **D-12:** Do not return full incident snapshots on every ingest response. Keep the response inspectable but compact and non-secret.
- **D-13:** Incident `decision_context` should store bounded non-secret processing facts: fingerprint, source id, matched rule name, group key, threshold transition facts, counted event/fingerprint facts, output action names, plugin names/status, config hash, and safe failure category/message.
- **D-14:** Do not store raw source payloads, SMTP transcripts, credentials, full exception traces, or rendered notification bodies in `decision_context`.
- **D-15:** Notification failure details exposed to API clients should be typed safe categories such as `missing_plugin`, `missing_incident`, `plugin_exception`, and `dispatch_failed`, with sanitized messages only.
- **D-16:** Accepted `PROBLEM` events that update an incident but do not trigger notification should return an explicit no-dispatch outcome, not just `notification_count=0`. Reasons should distinguish `below_threshold`, `already_notified`, `replay`, and comparable safe explanations.

### Aggregation State Source
- **D-17:** Threshold/window counting must survive process restarts in v1. Persist bounded window state keyed by `rule_name + group_key` / open incident, including enough fingerprint and event-time facts to evaluate thresholds without raw payload storage.
- **D-18:** Prefer bounded durable window state associated with the open incident over a separate aggregation table unless research shows a table is required for correctness or maintainability.
- **D-19:** Replayed fingerprints already counted in the current open incident/window do not increment `event_count`, do not change affected sets except where genuinely new deterministic content appears, and do not trigger notification.
- **D-20:** `event_count` should represent unique accepted problem fingerprints contributing to the open incident, not raw delivery count.
- **D-21:** Threshold/window state update, incident insert/update, and threshold/notification marker write must be atomic in one PostgreSQL transaction. TaskRunner/output dispatch happens after that durable write boundary.
- **D-22:** Use `NormalizedEvent.timestamp` for window membership. `last_update_time` must not move backward; older/out-of-order events can count only if they are inside the current window and not replayed.

### Claude's Discretion
No selected area was delegated to Claude. Downstream agents should treat the decisions above as locked.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project Scope and Requirements
- `.planning/PROJECT.md` — Product definition, API-first/no-frontend constraint, plugin-boundary decisions, PostgreSQL-owned incident correctness, TaskRunner abstraction, and active Phase 3 requirements.
- `.planning/REQUIREMENTS.md` — Requirement IDs and traceability for Phase 3: AGG-01–AGG-05, TSK-01–TSK-03, NOT-01–NOT-05.
- `.planning/ROADMAP.md` — Phase 3 goal, dependencies, success criteria, and boundary against Phase 4 lifecycle/API/operability work.
- `.planning/STATE.md` — Accumulated decisions and concern that Phase 3 must settle notification durability boundaries for v1.
- `.planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md` — Locked Phase 1 decisions for incident lifecycle, `rule_name + group_key` identity, compact non-secret decision metadata, and PostgreSQL partial unique index/upsert invariants.
- `.planning/phases/02-icinga2-ingress-topology-and-rule-decisions/02-CONTEXT.md` — Locked Phase 2 decisions for HARD-only Icinga2 processing, topology tags/provenance, first-match rule evaluation, group keys, event-time windows, fingerprint replay dedupe, and typed threshold/window decisions.

### Research Grounding
- `.planning/research/ARCHITECTURE.md` — Existing modular-monolith boundaries, plugin/core separation, pipeline shape, and persistence isolation guidance.
- `.planning/research/FEATURES.md` — Alert aggregation, incident correlation, rule/window, and notification feature expectations.
- `.planning/research/PITFALLS.md` — Pitfalls to avoid: duplicate open incidents, recovery-as-alert mistakes, plugin boundary leakage, poor grouping semantics, and metadata/audit blind spots.
- `.planning/research/STACK.md` — Locked stack: Python 3.14+, uv, FastAPI, Pydantic v2 strict validation, SQLAlchemy 2.0, asyncpg, PostgreSQL, Alembic, PyYAML, pytest, Ruff, mypy, Testcontainers.

### Existing Source Contracts
- `app/domain/events.py` — `EventType.PROBLEM` / `RECOVERY`, `Severity`, strict `NormalizedEvent`, timezone validation, tags, fingerprint, and source event time.
- `app/domain/incidents.py` — `IncidentStatus`, acknowledgement-as-metadata, compact non-secret `DecisionContext`, and lifecycle transition helpers.
- `app/domain/rules.py` — `RuleDecision`, `ThresholdDecision`, `NoOpDecision`, `IncidentEffectSummary`, and `IngressDecisionEnvelope` response shape that Phase 3 must extend rather than replace.
- `app/processing/rule_engine.py` — Current first-match rule evaluation, human-readable group key rendering, event-time threshold/window logic, and in-memory `_window_state` that Phase 3 must replace or back with durable bounded state.
- `app/processing/ingress.py` — Existing Icinga2 processing pipeline: input plugin → optional topology enrichment → optional rule engine → decision envelope with incident/closure/notification placeholders.
- `app/config/rules.py` — Strict rule YAML validation, known actions/plugins validation seam, summary variable validation, deterministic rule hash, and existing `create_incident` action convention.
- `app/plugins/interfaces.py` — Current input/topology plugin protocols; Phase 3 should add output/runner seams in the same protocol-oriented style.
- `app/persistence/incidents.py` — `IncidentUpsertInput`, `build_open_incident_upsert`, and `upsert_open_incident`; Phase 3 must preserve atomic PostgreSQL upsert semantics while adding replay/threshold marker behavior.
- `app/persistence/models.py` — Incident columns, JSONB affected hosts/services and decision context, and `incidents_one_open_per_rule_group` partial unique index constants.
- `app/config/settings.py` — Existing `rules_path`, `topology_path`, and `plugins_path` settings slots for config loading.
- `app/api/routers/ingress.py`, `app/main.py`, `app/api/deps.py` — Existing router/dependency/app factory style for wiring the end-to-end processor.

### External Output-Channel References
- `https://mailpit.axllent.org/docs/install/` — Mailpit install docs; default SMTP port `1025`, web UI `8025`, Docker support. Use as v1 Docker dev/test target for email-style output.
- `https://mailpit.axllent.org/docs/api-v1/` — Mailpit REST API docs; useful for integration tests that need to inspect captured messages, send via HTTP, or clean stored messages.
- `https://mailu.io/2024.06/` — Mailu is a full Docker-based mail server with SMTP/submission, IMAP, admin UI, DKIM/SPF/DMARC, anti-spam, and TLS. Treat as external self-hosted mail infrastructure, not a Correlia dependency.
- `https://docs.postalserver.io/developer/api/` — Postal JSON HTTP API reference; keep as future reference for a programmable production mail-delivery output plugin, not Phase 3's concrete v1 target.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Icinga2DecisionProcessor` in `app/processing/ingress.py` already owns the normalized event pipeline and returns the decision envelope with incident/closure/notification placeholders; Phase 3 should replace placeholders with real aggregation/dispatch results.
- `RuleEngine` in `app/processing/rule_engine.py` already produces `RuleDecision` and `ThresholdDecision` from enriched `NormalizedEvent` objects; Phase 3 should preserve this contract while moving restart-sensitive counting facts into durable bounded state.
- `IncidentUpsertInput` and `upsert_open_incident` in `app/persistence/incidents.py` already provide the atomic open-incident mutation seam and max-severity/JSONB set merge behavior.
- `DecisionContext` in `app/domain/incidents.py` is the established compact debug envelope; extend or populate it with Phase 3 processing facts rather than introducing raw payload retention.
- `load_rules_config` in `app/config/rules.py` already validates known actions/plugins and computes a config hash; output registry planning should use this seam so rule actions reference configured plugins safely.

### Established Patterns
- Strict Pydantic v2 models at boundaries; malformed config/domain data fails explicitly.
- PostgreSQL owns incident correctness. Do not implement SELECT-then-INSERT or rely on process-local locks for active incident uniqueness.
- JSONB debug/context data is bounded and deterministic; no secrets, raw source payloads, SMTP transcripts, or arbitrary plugin blobs.
- Plugin boundaries are protocol-oriented and pure where possible. Input/topology/rule processing should not leak source-specific or output-specific implementation details into core incident state.
- Existing tests use behavior-focused assertions and Testcontainers for PostgreSQL-specific behavior; Phase 3 should use Testcontainers for transaction/upsert/replay/concurrency paths and can use Mailpit-style SMTP capture for output integration where practical.

### Integration Points
- Add an aggregation/processing layer between `RuleDecision` and `upsert_open_incident` that handles durable bounded window state, replay dedupe, threshold transition marker, incident effect summary, and decision context population.
- Add output plugin and `TaskRunner` protocols under `app/plugins/` or `app/processing/` following the existing `InputPlugin`/`TopologyEnricher` seam style.
- Wire named output plugins through `plugins_path` and rule action plugin names; keep YAML declarative and trusted.
- Extend `IngressDecisionEnvelope`/router response shape without breaking Phase 2 fields: `matched_rules`, `group_key`, `threshold_decision`, `incident_effects`, `closure_count`, and `notification_count` remain understandable.
- Use Mailpit SMTP as the concrete v1 target for email-style output tests/development; do not require Mailu or Postal to run Correlia.

</code_context>

<specifics>
## Specific Ideas

- The concrete v1 email target is Mailpit SMTP because it is Docker-friendly, open-source, and inspectable through UI/API. Mailu is useful production SMTP infrastructure, and Postal is useful future programmable-delivery research, but neither should become a Correlia dependency in this phase.
- Notification dispatch is transition-driven, not event-driven: first durable threshold crossing only, no repeat sends while the incident remains `OPEN`.
- Durable bounded window state should be enough to survive restarts and dedupe replayed fingerprints without storing raw source events.
- Responses should say why no notification was sent (`below_threshold`, `already_notified`, `replay`, etc.) so operators can debug rule/window behavior without reading logs.

</specifics>

<deferred>
## Deferred Ideas

- Postal HTTP API output plugin — future production-oriented programmable mail output, after the SMTP/Mailpit seam proves the output boundary.
- Mailu deployment guidance — useful external infrastructure docs, but not part of Correlia's v1 implementation.
- Celery/Redis runner — future replacement behind `TaskRunner`; v1 remains asyncio.
- Periodic reminders/escalation policy — belongs outside Phase 3's one-transition notification dispatch.

</deferred>

---

*Phase: 3-Problem Aggregation and Notification Dispatch*
*Context gathered: 2026-06-08*
