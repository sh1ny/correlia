---
phase: 06-canonical-incident-api-operation-parity
verified: 2026-06-17T22:05:00Z
status: passed
score: 7/7 must-haves verified
behavior_unverified: 0
overrides_applied: 0
decision_coverage:
  honored: 17
  total: 17
  not_honored: []
  blocking: false
  message: "All trackable CONTEXT.md decisions are honored by shipped artifacts."
deviations:
  - kind: process
    severity: info
    id: TDD-RED-COMMIT-GAP
    description: "Both tasks are marked tdd=\"true\" in the plan, which calls for a RED test(...) commit followed by a GREEN feat(...) commit. Each task was instead committed once at GREEN with tests and implementation together. The RED-GREEN cycle was exercised (failing tests were run and observed before implementing) but only the GREEN state is in the git log."
    impact: "No effect on correctness — all 14 tests pass and the implementation is complete. Git-log gate sequence (test then feat) is absent. This is a TDD process gap, not a goal failure."
    commits: ["8d849d3", "eb01d2e"]
  - kind: verify-command
    severity: info
    id: TASK2-REJECT-SUMMARY-TYPO
    description: "The plan's Task 2 <verify> expression uses -k \"reject_summary\", which selects ZERO tests because the actual test name is test_patch_rejects_summary_... (rejects_summary, with an s). pytest -k does substring matching and 'reject_summary' does not match 'rejects_summary'."
    impact: "The plan's targeted Task 2 command under-selects (3 passed, not 4) and silently omits the API-06 summary-rejection test. The executor compensated by running the full file (14 passed) as the authoritative check. API-06 IS verified by the full-file run and by the corrected selector -k \"rejects_summary\" (1 passed, exit 0). The plan command should be corrected to \"rejects_summary\"."
    evidence:
      plan_command: "uv run pytest tests/test_incidents_api.py -q -k \"patch_acknowledges or patch_close or reject_summary or explicit_ack\" -> 3 passed, 11 deselected (reject_summary matched 0)"
      corrected_command: "uv run pytest tests/test_incidents_api.py -q -k \"rejects_summary\" -> 1 passed, 13 deselected, exit 0"
      full_file: "uv run pytest tests/test_incidents_api.py -q -> 14 passed, exit 0"
  - kind: decision-caveat
    severity: info
    id: D09-D13-ACK-NO-REASON-FIELD
    description: "D-09/D-13 state that PATCH ACK records operator AND reason defaults (vigilo-compat). The reused canonical ack_open_incident(session, incident_id, *, operator) signature has NO reason parameter at all — ACK has no close-reason field. ACK stores lifecycle.reason='acknowledged' and lifecycle.operator='vigilo-compat' in decision_context.notes but no 'lifecycle.detail'/'reason default'. D-13's 'reason defaults' is therefore structurally applicable only to the CLOSE path (close_open_incident takes reason=, stored as lifecycle.detail='vigilo-compat')."
    impact: "ACK compatibility mutation records operator=vigilo-compat (verified: acknowledgement.acknowledged_by == 'vigilo-compat') and the log reason='acknowledged', but has no persisted caller-supplied reason because the canonical ACK lifecycle has no reason concept. This is a plan/CONTEXT wording imprecision against the canonical model, not an implementation defect. Tests assert the semantically available fields (acknowledged_by, status OPEN, idempotency) and pass."
    grounding: "app/persistence/incidents.py:1081 ack_open_incident(*, operator) -> _lifecycle_context(reason='acknowledged', operator=operator); no detail= arg. app/persistence/incidents.py:1139 close_open_incident(*, operator, reason) -> _lifecycle_context(reason='manual_close', operator=operator, detail=reason)."
  - kind: prose-imprecision
    severity: info
    id: FIRST-EVENT-TIME-IS-START-TIME
    description: "The plan's Task 1 behavior prose references first_event_time as a rich detail field. The ORM Incident model has no first_event_time column; the equivalent stored field is start_time. The detail regression test asserts start_time alongside last_update_time, created_at, updated_at."
    impact: "API-03 intent (rich Correlia fields preserved) is satisfied by the existing rich fields plus the newly-exposed window_state. No new field required."
---

# Phase 6: Canonical Incident API Operation Parity Verification Report

