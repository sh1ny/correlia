---
phase: 01-foundations-contracts-and-database-invariant
plan: 2
subsystem: domain
tags: [pydantic, domain-contracts, normalized-events, incident-lifecycle, validation]
requires:
  - phase: 01-01
    provides: [Python 3.14 uv environment, Pydantic v2 dependencies, pytest configuration]
provides:
  - Strict NormalizedEvent contract with EventType, Severity, tag constraints, and timezone validation
  - IncidentStatus lifecycle contract with acknowledgement metadata and transition helpers
  - Bounded DecisionContext metadata envelope that rejects raw payload and secret-shaped notes
affects: [01-03-persistence-models, 01-04-incident-repository, phase-02-ingestion-rules]
tech-stack:
  added: []
  patterns: [Pydantic v2 strict models, StrEnum domain statuses, bounded metadata envelope]
key-files:
  created: [app/domain/__init__.py, app/domain/events.py, app/domain/incidents.py, tests/test_domain_events.py, tests/test_domain_incidents.py]
  modified: []
key-decisions:
  - "Severity ordering is explicit as OK=0, WARNING=1, UNKNOWN=2, CRITICAL=3 for domain and future persistence reuse."
  - "Acknowledgement remains metadata on OPEN incidents; IncidentStatus contains only OPEN, RESOLVED, and CLOSED."
  - "DecisionContext stores only bounded, typed explainability facts and rejects raw payload or secret-shaped note content."
patterns-established:
  - "Domain models use ConfigDict(strict=True, extra='forbid') and Pydantic v2 model_validate in tests."
  - "Lifecycle transitions are centralized in app.domain.incidents.validate_incident_transition."
requirements-completed: [DOM-01, DOM-02, DOM-03, DOM-04, PRS-04]
duration: 4min
completed: 2026-06-08
---

# Phase 1 Plan 2: Domain Event and Incident Contract Summary

**Strict Pydantic domain contracts for normalized alerts, severity ranking, incident lifecycle, acknowledgement metadata, and bounded decision context.**

## Performance

- **Duration:** 4min
- **Started:** 2026-06-08T13:04:21Z
- **Completed:** 2026-06-08T13:09:04Z
- **Tasks:** 2 completed
- **Files modified:** 5

## Accomplishments

- Added `EventType`, `Severity`, `SEVERITY_RANK`, and `max_severity()` for source-independent normalized event classification.
- Added strict `NormalizedEvent` validation for required fields, enum instances, normalized tags, timezone-aware timestamps, and forbidden extra payload fields.
- Added `IncidentStatus`, `Acknowledgement`, `is_terminal_status()`, and `validate_incident_transition()` for the locked OPEN/RESOLVED/CLOSED lifecycle.
- Added bounded `DecisionContext` metadata that accepts compact explainability facts and rejects raw payload/secret-shaped note content.
- Added focused TDD coverage for valid contracts, rejected malformed/coerced data, lifecycle transitions, and decision metadata boundaries.

## Task Commits

Each task was committed atomically:

1. **Task 1 RED: Normalized event contract tests** - `9568da4` (test)
2. **Task 1 GREEN: Normalized event contract implementation** - `34b9486` (feat)
3. **Task 2 RED: Incident lifecycle and decision context tests** - `e4ee19b` (test)
4. **Task 2 GREEN: Incident lifecycle and decision context implementation** - `be9dd5c` (feat)

**Plan metadata:** pending final docs commit

_Note: Both tasks were marked `tdd="true"`, so each has separate RED and GREEN commits._

## Files Created/Modified

- `app/domain/__init__.py` - Side-effect-free domain package marker.
- `app/domain/events.py` - Strict normalized event, event type, severity, tag, timestamp, and severity ranking contracts.
- `app/domain/incidents.py` - Incident lifecycle statuses, acknowledgement metadata, transition helpers, and bounded decision metadata.
- `tests/test_domain_events.py` - NormalizedEvent TDD coverage for strict acceptance and rejection behavior.
- `tests/test_domain_incidents.py` - IncidentStatus, Acknowledgement, lifecycle transition, and DecisionContext TDD coverage.

## Decisions Made

- Used exact severity ordering from the plan: `OK: 0`, `WARNING: 1`, `UNKNOWN: 2`, `CRITICAL: 3`.
- Kept acknowledgement out of `IncidentStatus`; it is only metadata through `Acknowledgement`.
- Used a typed, bounded `DecisionContext` rather than free-form JSON so later persistence can store explainability data without raw payloads or secrets.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- TDD RED runs failed as expected with missing `app.domain.events` and `app.domain.incidents` modules before implementation.
- Unrelated `.claude/agents/*` modifications were present in the worktree at close-out and were intentionally left unstaged; plan commits only include the plan-owned files above.

## Verification Results

- `uv run pytest tests/test_domain_events.py -x` — RED PASS: failed before implementation with `ModuleNotFoundError: No module named 'app.domain.events'`.
- `uv run pytest tests/test_domain_events.py -x` — GREEN PASS: `17 passed`.
- Task 1 acceptance checks — PASS: enum sets, severity rank values, timezone error text, invalid tag cases, `ConfigDict(strict=True, extra="forbid")`, and no `.dict(`/`.parse_obj(` in source.
- `uv run pytest tests/test_domain_incidents.py -x` — RED PASS: failed before implementation with `ModuleNotFoundError: No module named 'app.domain.incidents'`.
- `uv run pytest tests/test_domain_incidents.py -x` — GREEN PASS: `28 passed`.
- Task 2 acceptance checks — PASS: status values exactly `OPEN`, `RESOLVED`, `CLOSED`; source contains no `ACKNOWLEDGED`; lifecycle transitions and forbidden terminal transitions covered; compact `DecisionContext` validation succeeds; raw/secret/extra metadata cases reject.
- Plan verification `uv run pytest tests/test_domain_events.py tests/test_domain_incidents.py -x` — PASS: `45 passed`.
- Stub scan — PASS: no TODO/FIXME/placeholder/coming-soon/not-available stubs in created implementation files.
- Threat surface scan — PASS: no new routes, auth paths, file access surfaces, schema changes, SQL generation, or YAML loading introduced.

## User Setup Required

None - no external service configuration required.

## Known Stubs

None.

## TDD Gate Compliance

- RED commits exist for both tasks: `9568da4`, `e4ee19b`.
- GREEN commits exist after their RED commits: `34b9486`, `be9dd5c`.
- No refactor commit was needed; no behavior-preserving cleanup remained after GREEN.

## Next Phase Readiness

Plan 01-03 can consume `IncidentStatus`, `Severity`, `SEVERITY_RANK`, and `DecisionContext` for persistence models and migration constraints. Plan 01-04 can reuse `max_severity()` semantics and the compact decision metadata shape for atomic incident upsert behavior.

## Self-Check: PASSED

- Found `app/domain/__init__.py`, `app/domain/events.py`, `app/domain/incidents.py`, `tests/test_domain_events.py`, and `tests/test_domain_incidents.py` on disk.
- Found task commits `9568da4`, `34b9486`, `e4ee19b`, and `be9dd5c` in git history.
- Plan-local verification passed with `45 passed`.

---
*Phase: 01-foundations-contracts-and-database-invariant*
*Completed: 2026-06-08*
