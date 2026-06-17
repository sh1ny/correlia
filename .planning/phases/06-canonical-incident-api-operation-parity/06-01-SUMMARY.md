---
phase: 06-canonical-incident-api-operation-parity
plan: "01"
subsystem: api

tags:
  - fastapi
  - pydantic-v2
  - sqlalchemy-async
  - incident-api
  - vigilo-compatibility
  - pagination
  - tdd

requires:
  - phase: 05-security-and-http-controls
    provides: Router-level Security(require_operator_token), route-class rate/size middleware, safe_log_extra

provides:
  - Query-only IncidentStatusFilter StrEnum with derived ACKNOWLEDGED
  - Offset pagination branch coexisting with cursor pagination (cursor wins)
  - Always-present total/limit/offset list metadata
  - Derived ACKNOWLEDGED SQL filter on acknowledged_at/acknowledged_by IS NOT NULL
  - Compatibility PATCH status mutation alias with vigilo-compat defaults
  - Compatibility DELETE close alias with vigilo-compat defaults
  - Compact string 422 rejection for summary mutation and missing/invalid status
  - Rich IncidentDetailResponse preserved (window_state added, no down-projection)
  - PostgreSQL-backed regression coverage for API-01 through API-07

affects:
  - 07-incident-event-audit-trail (rich detail response is the parity baseline)
  - 10-deployment-and-operational-visibility (compatibility mutation logs)

tech-stack:
  added: []
  patterns:
    - Separate query-filter StrEnum (IncidentStatusFilter) beside canonical IncidentStatus
    - Two-statement SQL construction (base for COUNT, page for rows) with offset/cursor branches
    - Manual Request body parsing to bypass global RequestValidationError handler for compact 422
    - Reuse of existing ack_open_incident/close_open_incident with vigilo-compat defaults
    - Extra-field check before status dispatch so summary mutation cannot trigger a mutation

key-files:
  created: []
  modified:
    - app/domain/incidents.py
    - app/persistence/incidents.py
    - app/api/routers/incidents.py
    - tests/test_incidents_api.py

key-decisions:
  - "IncidentStatusFilter is a plain StrEnum (query-only); IncidentStatus stays OPEN/RESOLVED/CLOSED per DB CHECK constraint."
  - "offset defaults to None on the filter (discriminator) and to 0 on the response/page (always-present metadata)."
  - "Cursor wins when both cursor and offset are supplied; no-param requests preserve the pre-Phase-6 cursor first-page behavior."
  - "total is computed from a separate base_stmt subquery before cursor/offset/ordering so count and page agree."
  - "ACKNOWLEDGED maps to status='OPEN' AND acknowledged_at IS NOT NULL AND acknowledged_by IS NOT NULL — no DB migration."
  - "PATCH dispatch compares raw strings ACKNOWLEDGED/CLOSED only; IncidentStatusFilter is not used for PATCH targets."
  - "window_state exposed as raw dict[str, Any] (not IncidentWindowState) so migration-defaulted {} rows do not 500."
  - "Compatibility mutations use operator=reason=vigilo-compat and reuse existing idempotent lifecycle functions."

patterns-established:
  - "Query-filter enums live beside canonical enums and never widen the stored status set."
  - "Manual Request parsing is the project pattern for compact-string 422 bodies that must bypass the global validation handler."
  - "Compatibility aliases reuse canonical persistence functions with deterministic defaults rather than parallel lifecycle code."

requirements-completed:
  - API-01
  - API-02
  - API-03
  - API-04
  - API-05
  - API-06
  - API-07

duration: 20min
completed: 2026-06-17
status: complete
---

# Phase 6 Plan 1: Canonical Incident API Operation Parity Summary