**Phase Goal:** Vigilo-shaped incident list, detail, acknowledgement, and close workflows work on canonical `/v1/incidents` without downgrading Correlia's richer incident model.
**Verified:** 2026-06-17T22:05:00Z
**Status:** passed (with 4 documented deviations/caveats — none block the goal)
**Re-verification:** No — initial verification

## Goal Achievement

The phase goal IS achieved: the canonical `/v1/incidents` surface now supports Vigilo-shaped list (offset/total metadata + derived ACKNOWLEDGED filter), detail (rich fields preserved, not down-projected), acknowledgement (PATCH alias), and close (PATCH/DELETE alias) workflows on the existing router, reusing canonical lifecycle functions with `vigilo-compat` defaults, while the explicit `/ack` and `/close` endpoints remain unchanged. All 14 PostgreSQL-backed tests pass.

### Observable Truths

Roadmap Success Criteria (SC1–SC5) and PLAN must-have truths (T1–T7) are verified together; each truth maps to one or more requirements (API-0x) and decisions (D-0x).

| # | Truth (Truth / SC / API / D) | Status | Evidence |
| --- | --- | --- | --- |
| 1 | Operators can use Vigilo-supported `status`, `severity`, `rule_name`, `limit`, and `offset` filters; `status` accepts OPEN/ACKNOWLEDGED/RESOLVED/CLOSED while ACKNOWLEDGED is a derived filter alias. (SC1 / API-01 / D-01 D-05 D-08) | ✓ VERIFIED | `IncidentStatusFilter` StrEnum (OPEN/ACKNOWLEDGED/RESOLVED/CLOSED) is query-only; `IncidentStatus` unchanged (OPEN/RESOLVED/CLOSED — DB CHECK constraint safe). `incident_list_filters` declares `offset: Annotated[int \| None, Query(ge=0)] = None`. `list_incidents` maps ACKNOWLEDGED → `status='OPEN' AND acknowledged_at IS NOT NULL AND acknowledged_by IS NOT NULL`. Test `test_list_incidents_acknowledged_filter_is_derived_and_open_includes_acknowledged` passes (exit 0). |
| 2 | Every list response includes items, total, limit, offset, and next_cursor; cursor pagination preserved; cursor wins over offset. (SC2 / API-02 / D-02 D-03 D-04) | ✓ VERIFIED | `IncidentListResponse` has `total/limit/offset` (non-optional int) + `next_cursor`; `IncidentListPage` has `total/offset`. `list_incidents` computes `total` from filtered `base_stmt` BEFORE cursor/offset/ordering; branch order: cursor (wins) → offset → default. Test `test_list_incidents_offset_metadata_and_cursor_coexistence` asserts total=3/limit/offset, offset page next_cursor=null, and cursor+offset → cursor wins. Passes (exit 0). |
| 3 | GET `/v1/incidents/{id}` returns Correlia's rich incident fields unchanged (not down-projected). (SC3 / API-03) | ✓ VERIFIED | `IncidentDetailResponse` carries all rich fields + new `window_state: dict[str, Any]`; `_incident_response` maps `dict(incident.window_state or {})`. Raw dict (not strict `IncidentWindowState`) avoids 500 on migration-0002 default `{}` rows. Test `test_incident_detail_preserves_rich_fields_for_compatibility` asserts affected_hosts/services, decision_context, window_state, acknowledgement, start_time/last_update_time/created_at/updated_at. Passes (exit 0). (Prose: plan said `first_event_time`; actual field is `start_time` — see deviations.) |
| 4 | PATCH `{"status":"ACKNOWLEDGED"}` reuses `ack_open_incident` with operator `vigilo-compat`, returns canonical status OPEN with acknowledgement populated; idempotent. (SC4 / API-04 / D-09 D-13 D-14) | ✓ VERIFIED (behavior) | `patch_incident` accepts `Request`, parses JSON manually, checks extras before dispatch, compares raw `"ACKNOWLEDGED"`, calls `ack_open_incident(operator=VIGILO_COMPAT_OPERATOR)`. Test `test_patch_acknowledges_with_vigilo_defaults_and_is_idempotent` sends PATCH twice, asserts both 200, status OPEN, `acknowledgement.acknowledged_by == "vigilo-compat"`. Passes (exit 0). CAVEAT: ACK has no reason field — see deviations D09-D13-ACK-NO-REASON-FIELD. |
| 5 | PATCH `{"status":"CLOSED"}` and DELETE close incidents with operator+reason `vigilo-compat`; idempotent. (SC4 / API-05 / D-10 D-11 D-13 D-14) | ✓ VERIFIED (behavior) | `patch_incident` CLOSED branch + `delete_incident` both call `close_open_incident(operator=VIGILO_COMPAT_OPERATOR, reason=VIGILO_COMPAT_REASON)`. reason persisted as `lifecycle.detail="vigilo-compat"` (via `_lifecycle_context(reason="manual_close", detail=reason)`); log `reason="manual_close"`. Test `test_patch_close_and_delete_close_with_vigilo_defaults_are_idempotent` asserts PATCH CLOSED x2 + DELETE x2 all 200 with status CLOSED. Passes (exit 0). |
| 6 | Unsupported PATCH fields return 422 `summary mutation is not supported`; missing/invalid status returns 422 `status is required`; summary unchanged. (SC5 / API-06 / D-15 D-16 D-17) | ✓ VERIFIED (behavior) | `patch_incident`: JSON decode/non-dict/missing → 422 "status is required"; `any(key != "status")` → 422 "summary mutation is not supported" (checked BEFORE session/dispatch, so `{"status":"ACKNOWLEDGED","summary":"x"}` cannot acknowledge); OPEN/RESOLVED/UNKNOWN/non-string → 422 "status is required". Test `test_patch_rejects_summary_mutation_and_missing_status_with_compact_422` asserts all 8 missing-status cases + 2 summary cases + 404 for nil UUID + GET summary unchanged + acknowledged_by still null. Passes via full-file + corrected selector `-k "rejects_summary"` (exit 0). |
| 7 | Explicit POST `/ack` and POST `/close` remain available and require caller-supplied operator/reason; do not silently adopt compat defaults. (SC5 / API-07 / D-12) | ✓ VERIFIED (behavior) | `acknowledge_incident` and `close_incident_endpoint` unchanged: `Body(...)` with `IncidentAckRequest`/`IncidentCloseRequest` (required operator/reason). Test `test_explicit_ack_and_close_endpoints_remain_available_alongside_aliases` asserts explicit ack/close 200 with caller operator, and missing-body → 422. Passes (exit 0). |

