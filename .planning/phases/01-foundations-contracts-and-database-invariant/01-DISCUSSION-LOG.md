# Phase 1: Foundations, Contracts, and Database Invariant - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-08
**Phase:** 01-Foundations, Contracts, and Database Invariant
**Areas discussed:** Active incident lifecycle, Incident debug metadata, Domain contract strictness, Service bootstrap surface

---

## Active Incident Lifecycle

### Acknowledgement model

| Option | Description | Selected |
|--------|-------------|----------|
| Acknowledgement metadata | Keep status OPEN; add acknowledged_at/acknowledged_by. Best fit for partial unique index WHERE status = OPEN and avoids duplicate active incidents. | ✓ |
| ACKNOWLEDGED status | Use a separate active status and include OPEN + ACKNOWLEDGED in the unique predicate. More explicit lifecycle state, more complex upsert target. | |
| No acknowledgement fields yet | Defer acknowledgement modeling to Phase 4. Simpler now, but risks Phase 1 schema churn when operator APIs land. | |

**User's choice:** Acknowledgement metadata

### Status enum

| Option | Description | Selected |
|--------|-------------|----------|
| OPEN, RESOLVED, CLOSED | Keep status focused on lifecycle outcomes; acknowledgement stays metadata. Covers active, source-recovered, and expired/manual closed states. | ✓ |
| OPEN, ACKNOWLEDGED, RESOLVED, CLOSED | Matches earlier state vocabulary, but conflicts with the metadata decision unless ACKNOWLEDGED is treated as non-active. | |
| OPEN and CLOSED only | Minimal schema, but loses distinction between source recovery and stale/manual closure. | |

**User's choice:** OPEN, RESOLVED, CLOSED

### Database uniqueness

| Option | Description | Selected |
|--------|-------------|----------|
| Only OPEN incidents | Unique (rule_name, group_key) WHERE status = 'OPEN'. With acknowledgement metadata, this preserves one active aggregation target. | ✓ |
| All non-closed incidents | Unique while status is OPEN or RESOLVED. Prevents unresolved duplicates, but may block keeping historical resolved incidents per group. | |
| All incidents globally | Unique rule/group forever. Simplest index, but prevents a later outage from creating a new incident after closure. | |

**User's choice:** Only OPEN incidents

### Transition rules

| Option | Description | Selected |
|--------|-------------|----------|
| Validate all planned transitions | Define transition helpers/invariants for OPEN -> RESOLVED/CLOSED and disallow reopening closed/resolved incidents. Later APIs reuse them. | ✓ |
| Schema only | Only define enum values and columns now. Later phases add transition rules. Faster, but planner may scatter lifecycle logic. | |
| Full lifecycle implementation | Implement recovery, expiration, acknowledgement, and close behavior now. Too much scope for Phase 1; belongs to later phases. | |

**User's choice:** Validate all planned transitions

### Identity, timestamps, severity, affected entities

| Question | Selected |
|----------|----------|
| What fields should define aggregation identity? | Rule name + group key |
| Which timestamps should Phase 1 require? | Add resolved/closed now too |
| How should incident severity behave as PROBLEM events join? | Store current max severity |
| How should affected hosts/services be represented? | Bounded JSONB sets |

---

## Incident Debug Metadata

| Question | Selected | Alternatives |
|----------|----------|--------------|
| What optional debug/decision metadata should Phase 1 schema support? | Compact decision metadata | Raw source payload storage; No metadata schema yet |
| Should Phase 1 create a raw_events table, or defer it until ingress exists? | Defer table, define seam | Create raw_events now; Never store raw events |
| What should compact incident decision_context contain? | Non-secret processing facts | Any plugin-provided JSON; Only config version/hash |
| How strict should debug metadata shape be? | Typed envelope, flexible details | Fully typed fields only; Free-form JSONB |

---

## Domain Contract Strictness

| Question | Selected | Alternatives |
|----------|----------|--------------|
| How strict should NormalizedEvent validation be? | Strict fail-fast | Normalize permissively; Mixed by source |
| Which domain values should be enums/literals? | EventType, Severity, IncidentStatus | Strings with validators; Enums for everything |
| How should event tags be defined? | String map with strict keys/values | List of strings; Free JSON object |
| How should event timestamps be treated? | Timezone-aware required | Assume UTC for naive; Processing time only |

---

## Service Bootstrap Surface

| Question | Selected | Alternatives |
|----------|----------|--------------|
| What REST health surface should Phase 1 expose? | Health plus readiness | Health only; Full ops endpoints |
| What settings should be validated in Phase 1? | Application settings only | All YAML configs now; DATABASE_URL only |
| How should a maintainer run the Phase 1 service? | Makefile plus uv commands | uv commands only; Docker compose now |
| How much Alembic setup should Phase 1 include? | Full initial migration | Alembic scaffold only; Manual SQL only |

---

## Claude's Discretion

None.

## Deferred Ideas

None.
