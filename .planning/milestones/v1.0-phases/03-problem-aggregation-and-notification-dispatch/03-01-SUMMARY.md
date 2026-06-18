---
phase: 03-problem-aggregation-and-notification-dispatch
plan: 1
subsystem: persistence
tags: [postgresql, sqlalchemy, alembic, jsonb, incident-aggregation, threshold-state, pydantic, testcontainers]
requires:
  - phase: 01-foundations-contracts-and-database-invariant
    provides: PostgreSQL incidents table, partial open-incident unique index, atomic upsert repository pattern
  - phase: 02-icinga2-ingress-topology-and-rule-decisions
    provides: NormalizedEvent, RuleDecision, ThresholdDecision, group keys, and rule action names
provides:
  - Durable bounded incident window_state JSONB with threshold_crossed and notified_at columns
  - Replay-safe unique fingerprint event_count semantics for open incident aggregation
  - First-threshold-transition detection returned from the durable write path
  - IncidentManager seam from NormalizedEvent plus RuleDecision to compact aggregation results
affects: [phase-03-notification-dispatch, phase-04-operator-apis, incident-lifecycle]
tech-stack:
  added: []
  patterns:
    - "PostgreSQL insert-first aggregation: INSERT ... ON CONFLICT DO NOTHING before row-lock read/update"
    - "Incident-side JSONB window state stores bounded fingerprint timestamps for restart-safe thresholds"
    - "Threshold dispatch is keyed by first durable false-to-true threshold_crossed transition"
    - "DecisionContext stores only bounded non-secret aggregation facts"
key-files:
  created:
    - migrations/versions/0002_add_threshold_state.py
    - app/processing/incident_manager.py
    - tests/test_incident_manager.py
  modified:
    - app/persistence/models.py
    - app/persistence/incidents.py
    - app/domain/incidents.py
    - app/domain/rules.py
    - tests/test_migrations.py
    - tests/test_incident_repository.py
    - tests/test_domain_incidents.py
key-decisions:
  - "Kept the incident row as the source of truth for threshold/window state instead of introducing a new aggregation table."
  - "Used an insert-first conflict path, then SELECT FOR UPDATE only after an open-row conflict, preserving the no SELECT-before-INSERT invariant while allowing Python-side bounded JSON state merge."
  - "Reserved notified_at for later notification dispatch while using threshold_crossed as this plan's no-repeat durable transition marker."
patterns-established:
  - "record_problem_incident returns detached incident plus effect, replay, inside_window, counted, threshold_crossed, first_threshold_transition, and counted facts."
  - "IncidentManager returns explicit no_dispatch_reason values: below_threshold, replay, already_notified."
requirements-completed:
  - AGG-02
  - AGG-03
  - AGG-04
  - AGG-05
  - NOT-05
duration: 9min
completed: 2026-06-09
---

# Phase 03 Plan 01: Durable Problem Aggregation and Threshold State Summary

**PostgreSQL-backed incident aggregation with bounded fingerprint windows, replay-safe event counts, first threshold transition detection, and compact safe manager outcomes.**

## Performance

- **Duration:** 9 min
- **Started:** 2026-06-09T05:48:39Z
- **Completed:** 2026-06-09T05:57:37Z
- **Tasks:** 2 completed
- **Files modified:** 10

## Accomplishments

- Added Alembic revision `0002_add_threshold_state` with PostgreSQL `window_state` JSONB, `threshold_crossed` boolean, and nullable `notified_at` timestamptz columns while preserving `incidents_one_open_per_rule_group`.
- Extended the incident repository with bounded `IncidentWindowState`, `MAX_WINDOW_FINGERPRINTS`, replay-safe unique fingerprint counting, out-of-order event handling, and first-threshold-transition facts.
- Created `IncidentManager.apply_problem(event, decision)` to persist matched PROBLEM decisions and return compact incident id/effect/status/threshold/no-dispatch/notification fields without dispatching output work in this plan.
- Extended strict domain contracts with safe `NotificationResult`, additional `IngressDecisionEnvelope` notification fields, and bounded non-secret `DecisionContext` aggregation facts.

