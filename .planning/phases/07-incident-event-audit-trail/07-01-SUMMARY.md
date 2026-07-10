---
phase: 07-incident-event-audit-trail
plan: "01"
subsystem: database
tags: [postgres, alembic, sqlalchemy, pydantic, hmac, redaction, audit]

requires:
  - phase: 05-security-and-http-controls
    provides: auth, settings, and test Settings-callsite patterns
  - phase: 06-canonical-incident-api-operation-parity
    provides: incident persistence and cursor/list patterns

provides:
  - append-only incident_events table, ORM model, and migration
  - required audit settings (raw-payload cap and HMAC key)
  - strict audit domain contracts (AuditDecisionSummary, filters, responses)
  - audit-owned raw-payload redaction, semantic cap, and pre-redaction HMAC
  - cursor helpers for (accepted_at, id) pagination
  - repository insert/list helpers with safe default projection
  - foundation unit and persistence tests

affects:
  - 07-02-incident-event-audit-trail
  - 07-03-incident-event-audit-trail

tech-stack:
  added: []
  patterns:
    - Audit-owned redactor avoids coupling to incident DecisionContext
    - Default list projection omits raw_payload and full normalized_event
    - Server-generated UUID for audit row ids

key-files:
  created:
    - migrations/versions/0003_create_incident_events.py
    - app/domain/audit.py
    - app/persistence/audit.py
    - tests/test_domain_audit.py
    - tests/test_audit_redaction.py
    - tests/test_audit_persistence.py
  modified:
    - app/persistence/models.py
    - app/config/settings.py
    - tests/conftest.py
    - tests/test_migrations.py
    - tests/test_settings.py
    - tests/test_health.py
    - tests/test_security.py
    - tests/test_size_limit.py
    - tests/test_incidents_api.py
    - tests/test_exposure_config.py
    - tests/test_rate_limit.py
    - tests/test_ingress_router.py
    - tests/test_plugins_router.py
    - tests/test_config_status_api.py
    - tests/test_metrics_api.py
    - tests/test_lifecycle_worker.py

key-decisions:
  - Raw payload and metadata fields are non-null in migration, model, and insert helper.
  - Redaction is audit-owned; private forbidden-fragment symbols from incident domain are not reused.
  - Default read projection selects only normalized_event message/tags plus metadata; raw_payload is never selected.
  - Cursor pagination uses immutable (accepted_at DESC, id DESC) tuple.

patterns-established:
  - "Audit helpers live in app.persistence.audit; decision modules do not import them."
  - "Read-time redaction helper is idempotent and applied in both repository and future API mapper."

requirements-completed:
  - AUD-01
  - AUD-02

duration: 120min
completed: 2026-06-18
status: complete
---

# Phase 7 Wave 1: Audit Foundation Summary

**Created the Phase 7 audit foundation: append-only `incident_events` table, strict bounded domain contracts, audit-owned raw-payload redaction/HMAC, cursor helpers, and Testcontainers-backed persistence helpers/tests.**

## Performance

- **Duration:** ~120 min
- **Started:** 2026-06-18T12:20Z
- **Completed:** 2026-06-18T15:01Z
- **Tasks:** 3
- **Files modified:** 17

## Accomplishments
- Alembic migration `0003_create_incident_events` with server-generated UUID, JSONB columns, CHECK constraints, and lookup indexes.
- `IncidentEvent` ORM model and required `Settings.audit_raw_payload_*` fields with separate HMAC-key validator.
- Strict Pydantic v2 contracts in `app/domain/audit.py` for decision summaries, filters, and bounded responses.
- Independent recursive redactor, semantic size cap, and pre-redaction HMAC in `app.persistence.audit`.
- Repository helpers `insert_incident_event` and `list_incident_events` with safe default projection and cursor/offset pagination.
- Updated all existing `Settings(...)` test callsites to supply a test audit HMAC key.

## Task Commits

1. **Task 1: Schema, ORM model, audit settings, and Settings callsite maintenance** - `a2f2c21` (test RED), `2a53350` (feat GREEN), `ec98f48` (CHECK fix)
2. **Task 2: Domain contracts, redaction, HMAC, and cursor helpers** - `2334e67`
3. **Task 3: Repository insert/list helpers and persistence tests** - `d03de68`

## Files Created/Modified
- `migrations/versions/0003_create_incident_events.py` - audit table, constraints, indexes
- `app/persistence/models.py` - `IncidentEvent` ORM model
- `app/config/settings.py` - audit raw-payload cap and required HMAC key
- `app/domain/audit.py` - bounded audit domain contracts
- `app/persistence/audit.py` - redaction, HMAC, cursor, repository helpers
- `tests/test_domain_audit.py` - domain contract tests
- `tests/test_audit_redaction.py` - redaction/HMAC/cursor unit tests
- `tests/test_audit_persistence.py` - Testcontainers persistence tests
- Existing test Settings callsites - supply audit HMAC key

## Decisions Made
- Non-null raw-payload metadata and HMAC in DB and helper contract to fail fast.
- Redactor uses an audit-owned sensitive-fragment tuple rather than importing incident-domain forbidden fragments.
- Default list projection omits `raw_payload` and full `normalized_event`; read-time redaction is applied to projected message/tags.

## Deviations from Plan

### Auto-fixed Issues

**1. [Helper split] Repository helpers implemented across Tasks 2 and 3**
- **Found during:** Task 2 implementation
- **Issue:** Task 2 created `insert_incident_event` and `list_incident_events` alongside redaction/cursor helpers; Task 3 was scoped to tests.
- **Fix:** Kept helper code in `app.persistence.audit.py`; Task 3 added `tests/test_audit_persistence.py` and tightened the helper non-null contract.
- **Files modified:** `app/persistence/audit.py`, `tests/test_audit_persistence.py`
- **Verification:** `uv run pytest tests/test_audit_persistence.py -q` passes (10 tests).
- **Committed in:** `d03de68` (Task 3 commit)

**2. [Manual recovery] Subagent failed before creating Task 3 persistence tests**
- **Found during:** Wave 1 execution
- **Issue:** `gsd-executor` completed Task 1 and Task 2 but failed before producing `tests/test_audit_persistence.py`.
- **Fix:** Orchestrator performed focused manual Task 3 pass: tightened `insert_incident_event`, wrote persistence tests, fixed a `test_health.py` Settings-callsite syntax error left by earlier agent edits.
- **Files modified:** `app/persistence/audit.py`, `tests/test_audit_persistence.py`, `tests/test_health.py`
- **Verification:** Foundation gate passes (`72 tests`) and Settings-callsite regression passes (`134 tests`).
- **Committed in:** `d03de68`

---

**Total deviations:** 2 auto-fixed (1 helper-scope adjustment, 1 manual subagent recovery)
**Impact on plan:** No scope creep. Foundation deliverables match plan acceptance criteria.

## Issues Encountered
- Early subagent `HilariousAnt` completed only Task 1 before yielding partial; continuation subagent `FeministPorcupine` completed Task 2 but failed before Task 3. Final Task 3 was completed manually.
- `test_health.py` Settings-callsite edit introduced a syntax error (missing comma) that was caught by the regression gate and fixed.

## User Setup Required
Operators must set `CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY` to a dedicated secret
(distinct from operator/ingress tokens). `Settings()` will fail validation if
the key is missing, blank, or equal to a configured auth token. No other
external service configuration is required.

## Next Phase Readiness
- Audit foundation is ready for Wave 2 (`07-02-PLAN.md`): ingress transaction refactor and audit-write integration.
- No blockers.

---
*Phase: 07-incident-event-audit-trail*
*Completed: 2026-06-18*
