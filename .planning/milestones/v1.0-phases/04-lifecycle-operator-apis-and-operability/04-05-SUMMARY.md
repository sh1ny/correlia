---
phase: 04-lifecycle-operator-apis-and-operability
plan: 5
subsystem: operability
tags: [fastapi, logging, readiness, json, pytest, operability]
requires:
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-01 recovery/operator lifecycle mutations and RECOVERY ingress routing
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-02 lifespan lifecycle worker health state
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-03 /v1 API namespace, incident APIs, config/plugin app-state dependencies
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-04 metrics instrumentation at processing seams
provides:
  - Safe stdlib JSON logging formatter and allowlisted structured log extras
  - Structured operational events across ingress, incident, notification, lifecycle, worker, operator, readiness, and task failure boundaries
  - Expanded GET /v1/readyz dependency checks for database, settings/config state, plugin registry/plugin readiness, and lifecycle worker health
  - Phase 04 targeted verification command covering backend lifecycle, API, metrics, logging, readiness, and PostgreSQL/Testcontainers paths
affects: [04-lifecycle-operator-apis-and-operability, operability, readiness, structured-logging]
tech-stack:
  added: []
  patterns:
    - Stdlib logging JsonFormatter with SAFE_LOG_KEYS and safe_log_extra allowlist
    - Readiness responses expose bounded check names and statuses only
    - Phase 04 verification command is documented in targeted health coverage
key-files:
  created:
    - app/processing/logging.py
    - tests/test_structured_logging.py
  modified:
    - app/processing/ingress.py
    - app/processing/incident_manager.py
    - app/processing/notification_dispatcher.py
    - app/processing/task_runner.py
    - app/processing/lifecycle.py
    - app/processing/lifecycle_worker.py
    - app/api/routers/incidents.py
    - app/api/routers/health.py
    - app/main.py
    - tests/test_ingress_router.py
    - tests/test_incidents_api.py
    - tests/test_health.py
key-decisions:
  - "Use stdlib logging only; safe_log_extra allowlists operational fields and drops raw payloads, plugin options, credentials, and exception messages."
  - "Readiness failure payloads expose only check statuses, with exception type logged safely and no source exception text returned."
  - "Phase 04 verification readiness is documented as one targeted pytest command over actual test files; no SQLite substitute command is present."
patterns-established:
  - "Log call sites pass event/category/effect/count identifiers through app.processing.logging.safe_log_extra rather than free-form extras."
  - "GET /v1/readyz builds a compact checks map and returns 503 JSONResponse with detail=not ready when any dependency is not ready."
requirements-completed: [OPS-01, OPS-02, OPS-04]
duration: 15min
completed: 2026-06-09
---

# Phase 04 Plan 05: Structured Logging and Readiness Summary

**Safe JSON event logging plus expanded /v1/readyz dependency checks and explicit Phase 04 targeted verification readiness.**

## Performance

- **Duration:** 15 min
- **Started:** 2026-06-09T15:23:01Z
- **Completed:** 2026-06-09T15:38:22Z
- **Tasks:** 2
- **Files modified:** 14

## Accomplishments

- Added `app/processing/logging.py` with `JsonFormatter`, `SAFE_LOG_KEYS`, `safe_log_extra()`, and `configure_json_logging()` using only Python stdlib logging.
- Configured JSON logging through `app.main` using `Settings.log_level` and instrumented required processing/lifecycle/operator/readiness/task boundaries with safe structured fields.
- Removed task failure `exc_info` stack-trace logging and replaced broad exception logging in Phase 4-touched paths with exception type/category only.
- Expanded `/v1/readyz` to check database connectivity, settings/config loaded state, plugin registry/plugin readiness, and lifecycle worker health with bounded non-secret responses.
- Added targeted tests for safe JSON formatting, task failure secrecy, ingress and operator mutation logs, readiness dependency failures, lifecycle worker health, and the Phase 04 verification command.

## Task Commits

