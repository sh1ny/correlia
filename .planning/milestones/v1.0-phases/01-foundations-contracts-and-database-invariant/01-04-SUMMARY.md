---
phase: 01-foundations-contracts-and-database-invariant
plan: 4
subsystem: persistence
tags: [postgresql, sqlalchemy, upsert, jsonb, testcontainers, repository, tdd]
requires:
  - phase: 01-03
    provides: [Alembic migration environment, Incident SQLAlchemy model, partial unique index]
provides:
  - Atomic open-incident upsert repository with PostgreSQL ON CONFLICT
  - IncidentUpsertInput dataclass with validation and bounded JSONB set handling
  - Testcontainers-backed repository tests covering insert, update, severity max, JSONB merge, and security
affects: [phase-02-ingestion-rules, phase-03-problem-aggregation, incident-lifecycle]
tech-stack:
  added: []
  patterns:
    - "PostgreSQL ON CONFLICT DO UPDATE with partial unique index and literal index_where"
    - "Core INSERT RETURNING * columns mapped to fresh ORM instances to avoid identity-map staleness"
    - "Bounded deterministic JSONB array merge via SQLAlchemy scalar subqueries"
    - "Severity rank comparison using SQL CASE expressions in upsert SET"
    - "Testcontainers per-test engine lifecycle to avoid asyncpg event-loop collisions"
key-files:
  created:
    - app/persistence/incidents.py
  modified:
    - app/persistence/models.py
    - tests/test_incident_repository.py
key-decisions:
  - "Use literal text() for index_where to avoid PostgreSQL parameter-binding limitation in ON CONFLICT index inference"
  - "Return fresh Incident(**mapping) from Core RETURNING columns instead of ORM scalar_one() to avoid identity-map stale values on update path"
  - "Truncate test data in a separate cleanup engine/session to avoid asyncpg concurrent-operation errors"
patterns-established:
  - "Repository functions return detached ORM instances built from Core mappings when UPSERT semantics are required"
  - "PostgreSQL partial-index upserts must use literal predicates, not bound parameters, in the conflict target"
requirements-completed: [PRS-01, PRS-02, PRS-03, PRS-04]
duration: 25min
completed: 2026-06-08
---

# Phase 1 Plan 4: Atomic Open-Incident Upsert Repository Summary

**PostgreSQL atomic upsert repository for open incidents with max severity, bounded JSONB set merge, and Testcontainers-backed security verification.**

## Performance

- **Duration:** 25min
- **Started:** 2026-06-08T13:30:00Z
- **Completed:** 2026-06-08T13:55:00Z
- **Tasks:** 2 completed
- **Files modified:** 3

## Accomplishments

- Created `app/persistence/incidents.py` with `IncidentUpsertInput` frozen slots dataclass, `build_open_incident_upsert()`, `upsert_open_incident()`, `_jsonb_sorted_union()`, and `_severity_rank_expr()`.
- Implemented atomic PostgreSQL upsert using `sqlalchemy.dialects.postgresql.insert(...).on_conflict_do_update(index_elements=..., index_where=text(...), ...)` targeting the partial unique index `incidents_one_open_per_rule_group`.
- Enforced max severity via SQL `CASE` rank comparison (`OK=0`, `WARNING=1`, `UNKNOWN=2`, `CRITICAL=3`).
- Merged affected hosts/services as deterministic bounded JSONB arrays (`MAX_AFFECTED_HOSTS = 100`, `MAX_AFFECTED_SERVICES = 100`) through SQLAlchemy scalar subqueries.
- Validated `IncidentUpsertInput` in `__post_init__` for non-empty strings, timezone-aware datetimes, bounded sets, and `DecisionContext` secret rejection.
- Created `tests/test_incident_repository.py` with 27 Testcontainers-backed tests: insert, update, uniqueness, terminal-status coexistence, max severity (CRITICAL over WARNING, UNKNOWN over WARNING, no downgrade), JSONB sorted/deduplicated/merged sets, 100-item bounds, decision context persistence, SQL injection literal persistence, and secret metadata rejection.

## Task Commits

1. **Task 1 RED + Task 2 RED: Add failing incident repository upsert and security tests** - `f6689b8` (test)
2. **Task 1 GREEN + Task 2 GREEN: Implement atomic open-incident upsert repository** - `7cea569` (feat)

**Plan metadata:** pending final docs commit

## Files Created/Modified

- `app/persistence/incidents.py` - `IncidentUpsertInput`, `build_open_incident_upsert`, `upsert_open_incident`, `_jsonb_sorted_union`, `_severity_rank_expr`.
- `app/persistence/models.py` - Added `DateTime(timezone=True)` to all timestamp columns to match migration and fix asyncpg datetime binding errors.
- `tests/test_incident_repository.py` - 27 Testcontainers-backed repository and security tests.

## Decisions Made

