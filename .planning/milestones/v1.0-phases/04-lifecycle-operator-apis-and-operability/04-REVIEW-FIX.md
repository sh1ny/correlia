---
phase: 04-lifecycle-operator-apis-and-operability
fixed_at: 2026-06-09T15:59:51Z
review_path: .planning/phases/04-lifecycle-operator-apis-and-operability/04-REVIEW.md
iteration: 1
findings_in_scope: 4
fixed: 4
skipped: 0
status: all_fixed
---

# Phase 04: Code Review Fix Report

**Fixed at:** 2026-06-09T15:59:51Z
**Source review:** `.planning/phases/04-lifecycle-operator-apis-and-operability/04-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope: 4
- Fixed: 4
- Skipped: 0

## Fixed Issues

### CR-01: Service recovery removes the host even when other services on that host are still affected

**Files modified:** `app/persistence/incidents.py`, `tests/test_lifecycle_repository.py`
**Commit:** 5a5bd68
**Applied fix:** Service recovery now preserves the affected host while other services remain on that host, and preserves the affected service while other hosts remain for that service. Added a repository test proving a `web-01/http` recovery leaves `web-01/disk` recoverable and then resolves the incident.

### CR-02: `/v1/icinga2/events` still logs exceptions with traceback and exception text

**Files modified:** `app/api/routers/ingress.py`, `tests/test_ingress_router.py`, `tests/test_structured_logging.py`
**Commit:** fada031
**Applied fix:** Replaced `logger.exception()` with a safe structured `logger.error()` event containing only `event` and `exception_type`. Added router-path coverage to the structured logging source assertion and a route test that verifies exception text is not logged.

### CR-03: Operator action free-text is not validated before being logged or written to lifecycle context

**Files modified:** `app/domain/incidents.py`, `app/api/routers/incidents.py`, `app/main.py`, `tests/test_domain_incidents.py`, `tests/test_incidents_api.py`
**Commit:** fdfc223
**Applied fix:** Request models now reject secret-like operator/reason text, validation responses strip raw input fields, close logs use bounded `manual_close` instead of the raw reason, and tests cover model rejection, safe 4xx responses, and safe operator mutation logs.

### WR-01: Notification attempt metrics are double-counted for successful queued notifications

**Files modified:** `app/processing/incident_manager.py`, `tests/test_incident_manager.py`, `tests/test_notification_dispatch.py`
**Commit:** 5afa26d
**Applied fix:** Removed the successful queued-notification attempt increment from `IncidentManager`, leaving actual successful delivery attempts at the dispatcher boundary while preserving immediate failure attempt/failure metrics in the manager. Tests cover queue-boundary success, manager failure metrics, and dispatcher success attempts.

---

_Fixed: 2026-06-09T15:59:51Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
