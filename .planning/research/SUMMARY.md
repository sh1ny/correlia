# Project Research Summary

**Project:** Correlia
**Domain:** Python API-first infrastructure alert aggregation / incident management backend
**Researched:** 2026-06-08
**Confidence:** HIGH

## Executive Summary

Correlia is a modular, API-first alert aggregation backend. It should not become a monitoring system, on-call scheduler, workflow-builder, or frontend product. Experts build this class of system as a deterministic event-correlation pipeline: accept source-specific monitoring events, normalize them into a stable event model, enrich with topology, evaluate simple ordered rules, persist one durable incident per correlation group, and dispatch notifications only from state transitions.

The recommended approach is a lean async Python modular monolith: FastAPI, Pydantic v2, SQLAlchemy 2.0 with asyncpg, PostgreSQL, Alembic, PyYAML plus strict Pydantic config validation, and an explicit `TaskRunner` abstraction backed by asyncio in v1. PostgreSQL must own incident correctness through a partial unique index and atomic `INSERT ... ON CONFLICT DO UPDATE`; plugins translate only at the edges and must never own rule decisions, incident transactions, or lifecycle state.

The main risks are correctness failures under real outage conditions: duplicate open incidents during concurrent bursts, bad grouping that hides the real failure, recovery events that do not close the right incident, topology misclassification, notification storms, and unobservable background task failures. Mitigate these by defining normalized lifecycle semantics up front, enforcing open-incident singularity in the database, making YAML/rule/topology config strict and explainable, recording decision/audit metadata, and adding health/metrics/logs from the first processing slice.

## Key Findings

### Recommended Stack

Use Python 3.13 as the baseline with uv-managed dependencies and a single lockfile. Build a FastAPI async REST service using Pydantic v2 for HTTP schemas, normalized domain models, settings, and strict YAML config validation. Use PostgreSQL as the only v1 incident state backend, accessed through SQLAlchemy 2.0 async engines and asyncpg. Use Alembic from the first schema change so partial indexes, JSONB fields, enum changes, and migration behavior are explicit and reviewable.

PyYAML should be parser-only: `safe_load()` into plain data, then Pydantic v2 models with `extra="forbid"`, strict fields where coercion would hide operator mistakes, cross-reference validation, compiled regex/CIDR objects, and clear error paths. The v1 background execution model should be an explicit `TaskRunner` protocol with an asyncio implementation; Celery/Redis stays out of v1 but remains a clean future replacement because task payloads are serializable and named.

**Core technologies:**
- Python 3.13.x — runtime baseline; modern enough for the project while safer than relying on 3.14 before dependency CI proves compatibility.
- uv 0.11.x — project/dependency manager; single lockfile, Python pinning, and fast tool execution.
- FastAPI 0.136.x + Uvicorn 0.49.x — async REST API and ASGI runtime; fits the no-frontend, OpenAPI-first product surface.
- Pydantic 2.13.x + pydantic-settings 2.14.x — domain/API/config validation; use v2 APIs only.
- PostgreSQL 18.x preferred, 17.x acceptable — authoritative incident state; required for JSONB, partial unique indexes, and atomic upsert.
- SQLAlchemy 2.0.x + asyncpg 0.31.x — async database access with PostgreSQL-specific `on_conflict_do_update(index_where=...)` support.
- Alembic 1.18.x — migrations from day one; hand-author partial indexes and non-trivial PostgreSQL features.
- PyYAML 6.0.x — YAML parsing only; never `yaml.load()` and never raw dicts past the config layer.
- asyncio stdlib behind `TaskRunner` — v1 dispatch/lifecycle execution without broker dependency.
- pytest/pytest-asyncio/httpx/testcontainers/Ruff/mypy — recommended verification/tooling stack for later implementation phases, with PostgreSQL-backed tests for concurrency paths.

**Critical version requirements:**
- Target Python `py313` in tooling.
- Keep Pydantic on v2 APIs (`model_validate`, `model_dump`, `ConfigDict`); do not use v1 compatibility imports.
- Do not substitute SQLite for incident correctness tests or local behavior that depends on PostgreSQL partial indexes/upserts.
- PostgreSQL 18 is preferred; if deployment uses PostgreSQL 17, run migrations/upsert checks against that exact major.

### Expected Features

