# Phase 7: Incident Event Audit Trail - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in `07-CONTEXT.md`.

**Date:** 2026-06-18
**Phase:** 7-Incident Event Audit Trail
**Areas discussed:** Audit write timing, Raw payload retention, Operator inspection surface, Decision summary content

---

## Audit write timing

| Option | Description | Selected |
|--------|-------------|----------|
| Same-transaction insert (recommended) | Atomic with incident write inside ingress transaction; notification delivery confirmation out of Phase 7 scope | ✓ |
| Post-commit synchronous insert | Crash window violates AUD-02 | |
| Async via TaskRunner | Non-durable; violates AUD-02 | |
| Transactional outbox | Over-engineered for single-worker runtime | |

**User's choice:** Same-transaction insert (recommended)
**Notes:** User asked whether this was foreseen during milestone planning. Confirmed that notification delivery confirmation was intentionally deferred to Phase 9; Phase 7 scope covers event-to-decision traceability. Audit row records notification intent (`dispatch_planned` / `no_dispatch`), not actual plugin delivery.

---

## Raw payload retention

| Option | Description | Selected |
|--------|-------------|----------|
| Redacted + size-capped snapshot (recommended) | Secrets stripped, bounded storage, HMAC integrity, configurable size cap | ✓ |
| Full raw payload with recursive redaction, no size cap | Retains full structure but unbounded growth | |
| Metadata-only | Fails AUD-02 literal requirement | |

**User's choice:** Redacted + size-capped snapshot, configurable size cap
**Notes:** User explicitly requested configurability (`CORRELIA_AUDIT_RAW_PAYLOAD_MAX_BYTES`) so the cap can be adjusted without code changes.

---

## Operator inspection surface

| Option | Description | Selected |
|--------|-------------|----------|
| Top-level GET /v1/incident-events only (recommended) | Primary canonical surface with rich filters; satisfies AUD-04 | ✓ |
| Top-level + incident-scoped alias | Adds ergonomic alias | |
| Incident-scoped only | Fails AUD-04 no-op inspection | |

**User's choice:** Top-level `GET /v1/incident-events` only
**Notes:** Researcher later clarified field taxonomy: `incident_effect` (none|inserted|updated|resolved|affected_set_shrunk) and `no_dispatch_reason` (below_threshold|replay|already_notified|null) must be separate; `has_incident=false` maps to `incident_effect=none` only. Cursor on `(accepted_at, id)`; `event_timestamp` is filter/display only.

---

## Decision summary content

| Option | Description | Selected |
|--------|-------------|----------|
| Bounded rich aggregation snapshot (recommended) | Versioned Pydantic model with threshold/replay/dispatch/recovery context; excludes rule internals | ✓ |
| Minimal effect summary | Too thin for AUD-04 no-op inspection | |
| Rich snapshot plus rule match context | Couples audit to rule/enricher internals | |

**User's choice:** Bounded rich aggregation snapshot (recommended)
**Notes:** Field name corrected from `notification_dispatch=submitted` to `notification_intent` (`dispatch_planned` / `no_dispatch`) to reflect that audit row is written before post-commit task submission. Enforceable bounds added: `incident_ids` max 20, `affected_incident_count` alongside, `incident_ids_truncated` flag.

---

## Claude's Discretion

- Pydantic model naming (`AuditDecisionSummary`) and schema-versioning discipline.
- Default raw payload size cap value (64 KiB suggested).
- Dedicated `app/persistence/audit.py` and `app/api/routers/audit.py` module layout.
- Alembic migration approach for the new table and indexes.

## Deferred Ideas

- Phase 9 notification delivery result audit in a separate table.
- Phase 10 audit metrics and structured logging.
- Future JSONB GIN/full-text search if query patterns justify it.

---

*Phase: 7-Incident Event Audit Trail*
*Discussion logged: 2026-06-18*
