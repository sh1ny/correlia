# Phase 1: Foundations, Contracts, and Database Invariant - Context

**Gathered:** 2026-06-08
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 1 delivers the runnable backend foundation and the core contracts that later ingestion, enrichment, rules, aggregation, lifecycle, and operator APIs must build on. In scope: Python 3.13/uv project setup, FastAPI service startup, application settings validation, health/readiness basics, Alembic/PostgreSQL setup, strict domain models for normalized events and incidents, and the database-enforced invariant that only one OPEN incident can exist for a `(rule_name, group_key)` pair.

Not in scope: Icinga2 webhook behavior, topology enrichment implementation, rule evaluation, notification dispatch, recovery processing, expiration loops, operator incident APIs, production metrics, or AI-driven enrichment.

</domain>

<decisions>
## Implementation Decisions

### Active Incident Lifecycle
- **D-01:** Model acknowledgement as metadata on an active incident, not as an incident status. Use fields such as `acknowledged_at` and `acknowledged_by`; the incident remains `OPEN` until source recovery, expiration, or manual close changes lifecycle state.
- **D-02:** Lock the Phase 1 incident statuses to `OPEN`, `RESOLVED`, and `CLOSED`. Do not include `ACKNOWLEDGED` in `IncidentStatus`.
- **D-03:** Enforce active incident uniqueness with a PostgreSQL partial unique index on `(rule_name, group_key) WHERE status = 'OPEN'`.
- **D-04:** Phase 1 should define domain transition helpers/invariants for planned lifecycle transitions: `OPEN -> RESOLVED`, `OPEN -> CLOSED`, and no reopening of `RESOLVED`/`CLOSED` incidents. Recovery, expiration, and REST mutation implementations arrive later, but the model should prevent scattered lifecycle logic.
- **D-05:** Incident aggregation identity is exactly `rule_name + group_key`. Source, host, service, and fingerprint are incident content/metadata, not uniqueness identity.
- **D-06:** Incident timestamps should include `start_time`, `last_update_time`, `created_at`, `updated_at`, plus nullable `resolved_at` and `closed_at` from the initial migration.
- **D-07:** Incident severity should store the current maximum severity seen while the incident is `OPEN`, not just the latest event severity.
- **D-08:** Represent affected hosts/services as bounded deterministic JSONB sets (`affected_hosts`, `affected_services`) in v1. Do not introduce a membership table in Phase 1.

### Incident Debug Metadata
- **D-09:** Support compact decision metadata, not full raw source payload storage, in Phase 1.
- **D-10:** Defer a concrete `raw_events` table until Phase 2 ingestion produces real payload/redaction requirements. Phase 1 should define the storage seam and add compact incident-side debug context.
- **D-11:** `decision_context` may contain only non-secret processing facts: normalized fingerprint, source id, rule/group details, matched rule names, enrichment provenance references, event counts, config version/hash, and similar explainability data. It must not contain raw payloads, credentials, plugin config secrets, or arbitrary plugin JSON.
- **D-12:** Use a typed metadata envelope with stable top-level keys/version and JSON-serializable bounded details. Avoid completely free-form JSONB.

### Domain Contract Strictness
- **D-13:** `NormalizedEvent` validation at the plugin/core boundary is strict and fail-fast. Missing, ambiguous, or coerced values should produce explicit validation errors rather than permissive normalization.
- **D-14:** Phase 1 should define explicit enums/literals for `EventType`, `Severity`, and `IncidentStatus`.
- **D-15:** Event tags are a strict `dict[str, str]` style contract with non-empty keys and values and a normalized key format. Do not model tags as a list or free JSON object.
- **D-16:** Event timestamps must be timezone-aware. Reject naive timestamps. Keep source event time distinct from processing/database timestamps.

### Service Bootstrap Surface
- **D-17:** Expose both liveness and readiness basics in Phase 1: `/health` for process liveness and `/readyz` for database/config readiness. Do not add metrics/config-summary endpoints yet.
- **D-18:** Validate application settings only in Phase 1: `DATABASE_URL`, environment/log level, and paths for future rule/topology/plugin config. Concrete rule/topology/plugin YAML loading belongs to later phases.
- **D-19:** Provide Makefile targets in addition to uv commands for common maintainer flows: test, lint, typecheck, and run. uv remains the package manager/source of truth.
- **D-20:** Include full initial Alembic setup and migration for the incidents table, enum/status constraints, JSONB metadata fields, timestamps, and the partial unique index. Do not stop at an Alembic scaffold.

### Claude's Discretion
No selected area was delegated to Claude. Downstream agents should treat the decisions above as locked.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project Scope and Requirements
- `.planning/PROJECT.md` — Product definition, active/out-of-scope requirements, architecture constraints, and project-level key decisions.
- `.planning/REQUIREMENTS.md` — Requirement IDs and traceability for Phase 1: FND-01–FND-04, DOM-01–DOM-04, PRS-01–PRS-04.
- `.planning/ROADMAP.md` — Phase 1 goal, boundary, success criteria, dependencies, and downstream phase boundaries.
- `.planning/STATE.md` — Current planning state and accumulated decisions/concerns, including acknowledgement modeling as a Phase 1 concern.

### Research Grounding
- `.planning/research/STACK.md` — Locked stack recommendations: Python 3.13, uv, FastAPI, Pydantic v2, SQLAlchemy 2.0, asyncpg, PostgreSQL, Alembic, PyYAML, pytest, Ruff, mypy, Testcontainers.
- `.planning/research/ARCHITECTURE.md` — Recommended modular-monolith boundaries, project structure, database-enforced incident singularity, lifecycle status model warning, PostgreSQL schema guidance, and API/router boundaries.
- `.planning/research/PITFALLS.md` — Pitfalls to avoid: duplicate open incidents, recovery-as-alert mistakes, fragile YAML validation, plugin leakage, metadata/audit blind spots, and acknowledgement semantics fighting automatic recovery.

No SPEC.md or prior phase CONTEXT.md exists for Phase 1.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- No application source tree exists yet in the current workspace. Phase 1 is greenfield implementation from planning artifacts.
- Existing reusable assets are planning/research documents listed in Canonical References.

### Established Patterns
- Use domain-oriented packages, not a generic dumping ground: `domain/`, `persistence/`, `config/`, `api/`, and later `processing/` / `plugins/` as described in architecture research.
- Keep SQLAlchemy/PostgreSQL details isolated in persistence code. The atomic upsert and partial unique index are named, tested invariants, not incidental repository behavior.
- Keep config parsing at the edge: PyYAML `safe_load()` feeds strict Pydantic v2 models; processors receive typed objects.
- Use Testcontainers for PostgreSQL-specific migration/index/upsert behavior. SQLite is not an acceptable substitute.

### Integration Points
- Phase 1 creates the app factory/lifespan, settings, health/readiness router, database session/migration foundation, domain contracts, and incident persistence model.
- Later phases connect Icinga2 input plugins, topology enrichment, rules, aggregation, notification dispatch, recovery, expiration, and operator APIs to these contracts.

</code_context>

<specifics>
## Specific Ideas

- Prefer acknowledgement metadata (`acknowledged_at`, `acknowledged_by`) over `ACKNOWLEDGED` status specifically to preserve the simple `WHERE status = 'OPEN'` partial unique index.
- Keep Phase 1 raw/debug storage compact and non-secret; downstream planners should avoid premature raw payload retention.
- Include `/readyz` now because DB/config readiness is part of proving the runnable backend, but defer metrics and config summary APIs to operability phases.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 1-Foundations, Contracts, and Database Invariant*
*Context gathered: 2026-06-08*