Correlia's launch scope is one end-to-end Icinga2-to-incident-to-notification path that proves the core promise: one alert storm becomes one accurate, topology-aware incident with a durable lifecycle. Feature breadth must not outrun the first concrete integration. Build seams for future inputs, outputs, and task runners, but ship only Icinga2 input and one email-style output channel in v1.

**Must have (table stakes):**
- Icinga2 webhook ingress with validation/auth — proves the first concrete source path.
- Icinga2 state-to-event mapping — maps host UP/service OK to `RECOVERY`; host DOWN and service WARNING/CRITICAL/UNKNOWN to `PROBLEM`; preserves host/service identity.
- `NormalizedEvent` model — fingerprint, source ID, host, optional service, severity, `event_type`, timestamp, tags, message, optional IP address.
- Idempotency and replay tolerance — assumes at-least-once webhook delivery and source retries.
- Topology enrichment from hostname patterns and IP subnet mappings — hostname precedence over IP fallback; explicit source tags preserved unless override is configured.
- YAML rules with strict validation — name, priority, match criteria, grouping window, `group_by`, threshold, summary template, actions.
- Priority-ordered rule evaluation and deterministic group key generation — visible keys such as `datacenter=lon|service=http`, not opaque-only hashes.
- Threshold/window aggregation — counts meaningful affected objects where appropriate, not blindly raw event count.
- PostgreSQL incident table with one active incident per rule/group — partial unique index plus atomic upsert.
- Incident lifecycle — `OPEN`, acknowledged metadata or equivalent, `RESOLVED`, `CLOSED`; recovery and expiration must be distinct transitions.
- Recovery handling — source OK/resolved events close matching active incidents without entering problem aggregation.
- Expiration lifecycle — stale incidents close when no events arrive within the rule window.
- Output plugin dispatch through `TaskRunner` — notification only from durable threshold/status transitions.
- API-first operator workflows — incident list/detail, acknowledge, close, rules/topology summary, health/readiness.
- Structured logs and basic metrics — ingestion, normalization, enrichment, rule matches, upsert outcomes, notifications, recovery, expiration, task failures, config validity.

**Should have (competitive / v1.x hardening):**
- Explainable correlation trace — matched/skipped rules, group key components, threshold state, notification decision.
- Rule dry-run/simulation API — safe rule tuning with sample/captured events.
- Topology coverage reporting — unmapped hosts/subnets and enrichment misses.
- Atomic config reload with last-known-good behavior — reject malformed YAML without partial application.
- Notification delivery records/outbox — attempts, idempotency keys, retries, failures, suppression reasons.
- Recovery notifications — useful after problem notification correctness is proven.
- Basic API-managed suppressions/silences — only after auth/audit/lifecycle semantics are stable.
- Additional output plugins — generic webhook, Slack, PagerDuty Events API, Grafana OnCall, demand-driven.

**Defer (v2+):**
- Prometheus Alertmanager or other non-Icinga2 input plugins — the plugin seam exists in v1; breadth waits for proven lifecycle semantics.
- Celery/Redis task runner — replace `TaskRunner` when throughput/retry durability justifies it.
- HA deployment guidance beyond database-enforced correctness — multi-instance patterns need measured usage.
- Full API-managed maintenance windows and inhibition engine — large feature with tricky lifecycle interactions.
- Bidirectional Icinga2 acknowledgement/mutation — requires source-of-truth policy and Icinga permissions model.
- Streaming incident/event API — wait for a concrete frontend/ChatOps consumer.
- ML-assisted grouping/root cause — only after deterministic, explainable incident history exists.
- Built-in web frontend — explicit non-goal.
- Full on-call scheduling/escalation platform — dispatch to integrations instead.

### Architecture Approach

Build Correlia as an async Python modular monolith with strict ports/adapters boundaries. The pipeline should be one-way and explicit: HTTP ingress -> input plugin normalization -> topology enrichment -> rule evaluation -> incident manager -> PostgreSQL atomic upsert/lifecycle state -> task runner submission -> output plugin dispatch. Route handlers handle HTTP; plugins translate edges; config loaders produce typed immutable config; the core processor owns normalized semantics; PostgreSQL owns concurrency correctness.

