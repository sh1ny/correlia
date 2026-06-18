---
phase: 07-incident-event-audit-trail
plan: "02"
subsystem: audit-write-integration
tags: [postgres, sqlalchemy, pydantic, hmac, redaction, audit, ingress, transaction]

requires:
  - phase: 07-incident-event-audit-trail
    provides: audit schema, ORM model, redaction, HMAC, insert_incident_event helper
    plan: 07-01

provides:
  - ingress-owned single transaction for accepted events (incident/audit write + post-commit notification)
  - commit-free IncidentAggregationResult and LifecycleResult contracts with notification_intent
  - audit summary builders for PROBLEM, RECOVERY, and NOOP accepted paths
  - audit-row dependency-boundary test enforcing AUD-03 (observational only)
  - operator/background-sweep regression coverage proving incident_events stays empty

affects:
  - 07-03-incident-event-audit-trail

tech-stack:
  added: []
  patterns:
    - Single ingress-owned AsyncSession per accepted event
    - Audit summary derived from manager result objects, never from stored audit rows
    - Notification submission after commit, audit rows record intent only
    - Fail-fast RuntimeError on accepted event without sessionmaker

key-files:
  created: []
  modified:
    - app/processing/incident_manager.py
    - app/processing/lifecycle.py
    - app/processing/ingress.py
    - app/main.py
    - tests/test_incident_manager.py
    - tests/test_lifecycle_repository.py
    - tests/test_ingress_router.py
    - tests/test_metrics_api.py
    - tests/test_incidents_api.py
    - tests/test_lifecycle_expiration.py

key-decisions:
  - notification_intent is the manager contract for dispatch signaling; notification_triggered/failed/results are derived post-commit in ingress.
  - LifecycleResult.notification_intent is always "no_dispatch" (recovery never triggers notifications per D-03).
  - Accepted events without a sessionmaker fail fast with a RuntimeError matching "audit" instead of silently dropping AUD-02 writes.
  - Audit summary builders (_build_problem_audit_summary, _build_recovery_audit_summary, _build_noop_audit_summary) are ingress-private helpers; they consume manager result objects only.
  - _incident_ids_for_audit caps to 20 and sets incident_ids_truncated per D-18/D-14.
  - Accepted-path tests pass a real Testcontainers session_factory to the test helper build_icinga2_processor and create_app; rejection / 422 paths remain DB-free because ingress short-circuits before audit writes. The fail-fast test bypasses the wrapper entirely by calling _real_build_icinga2_processor directly with sessionmaker=None.
  - IncidentEvent.__table__.delete() in test_incidents_api and TRUNCATE incident_events, incidents in test_lifecycle_expiration ensure the zero-count audit assertions are not invalidated by leaked rows.

requirements-completed:
  - AUD-02
  - AUD-03
  - AUD-04

duration: ~60min
completed: 2026-06-18
status: complete
---

# Phase 7 Plan 2: Ingress Transaction Refactor and Audit Write Integration


## Performance

- **Duration:** ~60 min (continuation from initial Task 1 commit)
- **Started:** 2026-06-18T14:20Z (Task 1)
- **Completed:** 2026-06-18T15:35Z (Task 3)
- **Tasks:** 3
- **Files modified:** 10

## Accomplishments