**Score:** 7/7 truths verified (0 present, behavior-unverified — every behavior-dependent truth had a passing PostgreSQL-backed test).

### Required Artifacts

| Artifact | Expected | Status | Details |
| --- | --- | --- | --- |
| `app/domain/incidents.py` | Query-only `IncidentStatusFilter`; `IncidentListFilters.offset`; `IncidentListResponse.total/limit/offset`; `IncidentDetailResponse.window_state` | ✓ VERIFIED | `IncidentStatusFilter(StrEnum)` with 4 members, no `model_config`/validator/BaseModel; `IncidentListFilters.offset: Annotated[int, Field(ge=0)] \| None = None`; `IncidentListResponse` total/limit/offset non-optional; `IncidentDetailResponse.window_state: dict[str, Any]`; `IncidentStatus` still exactly OPEN/RESOLVED/CLOSED. |
| `app/persistence/incidents.py` | `IncidentListPage.total/offset`; `list_incidents` filtered count + derived ACKNOWLEDGED predicate + offset branch | ✓ VERIFIED | `IncidentListPage` dataclass has `total: int`, `offset: int`; `list_incidents` builds `base_stmt` (apply_filters) → `COUNT(*)` before cursor/offset/ordering; ACKNOWLEDGED → `status='OPEN' AND acknowledged_at IS NOT NULL AND acknowledged_by IS NOT NULL`; cursor/offset/default branches present. |
| `app/api/routers/incidents.py` | List metadata wiring + `patch_incident` + `delete_incident` exports | ✓ VERIFIED | `patch_incident` and `delete_incident` handlers present; `VIGILO_COMPAT_OPERATOR`/`VIGILO_COMPAT_REASON` constants; list endpoint forwards `page.total`/`filters.limit`/`page.offset`; `_incident_response` includes `window_state`. |
| `tests/test_incidents_api.py` | PostgreSQL-backed regression for API-01..API-07 | ✓ VERIFIED | 8 new tests + 6 pre-existing = 14 total; all named plan tests present and passing. |