**Major components:**
1. FastAPI application and routers — API wiring, dependency injection, lifespan startup/shutdown, ingress, incidents, health/readiness, optional config introspection.
2. Domain models — `NormalizedEvent`, `EventType`, severity, rule/config schemas, incident status and transition vocabulary.
3. Input plugin registry and Icinga2 plugin — source payload validation and conversion to `NormalizedEvent`; no database or rule access.
4. Config loaders — YAML rules, topology, plugin registry, settings; strict validation and immutable snapshots.
5. Topology enricher — deterministic tag enrichment from trusted source tags, hostname patterns, then IP subnet fallback; provenance/debug metadata.
6. Rule engine — ordered match evaluation, canonical group keys, explicit decisions; no SQL writes.
7. Incident manager and repository — atomic problem upsert, recovery resolution, ack/close/expiration transitions, transaction boundaries.
8. PostgreSQL schema/migrations — incidents, optional raw/debug events, notification attempts when dispatch lands, partial unique index for active/open incidents.
9. Task runner and notification dispatcher — serializable task submission after commit, fresh incident load by ID, output plugin invocation.
10. Output plugin registry and email-style plugin — prepared incident/config in, one transport side effect out.
11. Lifecycle expirer — lifespan-owned idempotent scanner for stale active incidents.
12. Observability module — structured processing logs, low-cardinality metrics, health/readiness, config/plugin/task status.

**Key patterns to follow:**
- Ports and adapters for input plugins, output plugins, and task execution.
- Pure decision stages before writes: enrich and evaluate rules before incident mutation.
- Database-enforced incident singularity with partial unique index and PostgreSQL upsert.
- Typed YAML at the edge; no raw dict configs in processors.
- Lifespan-owned background work; no `asyncio.create_task()` outside the task runner.
- Domain observability: log/measure decisions, not just HTTP 200/500s.
- Acknowledgement design adjustment: prefer `acknowledged_at`/`acknowledged_by` metadata while status remains `OPEN`, or include `ACKNOWLEDGED` in the active unique predicate. Do not let acknowledged-but-active incidents fall outside uniqueness.

**Recommended build order:**
1. Package skeleton, settings, domain models, typed config schemas.
2. PostgreSQL schema, Alembic, incident repository, partial unique index, atomic upsert method.
3. Input plugin interface and concrete Icinga2 normalizer, including PROBLEM/RECOVERY mapping.
4. Topology loader/enricher with compiled hostname regex and CIDR matchers.
5. Rule loader/engine with priority, match criteria, canonical group keys, thresholds, and actions.
6. Event processor and incident manager for PROBLEM events end to end.
7. Task runner, dispatcher, output plugin, and transition-based notification submission.
8. Recovery handling and lifecycle transitions.
9. Expiration scanner through FastAPI lifespan/task runner.
10. REST read/mutation APIs and observability hardening.

### Critical Pitfalls

1. **Duplicate open incidents under concurrent alert bursts** — avoid with PostgreSQL partial unique index on `(rule_name, group_key)` for active/open incidents and one atomic upsert; never SELECT-then-INSERT or in-memory locks.
2. **Noisy or over-broad grouping hides the real failure** — require explicit `group_by`, threshold, and window per rule; use canonical visible group keys; add dry-run/explainability before broad rule rollout.
3. **Recovery treated as just another OK event** — make `event_type: PROBLEM | RECOVERY` mandatory; branch recovery to lifecycle resolution; keep source state mapping inside input plugins.
4. **Topology misclassification corrupts grouping** — enforce precedence, validate overlapping/ambiguous regex/CIDR rules, record enrichment provenance, and expose topology dry-run/coverage tooling.
5. **Plugin boundary leakage makes core Icinga-specific** — core only accepts `NormalizedEvent`; no raw Icinga fields in rules, incidents, or notifications.
6. **Notification storms from repeated threshold evaluation/retries** — notify only on durable transitions; store attempts/idempotency/suppression state before or alongside async dispatch.
7. **Fragile YAML config accepts invalid/dangerous rules** — `safe_load` only, strict Pydantic validation, cross-reference checks, compiled regex/CIDR at load time, startup/reload fail-fast behavior.
8. **Async task failures disappear after ingress returns success** — all background work goes through `TaskRunner`; persist notification intent/attempts; track failures and shutdown behavior.
9. **Missing auditability makes behavior unexplainable** — preserve normalized event/decision/timeline metadata, config version/hash, incident transitions, and notification attempts.
10. **Operational blind spots in the aggregator itself** — health/readiness and metrics must cover DB, config, plugin registry, ingestion, rule engine, upserts, tasks, notifications, recovery, and expiration.

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Foundations, Domain Contracts, and Database Invariant
**Rationale:** Every later component depends on stable event/lifecycle/config contracts and the database uniqueness invariant. Fixing these after processors and APIs exist is expensive and risky.
**Delivers:** Project skeleton, settings, domain models, Pydantic config schemas, Alembic setup, `incidents` schema, partial unique index, atomic upsert repository contract, health skeleton.
**Addresses:** Normalized event model, incident lifecycle vocabulary, PostgreSQL-backed state, idempotency foundation, observability skeleton.
**Avoids:** Duplicate open incidents, plugin leakage, missing auditability, acknowledgement/partial-index mismatch.
**Open questions to settle:** acknowledgement as metadata vs active status; exact active unique predicate; raw/debug event table shape; notification attempt table timing.

