---
phase: 03-problem-aggregation-and-notification-dispatch
plan: 3
subsystem: processing
tags: [fastapi, icinga2, postgresql, task-runner, output-plugins, notification-dispatch, plugin-listing]

requires:
  - phase: 03-problem-aggregation-and-notification-dispatch plan 1
    provides: Durable incident aggregation, threshold state, first transition detection, and compact aggregation result fields
  - phase: 03-problem-aggregation-and-notification-dispatch plan 2
    provides: AsyncIOTaskRunner, trusted output plugin registry, SMTP output plugin, and safe plugin listing metadata
provides:
  - End-to-end Icinga2 PROBLEM webhook path through normalization, topology enrichment, rule decision, durable aggregation, post-commit notify submission, and compact response fields
  - NotificationDispatcher with strict task payload validation, incident lookup, output plugin invocation, and safe failure categories
  - Sanitized notification result recording in incident decision_context
  - FastAPI lifespan wiring for plugin registry, task runner, notification dispatcher, and graceful drain
  - GET /plugins safe output plugin listing endpoint
affects: [phase-04-lifecycle-operator-apis-operability, notification-dispatch, plugin-status]

tech-stack:
  added: []
  patterns:
    - "IncidentManager commits durable incident/window/threshold state before any TaskRunner.submit('notify', ...) call."
    - "Notification task payloads carry only incident id, plugin name, and config hash; dispatcher reloads incident state from PostgreSQL."
    - "Notification failures are closed safe categories with bounded messages stored as sanitized decision_context notes."
    - "Ingress stays persistence-isolated by accepting a sessionmaker seam rather than importing app.persistence or AsyncSession."
    - "Plugin listing returns registry safe rows only: name, plugin_type, ready, status, config_hash."

key-files:
  created:
    - app/processing/notification_dispatcher.py
    - app/api/routers/plugins.py
    - tests/test_notification_dispatch.py
    - tests/test_plugins_router.py
  modified:
    - app/persistence/incidents.py
    - app/processing/incident_manager.py
    - app/processing/ingress.py
    - app/processing/rule_engine.py
    - app/api/deps.py
    - app/main.py
    - tests/test_incident_manager.py
    - tests/test_ingress_router.py

key-decisions:
  - "RuleDecision.actions now carries configured output plugin names so the aggregation manager can submit one notify task per rule action plugin without loading raw rule config in the ingress path."
  - "Dispatcher records safe notification outcomes back onto the incident decision_context instead of introducing a separate notification attempts table in this v1 slice."
  - "FastAPI lifespan skips notify handler re-registration when a test or caller provides a pre-registered TaskRunner, preserving app-factory override semantics."

patterns-established:
  - "NotificationDispatcher.process(payload) validates serialized payloads, resolves PluginRegistry by name, builds NotificationEnvelope from PostgreSQL incident state, and records bounded results."
  - "Icinga2DecisionProcessor wires IncidentManager only through injected sessionmaker/task_runner/plugin_registry seams and keeps RECOVERY/no-match paths as no-op aggregation."
  - "GET /plugins exposes PluginRegistry.list_plugins() rows and never returns plugin options, credentials, rendered bodies, class paths, or exception text."

requirements-completed:
  - AGG-01
  - AGG-05
  - TSK-03
  - NOT-03
  - NOT-04
  - NOT-05

duration: 13min
completed: 2026-06-09
---

# Phase 03 Plan 03: End-to-End Notification Dispatch and Plugin Listing Summary

**Icinga2 PROBLEM events now become durable PostgreSQL incidents and submit configured notification work through TaskRunner after commit, with safe failure recording and plugin status listing.**

## Performance

- **Duration:** 13 min
- **Started:** 2026-06-09T06:23:52Z
- **Completed:** 2026-06-09T06:37:10Z
- **Tasks:** 2 completed
- **Files modified:** 12

## Accomplishments

- Added `NotificationDispatcher` and `NotificationTaskPayload` for strict background notify payload validation, incident reload, plugin lookup, `NotificationEnvelope` construction, output invocation, and safe category mapping: `dispatched`, `missing_plugin`, `missing_incident`, `plugin_exception`, `dispatch_failed`.
- Extended `IncidentManager` to commit incident/window/threshold state before notification submission, then submit one `notify` task per configured output plugin only on the first durable threshold transition.
- Added sanitized notification result recording into `Incident.decision_context.notes` without raw payloads, credentials, SMTP transcripts, rendered bodies, plugin options, or exception traces.
- Wired `Icinga2DecisionProcessor` to durable incident aggregation through injected sessionmaker/task runner/plugin registry seams while preserving no-op behavior for RECOVERY and no-match paths.
- Added FastAPI lifespan setup for plugin registry loading, asyncio task runner creation, notification dispatcher handler registration, and graceful drain.
- Added `GET /plugins` safe output plugin listing.

