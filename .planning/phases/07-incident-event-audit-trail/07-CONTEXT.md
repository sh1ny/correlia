# Phase 7: Incident Event Audit Trail - Context

**Gathered:** 2026-06-18
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 7 adds an append-only `incident_events` audit table that records every accepted normalized source event, a redacted snapshot of the raw source payload, and a bounded decision summary. Audit rows are used for operator traceability only; they must not influence incident aggregation, notification thresholds, recovery, or lifecycle transitions. Operators can browse audit rows through a canonical read-only endpoint and correlate them to incidents when one exists.

Phase 7 does not implement notification plugin delivery confirmation, long-term raw event warehousing, webhook endpoint compatibility, Vigilo config migration, output-plugin hardening, or deployment packaging. It also does not allow summary mutation of incidents.

</domain>

<decisions>
## Implementation Decisions

### Audit Write Timing
- **D-01:** Audit rows are written in the same database transaction as the incident upsert/lifecycle write. This satisfies AUD-02's "every accepted normalized event" crash-safety requirement.
- **D-02:** Transaction commit ownership moves upward from `IncidentManager.apply_problem` and `LifecycleManager.resolve_for_event` to the ingress caller. Managers return their write result and notification intent; the ingress layer inserts the audit row and commits once.
- **D-03:** Notification task submission (`_submit_notifications`) remains post-commit, preserving current envelope behavior. Audit rows record notification **intent** only (`notification_intent = dispatch_planned | no_dispatch` with `no_dispatch_reason`), not actual plugin delivery results.

### Raw Payload Retention
- **D-04:** The audit table stores a redacted, size-capped snapshot of the accepted source payload object. Exact wire-body retention is not required unless the ingress route is changed to capture bytes.
- **D-05:** Raw payload redaction strips secrets before persistence. A new recursive redactor handles arbitrary JSON paths and string values; the existing `DecisionContext` notes filter is not reused for this purpose.
- **D-06:** Raw payload size cap is configurable via `CORRELIA_AUDIT_RAW_PAYLOAD_MAX_BYTES` in `app.config.settings.Settings`, with a conservative default (e.g., 64 KiB). Capping must be semantic, not arbitrary byte truncation of JSONB.
- **D-07:** Metadata columns accompany the raw snapshot: `original_byte_length`, `stored_byte_length`, `truncated`, `redaction_version`, `redacted_path_count`, and a keyed HMAC of the pre-redaction canonical payload.
- **D-08:** Default audit read responses never expose `raw_payload` or full `normalized_event`. `NormalizedEvent.message` and `tags` are also bounded/redacted on read.

### Operator Inspection Surface
- **D-09:** The primary canonical read surface is `GET /v1/incident-events`. No incident-scoped alias is added in Phase 7.
- **D-10:** Pagination is cursor-first on the immutable tuple `(accepted_at, id)`. Offset pagination with `total` is diagnostic-only and documented as approximate.
- **D-11:** Filters include `incident_id`, `has_incident` (true/false), `fingerprint`, `source_id`, `event_type`, `incident_effect`, `no_dispatch_reason`, `severity`, `host`, `service`, `accepted_since`/`accepted_until`, and `event_timestamp_since`/`event_timestamp_until`.
- **D-12:** `has_incident=false` maps strictly to `incident_effect = none`. `below_threshold` and `replay` are `no_dispatch_reason` values, not no-incident cases.
- **D-13:** Audit row identifier is a server-generated UUID. `fingerprint` is a correlation field only (repeats for replays).
- **D-14:** Incident correlation uses an `incident_ids` JSONB array. Recovery events may touch multiple incidents; no-op events touch none.
- **D-15:** Read responses project bounded metadata only; raw payload and full normalized event are never selected or serialized by default.
- **D-16:** `/v1/incident-events` is explicitly classified as route class `operator` in `app/middleware/classification.py` so Phase 5 auth and rate-limit inheritance is assertable.

### Decision Summary Content
- **D-17:** The `decision_summary` column is a bounded Pydantic model named `AuditDecisionSummary`, versioned with `schema_version: Literal[1]`, `strict=True`, `extra="forbid"`, following the existing `DecisionContext` discipline.
- **D-18:** Required fields: `decision_kind` (problem|recovery|noop), `incident_effect` (none|inserted|updated|resolved|affected_set_shrunk), `rule_name` (nullable string), `group_key` (nullable string), `incident_ids` (max 20), `affected_incident_count` (int), `incident_ids_truncated` (bool), `decision_reason` (nullable bounded string, max 256 chars), `no_dispatch_reason` (nullable bounded string, max 128 chars), `notification_intent` (dispatch_planned|no_dispatch), `counted_count` (nullable int), `threshold_count` (nullable int), `threshold_crossed` (nullable bool), `replay` (nullable bool), `first_threshold_transition` (nullable bool), `recovery_resolution` (nullable literal: noop|affected_set_shrunk|resolved), `affected_object_removed` (nullable bool).
- **D-19:** The model deliberately excludes `counted_fingerprints`, `enrichment_diagnostics`, and full `rule_decision`/`threshold_decision` dicts to bound row size, preserve rule-internal privacy, and decouple audit schema from rule-engine evolution.