**Offset/total list metadata, derived ACKNOWLEDGED filtering, rich detail preservation, compatibility PATCH/DELETE aliases with vigilo-compat defaults, compact 422 summary rejection, and explicit endpoint preservation on canonical `/v1/incidents`.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-06-17T21:06:59Z
- **Completed:** 2026-06-17T21:26:35Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- Added `IncidentStatusFilter` StrEnum (`OPEN`, `ACKNOWLEDGED`, `RESOLVED`, `CLOSED`) as a query-filter-only sibling of the canonical `IncidentStatus`; `IncidentStatus` remains `OPEN`/`RESOLVED`/`CLOSED` so the PostgreSQL `ck_incidents_status` CHECK constraint is unaffected.
- Retyped `IncidentListFilters.status` to `IncidentStatusFilter | None` and added `offset: Annotated[int, Field(ge=0)] | None = None` (None default = cursor-first-page discriminator).
- Extended `IncidentListResponse` with always-present non-null `total: int`, `limit: int`, `offset: int` so Vigilo clients read stable metadata without null checks.
- Added `window_state: dict[str, Any]` to `IncidentDetailResponse` so the detail response is not down-projected relative to Correlia's persisted rich fields.
- Rewrote `list_incidents` with a two-statement construction: a filtered `base_stmt` used for `COUNT(*)` (before cursor/offset/ordering) and a `page_stmt` that branches on cursor (wins), offset, or no-param default. The ACKNOWLEDGED filter maps to `status='OPEN' AND acknowledged_at IS NOT NULL AND acknowledged_by IS NOT NULL`.
- Extended `IncidentListPage` with `total: int` and `offset: int`; the router forwards `page.total`, `filters.limit`, and `page.offset` into the response.
- Added `patch_incident` (`PATCH /v1/incidents/{id}`) accepting `Request`, parsing JSON manually, checking extras before dispatch, comparing raw `status` strings to `ACKNOWLEDGED`/`CLOSED`, and reusing `ack_open_incident`/`close_open_incident` with `vigilo-compat` defaults.
- Added `delete_incident` (`DELETE /v1/incidents/{id}`) mapping directly to `close_open_incident` with `vigilo-compat` defaults and no body parsing.
- Both compatibility handlers emit `safe_log_extra(event="operator_mutation", operator="vigilo-compat", reason="acknowledged"/"manual_close")` audit logs; no raw bodies are logged.
- Added 8 new PostgreSQL-backed tests covering offset metadata + cursor coexistence, derived ACKNOWLEDGED filter, detail rich-field preservation, PATCH ACK idempotency, PATCH/DELETE CLOSED idempotency, compact 422 for missing/invalid status and summary mutation (with rejection-before-dispatch proof), 404 for non-existent UUID, explicit endpoint preservation, and compatibility mutation logs including DELETE.

## Task Commits

Each task was committed once at GREEN (tests + implementation together); RED was verified by running the failing tests before implementing, not by a separate `test(...)` commit:

1. **Task 1: Add list filter, metadata, offset pagination, and detail-preservation coverage** - `8d849d3` (feat)
2. **Task 2: Add compatibility PATCH and DELETE mutations with compact 422 coverage** - `eb01d2e` (feat)

## TDD Execution Record

Both tasks followed the RED-GREEN cycle (RED verified by running failing tests before implementing; GREEN verified by running the same tests after implementing):

- **Task 1 RED:** 3 tests failed — `KeyError: 'total'` (response metadata missing), `422` on `?status=ACKNOWLEDGED` (enum rejected the value), `window_state` missing from detail body.
- **Task 1 GREEN:** All 3 tests passed after domain/persistence/router implementation.
- **Task 2 RED:** 3 tests failed with `405 Method Not Allowed` (no PATCH/DELETE routes) and empty log events; 1 pre-existing-endpoint regression guard passed (expected — POST `/ack`/`/close` already work).
- **Task 2 GREEN:** All 4 tests (including the log test) passed after handler implementation.

No separate `test(...)` RED commits exist in the git log (RED was verified by running failing tests pre-implementation, not committed); each task has one `feat(...)` GREEN commit carrying both tests and implementation. This is a TDD gate-sequence gap — the RED-GREEN cycle was exercised but only the GREEN state was committed.

## Files Created/Modified

