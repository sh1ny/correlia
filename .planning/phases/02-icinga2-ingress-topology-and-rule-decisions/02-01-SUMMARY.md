---
phase: 02-icinga2-ingress-topology-and-rule-decisions
plan: 1
subsystem: api
tags: [fastapi, pydantic, icinga2, ingress, webhook, fingerprint]

# Dependency graph
requires:
  - phase: 01-foundations-contracts-and-database-invariant
    provides: NormalizedEvent, Severity, EventType, DecisionContext, Settings, create_app pattern
provides:
  - POST /webhooks/icinga2 endpoint
  - Icinga2 input plugin with strict payload validation
  - Stable fingerprint generation for replay tolerance
  - Decision envelope response with event identity, tags, and no-op rule decision
affects:
  - phase 02 plan 2 (topology enrichment will consume Icinga2 normalized events)
  - phase 02 plan 3 (rule engine will evaluate enriched events from this ingress path)
  - phase 03 (incident upsert will use fingerprints and group keys from this pipeline)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Strict Pydantic v2 with extra=forbid at every boundary"
    - "mode=before validator for ISO timestamp parsing under strict=True"
    - "FastAPI dependency injection via request.app.state"
    - "App factory keyword injection for testability (settings, sessionmaker, icinga2_processor)"
    - "Plugin returns rejection object rather than raising for non-actionable states"

key-files:
  created:
    - app/api/routers/ingress.py
    - app/domain/rules.py
    - app/plugins/__init__.py
    - app/plugins/inputs/__init__.py
    - app/plugins/inputs/icinga2.py
    - app/processing/__init__.py
    - app/processing/ingress.py
    - tests/test_icinga2_input.py
    - tests/test_ingress_router.py
  modified:
    - app/api/deps.py
    - app/main.py

key-decisions:
  - "Added mode=before timestamp validator to Icinga2WebhookPayload to accept ISO strings while keeping ConfigDict(strict=True)"
  - "Made Icinga2InputPlugin.process_payload async to align with Protocol-style plugin boundary from RESEARCH.md"
  - "IngressDecisionEnvelope omits state/state_type top-level fields; those live inside rejection object only"

patterns-established:
  - "Plugin rejection: return typed Icinga2Rejection for SOFT states instead of raising HTTP exceptions"
  - "Fingerprint identity: sha256 of source_id|host|event_type|severity|service truncated to 32 hex chars"
  - "Response envelope: complete decision envelope with zeroed incident effects before rule engine exists"

requirements-completed:
  - ING-01
  - ING-02
  - ING-03
  - ING-04
  - ING-05

# Metrics
duration: 5min
completed: 2026-06-08
---

# Phase 2 Plan 1: Icinga2 Ingress, Fingerprint, and Decision Envelope Summary

**Icinga2 webhook endpoint with strict payload validation, deterministic state mapping, replay-tolerant fingerprints, and a typed no-op decision envelope.**

## Performance

- **Duration:** 5 min
- **Started:** 2026-06-08T17:42:29Z
- **Completed:** 2026-06-08T17:47:00Z
- **Tasks:** 2
- **Files modified:** 11

## Accomplishments
- POST /webhooks/icinga2 accepts host and service HARD alert payloads with full Pydantic v2 strict validation
- Icinga2 states map to NormalizedEvent Severity and EventType per D-02/D-03 (UP/OK->RECOVERY, DOWN/WARNING/CRITICAL/UNKNOWN->PROBLEM)
- SOFT states return non-actionable diagnostics without entering normalized processing per D-01
- Stable 32-char fingerprints collapse replay deliveries while preserving state changes per D-05
- Complete decision envelope response with event identity, final tags, empty matched rules, None group key, and zero incident/closure/notification effects per D-06

## Task Commits

Each task was committed atomically:

1. **Task 1: Add failing Icinga2 ingress and fingerprint tests** - `a681849` (test)
2. **Task 2: Implement Icinga2 input plugin and webhook envelope** - `4a3067d` (feat)