- **Task 1 (commit-ownership refactor):** `IncidentManager.apply_problem` and `LifecycleManager.resolve_for_event` no longer call `self._session.commit()` or submit notification tasks. `IncidentAggregationResult` no longer carries `notification_triggered/failed/results`; it adds a `notification_intent: Literal["dispatch_planned", "no_dispatch"]` field. `LifecycleResult` gains `notification_intent: Literal["no_dispatch"]`. `acknowledge`, `manual_close`, and `expire_stale_batch` keep their own commits because they are not accepted source-event audit paths. Direct manager tests prove the transaction is deferred by opening an independent `AsyncSession` and verifying the row is not visible until the caller commits.
- **Task 2 (audit-write integration):** `Icinga2DecisionProcessor.process_payload` now owns one `AsyncSession` per accepted event. It calls `IncidentManager.apply_problem` (PROBLEM) or `LifecycleManager.resolve_for_event` (RECOVERY), or neither (no-rule-engine / no-matching-rule), then builds the `AuditDecisionSummary` from manager result objects via `_build_problem_audit_summary`, `_build_recovery_audit_summary`, or `_build_noop_audit_summary`. It runs `redact_payload(payload.model_dump(mode="json"), max_bytes=..., hmac_key=...)`, calls `insert_incident_event` with the pre-redacted fields, commits once, and then calls `_submit_notifications` post-commit. Rejection (`Icinga2Rejection`) returns early and writes zero audit rows. Accepted events without a sessionmaker fail fast with `RuntimeError("audit configuration is incomplete…")`. `Icinga2DecisionProcessor.__init__` and `build_icinga2_processor` accept required keyword-only `audit_raw_payload_max_bytes` and `audit_raw_payload_hmac_key`; `app.main.lifespan` passes `Settings.audit_raw_payload_max_bytes` and `Settings.audit_raw_payload_hmac_key` into the default processor builder. The static dependency test is renamed to `test_processing_ingress_dependency_boundaries_for_audit`: ingress is allowed to import `app.persistence.audit` and `app.domain.audit`, while `incident_manager`, `lifecycle`, `persistence.incidents`, and `lifecycle_worker` are explicitly forbidden from importing audit persistence, audit domain, or `IncidentEvent`. `test_no_rule_engine_accepted_event_writes_noop_audit_row` uses the real `session_factory` and asserts exactly one `incident_events` row with `decision_kind="noop"` in `decision_summary`, empty `incident_ids`, and `notification_intent="no_dispatch"`. `test_accepted_event_without_sessionmaker_fails_fast_for_audit` calls the processor directly (the HTTP router wraps errors as 500) to assert the precise `RuntimeError` message.
- **Task 3 (observational audit regression):** `test_incidents_api.session_factory` fixture clears `Incident` and `IncidentEvent` in both setup and teardown. `test_lifecycle_expiration.db_session` fixture truncates `incident_events` alongside `incidents`. The operator mutation tests (`test_ack_is_idempotent_and_keeps_incident_open`, `test_manual_close_is_idempotent_and_frees_open_slot`, `test_patch_acknowledges_with_vigilo_defaults_and_is_idempotent`, `test_patch_close_and_delete_close_with_vigilo_defaults_are_idempotent`) and the lifecycle sweep test (`test_expiration_uses_database_time_and_rule_window`) assert the `incident_events` row count remains zero after the non-accepted-event paths complete.

## Task Commits

1. **Task 1: Move manager commit ownership to ingress result contracts** — `32f4bed`
2. **Task 2: Write exactly one audit row inside each accepted ingress transaction** — `3e0bc92`
3. **Task 3: Prove audit remains observational on operator and sweep paths** — `99431a2`

## Files Modified