## Task Commits

| Task | Name | Commit | Type | Key files |
| ---- | ---- | ------ | ---- | --------- |
| 1 RED | Add failing notification dispatch tests | `b9e6612` | test | `tests/test_notification_dispatch.py`, `tests/test_incident_manager.py` |
| 1 GREEN | Dispatch notification tasks after durable transition commits | `8dcee7f` | feat | `app/processing/notification_dispatcher.py`, `app/processing/incident_manager.py`, `app/persistence/incidents.py` |
| 2 RED | Add failing ingress dispatch and plugin route tests | `44e56b8` | test | `tests/test_ingress_router.py`, `tests/test_plugins_router.py` |
| 2 GREEN | Wire full Icinga2 ingress and plugin listing vertical slice | `dbd016e` | feat | `app/processing/ingress.py`, `app/api/deps.py`, `app/api/routers/plugins.py`, `app/main.py`, `app/processing/rule_engine.py` |

## Files Created/Modified

- `app/processing/notification_dispatcher.py` - Validates notify task payloads, reloads incidents, invokes output plugins, maps safe failure categories, and records sanitized outcomes.
- `app/persistence/incidents.py` - Adds `record_notification_result()` to append bounded notification facts to incident decision context.
- `app/processing/incident_manager.py` - Adds post-commit notification submission through `TaskRunner`, missing-plugin/submission failure mapping, and result reporting.
- `app/processing/ingress.py` - Wires RuleDecision PROBLEM events to `IncidentManager` and returns durable incident/notification fields in the existing envelope.
- `app/processing/rule_engine.py` - Returns rule action plugin names in `RuleDecision.actions` for dispatch.
- `app/api/deps.py` - Adds task runner and plugin registry dependencies.
- `app/api/routers/plugins.py` - Adds safe `GET /plugins` route.
- `app/main.py` - Wires plugin registry, task runner, dispatcher, ingress processor dependencies, route registration, and drain.
- `tests/test_notification_dispatch.py` - Covers dispatcher success, missing plugin, missing incident, plugin exception, dispatch failure, and safe recording.
- `tests/test_incident_manager.py` - Covers commit-before-submit source order, no-dispatch branches, first transition submission, missing plugin, and submission failure.
- `tests/test_ingress_router.py` - Covers PostgreSQL-backed Icinga2 vertical slice, replay/already-notified suppression, RECOVERY bypass, and source boundary assertions.
- `tests/test_plugins_router.py` - Covers safe plugin route output and absence of operator incident APIs.

## Decisions Made

- `RuleDecision.actions` now represents configured output plugin names. This keeps notification submission independent from raw rule config while preserving one task per rule action plugin.
- Notification result persistence remains incident-local in `decision_context.notes`; a separate outbox/attempts table remains out of scope for v1 and unnecessary for the plan's safe observability requirement.
- App factory overrides take precedence over lifespan defaults. Injected task runners and plugin registries are reused, and `notify` registration is skipped if already present.

## Deviations from Plan

None - plan executed exactly as written.

**Total deviations:** 0 auto-fixed.
**Impact on plan:** No scope changes.

## Issues Encountered

None.

## Authentication Gates

None.

## User Setup Required

None for tests. Runtime notification delivery requires `CORRELIA_PLUGINS_PATH` to point at a valid output plugin registry and rule actions to reference configured plugin names.

## Known Stubs

None.

## Threat Flags

None - the new dispatcher payload boundary, output plugin boundary, and `/plugins` route were covered by the plan threat model and verified with safe-category and no-secret tests.

## Verification

- `uv run pytest tests/test_notification_dispatch.py tests/test_incident_manager.py -x` — PASSED (`9 passed`).
- `uv run pytest tests/test_notification_dispatch.py tests/test_ingress_router.py tests/test_plugins_router.py -x` — PASSED (`34 passed`).
- Source assertions passed for commit-before-submit ordering, ingress persistence isolation, no raw Icinga2 field references, no unsafe YAML execution helpers, and safe `/plugins` output.

## Next Phase Readiness

Phase 03 is ready for orchestrator-level wave/phase gates. Phase 04 can build RECOVERY lifecycle handling, stale expiration, operator incident REST APIs, and broader operability on top of the completed durable aggregation and notification dispatch path.

## Self-Check: PASSED

- Found `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-03-SUMMARY.md` on disk after writing.
- Found task commits `b9e6612`, `8dcee7f`, `44e56b8`, and `dbd016e` in git history.
- Verified targeted Task 1 and plan checks passed.
- Confirmed project-wide build/test/lint/typecheck/format gates were not run.
- Confirmed no intentional file deletions were introduced by task commits.

---
*Phase: 03-problem-aggregation-and-notification-dispatch*
*Completed: 2026-06-09*