### Key Link Verification

| From | To | Via | Status | Details |
| --- | --- | --- | --- | --- |
| `app/api/routers/incidents.py` | `app/domain/incidents.py` | `incident_list_filters` accepts `IncidentStatusFilter` and `offset`, constructs `IncidentListFilters` | ✓ WIRED | `incident_list_filters(status_filter: IncidentStatusFilter \| None, ..., offset: ...)` returns `IncidentListFilters(status=status_filter, ..., offset=offset)`. |
| `app/api/routers/incidents.py` | `app/persistence/incidents.py` | list endpoint passes `IncidentListFilters` to `list_incidents` and forwards `page.total` + `page.offset` | ✓ WIRED | `list_incidents_endpoint` calls `list_incidents(session, filters)` then `IncidentListResponse(..., total=page.total, offset=page.offset, ...)`. |
| `app/persistence/incidents.py` | `app/domain/incidents.py` | `list_incidents` compares `filters.status` to `IncidentStatusFilter.ACKNOWLEDGED`; `IncidentStatus` unchanged for stored DB values | ✓ WIRED | `if filters.status == IncidentStatusFilter.ACKNOWLEDGED:` → OPEN + acknowledged predicates; `IncidentStatus.OPEN.value` used for DB writes. |
| `app/api/routers/incidents.py` | `app/persistence/incidents.py` | PATCH/DELETE call `ack_open_incident`/`close_open_incident` with `vigilo-compat` defaults | ✓ WIRED | PATCH ACK → `ack_open_incident(operator=VIGILO_COMPAT_OPERATOR)`; PATCH CLOSED + DELETE → `close_open_incident(operator=VIGILO_COMPAT_OPERATOR, reason=VIGILO_COMPAT_REASON)`. |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
| --- | --- | --- | --- | --- |
| `list_incidents_endpoint` | `page.total` / `page.offset` / `items` | `list_incidents` → `COUNT(*)` on filtered `base_stmt` + `OFFSET/LIMIT` page query against PostgreSQL | Yes (real DB rows via testcontainers PostgresContainer + Alembic upgrade) | ✓ FLOWING |
| `get_incident` / `_incident_response` | `window_state` / `acknowledgement` / rich fields | `get_incident_by_id` → `Incident` ORM row (JSONB `window_state`, `acknowledged_at/by`) | Yes | ✓ FLOWING |
| `patch_incident` / `delete_incident` | `result.incident` | `ack_open_incident` / `close_open_incident` → `UPDATE ... RETURNING` | Yes | ✓ FLOWING |

### Behavioral Spot-Checks

All checks ran against a real PostgreSQL container (testcontainers `postgres:18-alpine`) with Alembic `upgrade head`. Exit codes captured unpiped (no `| tail` masking).

| Behavior | Command | Result | Status |
| --- | --- | --- | --- |
| Task 1: offset metadata + ACKNOWLEDGED filter + detail preservation | `uv run pytest tests/test_incidents_api.py -q -k "offset_metadata or acknowledged_filter or detail_preserves"` | 3 passed, 11 deselected; EXIT_TASK1=0 | ✓ PASS |
| Task 2 (plan expr): patch/close/explicit | `uv run pytest tests/test_incidents_api.py -q -k "patch_acknowledges or patch_close or reject_summary or explicit_ack"` | 3 passed, 11 deselected; EXIT_TASK2=0 — NOTE: `reject_summary` matched 0 tests (typo); see deviations | ✓ PASS (under-selects; API-06 covered by full-file + corrected run) |
| Task 2 (corrected): summary rejection | `uv run pytest tests/test_incidents_api.py -q -k "rejects_summary"` | 1 passed, 13 deselected; EXIT_CORRECTED=0 | ✓ PASS |
| Full file: all 14 tests | `uv run pytest tests/test_incidents_api.py -q` | 14 passed; EXIT_FULL=0 | ✓ PASS |

### Probe Execution

No `scripts/*/tests/probe-*.sh` probes declared for this phase; the plan's verification is pytest-based (covered under Behavioral Spot-Checks). N/A.

### Requirements Coverage