## Files Created/Modified
- `app/plugins/inputs/icinga2.py` - Icinga2WebhookPayload, Icinga2Rejection, map_icinga_state, fingerprint_icinga_event, Icinga2InputPlugin
- `app/processing/ingress.py` - Icinga2DecisionProcessor, build_icinga2_processor, NoOpDecision envelope assembly
- `app/domain/rules.py` - NoOpDecision, IncidentEffectSummary, IngressDecisionEnvelope
- `app/api/routers/ingress.py` - POST /webhooks/icinga2 route with ingest_icinga2 handler
- `app/api/deps.py` - Added get_icinga2_processor dependency
- `app/main.py` - Added ingress_router, build_icinga2_processor in lifespan, keyword injection
- `tests/test_icinga2_input.py` - 23 tests for payload validation, state mapping, fingerprinting, SOFT rejection
- `tests/test_ingress_router.py` - 20 tests for HTTP envelope shape, secret leak prevention, route exposure

## Decisions Made
- Added `mode="before"` timestamp validator to parse ISO strings under `strict=True` instead of dropping strict mode, preserving extra-field rejection and coercion prevention.
- Made `Icinga2InputPlugin.process_payload` async to align with the Plugin Protocol boundary pattern.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Added missing `await` in test async plugin calls**
- **Found during:** Task 2 (test execution after implementation)
- **Issue:** Tests called `plugin.process_payload()` without `await`, causing coroutine object assertions to fail
- **Fix:** Changed 4 test functions from `def` to `async def` and added `await` before plugin calls
- **Files modified:** `tests/test_icinga2_input.py`
- **Verification:** pytest passes after fix
- **Committed in:** `4a3067d` (Task 2 commit)

**2. [Rule 3 - Blocking] Added `mode="before"` timestamp validator for ISO string parsing**
- **Found during:** Task 2 (test execution after implementation)
- **Issue:** `Icinga2WebhookPayload` with `ConfigDict(strict=True)` rejected ISO timestamp strings because Pydantic v2 strict mode does not coerce strings to datetime
- **Fix:** Added `@field_validator("timestamp", mode="before")` to explicitly parse ISO strings via `datetime.fromisoformat`
- **Files modified:** `app/plugins/inputs/icinga2.py`
- **Verification:** pytest payload validation tests pass
- **Committed in:** `4a3067d` (Task 2 commit)

**3. [Rule 1 - Bug] Restored missing `@model_validator` decorator**
- **Found during:** Task 2 (test execution after implementation)
- **Issue:** An edit inserting the before validator accidentally dropped the `@model_validator(mode="after")` decorator from `validate_state_against_object_type`, causing host/service state cross-validation to be skipped
- **Fix:** Re-inserted the `@model_validator(mode="after")` decorator
- **Files modified:** `app/plugins/inputs/icinga2.py`
- **Verification:** `test_host_payload_with_service_state_is_rejected` and `test_service_payload_with_host_state_is_rejected` pass
- **Committed in:** `4a3067d` (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (2 bugs, 1 blocking)
**Impact on plan:** All auto-fixes necessary for correctness. No scope creep.

## Issues Encountered
- Pydantic v2 strict mode does not coerce JSON timestamp strings to datetime automatically; explicit `mode="before"` validator required
- Editing validator blocks requires careful placement to avoid decorator/definition mangling

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Icinga2 ingress pipeline is complete and testable
- Topology enrichment can now consume `NormalizedEvent` from `Icinga2InputPlugin`
- Rule engine can evaluate enriched events against YAML rules
- Phase 3 incident upsert can use fingerprints and group keys from this pipeline

## Self-Check: PASSED
- [x] `tests/test_icinga2_input.py` exists and passes
- [x] `tests/test_ingress_router.py` exists and passes
- [x] `app/processing/ingress.py` does not import `app.persistence` or `AsyncSession`
- [x] `app/api/routers/ingress.py` exposes `POST /webhooks/icinga2`
- [x] All ING-01 through ING-05 success criteria met

---
*Phase: 02-icinga2-ingress-topology-and-rule-decisions*
*Completed: 2026-06-08*