### Phase 2: Icinga2 Ingress and Topology Enrichment Tracer Bullet
**Rationale:** One real source payload should drive the abstractions before generalized plugin work expands. Topology must exist before meaningful group keys and rules.
**Delivers:** `InputPlugin` interface, Icinga2 plugin, webhook route, source auth/token hook, host/service PROBLEM/RECOVERY mapping, fingerprinting, topology YAML loader/enricher, enrichment diagnostics.
**Addresses:** Icinga2 webhook ingress, state-to-event mapping, topology enrichment, stable source identity, replay tolerance.
**Avoids:** Treating OK as low-severity problem, source payload leakage, topology misclassification.
**Open questions to settle:** whether v1 ignores SOFT states by default or tags them without paging; exact precedence for source tags vs topology overrides; minimal webhook auth before public deployment.

### Phase 3: Rule Loading, Evaluation, and Explainable Group Keys
**Rationale:** Rule behavior is the product's correlation policy; it must be deterministic, validated, and inspectable before incident mutation and notification fan-out depend on it.
**Delivers:** YAML rule loader, strict semantic validation, priority sorting, match engine, canonical group key generation, threshold/window decision objects, rule summary rendering context, processing result shape.
**Addresses:** YAML rule loading, priority evaluation, group keys, threshold/window aggregation preparation, rule-level suppression/action declarations.
**Avoids:** Noisy grouping, fragile YAML, broad wildcard surprises, rules referencing missing plugins/tags.
**Open questions to settle:** multi-match vs first-match policy; whether to support `stop_processing`; threshold counts raw events vs unique hosts/services per rule; minimum rule dry-run behavior in v1 vs v1.x.

### Phase 4: Durable Problem Aggregation End to End
**Rationale:** This is the first true product slice: a PROBLEM event becomes a durable, topology-aware incident without notification side effects.
**Delivers:** Event processor, topology + rule + incident manager wiring, transaction boundary, atomic open-incident upsert, affected host/service merge, inserted/updated outcome, incident read APIs for validation.
**Addresses:** PostgreSQL incident state, atomic upsert, idempotency/replay tolerance, threshold state tracking, API-first incident visibility.
**Avoids:** SELECT-then-INSERT races, in-memory incident state, unbounded affected-host growth, audit gaps.
**Open questions to settle:** JSONB affected entity shape vs child membership table later; exact idempotency semantics for duplicate fingerprints; whether audit records are separate rows or compact incident timeline initially.

### Phase 5: Task Runner, Output Plugin, and Notification Transition Control
**Rationale:** Notifications must follow durable incident transitions, not raw event arrivals. The task runner seam must be correct before output plugins or retry behavior expand.
**Delivers:** `TaskRunner` protocol, asyncio runner, task registry, notification dispatcher, email-style output plugin, notification idempotency key, delivery/attempt record or equivalent audit, threshold-crossing dispatch.
**Addresses:** Output plugin dispatch, pluggable task execution, notification dedup, retry/failure visibility.
**Avoids:** Notification storms, fire-and-forget task loss, direct `asyncio.create_task()` leakage, network I/O inside DB transactions.
**Open questions to settle:** whether notification attempts/outbox is mandatory in v1 or lands immediately after first send; initial email transport dependency (`aiosmtplib`) vs simpler email-style adapter; retry/backoff limits.