All 7 requirements map to Phase 6 in REQUIREMENTS.md (lines 100–106, currently marked Pending — the orchestrator owns flipping these). No orphaned requirements.

| Requirement | Source Plan | Description | Status | Evidence |
| --- | --- | --- | --- | --- |
| API-01 | 06-01 | List filters status/severity/rule_name/limit/offset + derived ACKNOWLEDGED | ✓ SATISFIED | Truth 1; `IncidentStatusFilter` + `offset` field + ACKNOWLEDGED SQL predicate; test passes. |
| API-02 | 06-01 | List metadata items/total/limit/offset + cursor preserved | ✓ SATISFIED | Truth 2; `IncidentListResponse`/`IncidentListPage` metadata + cursor-wins test passes. |
| API-03 | 06-01 | Detail rich fields preserved | ✓ SATISFIED | Truth 3; `IncidentDetailResponse.window_state` + rich fields; test passes. |
| API-04 | 06-01 | ACK via status mutation alias, operator vigilo-compat default | ✓ SATISFIED | Truth 4; PATCH ACK → `ack_open_incident(operator="vigilo-compat")`; idempotency test passes. |
| API-05 | 06-01 | Close via PATCH/DELETE alias, compat close reason default | ✓ SATISFIED | Truth 5; PATCH CLOSED + DELETE → `close_open_incident(reason="vigilo-compat")`; idempotency test passes. |
| API-06 | 06-01 | Summary mutation → 422 | ✓ SATISFIED | Truth 6; manual PATCH parse + extras-check-before-dispatch + compact 422; full-file + corrected selector pass. |
| API-07 | 06-01 | Explicit /ack and /close remain alongside aliases | ✓ SATISFIED | Truth 7; unchanged `Body(...)` handlers; preservation test passes. |

### Decision Coverage (D-01 through D-17)

Generated via `gsd-tools query check.decision-coverage-verify <phase-dir> <06-CONTEXT.md>` (positional phase-scoped context): **{skipped: false, blocking: false, total: 17, honored: 17, not_honored: [], message: "All trackable CONTEXT.md decisions are honored by shipped artifacts."}** — all 17 D-01..D-17 decisions are honored by shipped artifacts. The per-decision table below is the manual evidence trail.

| Decision | Statement | Status | Evidence |
| --- | --- | --- | --- |
| D-01 | Cursor + offset pagination; offset branch only when offset supplied | ✓ VERIFIED | `list_incidents` branch order: `if cursor` → `elif offset` → `else` default. |
| D-02 | List response always includes items/total/limit/offset | ✓ VERIFIED | `IncidentListResponse` total/limit/offset non-optional int. |
| D-03 | Cursor wins when both supplied | ✓ VERIFIED | cursor branch first; test asserts cursor+offset → cursor page, offset=0. |
| D-04 | Offset pagination computes total matching count | ✓ VERIFIED | `total = COUNT(*)` on filtered `base_stmt` before pagination. |
| D-05 | ACKNOWLEDGED is derived, not stored | ✓ VERIFIED | `IncidentStatus` unchanged; ACKNOWLEDGED only on `IncidentStatusFilter`; SQL predicate on acknowledged_at/by. |
| D-06 | status=ACKNOWLEDGED returns acknowledged open incidents | ✓ VERIFIED | Test asserts only the acked row returned, item status OPEN. |
| D-07 | status=OPEN includes acknowledged incidents | ✓ VERIFIED | Test asserts `{acked, plain} ⊆ open_ids`. |
| D-08 | Filter accepts canonical values + derived ACKNOWLEDGED | ✓ VERIFIED | `IncidentStatusFilter` has OPEN/ACKNOWLEDGED/RESOLVED/CLOSED. |
| D-09 | PATCH ACK calls existing ack path, returns canonical OPEN + acknowledgement | ✓ VERIFIED | `patch_incident` ACK → `ack_open_incident`; test asserts status OPEN + acknowledged_by. (Reason-field caveat — see deviations.) |
| D-10 | PATCH accepts only ACKNOWLEDGED and CLOSED targets | ✓ VERIFIED | Raw-string dispatch to exactly `"ACKNOWLEDGED"`/`"CLOSED"`; OPEN/RESOLVED/UNKNOWN/non-string → 422. |
| D-11 | DELETE maps to compatibility close | ✓ VERIFIED | `delete_incident` → `close_open_incident`; no body parsing. |
| D-12 | Explicit POST ack/close remain unchanged | ✓ VERIFIED | Handlers unchanged with `Body(...)`; preservation test passes. |
| D-13 | Compatibility mutations use operator+reason vigilo-compat | ✓ VERIFIED (with caveat) | CLOSE: operator+reason both `vigilo-compat` (reason persisted as `lifecycle.detail`). ACK: operator `vigilo-compat`; reason N/A (no reason field in canonical ACK). See deviations D09-D13-ACK-NO-REASON-FIELD. |
| D-14 | Compatibility mutations are idempotent | ✓ VERIFIED | Re-ACK/re-close/re-DELETE all return 200 with current state (lifecycle functions return `effect="noop"` for terminal state). |
| D-15 | PATCH accepts only `status`; other fields rejected | ✓ VERIFIED | `any(key != "status" for key in body)` → 422. |
| D-16 | Unsupported PATCH fields → 422 "summary mutation is not supported" | ✓ VERIFIED | Test asserts exact detail string for `{summary}` and `{status,summary}`. |
| D-17 | Empty/missing status → 422 "status is required" | ✓ VERIFIED | Test asserts exact detail for `{}`, non-dict, empty body, malformed JSON, OPEN/RESOLVED/UNKNOWN/non-string. |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| --- | --- | --- | --- | --- |
| (none) | — | No TBD/FIXME/XXX/TODO/HACK/PLACEHOLDER in any modified file | — | Clean. No stubs, no empty implementations, no hardcoded empty data flowing to output. |