## Task Commits

Each task was committed atomically with TDD RED/GREEN commits:

| Task | Commit | Type | Description |
|------|--------|------|-------------|
| Task 1 RED | `47ffce4` | test | Add failing aggregation state tests |
| Task 1 GREEN | `585c176` | feat | Persist incident threshold state |
| Task 2 RED | `8ad8667` | test | Add failing incident manager tests |
| Task 2 GREEN | `b758e0d` | feat | Add durable incident manager results |

## Files Created/Modified

- `migrations/versions/0002_add_threshold_state.py` - Adds durable threshold/window columns to `incidents`.
- `app/persistence/models.py` - Adds `Incident.window_state`, `threshold_crossed`, and `notified_at` mapped columns.
- `app/persistence/incidents.py` - Adds insert-first durable aggregation, bounded window state, replay-safe event_count, and transition result dataclass.
- `app/domain/incidents.py` - Adds strict `IncidentWindowState` and compact aggregation facts on `DecisionContext`.
- `app/processing/incident_manager.py` - Adds `IncidentManager`, `IncidentAggregationResult`, and `NoDispatchReason`.
- `app/domain/rules.py` - Adds `NotificationResult` and safe outcome fields on `IngressDecisionEnvelope`.
- `tests/test_migrations.py` - Verifies new PostgreSQL columns and preserved partial unique index.
- `tests/test_incident_repository.py` - Verifies insert/update/replay/out-of-order/first-transition repository behavior.
- `tests/test_incident_manager.py` - Verifies manager outcomes and safe persisted decision context.
- `tests/test_domain_incidents.py` - Verifies notification result validation.

## Decisions Made

- Used `threshold_crossed` as the durable no-repeat marker for this slice; `notified_at` remains nullable for the later dispatch slice that actually sends output work.
- Chose insert-first plus row-lock update on conflict rather than a single large JSONB SQL expression; this preserves PostgreSQL uniqueness/concurrency ownership and keeps the bounded window merge maintainable.
- Kept notification results empty and `notification_failed=False` in this plan because output submission is explicitly out of scope until later Phase 03 plans.

## Deviations from Plan

None - plan executed exactly as written.

**Total deviations:** 0 auto-fixed.
**Impact on plan:** No scope changes.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Known Stubs

None.

## Threat Flags

None - new schema and processing surfaces were covered by the plan threat model for PostgreSQL writes, threshold marker durability, bounded JSONB state, and safe decision context fields.

## Verification

- `uv run pytest tests/test_migrations.py tests/test_incident_repository.py -x` — passed during Task 1 GREEN (`36 passed`).
- `uv run pytest tests/test_incident_manager.py tests/test_domain_incidents.py -x` — passed during Task 2 GREEN (`37 passed`).
- `uv run pytest tests/test_migrations.py tests/test_incident_repository.py tests/test_incident_manager.py tests/test_domain_incidents.py -x` — passed for plan verification (`73 passed`).
- Stub scan across created/modified files returned `NO_STUB_PATTERNS`.

## Next Phase Readiness

The durable incident aggregation seam is ready for Phase 03 notification dispatch wiring. Later plans can rely on `IncidentManager` and `record_problem_incident` for one open incident per rule/group, unique-fingerprint event counts, first transition detection, and explicit no-dispatch reasons.

## Self-Check: PASSED

- Found `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-01-SUMMARY.md` on disk after writing.
- Found task commits `47ffce4`, `585c176`, `8ad8667`, and `b758e0d` in git history.
- Verified targeted plan tests passed with `73 passed`.
- Confirmed no intentional file deletions were introduced by task commits.

---
*Phase: 03-problem-aggregation-and-notification-dispatch*
*Completed: 2026-06-09*
