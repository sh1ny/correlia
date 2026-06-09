---
phase: 04-lifecycle-operator-apis-and-operability
plan: 2
subsystem: lifecycle
tags: [postgresql, sqlalchemy, fastapi, asyncio, lifespan, operability]
requires:
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-01 lifecycle repository mutations, LifecycleManager seam, acknowledgement, manual close, and RECOVERY routing
provides:
  - PostgreSQL database-time stale OPEN incident expiration using per-row rule window facts
  - Lifecycle batch service seam for scheduled expiration sweeps
  - FastAPI lifespan-managed LifecycleWorker with non-secret health state for readiness
  - Worker dependency seam through app state for Plan 05 readiness checks
affects: [04-lifecycle-operator-apis-and-operability, lifecycle, readiness, operability]
tech-stack:
  added: []
  patterns:
    - PostgreSQL func.now stale predicate with JSONB window_seconds and SELECT FOR UPDATE SKIP LOCKED
    - FastAPI lifespan-owned asyncio background worker with safe failure state
    - Lifecycle scheduling stays separate from TaskRunner notification dispatch
key-files:
  created:
    - app/processing/lifecycle_worker.py
    - tests/test_lifecycle_expiration.py
    - tests/test_lifecycle_worker.py
  modified:
    - app/config/settings.py
    - app/persistence/incidents.py
    - app/processing/lifecycle.py
    - app/main.py
    - app/api/deps.py
    - tests/test_task_runner.py
key-decisions:
  - "Stale expiration uses PostgreSQL func.now() and per-incident window_state.window_seconds; application clocks do not decide staleness."
  - "Expired incidents transition OPEN -> CLOSED with lifecycle.reason=expired, never RESOLVED/source_recovery."
  - "LifecycleWorker is owned by FastAPI lifespan and remains separate from TaskRunner notification dispatch."
patterns-established:
  - "expire_stale_incidents() selects stale OPEN rows with SKIP LOCKED, then performs guarded UPDATE RETURNING for terminal mutation."
  - "LifecycleWorker records only healthy, last_sweep_at, last_error_category, and expired_total for readiness-safe health state."
requirements-completed: [LCY-05, LCY-06, OPS-02, OPS-04]
duration: 8min
completed: 2026-06-09
---

# Phase 04 Plan 02: Stale Expiration Worker Summary

**PostgreSQL-time stale incident expiration with a FastAPI lifespan-owned worker and readiness-safe health seam.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-06-09T14:39:01Z
- **Completed:** 2026-06-09T14:46:37Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments

- Added `expire_stale_incidents()` to close stale `OPEN` incidents using PostgreSQL `func.now()` and each row's stored `window_state.window_seconds`.
- Added `expire_stale_batch()` in `app/processing/lifecycle.py` as the lifecycle service seam for scheduled sweeps.
- Added `LifecycleWorker` with start/stop lifecycle, safe health state, failure categorization, and expired-row counters.
- Wired one lifecycle worker into FastAPI lifespan startup/shutdown and exposed `get_lifecycle_worker()` for readiness work in Plan 05.
- Added targeted Testcontainers and lifespan/unit coverage for expiration behavior, non-secret context, worker health, and scheduler boundaries.

## Task Commits

1. **Task 1 RED: stale expiration behavior tests** - `e908888` (test)
2. **Task 1 GREEN: PostgreSQL-time stale expiration** - `c00ebfd` (feat)
3. **Task 2 RED: lifecycle worker behavior tests** - `b2a9273` (test)
4. **Task 2 GREEN: lifespan-managed lifecycle worker** - `0cf1185` (feat)

## Files Created/Modified

- `app/persistence/incidents.py` - Added DB-time stale predicate, SKIP LOCKED candidate selection, guarded CLOSED update, and bounded expired lifecycle context notes.
- `app/processing/lifecycle.py` - Added `expire_stale_batch()` service seam and lifecycle `expired` effect support.
- `app/processing/lifecycle_worker.py` - New lifespan-managed asyncio worker with safe health fields and deterministic shutdown.
- `app/config/settings.py` - Added bounded `lifecycle_scan_interval_seconds` and `lifecycle_batch_size` settings.
- `app/main.py` - Starts one lifecycle worker during lifespan startup and stops it before engine disposal.
- `app/api/deps.py` - Added `get_lifecycle_worker()` dependency for readiness integration.
- `tests/test_lifecycle_expiration.py` - New Testcontainers-backed expiration tests.
- `tests/test_lifecycle_worker.py` - New worker health, failure, lifespan, and scheduler-boundary tests.
- `tests/test_task_runner.py` - Updated `asyncio.create_task` source assertion to allow only TaskRunner and LifecycleWorker.

## Decisions Made

- Expiration closes stale incidents instead of resolving them so stale/no-future-event lifecycle is distinct from source recovery.
- Worker health state stores exception category only; stack traces, DB URLs, SQL text, raw payloads, and plugin options are not retained in readiness-visible state.
- The worker starts immediately on lifespan startup and loops independently from `TaskRunner`; notification dispatch remains the only TaskRunner responsibility.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## Known Stubs

None.

## Threat Flags

None - new lifecycle expiration, worker health, and concurrent sweep surfaces were already covered by the plan threat model.

## User Setup Required

None - no external service configuration required.

## Verification

- `uv run pytest tests/test_lifecycle_expiration.py::test_expiration_uses_database_time_and_rule_window tests/test_lifecycle_expiration.py::test_expiration_closes_only_stale_open_rows tests/test_lifecycle_expiration.py::test_expiration_context_is_non_secret tests/test_lifecycle_expiration.py::test_expiration_source_uses_database_time_not_app_clock -x` — passed: 4 tests.
- `uv run pytest tests/test_lifecycle_worker.py tests/test_task_runner.py::test_asyncio_create_task_is_confined_to_approved_background_modules -x` — passed: 5 tests.
- `uv run pytest tests/test_lifecycle_expiration.py tests/test_lifecycle_worker.py tests/test_task_runner.py::test_asyncio_create_task_is_confined_to_approved_background_modules -x` — passed: 9 tests.

## TDD Gate Compliance

- RED commits: `e908888`, `b2a9273`.
- GREEN commits: `c00ebfd`, `0cf1185`.

## Next Phase Readiness

Plan 04-03 can build operator incident APIs on the lifecycle repository functions and expired context. Plan 04-05 can use `get_lifecycle_worker()` and the worker's `healthy`, `last_sweep_at`, `last_error_category`, and `expired_total` fields for readiness without exposing secrets.


## Self-Check: PASSED

- Found created files: `app/processing/lifecycle_worker.py`, `tests/test_lifecycle_expiration.py`, `tests/test_lifecycle_worker.py`, `.planning/phases/04-lifecycle-operator-apis-and-operability/04-02-SUMMARY.md`.
- Found task commits: `e908888`, `c00ebfd`, `b2a9273`, `0cf1185`.
---
*Phase: 04-lifecycle-operator-apis-and-operability*
*Completed: 2026-06-09*
