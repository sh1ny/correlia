---
phase: 04-lifecycle-operator-apis-and-operability
plan: 4
subsystem: operability
tags: [fastapi, prometheus, metrics, python, observability]
requires:
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-01 recovery/ack/close lifecycle manager and ingress recovery branch
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-02 lifecycle worker health seam and expiration batch
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-03 /v1 API namespace and FastAPI router inclusion pattern
provides:
  - Approved prometheus-client dependency and private low-cardinality metrics registry
  - GET /v1/metrics Prometheus exposition route
  - Ingress, incident, lifecycle, notification, task, and worker metric instrumentation
  - Targeted metrics tests covering content type, declaration safety, and rendered low-cardinality output
affects: [04-lifecycle-operator-apis-and-operability, operability, metrics, prometheus]
tech-stack:
  added: [prometheus-client]
  patterns:
    - Private CollectorRegistry owned by app.processing.metrics
    - Prometheus imports isolated to one processing module
    - Metrics labels restricted to event_type, reason, rule_name, effect, plugin_name, category, task_name
key-files:
  created:
    - app/processing/metrics.py
    - app/api/routers/metrics.py
    - tests/test_metrics_api.py
  modified:
    - pyproject.toml
    - uv.lock
    - app/main.py
    - app/processing/ingress.py
    - app/processing/incident_manager.py
    - app/processing/notification_dispatcher.py
    - app/processing/task_runner.py
    - app/processing/lifecycle.py
    - app/processing/lifecycle_worker.py
key-decisions:
  - "Use official prometheus-client after orchestrator-approved package legitimacy evidence; no hand-rolled exposition fallback."
  - "Keep prometheus_client imports isolated to app/processing/metrics.py so call sites use project helpers only."
  - "Use one incident effect counter with bounded effect labels instead of separate high-cardinality incident labels."
patterns-established:
  - "Metrics helpers are the only instrumentation API exposed to application seams."
  - "Lifecycle worker health is represented as a 1/0 gauge updated on success, failure, and stop."
  - "Rendered metrics tests seed forbidden fragments and assert they never appear in Prometheus text."
requirements-completed: [OPS-03, OPS-04]
duration: 10min
completed: 2026-06-09
---

# Phase 04 Plan 04: Prometheus Metrics Summary

**Approved prometheus-client metrics surface with /v1/metrics and low-cardinality instrumentation across ingress, lifecycle, notification, task, and worker seams.**

## Performance

- **Duration:** 10 min
- **Started:** 2026-06-09T15:08:51Z
- **Completed:** 2026-06-09T15:18:23Z
- **Tasks:** 2 implementation tasks after approved package gate
- **Files modified:** 12

## Accomplishments

- Added `prometheus-client==0.25.0` through `uv add prometheus-client` after the user-approved package-legitimacy checkpoint.
- Added `app/processing/metrics.py` with a private `CollectorRegistry`, counters/gauge, rendering helper, and low-cardinality record helpers.
- Added `GET /v1/metrics` via `app/api/routers/metrics.py` and registered it in `create_app()`.
- Instrumented accepted/rejected ingress events, matched rules, incident effects, notification attempts/failures, async task failures, expiration effects, and lifecycle worker health.
- Added targeted `tests/test_metrics_api.py` coverage for route content type, required metric names, import isolation, forbidden label declarations, rendered low-cardinality output, and secret/high-cardinality exclusion.

## Task Commits

1. **Task 2 RED: metrics route and declaration tests** - `1eb6c3c` (test)
2. **Task 2 GREEN: dependency, metrics registry, and /v1/metrics route** - `cc9be1a` (feat)
3. **Task 3 RED: instrumentation seam metrics test** - `c4ba989` (test)
4. **Task 3 GREEN: backend metrics instrumentation** - `830a784` (feat)

## Files Created/Modified

- `pyproject.toml` - Added approved `prometheus-client` runtime dependency.
- `uv.lock` - Locked `prometheus-client==0.25.0`.
- `app/processing/metrics.py` - New private registry, counters/gauge, render helper, and record helper functions.
- `app/api/routers/metrics.py` - New `/v1/metrics` Prometheus text route.
- `app/main.py` - Registered the metrics router with the FastAPI app.
- `app/processing/ingress.py` - Records accepted/rejected events and matched rules.
- `app/processing/incident_manager.py` - Records problem insert/update effects and notification submission attempts/failures.
- `app/processing/notification_dispatcher.py` - Records dispatcher notification attempts/failures/successes by plugin and category.
- `app/processing/task_runner.py` - Records async task handler failures by task name.
- `app/processing/lifecycle.py` - Records recovery, acknowledgement, manual close, and expiration effects.
- `app/processing/lifecycle_worker.py` - Updates lifecycle worker health gauge after successful sweeps, failures, and stop.
- `tests/test_metrics_api.py` - New targeted metrics API and instrumentation coverage.

## Decisions Made

- Used `prometheus-client` exactly as approved by the orchestrator package gate; no substitute package or hand-written exposition was introduced.
- Kept all `prometheus_client` imports in `app/processing/metrics.py`; routers and processing seams call project-owned helper functions.
- Modeled incident mutations as `correlia_incident_effects_total{effect=...}` to cover inserted, updated, resolved, affected-set shrink, acknowledged, closed, and expired without per-incident labels.
- Recorded notification attempts and failures with existing bounded `plugin_name` and `category` values; payloads, incident ids, and transport messages are not labels.

## Deviations from Plan

None - plan executed exactly as written after the orchestrator-approved package checkpoint.

## Authentication Gates

None.

## Issues Encountered

- `prometheus_client.CONTENT_TYPE_LATEST` in installed `prometheus-client==0.25.0` returns `text/plain; version=1.0.0; charset=utf-8`; the test accepts either the plan's `version=0.0.4` text content type or the package-provided latest content type, matching the plan allowance.

## Known Stubs

None.

## Threat Flags

None - the new dependency, metrics endpoint, and metrics label surface were covered by the plan threat model and implemented with the listed mitigations.

## User Setup Required

None - no external service configuration required.

## Verification

- `uv run pytest tests/test_metrics_api.py::test_metrics_route_returns_prometheus_text tests/test_metrics_api.py::test_metric_declarations_exclude_high_cardinality_labels -x` — passed: 2 tests.
- `uv run pytest tests/test_metrics_api.py::test_ingest_lifecycle_notification_and_worker_metrics_use_low_cardinality_labels -x` — passed: 1 test.
- `uv run pytest tests/test_metrics_api.py -x` — passed: 3 tests.
- Stub scan over created/modified implementation and test files for TODO/FIXME/placeholder/coming soon/not available — no matches.

## TDD Gate Compliance

- RED commits: `1eb6c3c`, `c4ba989`.
- GREEN commits: `cc9be1a`, `830a784`.

## Self-Check: PASSED

- Found created files: `app/processing/metrics.py`, `app/api/routers/metrics.py`, `tests/test_metrics_api.py`, `.planning/phases/04-lifecycle-operator-apis-and-operability/04-04-SUMMARY.md`.
- Found task commits: `1eb6c3c`, `cc9be1a`, `c4ba989`, `830a784`.

## Next Phase Readiness

Plan 04-05 can broaden readiness knowing `/v1/metrics` exists and lifecycle worker health is already exported as a Prometheus gauge. Metrics helpers are centralized, so future logging/readiness work can add counters without importing `prometheus_client` outside `app/processing/metrics.py`.

---
*Phase: 04-lifecycle-operator-apis-and-operability*
*Completed: 2026-06-09*