- `app/processing/incident_manager.py` — `IncidentAggregationResult` gains `notification_intent`; loses `notification_triggered/failed/results`. `apply_problem` no longer commits or submits notifications; helper methods removed.
- `app/processing/lifecycle.py` — `LifecycleResult` gains `notification_intent="no_dispatch"`. `resolve_for_event` no longer commits. `acknowledge`, `manual_close`, `expire_stale_batch` keep their commits.
- `app/processing/ingress.py` — `Icinga2DecisionProcessor.__init__` and `build_icinga2_processor` accept required `audit_raw_payload_max_bytes` and `audit_raw_payload_hmac_key`. `process_payload` owns one `AsyncSession`, calls managers, builds audit summary, runs `redact_payload`, calls `insert_incident_event`, commits once, then submits notifications post-commit. New private builders: `_build_problem_audit_summary`, `_build_recovery_audit_summary`, `_build_noop_audit_summary`, `_incident_ids_for_audit`.
- `app/main.py` — `lifespan` passes `Settings.audit_raw_payload_max_bytes` and `Settings.audit_raw_payload_hmac_key` into `build_icinga2_processor`.
- `tests/test_incident_manager.py` — updated assertions to `notification_intent`; added `test_apply_problem_defers_commit_to_caller` and `test_incident_manager_defers_commit_and_notification_submit_to_caller`.
- `tests/test_lifecycle_repository.py` — added `test_resolve_for_event_defers_commit_to_caller` and `test_lifecycle_manager_source_defers_commit_to_caller`.
- `tests/test_ingress_router.py` — `session_factory` cleanup now `TRUNCATE incident_events, incidents`. Added `_count_audit_rows` helper and a local `build_icinga2_processor` test helper that injects default audit kwargs. Aggregation test asserts 4 audit rows. `test_processing_ingress_dependency_boundaries_for_audit` allows ingress to import audit symbols and forbids it from `incident_manager`/`lifecycle`/`incidents`/`lifecycle_worker`. New `test_no_rule_engine_accepted_event_writes_noop_audit_row` and `test_accepted_event_without_sessionmaker_fails_fast_for_audit`.
- `tests/test_metrics_api.py` — `InstrumentedProcessor` constructions accept the new audit kwargs; persistence-layer functions and audit insert are monkeypatched to no-ops so the fake session can satisfy the new ingress transaction path; payloads are real `Icinga2WebhookPayload` objects.
- `tests/test_incidents_api.py` — `session_factory` fixture clears `Incident` and `IncidentEvent` in setup and teardown; operator ACK/CLOSE and PATCH/DELETE compatibility tests assert `incident_events` row count remains zero.
- `tests/test_lifecycle_expiration.py` — `db_session` fixture truncates `incident_events` alongside `incidents`; sweep test asserts `incident_events` row count remains zero.

## Decisions Made

- The `no_dispatch_reason` field in `IncidentAggregationResult` is typed as `str | None` (enums coerced via `.value` at the boundary) to keep the audit summary Pydantic-validator-friendly.
- Audit summary builders are module-private helpers in `app.processing.ingress` rather than in `app.persistence.audit` so that audit persistence stays observational; the builders consume manager result objects only.
- All accepted-event tests pass a real Testcontainers `session_factory` to the test helper `build_icinga2_processor` and `create_app`; only rejection/422 paths remain DB-free because ingress short-circuits before audit writes. The fail-fast test bypasses the wrapper entirely by calling `_real_build_icinga2_processor` directly with `sessionmaker=None` to assert the misconfiguration `RuntimeError`.
- The HTTP router wraps processor errors as 500, so the fail-fast audit test calls `processor.process_payload` directly to assert the precise `RuntimeError` message.
- The dependency boundary test permits only `app.processing.ingress` to import audit persistence/domain; `incident_manager`, `lifecycle`, `persistence.incidents`, and `lifecycle_worker` are explicitly checked to not import `app.persistence.audit`, `app.domain.audit`, or `IncidentEvent`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Stale monkeypatch on `record_notification_attempt`**
- **Found during:** Task 1
- **Issue:** `tests/test_incident_manager.py::test_apply_problem_reports_updated_threshold_crossed_then_already_notified` monkeypatched `app.processing.incident_manager.record_notification_attempt`, which no longer exists after removing the notification-submission helper.
- **Fix:** Removed the monkeypatch and the unused `attempts` list from the test.
- **Files modified:** `tests/test_incident_manager.py`
- **Verification:** `pytest tests/test_incident_manager.py -q` → 8 passed.

**2. [Rule 1 - Bug] `IncidentAggregationResult` enum leaked into Pydantic strict model**
- **Found during:** Task 1
- **Issue:** Returning a `NoDispatchReason` enum from `apply_problem` would conflict with the Pydantic `BoundedNoDispatchReason = Annotated[str, ...]` validator in `app.domain.audit`.
- **Fix:** Typed `no_dispatch_reason: str | None` on `IncidentAggregationResult` and coerce via `.value` at the boundary.
- **Files modified:** `app/processing/incident_manager.py`
- **Verification:** `AuditDecisionSummary.model_validate(summary.model_dump(mode="json"))` succeeds for problem, recovery, and noop summaries.

