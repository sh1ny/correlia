# Correlia

## What This Is

Correlia is a modular, API-first event aggregation system for infrastructure alerts. v1.0 ships Icinga2 webhook ingestion, strict plugin-agnostic normalization, static topology enrichment, deterministic YAML rule evaluation, PostgreSQL-backed incident aggregation, lifecycle mutation, trusted internal REST operator APIs, notification dispatch, metrics, readiness, and safe structured logging. It intentionally ships without a built-in frontend; REST APIs are the product surface.

## Core Value

Operators receive one accurate, topology-aware incident for a related alert storm instead of many disconnected raw alerts.

## Current State

- **Shipped version:** v1.0 MVP on 2026-06-09.
- **Milestone scope:** 4 phases, 16 plans, 34 tasks.
- **Validated surface:** Icinga2 ingress, topology enrichment, rule evaluation, incident aggregation, notification dispatch, recovery/expiration lifecycle, operator APIs, metrics, readiness, and structured logs.
- **Current focus:** Planning the next milestone from fresh requirements.

## Next Milestone Goals

Fresh requirements should be defined with `/gsd-new-milestone`. Candidate future themes already deferred from v1:

- Additional input plugins, especially Prometheus Alertmanager.
- Broker-backed durable task execution and outbox/retry semantics.
- API-managed suppressions, silences, maintenance windows, and config dry-run/reload workflows.
- Additional output plugins such as Slack, generic webhook, PagerDuty Events API, or Grafana OnCall.
- AI-driven topology enrichment and root-cause assistance after more deterministic history exists.

## Requirements

### Validated

- ✓ Python 3.14+ uv/FastAPI foundation, strict Pydantic settings, normalized event and incident contracts, Alembic/PostgreSQL schema invariant, and atomic open-incident upsert path — v1.0.
- ✓ Icinga2 webhook ingestion, strict input normalization, static YAML topology enrichment, strict YAML rule loading, deterministic first-match rule evaluation, group-key rendering, and inspectable threshold/window decisions — v1.0.
- ✓ PostgreSQL-backed problem aggregation, durable bounded threshold/window state, first-transition notification submission, asyncio `TaskRunner`, trusted output plugin registry loading, Mailpit-compatible SMTP output, and compact dispatch outcome reporting — v1.0.
- ✓ RECOVERY lifecycle mutation, stale incident expiration, trusted internal `/v1` operator APIs, low-cardinality Prometheus metrics, safe JSON structured logs, and expanded readiness checks — v1.0.

### Active

- Fresh active requirements will be created by `/gsd-new-milestone` for the next milestone.

### Out of Scope

- Built-in web frontend — API-first system; user interfaces can be separate clients.
- Celery/Redis task execution in v1 — task execution must be abstracted, but asyncio is the v1 runner.
- Non-Icinga2 input plugins in v1 — plugin architecture allows them, but Icinga2 is the first concrete input.
- Complex notification transports beyond an initial email-style output plugin — output plugins are pluggable, but v1 only ships one concrete channel.
- Long-term raw event retention guarantees — raw events are optional/rotated for debugging and audit, not the primary product value.
- AI-driven topology enrichment implementation in v1 — the topology enrichment interface makes this possible later, but v1 proves the static YAML plugin first.

## Context

The v1 codebase is a Python 3.14+ backend service using FastAPI, SQLAlchemy 2.0+, asyncpg, PostgreSQL, Pydantic v2, PyYAML, uv, Alembic, prometheus-client, and Testcontainers-backed pytest coverage. Its core architecture is stateless business logic backed by stateful PostgreSQL storage. Configuration is externalized to YAML for rules, topology, and plugin registry definitions.

The domain is alert aggregation for monitoring systems. The initial integration target is Icinga2, including host and service states mapped to plugin-agnostic `PROBLEM` and `RECOVERY` events. Future systems such as Prometheus Alertmanager should fit through the same input plugin contract.

The key data flow is: input payload → input plugin normalization → topology enrichment plugin → rule matching → incident upsert/update → task runner submission → output plugin notification. Incident lifecycle management includes open, acknowledged, resolved, and closed states.

Concurrency safety is a first-class concern. Incident writes must not perform SELECT-then-INSERT for open incident aggregation; PostgreSQL `ON CONFLICT` against a partial unique index on `(rule_name, group_key) WHERE status = 'OPEN'` is required to prevent duplicate open incidents under concurrent alert bursts.

Testing should use Testcontainers for Python for PostgreSQL-backed integration tests where database behavior matters. SQLite is not an acceptable substitute for partial unique indexes, JSONB, migrations, transaction behavior, or concurrent upsert verification.

## Constraints

- **Tech stack**: Python 3.14+, uv, FastAPI, PostgreSQL, SQLAlchemy 2.0+, asyncpg, Pydantic v2, PyYAML, prometheus-client — aligned with the backend/API-first goal.
- **Architecture**: No built-in frontend — REST APIs are the interface and keep the backend independently deployable.
- **Plugin boundaries**: Inputs, topology enrichers, outputs, storage-adjacent behavior, and task execution must be modular — future integrations should not require rewriting the core processor.
- **State ownership**: Logic lives in code and YAML rules; durable state lives in PostgreSQL — avoids split-brain state across worker memory or plugin instances.
- **Task execution**: v1 defaults to asyncio, but all task submission must go through `TaskRunner` — keeps a clean cutover path to Celery/Redis.
- **Concurrency**: Open incident aggregation must be database-enforced with a partial unique index and atomic upsert — race conditions create duplicate incidents and break the core value.
- **Topology enrichment**: Enrichment is a plugin boundary; the first concrete plugin is static YAML hostname/IP enrichment with hostname matching before IP subnet fallback.
- **Testing**: PostgreSQL integration and concurrency behavior must be tested with Testcontainers for Python — no SQLite-backed substitute for database-specific invariants.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| API-first backend with no built-in frontend | Keeps v1 focused on alert ingestion, aggregation, state, and REST contracts | Validated in v1.0 |
| Icinga2 as first input plugin | The project needs one concrete monitoring integration before generalizing | Validated in v1.0 |
| Plugin-agnostic `NormalizedEvent` model | Core processing should not depend on source-specific payload shapes | Validated in v1.0 |
| `PROBLEM` / `RECOVERY` event classification | Incident lifecycle cannot be correct if OK/resolved source states are treated like ordinary alerts | Validated in v1.0 |
| PostgreSQL as authoritative incident state | Aggregation correctness needs durable, queryable state and database constraints | Validated in v1.0 |
| Partial unique index for open incidents | Prevents duplicate open incidents per rule/group under concurrent ingestion | Validated in v1.0 |
| YAML rules, topology, and plugin registry | Operators can adjust behavior without changing Python code | Validated in v1.0 |
| Topology enrichment plugin interface | Static YAML enrichment ships first, but later enrichers such as an AI-driven topology enricher should plug into the same boundary | Validated in v1.0 |
| Testcontainers for Python for PostgreSQL tests | Correlia depends on PostgreSQL-specific behavior that SQLite cannot validate | Validated in v1.0 |
| `TaskRunner` abstraction with asyncio default | Supports v1 simplicity while preserving a clean path to Celery/Redis | Validated in v1.0 |
| Trusted internal `/v1` operator API | v1 proves operator workflows before production auth and tenancy concerns | Validated in v1.0 |
| Vertical MVP roadmap mode | End-to-end slices proved product behavior before broader integrations | Validated in v1.0 |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition**:
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone**:
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-09 after v1.0 milestone completion*
