---
phase: 04-lifecycle-operator-apis-and-operability
plan: 1
subsystem: lifecycle
tags: [postgresql, sqlalchemy, fastapi, pydantic, icinga2, lifecycle]
requires:
  - phase: 01-foundations-contracts-and-database-invariant
    provides: PostgreSQL incident table, lifecycle statuses, partial open-incident unique index, and atomic upsert patterns
  - phase: 02-icinga2-ingress-topology-and-rule-decisions
    provides: Icinga2 RECOVERY normalization and strict ingress envelope patterns
  - phase: 03-problem-aggregation-and-notification-dispatch
    provides: problem-only aggregation manager, threshold state, and TaskRunner notification boundary
provides:
  - PostgreSQL lifecycle repository mutations for host/service recovery, acknowledgement, and manual close
  - LifecycleManager recovery/operator mutation seam
  - RECOVERY ingress branch with lifecycle outcome envelope fields and no notification side effects
affects: [04-lifecycle-operator-apis-and-operability, incidents-api, operability]
tech-stack:
  added: []
  patterns:
    - SQLAlchemy row-lock read-modify-write for affected-set lifecycle shrinking
    - UPDATE RETURNING state transitions guarded by Incident.status == OPEN
    - Strict Pydantic lifecycle outcome for non-secret operator-visible context
key-files:
  created:
    - app/processing/lifecycle.py
    - tests/test_lifecycle_repository.py
  modified:
    - app/domain/incidents.py
    - app/domain/rules.py
    - app/persistence/incidents.py
    - app/processing/ingress.py
    - tests/test_domain_incidents.py
    - tests/test_ingress_router.py
key-decisions:
  - "RECOVERY matching uses current incident affected-object membership, not rule/group rematching."
  - "Service recovery requires both recovered host and service membership before mutation."
  - "Acknowledgement remains metadata on OPEN incidents; manual close transitions OPEN to CLOSED and frees the partial unique index slot."
patterns-established:
  - "LifecycleWriteResult carries mutation effect, prior affected counts, transition target, and removed-object flag."
  - "LifecycleManager is separate from IncidentManager so RECOVERY never enters threshold aggregation or notification dispatch."
requirements-completed: [LCY-01, LCY-02, LCY-03, LCY-04, API-03, API-04]
duration: 9min
completed: 2026-06-09
---

# Phase 04 Plan 01: Lifecycle Mutation Core Summary

**PostgreSQL-backed recovery, acknowledgement, and manual-close lifecycle mutations with RECOVERY ingress routing that bypasses problem aggregation and notification dispatch.**

## Performance

- **Duration:** 9 min
- **Started:** 2026-06-09T14:24:56Z
- **Completed:** 2026-06-09T14:34:20Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments

- Added atomic PostgreSQL repository lifecycle mutations for host recovery, service recovery, acknowledgement, and manual close.
- Added `LifecycleManager` as the processing seam for RECOVERY and operator lifecycle mutations, separate from `IncidentManager.apply_problem()`.
- Extended ingress response envelopes with `lifecycle_outcome`, `recovery_resolution`, and `affected_object_removed` while keeping incident insert/update and notification counts at zero for RECOVERY.
- Added targeted Testcontainers and ingress tests proving affected-set shrinking, final resolution, idempotent ack/close, and no aggregation/notification side effects.

## Task Commits

1. **Task 1 RED: lifecycle repository tests** - `7859804` (test)
2. **Task 1 GREEN: lifecycle repository mutations** - `ed2f43c` (feat)
3. **Task 2 RED: recovery ingress tests** - `590dbec` (test)
4. **Task 2 GREEN: recovery lifecycle routing** - `33f8f37` (feat)

## Files Created/Modified

- `app/processing/lifecycle.py` - New lifecycle manager and result type for recovery, acknowledgement, and manual close flows.
- `tests/test_lifecycle_repository.py` - New Testcontainers-backed repository tests for lifecycle mutations.
- `app/domain/incidents.py` - Added strict `LifecycleOutcome` with non-secret notes validation.
- `app/domain/rules.py` - Added lifecycle fields to `IngressDecisionEnvelope`.
- `app/persistence/incidents.py` - Added `LifecycleWriteResult`, host/service recovery, affected-set shrink/resolve helpers, ack, and manual close.
- `app/processing/ingress.py` - Routed RECOVERY to lifecycle handling and left PROBLEM behavior on `IncidentManager.apply_problem()`.
- `tests/test_domain_incidents.py` - Added lifecycle outcome validation coverage.
- `tests/test_ingress_router.py` - Added RECOVERY ingress lifecycle and no-notification coverage.

## Decisions Made

- RECOVERY uses current affected-object membership so topology/rule drift cannot prevent lifecycle resolution.
- Host recovery removes only the recovered host; service recovery requires host + service membership and removes the recovered pair from the incident sets.
- ACK is retry-safe OPEN metadata using `acknowledged_at = coalesce(existing, now())`; manual close is an OPEN -> CLOSED transition and already-closed retries return the current row.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## Known Stubs

None.

## User Setup Required

None - no external service configuration required.

## Verification

- `uv run pytest tests/test_lifecycle_repository.py tests/test_domain_incidents.py -x` — passed: 41 tests.
- `uv run pytest tests/test_ingress_router.py::test_recovery_routes_to_lifecycle_without_problem_upsert tests/test_ingress_router.py::test_recovery_response_contains_lifecycle_outcome_without_notification tests/test_ingress_router.py::test_recovery_event_does_not_enter_problem_aggregation -x` — passed: 3 tests.
- `uv run pytest tests/test_lifecycle_repository.py tests/test_domain_incidents.py tests/test_ingress_router.py::test_recovery_routes_to_lifecycle_without_problem_upsert tests/test_ingress_router.py::test_recovery_response_contains_lifecycle_outcome_without_notification tests/test_ingress_router.py::test_recovery_event_does_not_enter_problem_aggregation -x` — passed: 44 tests.

## TDD Gate Compliance

- RED commits: `7859804`, `590dbec`.
- GREEN commits: `ed2f43c`, `33f8f37`.

## Next Phase Readiness

Plan 04-02 can build lifecycle expiration on the same lifecycle manager/repository seam. Plan 04-03 REST endpoints can call `ack_open_incident()` and `close_open_incident()` without weakening the open-incident partial unique index invariant.


## Self-Check: PASSED

- Found created files: `app/processing/lifecycle.py`, `tests/test_lifecycle_repository.py`, `.planning/phases/04-lifecycle-operator-apis-and-operability/04-01-SUMMARY.md`.
- Found task commits: `7859804`, `ed2f43c`, `590dbec`, `33f8f37`.
---
*Phase: 04-lifecycle-operator-apis-and-operability*
*Completed: 2026-06-09*
