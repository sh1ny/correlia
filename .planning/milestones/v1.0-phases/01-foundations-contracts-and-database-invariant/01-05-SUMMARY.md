---
phase: 01-foundations-contracts-and-database-invariant
plan: 5
subsystem: api
tags: [fastapi, health, readiness, sqlalchemy, httpx]
requires:
  - phase: 01-01
    provides: strict settings contract and async SQLAlchemy readiness helper plumbing
provides:
  - FastAPI app factory with lifespan-managed settings, engine, and async sessionmaker wiring
  - API dependencies for request-scoped settings and sessionmaker access
  - Health router exposing process liveness and database/config readiness only
  - HTTPX/ASGI tests for liveness, readiness success, readiness failure, and excluded routes
affects: [01-02-domain-contracts, 01-03-migrations, 04-operability]
tech-stack:
  added: []
  patterns: [FastAPI app factory, lifespan resource management, router-scoped health endpoints, sanitized readiness errors]
key-files:
  created: [app/main.py, app/api/__init__.py, app/api/deps.py, app/api/routers/__init__.py, app/api/routers/health.py, tests/test_health.py]
  modified: []
key-decisions:
  - "Keep /health process-only and independent of database readiness."
  - "Make /readyz consume app settings plus Plan 01-01 check_database_ready() and return only a sanitized not-ready detail on failure."
  - "Register only the health router in Phase 1; metrics, config summary, ingestion, and operator incident routes remain out of scope."
patterns-established:
  - "create_app(settings=None, sessionmaker=None) stores explicit test resources on app.state and lets lifespan create production resources when omitted."
  - "API dependencies read request.app.state so routers do not construct settings or database sessions directly."
requirements-completed: [FND-02, FND-04]
duration: 4min
completed: 2026-06-08
---

# Phase 1 Plan 5: FastAPI Health and Readiness Summary

**FastAPI app factory with separate `/health` liveness and sanitized `/readyz` database readiness routes.**

## Performance

- **Duration:** 4min
- **Started:** 2026-06-08T13:04:55Z
- **Completed:** 2026-06-08T13:08:31Z
- **Tasks:** 1 completed
- **Files modified:** 6

## Accomplishments

- Added `create_app()` and `lifespan()` in `app/main.py`, including app-state wiring for validated settings, async engine creation, async sessionmaker creation, and engine disposal on shutdown.
- Added `app/api/deps.py` request dependencies that expose `app.state.settings` and `app.state.sessionmaker` to routers.
- Added `app/api/routers/health.py` with `GET /health` returning `{"status":"ok"}` and `GET /readyz` returning `{"status":"ready"}` after `check_database_ready()` succeeds.
- Converted readiness failures to `503 {"detail":"not ready"}` without reflecting connection strings, environment values, or exception text.
- Added HTTPX/ASGI tests covering `/health`, `/readyz` success, `/readyz` sanitized failure, and absence of `/metrics`, `/config`, and `/config-summary`.

## Task Commits

Each TDD gate was committed atomically:

1. **Task 1 RED: Health/readiness route behavior tests** - `a41299a` (test)
2. **Task 1 GREEN: FastAPI app factory and health router** - `9953c54` (feat)

**Plan metadata:** pending final docs commit

_Note: Task 1 was marked `tdd="true"`, so it has separate RED and GREEN commits._

## Files Created/Modified

- `app/main.py` - FastAPI composition root with lifespan-managed settings, engine, sessionmaker, and health router registration.
- `app/api/__init__.py` - Side-effect-free API package marker.
- `app/api/deps.py` - Request dependencies for app settings and async sessionmaker.
- `app/api/routers/__init__.py` - Side-effect-free router package marker.
- `app/api/routers/health.py` - `/health` and `/readyz` route handlers.
- `tests/test_health.py` - HTTPX/ASGI tests for liveness/readiness behavior and out-of-scope route exclusions.

## Decisions Made

- Kept `/health` independent from the database so process liveness remains available even when readiness fails.
- Reused Plan 01-01 `check_database_ready()` as the only database readiness mechanism; `/readyz` does not inspect URLs, run migrations, or load YAML.
- Returned fixed readiness error text only, satisfying the plan threat model's information-disclosure mitigation.

## Deviations from Plan

None - plan executed exactly as written.

**Total deviations:** 0 auto-fixed.
**Impact on plan:** No scope changes.

## Issues Encountered

- The RED gate failed as expected with `ModuleNotFoundError: No module named 'app.main'` before the FastAPI app factory existed.

## Verification Results

- RED: `uv run pytest tests/test_health.py -x` — PASS as a failing RED gate (`ModuleNotFoundError: No module named 'app.main'`).
- GREEN/final: `uv run pytest tests/test_health.py -x` — PASS (`4 passed`).
- Acceptance criteria — PASS: tests cover `/health` success, `/readyz` success, `/readyz` failure, `/health` with failing readiness dependency, sanitized failure body, and absence of `/metrics`, `/config`, and `/config-summary`.
- Stub scan — PASS: no TODO/FIXME/placeholder/coming-soon/not-available stubs in created implementation/test files.

## User Setup Required

None - no external service configuration required.

## Known Stubs

None.

## Next Phase Readiness

Plan 01-02 and later API slices can use `create_app()`, `app.state.settings`, and router-level dependencies as the Phase 1 FastAPI composition pattern. Readiness is ready for later expansion only when future phases intentionally add plugin/background-task checks.

## Self-Check: PASSED

- Found `app/main.py`, `app/api/__init__.py`, `app/api/deps.py`, `app/api/routers/__init__.py`, `app/api/routers/health.py`, and `tests/test_health.py` on disk.
- Found task commits `a41299a` and `9953c54` in git history.

---
*Phase: 01-foundations-contracts-and-database-invariant*
*Completed: 2026-06-08*
