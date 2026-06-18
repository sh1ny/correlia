---
phase: 07-incident-event-audit-trail
plan: "03"
subsystem: api
tags: [fastapi, operator-api, audit-trail, cursor-pagination, pydantic]

requires:
  - phase: 07-incident-event-audit-trail
    provides: "AuditEventListFilters, AuditEventResponse, AuditEventListResponse, list_incident_events, redact_normalized_event_message_tags, insert_incident_event"
provides:
  - "Read-only GET /v1/incident-events operator endpoint with all D-11 filters"
  - "Bounded response projection with idempotent read-time redaction"
  - "Cursor-first pagination on (accepted_at, id)"
  - "Explicit operator route classification (D-16)"
  - "Integration tests for auth, projection, filters, pagination, correlation, and rate-limit inheritance"
affects: [phase-10-deployment-and-operations]

tech-stack:
  added: []
  patterns: ["Audit router with router-level Security(require_operator_token)", "Bounded projection mapper with idempotent redaction"]

key-files:
  created:
    - "app/api/routers/audit.py"
    - "tests/test_audit_api.py"
  modified:
    - "app/middleware/classification.py"
    - "app/main.py"
    - "tests/test_rate_limit.py"
    - "tests/test_size_limit.py"

key-decisions:
  - "Router-level Security(require_operator_token) dependency matches incidents router pattern (D-09/D-16)"
  - "Idempotent redact_normalized_event_message_tags call in _audit_event_response even though repository also redacts"
  - "try/except ValueError around list_incident_events to return 400 for invalid cursors"
  - "ValidationError from AuditEventListFilters caught and converted to HTTPException(422)"

patterns-established:
  - "Audit router pattern: filter dependency + response mapper + persistence delegation"
  - "Operator route classification: explicit tuple entry in ROUTE_CLASS_PREFIXES"

requirements-completed: [AUD-02, AUD-03, AUD-04]

duration: 28min
completed: 2026-06-18
status: complete
---

# Phase 7 Plan 03: Read-Only Audit API Summary

**Operator-facing GET /v1/incident-events endpoint with D-11 filters, cursor pagination, bounded projection, read-time redaction, and explicit operator route classification**

## Performance

- **Duration:** 28 min
- **Started:** 2026-06-18T17:01:47Z
- **Completed:** 2026-06-18T17:30:06Z
- **Tasks:** 3
- **Files modified:** 6

## Accomplishments

- Created `app/api/routers/audit.py` with `GET /v1/incident-events`, all D-11 filters, cursor-first pagination, bounded response projection, and idempotent read-time redaction
- Registered the audit router in `app/main.py` and classified `/v1/incident-events` as `operator` in `app/middleware/classification.py`
- Added comprehensive integration tests: auth, empty response, bounded projection (redacted message/tags, no raw_payload/normalized_event), all filter types, cursor pagination with multi-page and invalid cursor handling, ingress correlation (incident + no-op), and rate-limit inheritance

## Task Commits

Each task was committed atomically:

1. **Task 1: Create the read-only incident-events router** - `621d74f` (feat)
2. **Task 2: Register the router and classify the route as operator** - `0a4d6a2` (feat)
3. **Task 3: Add endpoint, rate-limit, filter, cursor, and correlation integration tests** - `3773611` (test)

## Files Created/Modified

- `app/api/routers/audit.py` — Read-only operator audit-event router with filter dependency, response mapper, and persistence delegation
- `app/middleware/classification.py` — Added `("/v1/incident-events", "operator")` to `ROUTE_CLASS_PREFIXES`
- `app/main.py` — Imported and registered `audit_router` after `incidents_router`
- `tests/test_audit_api.py` — 7 integration tests: auth, empty response, bounded projection, incident/noop filters, scalar/time filters, cursor pagination, ingress correlation
- `tests/test_rate_limit.py` — Added `test_incident_events_inherit_operator_rate_limit`
- `tests/test_size_limit.py` — Extended `test_classify_path_maps_routes` with `/v1/incident-events` entries

## Decisions Made

- Router-level `Security(require_operator_token)` dependency matches incidents router pattern (D-09/D-16)
- Idempotent `redact_normalized_event_message_tags` call in `_audit_event_response` even though repository also redacts — satisfies plan acceptance criteria
- `try/except ValueError` around `list_incident_events` to return 400 for invalid cursors (mirrors incidents endpoint)
- `ValidationError` from `AuditEventListFilters` construction caught and converted to `HTTPException(422)` to avoid 500s from strict Pydantic validation

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed query parameter typing to match existing pattern**
- **Found during:** Task 1
- **Issue:** Initial implementation used `Annotated[str, Query(...)] | None` instead of `Annotated[str | None, Query(...)] = None` for optional constrained params
- **Fix:** Changed all optional string query params to `Annotated[str | None, Query(...)] = None` matching `app/api/routers/incidents.py` pattern
- **Files modified:** `app/api/routers/audit.py`
- **Verification:** Compile check passes, all tests pass
- **Committed in:** `621d74f` (Task 1 commit)

**2. [Rule 1 - Bug] Added cursor error handling to endpoint**
- **Found during:** Task 1
- **Issue:** `decode_audit_cursor` ValueError from `list_incident_events` would escape as 500
- **Fix:** Wrapped `await list_incident_events(...)` in `try/except ValueError` and raise `HTTPException(400, detail="invalid cursor")`
- **Files modified:** `app/api/routers/audit.py`
- **Verification:** `test_list_incident_events_cursor_pagination_and_invalid_cursor` passes
- **Committed in:** `621d74f` (Task 1 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs)
**Impact on plan:** Both fixes necessary for correctness. No scope creep.

## Issues Encountered

None — plan executed cleanly after auto-fixes.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 7 complete (3/3 plans). All AUD-01 through AUD-04 requirements satisfied.
- Read-only audit surface ready for Phase 10 operational visibility metrics and logging.
- No blockers for Phase 8 (Vigilo Config Migration).

---
*Phase: 07-incident-event-audit-trail*
*Completed: 2026-06-18*
