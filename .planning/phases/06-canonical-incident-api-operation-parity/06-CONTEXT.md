# Phase 6: Canonical Incident API Operation Parity - Context

**Gathered:** 2026-06-17
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 6 extends canonical `/v1/incidents` so Vigilo-shaped list, detail, acknowledgement, and close workflows work on the existing Correlia surface without downgrading the richer incident model or adding a separate `/api/v1` facade. The existing cursor-based listing, explicit `POST /ack`, and explicit `POST /close` endpoints remain unchanged; this phase adds Vigilo-compatible `limit`/`offset` pagination, an `ACKNOWLEDGED` compatibility filter/mutation alias, `PATCH`/`DELETE` status mutations, and deterministic rejection of summary mutation.

</domain>

<decisions>
## Implementation Decisions

### Offset Pagination and List Metadata
- **D-01:** Canonical `GET /v1/incidents` supports both cursor pagination (existing default) and offset pagination. When `offset` is supplied, the response is an offset-based page; when only `cursor` is supplied, cursor pagination is used.
- **D-02:** The list response always includes `items`, `total`, `limit`, and `offset` fields. For cursor-driven requests, `total`, `limit`, and `offset` are present (with `offset` reflecting the implied position or `0`) so the schema is stable for Vigilo clients.
- **D-03:** When both `cursor` and `offset` are supplied, cursor pagination wins. The `offset` parameter is ignored and `next_cursor` is populated as usual.
- **D-04:** For offset pagination, compute the total matching count so Vigilo clients receive accurate `total`/`limit`/`offset` metadata.

### ACKNOWLEDGED Status Semantics
- **D-05:** `ACKNOWLEDGED` is a compatibility status alias, not a new canonical `IncidentStatus` or database value. It maps to `acknowledged_at IS NOT NULL` and `acknowledged_by IS NOT NULL` while canonical `status` remains `OPEN`.
- **D-06:** `GET /v1/incidents?status=ACKNOWLEDGED` returns open incidents where `acknowledged_at`/`acknowledged_by` are set.
- **D-07:** `GET /v1/incidents?status=OPEN` continues to include acknowledged incidents (Correlia lifecycle view). Status filters are not mutually exclusive.
- **D-08:** **Filter contract:** the canonical `status` query parameter continues to accept existing Correlia values (`OPEN`, `RESOLVED`, `CLOSED`) and additionally accepts derived `ACKNOWLEDGED`. The compatibility filter surface focuses on `OPEN`, `ACKNOWLEDGED`, and `CLOSED`; `RESOLVED` remains available for canonical use.
- **D-09:** `PATCH /v1/incidents/{id}` with `{"status": "ACKNOWLEDGED"}` calls the existing `ack_open_incident` path, records the compatibility operator/reason defaults, and returns the incident with canonical `status: OPEN` and the existing `acknowledgement` object populated.

### Status Mutation Aliases
- **D-10:** `PATCH /v1/incidents/{id}` accepts only `ACKNOWLEDGED` and `CLOSED` status mutations. `OPEN` is not a meaningful target from a Vigilo client.
- **D-11:** `DELETE /v1/incidents/{id}` maps to `close_open_incident` with the compatibility default operator and reason.
- **D-12:** Existing explicit `POST /v1/incidents/{id}/ack` and `POST /v1/incidents/{id}/close` endpoints remain unchanged and continue to require caller-supplied operator/reason.
- **D-13:** Compatibility mutations (`PATCH` and `DELETE`) always use `operator="vigilo-compat"` and `reason="vigilo-compat"` because the `status`-only PATCH body does not accept caller-supplied operator or reason.

### Summary Mutation Rejection
- **D-15:** `PATCH /v1/incidents/{id}` accepts only a `status` field. Any body containing other fields (including `summary`) is rejected with HTTP `422`.
- **D-16:** The deterministic `422` detail for unsupported PATCH fields is `"summary mutation is not supported"`.
- **D-17:** An empty PATCH body or a body missing `status` returns `422` with detail `"status is required"`.

### Claude's Discretion
- Preserve the existing `IncidentDetailResponse` schema; do not down-project fields for compatibility.
- Implement the offset pagination helper in the existing persistence layer without removing cursor support.
- Keep `RESOLVED` as a canonical status value for recovery-driven transitions; do not expose it in compatibility PATCH mutations.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase Scope and Locked Requirements
- `.planning/ROADMAP.md` — Phase 6 goal, success criteria, and dependency on Phase 5.
- `.planning/REQUIREMENTS.md` — API-01 through API-07 and out-of-scope compatibility constraints.
- `.planning/PROJECT.md` — project architecture, API-first boundary, strict validation posture, and v1.1 compatibility goal.
- `.planning/STATE.md` — current milestone position and locked v1.1 roadmap decisions.
- `.planning/phases/05-security-and-http-controls/05-CONTEXT.md` — locked route protection, token separation, and HTTP-control decisions that Phase 6 builds on.

### Compatibility Target
- `VIGILO_COMPATIBILITY.md` §1 — original incident API compatibility target. **Superseded:** Phase 6 implements parity on canonical `/v1/incidents` only; no `/api/v1/incidents` facade or down-projection.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `app/api/routers/incidents.py` — existing `GET /v1/incidents`, `GET /v1/incidents/{id}`, `POST /ack`, and `POST /close` endpoints. Add `PATCH`/`DELETE` handlers and extend the list filter dependency here.
- `app/domain/incidents.py` — `IncidentListFilters` already supports `status`, `severity`, `rule_name`, `limit`, and `cursor`. Add `offset` and derive `ACKNOWLEDGED` filter semantics here or in the repository.
- `app/domain/incidents.py` — `IncidentListResponse` currently has `items` and `next_cursor`. Extend it to include `total`, `limit`, and `offset`.
- `app/persistence/incidents.py` — `list_incidents` implements cursor pagination. Add an offset-pagination branch that computes `total` and returns a page by offset/limit.
- `app/persistence/incidents.py` — `ack_open_incident` and `close_open_incident` are the canonical lifecycle paths; compatibility mutations reuse them.
- `app.processing.logging.safe_log_extra` — use for safe structured logs on compatibility mutations.

### Established Patterns
- FastAPI routers live under canonical `/v1` paths; no facade or versioning shim is planned.
- Existing list response uses cursor pagination ordered by `last_update_time desc, id desc`. Preserve this ordering for offset pagination.
- Explicit operator endpoints require caller-supplied `operator`/`reason`; compatibility mutations supply deterministic defaults.
- Idempotent lifecycle operations return the current incident state on repeat calls rather than errors.
- Tests use `httpx.ASGITransport` with `create_app(...)` injection; Phase 6 tests can exercise new endpoints without running Uvicorn.

### Integration Points
- `app/main.py` includes the incidents router at `/v1/incidents`; no new router registration is needed.
- Phase 5 auth/rate/size controls already protect `/v1/incidents`; new endpoints inherit that protection automatically.
- The incident response model is shared across list and detail; extending it affects both endpoints consistently.

</code_context>

<specifics>
## Specific Ideas

- Keep response schemas rich: do not strip Correlia fields for Vigilo clients.
- Use deterministic default actor/reason strings (`vigilo-compat`) so audit context is traceable.
- Return `422 {"detail":"summary mutation is not supported"}` for unsupported PATCH fields; match the compact error style from Phase 5.
- For `status=ACKNOWLEDGED` filtering, translate to a SQL condition on `acknowledged_at IS NOT NULL` rather than adding a status enum value.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 6-Canonical Incident API Operation Parity*
*Context gathered: 2026-06-17*