### Claude's Discretion
- Choose an Alembic migration for the new `incident_events` table and indexes.
- Choose a dedicated `app/persistence/audit.py` module and `app/api/routers/audit.py` router.
- Reuse existing `app.processing.logging.safe_log_extra` for audit-related control logs.
- Keep audit writes synchronous inside the ingress transaction; do not introduce outbox/relay infrastructure in Phase 7.

### Folded Todos
None.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase Scope and Locked Requirements
- `.planning/ROADMAP.md` — Phase 7 goal, success criteria, and dependencies.
- `.planning/REQUIREMENTS.md` — AUD-01 through AUD-04.
- `.planning/PROJECT.md` — project architecture, API-first boundary, strict validation posture, and v1.1 compatibility goal.
- `.planning/STATE.md` — current milestone position and prior phase decisions.
- `.planning/phases/05-security-and-http-controls/05-CONTEXT.md` — locked route protection, token separation, and HTTP-control decisions.
- `.planning/phases/06-canonical-incident-api-operation-parity/06-CONTEXT.md` — incident API surface and lifecycle mutation decisions.

### Implementation Context
- `app/domain/events.py` — `NormalizedEvent`, `EventType`, `Severity` contracts.
- `app/domain/incidents.py` — `DecisionContext`, bounded Pydantic discipline, `IncidentStatus`, `IncidentListFilters`.
- `app/processing/ingress.py` — `Icinga2DecisionProcessor`, `_submit_notifications`, ingress decision envelope.
- `app/processing/incident_manager.py` — `IncidentManager.apply_problem`, `IncidentAggregationResult`, `NoDispatchReason`.
- `app/processing/lifecycle.py` and `app/processing/lifecycle_worker.py` — recovery/expiration lifecycle paths.
- `app/persistence/incidents.py` — atomic upsert patterns, cursor pagination helpers.
- `app/persistence/models.py` — SQLAlchemy declarative base and `Incident` model conventions.
- `app/middleware/classification.py` — route-class registration pattern for auth/rate-limit inheritance.
- `app/config/settings.py` — strict Pydantic settings pattern and `CORRELIA_` env prefix.
- `migrations/` — Alembic migration conventions.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `app.domain.incidents.DecisionContext` — template for bounded, versioned, strict Pydantic JSONB models.
- `app.processing.logging.safe_log_extra` — safe structured logging without leaking payloads/tokens.
- `app.persistence.incidents.list_incidents` — cursor pagination implementation to mirror for audit listing.
- `app.middleware.classification.ROUTE_CLASS_PREFIXES` — explicit route classification for Phase 5 auth/rate-limit inheritance.
- `app.api.routers.incidents` — pattern for read-only operator endpoints with filter dependencies.

### Established Patterns
- FastAPI routers under canonical `/v1` paths; no versioning shim or facade.
- PostgreSQL atomic writes via SQLAlchemy `AsyncSession`; no SELECT-then-INSERT for open incident aggregation.
- Pydantic v2 strict models with `extra="forbid"` for request/response and JSONB contracts.
- Testcontainers-backed pytest for database behavior.
- Compact FastAPI error responses (`{"detail": "..."}`).

### Integration Points
- `app/main.py` includes routers and middleware; register the new audit router here.
- `app/processing/ingress.py` is the natural place to insert audit rows after manager calls return.
- Incident manager and lifecycle manager currently call `session.commit()` internally; this must change so commit ownership moves to ingress.
- Phase 5 middleware (`rate_limit.py`, `size_limit.py`, `security.py`) protects `/v1` operator routes; explicit classification makes this assertable.

</code_context>

<specifics>
## Specific Ideas

- Default raw payload size cap: 64 KiB (configurable).
- Default sort/cursor: `(accepted_at DESC, id DESC)`.
- Time semantics: `accepted_at` (server time, immutable, used for cursor/order/default time filters) vs `event_timestamp` (source time, filter/display only).
- Redaction version: start at 1; stored in metadata for audit comparability.
- `notification_intent` not `submitted`: audit row is written pre-commit, before TaskRunner submission.
- No incident-scoped alias in Phase 7; top-level `/v1/incident-events` is the canonical surface.

</specifics>

<deferred>
## Deferred Ideas

- **Phase 9 notification delivery result audit:** Actual plugin delivery outcomes (SMTP exception, retry, final delivery timestamp) belong in a separate notification-result table, not as an update to the append-only `incident_events` row.
- **Phase 10 audit metrics:** Low-cardinality Prometheus metrics for audit writes, read latency, and raw-payload truncation events.
- **Phase 10 audit log safety:** Structured logging for audit write failures and inspection access.
- **Future advanced correlation:** JSONB GIN indexes or full-text search on audit rows if operator query patterns justify it.

### Reviewed Todos (not folded)
None.

</deferred>

---

*Phase: 7-Incident Event Audit Trail*
*Context gathered: 2026-06-18*