- Used `text(f"status = '{IncidentStatus.OPEN.value}'")` for `index_where` because PostgreSQL cannot infer a partial unique index when the conflict-target predicate contains a bound parameter.
- Returned `Incident(**mapping)` from Core `RETURNING *` instead of `result.scalar_one()` because SQLAlchemy's identity map returns the cached first-insert object with stale attributes on the update path.
- Used per-test `create_async_engine` + `AsyncSession` with a separate cleanup engine for `TRUNCATE` to avoid asyncpg "another operation is in progress" errors caused by module-scoped engine fixtures crossing pytest-asyncio event-loop boundaries.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed SQLAlchemy model DateTime columns missing `timezone=True`**
- **Found during:** Task 1 (GREEN verification)
- **Issue:** `app/persistence/models.py` declared `start_time`, `last_update_time`, and other timestamps as `mapped_column(nullable=False)` without `DateTime(timezone=True)`. asyncpg rejected timezone-aware Python datetimes with `can't subtract offset-naive and offset-aware datetimes`.
- **Fix:** Added `DateTime(timezone=True)` to all timestamp columns in `Incident` to match the migration DDL.
- **Files modified:** `app/persistence/models.py`
- **Verification:** `uv run pytest tests/test_incident_repository.py` passed after fix.
- **Committed in:** `7cea569`

**2. [Rule 3 - Blocking] Fixed PostgreSQL parameter binding in `ON CONFLICT` partial index predicate**
- **Found during:** Task 1 (GREEN verification)
- **Issue:** `index_where=(Incident.status == IncidentStatus.OPEN.value)` compiled to `status = $13::VARCHAR`, a bound parameter. PostgreSQL cannot infer a partial unique index when the conflict target uses parameters, so the second upsert performed a new INSERT instead of an UPDATE.
- **Fix:** Changed `index_where` to `text(f"status = '{IncidentStatus.OPEN.value}'")` so the predicate is a literal string in the emitted SQL.
- **Files modified:** `app/persistence/incidents.py`
- **Verification:** `test_second_upsert_updates_same_open_incident` passed after fix.
- **Committed in:** `7cea569`

**3. [Rule 3 - Blocking] Fixed SQLAlchemy ORM identity map returning stale values on upsert update path**
- **Found during:** Task 1 (GREEN verification)
- **Issue:** `returning(Incident)` with `result.scalar_one()` returned the cached identity-map object from the first insert, showing `event_count=1` after the database had correctly updated to `2`.
- **Fix:** Changed `returning` to `*Incident.__table__.columns` and constructed a fresh `Incident(**mapping)` from the Core mapping result.
- **Files modified:** `app/persistence/incidents.py`
- **Verification:** `test_second_upsert_updates_same_open_incident` passed after fix.
- **Committed in:** `7cea569`

**4. [Rule 3 - Blocking] Fixed asyncpg "another operation is in progress" from module-scoped async engine fixture**
- **Found during:** Task 1 (GREEN verification)
- **Issue:** A module-scoped `engine` fixture shared an asyncpg connection pool across pytest-asyncio function-scoped event loops, causing `InterfaceError: cannot perform operation: another operation is in progress`.
- **Fix:** Removed module-scoped engine fixture; each test creates its own `create_async_engine` and disposes it. Cleanup `TRUNCATE` runs in a separate cleanup engine/session.
- **Files modified:** `tests/test_incident_repository.py`
- **Verification:** All 27 tests passed sequentially without asyncpg errors.
- **Committed in:** `7cea569`

**5. [Rule 1 - Bug] Fixed ambiguous column reference in `_jsonb_sorted_union`**
- **Found during:** Task 1 (GREEN verification)
- **Issue:** `jsonb_array_elements_text(affected_hosts)` inside the ON CONFLICT subquery was ambiguous because both the existing row and the `excluded` pseudo-table expose `affected_hosts`.
- **Fix:** Qualified the existing column as `incidents.{existing_column.name}`.
- **Files modified:** `app/persistence/incidents.py`
- **Verification:** `test_first_upsert_creates_open_incident` passed after fix.
- **Committed in:** `7cea569`

---

**Total deviations:** 5 auto-fixed (1 blocking model drift, 1 blocking parameter binding, 1 blocking identity-map stale values, 1 blocking event-loop fixture, 1 bug ambiguous column)
**Impact on plan:** All fixes were necessary for correct PostgreSQL upsert behavior and test reliability. No scope creep.

## Issues Encountered

- PostgreSQL `ON CONFLICT ... WHERE` cannot use bound parameters in the predicate for index inference; the predicate must be a literal.
- SQLAlchemy ORM identity map caches objects across commits when `expire_on_commit=False`, causing returned objects to show stale values after an upsert UPDATE path.
- asyncpg connections cannot be shared across pytest-asyncio function-scoped event loops; module-scoped engine fixtures cause concurrent-operation errors.
- `func.cast("[]", JSONB)` compiles correctly but the pure SQLAlchemy subquery approach for JSONB merge is more robust and avoids raw SQL text entirely.

## User Setup Required

None - no external service configuration required.

## Known Stubs

None.

## TDD Gate Compliance

- RED commit exists: `f6689b8`
- GREEN commit exists after RED: `7cea569`
- No refactor commit was needed.

## Next Phase Readiness

Plan 01-04 delivers the core repository that Phase 2 (Icinga2 ingestion, topology, rules) and Phase 3 (problem aggregation, notification dispatch) will call to persist and update incidents. The atomic upsert invariant is proven through application code and Testcontainers tests. No blockers remain.

## Self-Check: PASSED

- Found `app/persistence/incidents.py`, `tests/test_incident_repository.py`, and `app/persistence/models.py` on disk.
- Found task commits `f6689b8` and `7cea569` in git history.
- Plan-local verification passed with `27 passed`.
- All existing tests passed with `65 passed`.

---
*Phase: 01-foundations-contracts-and-database-invariant*
*Completed: 2026-06-08*