- `app/domain/incidents.py` - Added `IncidentStatusFilter` StrEnum; retyped `IncidentListFilters.status`; added `offset` field; extended `IncidentListResponse` with `total`/`limit`/`offset`; added `window_state` to `IncidentDetailResponse`.
- `app/persistence/incidents.py` - Imported `IncidentStatusFilter`; extended `IncidentListPage` with `total`/`offset`; rewrote `list_incidents` with two-statement base/page construction, ACKNOWLEDGED-derived predicate, and offset branch.
- `app/api/routers/incidents.py` - Added `Request` import and `VIGILO_COMPAT_OPERATOR`/`VIGILO_COMPAT_REASON` constants; retyped `status_filter` to `IncidentStatusFilter`; added `offset` query param; forwarded `total`/`limit`/`offset` in list response; added `window_state` to `_incident_response`; added `patch_incident` and `delete_incident` handlers.
- `tests/test_incidents_api.py` - Added 8 tests covering API-01 through API-07.

## Decisions Made

- Followed all D-01 through D-17 locked decisions: cursor/offset coexistence with cursor winning, always-present list metadata, derived ACKNOWLEDGED filter, PATCH/DELETE aliases reusing lifecycle functions with `vigilo-compat` defaults, idempotent mutations, summary-mutation rejection, and explicit endpoint preservation.
- Chose raw `dict[str, Any]` for `window_state` on `IncidentDetailResponse` instead of the strict `IncidentWindowState` model: migration 0002 defaults existing rows to `{}`, which would fail `IncidentWindowState` validation (it requires non-empty `window_started_at`/`window_ended_at`) and turn GET/list into 500s. Raw dict preserves the rich field without a strict-shape runtime hazard.
- Reused `"status is required"` for all present-but-invalid PATCH `status` values (`OPEN`, `RESOLVED`, `UNKNOWN`, non-string) per the research Open Question 4 recommendation, keeping one consistent message for all "status not acceptable" cases.
- PATCH check order: parse JSON → require dict → reject extras (`any(key != "status")`) → validate `status` string → only then open session and dispatch. This guarantees `{"status":"ACKNOWLEDGED","summary":"x"}` returns 422 without acknowledging.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing critical functionality] Added `window_state` to `IncidentDetailResponse`**
- **Found during:** Task 1 RED phase
- **Issue:** The plan's Task 1 behavior and acceptance criteria name `window_state` as a required rich field in the detail response, but `IncidentDetailResponse` did not expose it (the ORM `Incident` model has a `window_state` JSONB column from migration 0002). API-03's intent ("rich incident fields preserved", "not down-projected") required the stored rich field to be present.
- **Fix:** Added `window_state: dict[str, Any]` to `IncidentDetailResponse` and mapped `dict(incident.window_state or {})` in `_incident_response`. Used raw `dict` rather than `IncidentWindowState` because migration 0002 defaults rows to `{}`, which fails the strict model's required `window_started_at`/`window_ended_at` fields.
- **Files modified:** `app/domain/incidents.py`, `app/api/routers/incidents.py`
- **Verification:** `test_incident_detail_preserves_rich_fields_for_compatibility` asserts `window_state` is present and is a dict; full suite passes.
- **Commit:** `8d849d3`

**2. [Rule 2 - Missing critical functionality] Added compatibility mutation log test not in plan verify expression**
- **Found during:** Task 2 RED phase
- **Issue:** The plan's `<verify>` expression `-k "patch_acknowledges or patch_close or reject_summary or explicit_ack"` does not select `test_compatibility_mutations_emit_safe_json_logs`, which the acceptance criteria require (operator=vigilo-compat, reason=acknowledged/manual_close, no raw bodies). An implementation that forgets to log DELETE would still satisfy the plan's verify commands.
- **Fix:** Added `test_compatibility_mutations_emit_safe_json_logs` exercising PATCH ACK, PATCH CLOSED, and DELETE close; ran the full file (14 passed) in addition to the plan's targeted expressions.
- **Files modified:** `tests/test_incidents_api.py`
- **Verification:** Full `tests/test_incidents_api.py` passes (14 passed); log test asserts effect sequence `["acknowledged", "closed", "closed"]`, incident IDs, `operator="vigilo-compat"`, `reason` set `{"acknowledged", "manual_close"}`, and no raw-body fragments in logs.
- **Commit:** `eb01d2e`