### Phase 6: Recovery and Expiration Lifecycle
**Rationale:** Incident lifecycle correctness is incomplete until source recoveries and stale incident expiry close incidents distinctly and audibly.
**Delivers:** RECOVERY event branch, host/service recovery matching, `RESOLVED` transitions, optional recovery notification hook, lifespan-owned expiration scanner, `CLOSED` expiration transitions, lifecycle metrics/logs.
**Addresses:** Recovery handling, stale expiration, lifecycle states, source OK/UP semantics, late/no recovery behavior.
**Avoids:** Permanently open incidents, OK events opening incidents, expiration/recovery ambiguity, acknowledged incidents fighting automatic recovery.
**Open questions to settle:** recovery matching for topology-level incidents with many affected services; late event behavior after expiration; whether acknowledged incidents auto-resolve and how that is surfaced.

### Phase 7: Operator REST APIs and Operability Hardening
**Rationale:** REST APIs are the product surface, and Correlia itself is critical alerting infrastructure. Operators need inspection, mutation, and health signals before production use.
**Delivers:** incident list/detail filters, ack/close APIs, rules/topology/plugin summary endpoints with secret redaction, health/readiness, structured logs, metrics, config/plugin/task status, pagination/filtering.
**Addresses:** API-first operator workflows, observability endpoints, audit/debug traceability, external automation readiness.
**Avoids:** API consumers getting only `accepted`, missing health signals, unexplainable incidents, high-cardinality metric mistakes.
**Open questions to settle:** authn/authz scope for operator APIs; pagination/filter defaults; which incident timeline fields are required for launch.

### Phase 8: Experience Hardening and Expansion Gates
**Rationale:** These features improve safe operations after the core Icinga2 path works. They should not block proving the core path, but they strongly influence post-launch roadmap quality.
**Delivers:** rule dry-run/simulation, explainable correlation trace in detail API, topology coverage report, atomic config reload with last-known-good config, expanded delivery records/outbox, basic suppressions, additional output plugins.
**Addresses:** differentiators and v1.x safety improvements.
**Avoids:** unsafe rule tuning, topology unknowns, invisible suppression, config reload partial failure.
**Open questions to settle:** reload vs restart-only configuration acceptance for launch; API-managed silences design; second output/input plugin priority after usage data.

### Phase Ordering Rationale

- Domain contracts and PostgreSQL invariants come first because every later behavior depends on normalized lifecycle fields and one active incident per rule/group.
- Icinga2 ingress arrives early to prevent abstract plugin over-design and to validate host/service PROBLEM/RECOVERY semantics against real payloads.
- Topology precedes rule aggregation because Correlia's main value is topology-aware grouping; rule grouping without enrichment degrades to ordinary host/service deduplication.
- Rules precede notification because notification actions, summaries, thresholds, and suppression decisions originate in validated rule config.
- Durable incident upsert precedes dispatch because notifications must reference persisted incidents and threshold transitions, not transient processor memory.
- Recovery and expiration follow problem aggregation but must land before broad operator adoption; otherwise incidents remain open or close for the wrong reason.
- Operator APIs and observability are not polish; they are grouped after core paths so they expose real behavior and reuse the same transition methods.
- Experience hardening and ecosystem expansion wait until one Icinga2 path proves correctness under realistic bursts.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2:** Icinga2 webhook payload/NotificationCommand details, authentication pattern, and HARD/SOFT state policy need implementation-specific validation.
- **Phase 3:** Rule semantics need product decisions: multi-match vs first-match, threshold counting model, wildcard behavior, and dry-run response shape.
- **Phase 5:** Notification durability and retry/outbox design need deeper design if launch requires guaranteed delivery rather than best-effort audited send attempts.
- **Phase 6:** Recovery matching for topology-level incidents and acknowledgement interaction need careful design before implementation.
- **Phase 7:** Operator API authn/authz and audit exposure need security review before non-local deployment.
- **Phase 8:** Config reload, suppressions/silences, and additional plugin contracts need separate planning to avoid importing Alertmanager/PagerDuty complexity wholesale.