### Human Verification Required

None. All truths — including the behavior-dependent ones (idempotency state transitions, 422 rejection-before-dispatch ordering, derived ACKNOWLEDGED filter) — are exercised by passing PostgreSQL-backed tests. No visual/real-time/external-service checks are required.

### Deviations Summary

**Overall verdict: PASS with 4 documented deviations/caveats — none block the phase goal.**

1. **TDD-RED-COMMIT-GAP (process, info):** Both `tdd="true"` tasks were committed once at GREEN (`feat`), not as a RED `test` commit + GREEN `feat` commit. The RED-GREEN cycle was exercised (failing tests run pre-implementation) but the git-log gate sequence is absent. Commits `8d849d3`, `eb01d2e`. No correctness impact.

2. **TASK2-REJECT-SUMMARY-TYPO (verify-command, info):** The plan's Task 2 `<verify>` uses `-k "reject_summary"` which matches 0 tests (actual name is `rejects_summary`). The plan's targeted run therefore reports 3 passed (not 4) and silently omits the API-06 test. The executor compensated with the full-file run (14 passed) and the SUMMARY self-flagged this. Corrected selector `-k "rejects_summary"` → 1 passed, exit 0. API-06 IS verified. The plan command should be corrected.

3. **D09-D13-ACK-NO-REASON-FIELD (decision-caveat, info):** D-09/D-13 mention ACK "reason defaults", but `ack_open_incident` has no `reason` parameter — the canonical ACK lifecycle has no reason concept. ACK records `lifecycle.operator="vigilo-compat"` and log `reason="acknowledged"`; no `lifecycle.detail`. D-13's reason-default applies structurally only to CLOSE (`lifecycle.detail="vigilo-compat"`). Tests assert the semantically available ACK fields and pass. This is a CONTEXT/plan wording imprecision against the canonical model, not an implementation defect.

4. **FIRST-EVENT-TIME-IS-START-TIME (prose-imprecision, info):** Plan Task 1 behavior prose references `first_event_time`; the ORM column is `start_time`. The detail test asserts `start_time`. API-03 intent satisfied. No new field needed.

### Gaps Summary

No gaps. All 7 truths VERIFIED, all 4 artifacts exist+substantive+wired+data-flowing, all 4 key links WIRED, all 7 requirements SATISFIED, all 17 decisions VERIFIED (D-13 with caveat), no blocker anti-patterns, no debt markers, no human verification items. The 4 deviations are process/wording/verify-command issues that do not affect goal achievement.

---

_Verified: 2026-06-17T22:05:00Z_
_Verifier: Claude (gsd-verifier)_