### Notes

- The plan's Task 1 behavior prose references `first_event_time` as a rich field. The ORM `Incident` model has no `first_event_time` column; the equivalent stored field is `start_time`. The detail regression test asserts `start_time` (the actual persisted field) alongside `last_update_time`, `created_at`, and `updated_at`. This is treated as behavior-prose imprecision rather than a deviation requiring a new field, because API-03's intent ("Correlia's rich incident fields unchanged") is satisfied by the existing rich fields plus the newly-exposed `window_state`.

### Process Deviations

**3. [Process] TDD RED commits not separated from GREEN commits**
- **Found during:** Summary self-check
- **Issue:** The plan marks both tasks `tdd="true"`, which calls for a RED `test(...)` commit (failing tests) followed by a GREEN `feat(...)` commit (implementation). Each task was instead committed once at GREEN with tests and implementation together. The RED-GREEN cycle was exercised (failing tests were run and observed before implementing), but only the GREEN state is in the git log.
- **Impact:** The git-log gate sequence (`test` then `feat`) is absent. This does not affect correctness — all tests pass and the implementation is complete — but it is a TDD process gap from the plan's `tdd="true"` designation.
- **Commits affected:** `8d849d3` (Task 1), `eb01d2e` (Task 2)

**Total deviations:** 3 — 2 auto-fixed (2 Rule 2 missing-critical) + 1 process (TDD RED-commit separation). **Impact:** The two Rule 2 deviations strengthen API-03 compliance (rich field preservation) and API-04/API-05 audit-log acceptance coverage without changing the plan's architectural scope. The process deviation does not affect correctness; all 14 tests pass.

## Authentication Gates

None — Phase 5 router-level `Security(require_operator_token)` is inherited by the new PATCH/DELETE handlers automatically; tests disable auth via `api_auth_enabled=False` in `_settings()`.

## Known Stubs

None — no placeholder, mock, or no-op code was shipped. All compatibility mutations reuse the existing idempotent `ack_open_incident`/`close_open_incident` persistence functions.

## Threat Flags

None — no new network endpoints, auth paths, file access patterns, or schema changes at trust boundaries beyond what the plan's threat model already covers. The new PATCH/DELETE handlers inherit the router-level operator-token auth (T-06-01-S), use parameterized SQLAlchemy and manual body parsing with compact 422 rejection (T-06-01-T1/T2/E), emit only safe-log-allowlisted fields (T-06-01-R/I), and rely on Phase 5 rate/size middleware (T-06-01-D). No new packages were installed (T-06-01-SC).

## User Setup Required

None — no external service configuration required. All changes are pure code within the existing FastAPI/SQLAlchemy/Pydantic stack.

## Next Phase Readiness

- API-01 through API-07 are complete; Phase 6 is fully implemented.
- The canonical `/v1/incidents` surface now supports Vigilo-shaped list, detail, acknowledgement, and close workflows without a facade and without down-projecting Correlia's rich model.
- The `IncidentStatusFilter` pattern and manual-PATCH-parse pattern are reusable for future compatibility API surfaces.

## Self-Check: PASSED

- [x] Key modified files exist: `app/domain/incidents.py`, `app/persistence/incidents.py`, `app/api/routers/incidents.py`, `tests/test_incidents_api.py`
- [x] Commits exist: `8d849d3` (Task 1), `eb01d2e` (Task 2)
- [x] Targeted automated checks pass:
  - `uv run pytest tests/test_incidents_api.py -q -k "offset_metadata or acknowledged_filter or detail_preserves"` → 3 passed
  - `uv run pytest tests/test_incidents_api.py -q -k "patch_acknowledges or patch_close or reject_summary or explicit_ack or compatibility_mutations"` → 4 passed (the plan's verify expression omits `compatibility_mutations`; the full-file run below is the authoritative check)
  - `uv run pytest tests/test_incidents_api.py -q` → 14 passed

---
*Phase: 06-canonical-incident-api-operation-parity*
*Completed: 2026-06-17*