1. **Task 1 RED: structured logging behavior tests** - `f1549fe` (test)
2. **Task 1 GREEN: safe structured logging implementation** - `a2a5452` (feat)
3. **Task 2 RED: readiness dependency behavior tests** - `fd81658` (test)
4. **Task 2 GREEN: expanded readiness checks** - `ecf4ed4` (feat)

## Files Created/Modified

- `app/processing/logging.py` - New JSON formatter, safe log key allowlist, safe extra helper, and logging configuration helper.
- `app/processing/ingress.py` - Emits ingestion, normalization, enrichment, rule match, and recovery structured events.
- `app/processing/incident_manager.py` - Emits incident upsert and notification decision structured events.
- `app/processing/notification_dispatcher.py` - Emits safe notification dispatch outcome events.
- `app/processing/task_runner.py` - Emits task failure/cancellation events without stack traces or exception messages.
- `app/processing/lifecycle.py` - Emits recovery, operator mutation, and expiration events through the safe logging helper.
- `app/processing/lifecycle_worker.py` - Emits safe worker sweep success/failure health events.
- `app/api/routers/incidents.py` - Emits safe ack/close operator mutation events.
- `app/api/routers/health.py` - Expanded `/v1/readyz` checks and safe readiness failure logging/responses.
- `app/main.py` - Configures JSON logging from `Settings.log_level`.
- `tests/test_structured_logging.py` - New safe JSON logging and source assertion tests.
- `tests/test_ingress_router.py` - Added ingress structured logging coverage.
- `tests/test_incidents_api.py` - Added operator mutation structured logging coverage.
- `tests/test_health.py` - Added readiness dependency, lifecycle worker, and verification command coverage.

## Decisions Made

- Used allowlist-based stdlib JSON logging instead of adding a logging dependency.
- Kept readiness response details to check names and `ready`/`not_ready` statuses; exception types are logged, not returned.
- Documented Phase 04 verification as a targeted pytest command over actual files, including topology/rule tests and PostgreSQL-backed lifecycle/API paths.

## Deviations from Plan

None - plan executed exactly as written.

## Authentication Gates

None.

## Issues Encountered

- During GREEN verification, two new test expectations were corrected to match existing strict contracts: rule group keys render as `service=http`, and `IncidentAckRequest` accepts `operator` only. No product code behavior was changed for either correction.

## Known Stubs

None.

## Threat Flags

None - JSON log and readiness trust boundaries were covered by the plan threat model and implemented with the listed mitigations.

## User Setup Required

None - no external service configuration required.

## Verification

- `uv run pytest tests/test_structured_logging.py tests/test_ingress_router.py::test_ingress_logs_safe_json_events tests/test_incidents_api.py::test_operator_mutations_emit_safe_json_logs -x` — passed: 5 tests.
- `uv run pytest tests/test_health.py::test_readyz_reports_dependency_failures_without_secrets tests/test_health.py::test_readyz_requires_lifecycle_worker_health tests/test_health.py::test_phase_four_targeted_verification_commands_are_documented -x` — passed: 7 tests.
- `uv run pytest tests/test_structured_logging.py tests/test_health.py -x` — passed: 15 tests.
- Stub scan over created/modified implementation and test files for TODO/FIXME/placeholder/coming soon/not available — no matches.

## TDD Gate Compliance

- RED commits: `f1549fe`, `fd81658`.
- GREEN commits: `a2a5452`, `ecf4ed4`.

## Next Phase Readiness

Phase 04 implementation is complete. The backend now has recovery, expiration, operator APIs, config/plugin status, metrics, structured logs, readiness, and targeted verification coverage ready for the orchestrator's wave/phase gates.

## Self-Check: PASSED

- Found created files: `app/processing/logging.py`, `tests/test_structured_logging.py`, `.planning/phases/04-lifecycle-operator-apis-and-operability/04-05-SUMMARY.md`.
- Found task commits: `f1549fe`, `a2a5452`, `fd81658`, `ecf4ed4`.

---
*Phase: 04-lifecycle-operator-apis-and-operability*
*Completed: 2026-06-09*
