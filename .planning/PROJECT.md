# Vigilo

## What This Is

Vigilo is a modular, API-first event aggregation system for infrastructure alerts. It starts with Icinga2 webhook ingestion, then normalizes events into a plugin-agnostic model, enriches them with topology context, aggregates them into incidents with PostgreSQL-backed state, and dispatches notifications through pluggable output channels. It intentionally ships without a built-in frontend; REST APIs are the product surface.

## Core Value

Operators receive one accurate, topology-aware incident for a related alert storm instead of many disconnected raw alerts.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Accept Icinga2 alert payloads through a REST webhook.
- [ ] Normalize every input into a consistent event model with fingerprint, source, host, service, severity, event type, timestamp, tags, message, and optional IP address.
- [ ] Enrich events through a topology enrichment plugin, with a static YAML hostname/IP plugin as the first implementation.
- [ ] Load rule configuration from YAML with priority, match criteria, grouping window, threshold, output summary, and actions.
- [ ] Aggregate matching problem events into PostgreSQL-backed incidents.
- [ ] Maintain concurrency-safe incident state with one open incident per rule and group key.
- [ ] Dispatch threshold-crossing incidents through pluggable output channels.
- [ ] Abstract task execution behind a task runner that defaults to asyncio in v1 and can be replaced by Celery/Redis later.
- [ ] Resolve incidents when recovery events arrive from input plugins.
- [ ] Expire stale open incidents when no events arrive within the rule window.
- [ ] Expose system behavior through REST APIs, with no built-in frontend.

### Out of Scope

- Built-in web frontend — API-first system; user interfaces can be separate clients.
- Celery/Redis task execution in v1 — task execution must be abstracted, but asyncio is the v1 runner.
- Non-Icinga2 input plugins in v1 — plugin architecture must allow them, but Icinga2 is the first concrete input.
- Complex notification transports beyond an initial email-style output plugin — output plugins must be pluggable, but v1 only needs one concrete channel.
- Long-term raw event retention guarantees — raw events are optional/rotated for debugging and audit, not the primary product value.
- AI-driven topology enrichment implementation in the initial topology phase — the topology enrichment interface must make this possible later, but v1 proves the static YAML plugin first.

## Context

The idea document defines Vigilo as a Python 3.13+ backend service using FastAPI, SQLAlchemy 2.0+, asyncpg, PostgreSQL, Pydantic v2, PyYAML, and uv. Its core architecture is stateless business logic backed by stateful PostgreSQL storage. Configuration is intentionally externalized to YAML for rules, topology, and plugin registry definitions.

The domain is alert aggregation for monitoring systems. The initial integration target is Icinga2, including host and service states mapped to plugin-agnostic `PROBLEM` and `RECOVERY` events. Future systems such as Prometheus Alertmanager should fit through the same input plugin contract.

The key data flow is: input payload → input plugin normalization → topology enrichment plugin → rule matching → incident upsert/update → task runner submission → output plugin notification. Incident lifecycle management includes open, acknowledged, resolved, and closed states.

Concurrency safety is a first-class concern. Incident writes must not perform SELECT-then-INSERT for open incident aggregation; PostgreSQL `ON CONFLICT` against a partial unique index on `(rule_name, group_key) WHERE status = 'OPEN'` is required to prevent duplicate open incidents under concurrent alert bursts.
Testing should use Testcontainers for Python for PostgreSQL-backed integration tests where database behavior matters. SQLite is not an acceptable substitute for partial unique indexes, JSONB, migrations, transaction behavior, or concurrent upsert verification.

## Constraints

- **Tech stack**: Python 3.13+, uv, FastAPI, PostgreSQL, SQLAlchemy 2.0+, asyncpg, Pydantic v2, PyYAML — specified by the idea document and aligned with the backend/API-first goal.
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
| API-first backend with no built-in frontend | Keeps v1 focused on alert ingestion, aggregation, state, and REST contracts | — Pending |
| Icinga2 as first input plugin | The project needs one concrete monitoring integration before generalizing | — Pending |
| Plugin-agnostic `NormalizedEvent` model | Core processing should not depend on source-specific payload shapes | — Pending |
| `PROBLEM` / `RECOVERY` event classification | Incident lifecycle cannot be correct if OK/resolved source states are treated like ordinary alerts | — Pending |
| PostgreSQL as authoritative incident state | Aggregation correctness needs durable, queryable state and database constraints | — Pending |
| Partial unique index for open incidents | Prevents duplicate open incidents per rule/group under concurrent ingestion | — Pending |
| YAML rules, topology, and plugin registry | Operators can adjust behavior without changing Python code | — Pending |
| Topology enrichment plugin interface | Static YAML enrichment ships first, but later enrichers such as an AI-driven topology enricher should plug into the same boundary | — Pending |
| Testcontainers for Python for PostgreSQL tests | Vigilo depends on PostgreSQL-specific behavior that SQLite cannot validate | — Pending |
| `TaskRunner` abstraction with asyncio default | Supports v1 simplicity while preserving a clean path to Celery/Redis | — Pending |
| Vertical MVP roadmap mode | Auto mode defaults to end-to-end slices that prove product behavior early | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-08 after initialization*