**3. [Rule 2 - Critical] Audit-row-count assertions need clean fixtures**
- **Found during:** Task 2 / Task 3
- **Issue:** `incident_events` has no FK cascade from `incidents` (correlation is JSONB), so existing TRUNCATE/DELETE fixtures left audit rows from prior tests.
- **Fix:** `test_incidents_api.session_factory` now executes `IncidentEvent.__table__.delete()` in both setup and teardown; `test_lifecycle_expiration.db_session` now truncates `incident_events, incidents`.
- **Files modified:** `tests/test_incidents_api.py`, `tests/test_lifecycle_expiration.py`
- **Verification:** Zero-count audit assertions pass deterministically.

**4. [Rule 1 - Bug] Fail-fast test bypasses helper to avoid wrapper interference**
- **Found during:** Task 2
- **Issue:** The `build_icinga2_processor` test helper injects default audit kwargs but does not substitute `sessionmaker`; to guarantee no helper interference the fail-fast test must call `_real_build_icinga2_processor` directly with `sessionmaker=None`.
- **Fix:** The fail-fast test calls `_real_build_icinga2_processor(sessionmaker=None, audit_raw_payload_max_bytes=1024, audit_raw_payload_hmac_key="test-audit-hmac")` directly to bypass the test helper and ensure the misconfiguration `RuntimeError` is raised.
- **Files modified:** `tests/test_ingress_router.py`
- **Verification:** `pytest tests/test_ingress_router.py::test_accepted_event_without_sessionmaker_fails_fast_for_audit` passes.

**5. [Rule 2 - Critical] `InstrumentedProcessor` subclass overrides no longer called**
- **Found during:** Task 2
- **Issue:** The new `process_payload` constructs `IncidentManager` / `LifecycleManager` directly instead of calling `_apply_problem` / `_apply_recovery` seams on the subclass, so the test's fake session couldn't satisfy the real manager code paths.
- **Fix:** `test_metrics_api.py` monkeypatches `record_problem_incident`, `resolve_host_recovery`, `resolve_service_recovery` (in `incident_manager` and `lifecycle` modules) and `insert_incident_event` (in `ingress` module) to no-ops / fake results. It also uses real `Icinga2WebhookPayload` objects instead of `{}`.
- **Files modified:** `tests/test_metrics_api.py`
- **Verification:** `pytest tests/test_metrics_api.py -q` passes (3 tests including the metrics-label assertions).

---

**Total deviations:** 5 auto-fixed (1 stale monkeypatch, 1 Pydantic-strict boundary fix, 1 fixture cleanup, 1 wrapper bypass, 1 metrics-test refit)
**Impact on plan:** No scope creep. All plan acceptance criteria met:
- AUD-02: every accepted event writes exactly one `incident_events` row in the same transaction as incident/lifecycle writes.
- AUD-03: manager, lifecycle, persistence.incidents, and lifecycle worker do not import audit persistence or read `incident_events` for decisions.
- AUD-04/D-12: problem rows correlate to their incident; below-threshold/replay/already-notified set `no_dispatch_reason` and `incident_effect` from the manager result.
- AUD-04/D-14: recovery rows store all affected incident IDs (capped to 20 with `incident_ids_truncated`); noop accepted rows store empty `incident_ids`.
- D-01/D-02: `apply_problem` and `resolve_for_event` do not commit; ingress commits once.
- D-03: notification submission occurs after the commit; audit rows record intent only.
- Operator mutations and lifecycle expiration sweeps leave `incident_events` empty.

## User Setup Required

None. All required `Settings` keys (`audit_raw_payload_max_bytes`, `audit_raw_payload_hmac_key`) were already introduced in 07-01.

## Next Phase Readiness

- 07-03 can build the read-only `/v1/incident-events` operator API on top of the existing `list_incident_events` repository helper and `AuditEventListFilters` / `AuditEventResponse` domain models.
- No blockers.