Phases with standard patterns where research can usually be skipped or kept light:
- **Phase 1:** Python/FastAPI/Pydantic/Alembic scaffolding and PostgreSQL partial unique index patterns are well documented; focus on project-specific invariant choices.
- **Phase 4:** PostgreSQL upsert implementation is documented; the main need is correctness verification against the chosen schema, not broad research.
- **Phase 7:** FastAPI routers, pagination, health/readiness, and low-cardinality metrics have established patterns; adapt to Correlia domain fields.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Project constraints and current official package/docs metadata align: Python 3.13, FastAPI/Pydantic v2, SQLAlchemy 2.0, asyncpg, PostgreSQL, Alembic, PyYAML, uv. Optional email/performance libraries remain demand-driven. |
| Features | MEDIUM-HIGH | Core alert-management table stakes are supported by Icinga2, Alertmanager, PagerDuty, Grafana OnCall references and project scope. Correlia-specific prioritization is less certain until users validate workflows. |
| Architecture | HIGH | Modular monolith with ports/adapters, typed config, PostgreSQL-owned state, FastAPI lifespan, and task-runner boundary follows project constraints and established backend patterns. Acknowledgement modeling is the main unresolved design adjustment. |
| Pitfalls | HIGH | Concurrency, recovery, YAML safety, async task, and observability risks are grounded in official PostgreSQL/SQLAlchemy/Icinga2/FastAPI/PyYAML/Pydantic/SRE references and directly map to Correlia requirements. |

**Overall confidence:** HIGH for the v1 technical direction; MEDIUM-HIGH for exact roadmap cut lines and operator-experience prioritization before real user validation.

### Gaps to Address

- **Acknowledgement model:** Decide before schema implementation whether acknowledgement is metadata on `OPEN` incidents or a status included in the active uniqueness predicate.
- **Rule match policy:** Decide multi-match default, `stop_processing` support, and how priority interacts with simultaneous topology-level and single-host rules.
- **Threshold semantics:** Define when thresholds count raw events, unique fingerprints, unique hosts, unique services, or rule-specific affected objects.
- **Icinga2 SOFT/HARD policy:** Choose whether SOFT states are ignored, tagged but non-paging, or accepted by explicit rule configuration.
- **Notification durability:** Decide if v1 requires a notification attempts/outbox table at first dispatch or immediately after the first concrete output plugin.
- **Recovery matching:** Specify host vs service recovery behavior for topology-level incidents and acknowledged active incidents.
- **Topology conflicts:** Define override/conflict behavior between source tags, hostname captures, and subnet fallback.
- **Auth and exposure:** Define webhook authentication and operator API authn/authz before non-local deployment.
- **Config reload timing:** Decide whether v1 is restart-only config with strict startup validation or includes atomic reload before launch.
- **Audit retention:** Define raw/debug event retention limits and the minimum durable decision timeline needed for incident explainability.

## Sources

### Primary (HIGH confidence)
- `.planning/PROJECT.md` — Correlia scope, active requirements, constraints, data flow, key decisions, and concurrency invariant.
- `.planning/research/STACK.md` — recommended Python/FastAPI/Pydantic/PostgreSQL/SQLAlchemy/asyncpg/Alembic/PyYAML/asyncio stack and versions.
- `.planning/research/FEATURES.md` — table stakes, differentiators, anti-features, feature dependencies, MVP definition, and competitor/reference feature analysis.
- `.planning/research/ARCHITECTURE.md` — modular monolith design, boundaries, data flow, build order, incident state model, REST/task/output/topology/rule/observability architecture.
- `.planning/research/PITFALLS.md` — critical pitfalls, phase mappings, technical debt patterns, integration gotchas, performance traps, security mistakes, recovery strategies.
- PostgreSQL documentation — partial unique indexes and `INSERT ... ON CONFLICT` behavior.
- SQLAlchemy 2.0 PostgreSQL dialect docs — `insert().on_conflict_do_update()` with conflict targets and `index_where`.
- FastAPI official docs — routers, dependency patterns, lifespan startup/shutdown.
- Pydantic v2 docs — strict validation, validators, model APIs.
- PyYAML docs — unsafe `yaml.load` warning and `safe_load` behavior.
- Icinga2 official docs — host/service states, notifications, API, state/type filters.
- Prometheus Alertmanager official docs — grouping, routing, silences, inhibition, resolved/firing semantics, management API.

### Secondary (MEDIUM confidence)
- PagerDuty Event Orchestration support docs — routing, dedup keys, threshold conditions, suppression/drop actions, maintainability cautions.
- Grafana OnCall docs — integration URLs, grouping IDs, route/escalation behavior, ack/resolve behavior.
- Google SRE book/workbook — monitoring signals, alert fatigue, SLO alerting, configuration safety.
- OpenTelemetry FastAPI instrumentation docs — tracing hooks and integration options.

### Tertiary (LOW confidence)
- None material for core v1 decisions. Remaining uncertainty is product-specific prioritization and launch policy rather than weak source quality.

---
*Research completed: 2026-06-08*
*Ready for roadmap: yes*
