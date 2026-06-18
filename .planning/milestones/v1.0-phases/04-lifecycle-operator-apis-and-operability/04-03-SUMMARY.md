---
phase: 04-lifecycle-operator-apis-and-operability
plan: 3
subsystem: api
tags: [fastapi, postgresql, sqlalchemy, pydantic, operator-api, config-status]
requires:
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-01 lifecycle repository mutations for acknowledgement and manual close
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: Plan 04-02 lifespan lifecycle worker state and app-state dependency patterns
provides:
  - Trusted internal /v1 incident list/detail/ack/close REST workflows
  - Opaque keyset cursor pagination over last_update_time DESC, id DESC
  - Safe /v1 rules, topology, and plugin status summaries without secret-bearing config
  - Clean /v1 namespace cutover for health, readiness, plugin listing, and Icinga2 ingress
  - Targeted API tests for incident workflows, config status, and route exposure
affects: [04-lifecycle-operator-apis-and-operability, incidents-api, config-status, route-cutover]
tech-stack:
  added: []
  patterns:
    - FastAPI APIRouter self-prefixes for /v1-only route registration
    - SQLAlchemy expression-only incident filters with bounded keyset pagination
    - Allowlisted config/status summaries with hashes instead of raw YAML/runtime objects
key-files:
  created:
    - app/api/routers/incidents.py
    - app/api/routers/config_status.py
    - tests/test_incidents_api.py
    - tests/test_config_status_api.py
  modified:
    - app/domain/incidents.py
    - app/persistence/incidents.py
    - app/api/deps.py
    - app/api/routers/health.py
    - app/api/routers/ingress.py
    - app/api/routers/plugins.py
    - app/main.py
    - tests/test_ingress_router.py
    - tests/test_plugins_router.py
    - tests/test_health.py
key-decisions:
  - "Incident listing uses opaque base64url cursors containing last_update_time and id; repository queries keep the locked last_update_time DESC, id DESC order."
  - "Operator incident actions remain trusted-internal with no auth dependency and reuse Plan 04-01 lifecycle repository guards."
  - "Rules/topology REST status responses are allowlists with hashes; they do not expose raw YAML, regex/CIDR match values, plugin options, class paths, or recipient addresses."
patterns-established:
  - "Incident REST response construction validates or drops unsafe persisted decision context before serialization."
  - "Config/status dependencies are loaded into app.state and exposed through typed dependency helpers."
requirements-completed: [API-01, API-02, API-03, API-04, API-05, OPS-04]
duration: 11min
completed: 2026-06-09
---

# Phase 04 Plan 03: Operator API and /v1 Cutover Summary

**Trusted internal /v1 operator REST APIs for incident inspection/mutation plus safe rule, topology, plugin, health, readiness, and ingress route cutover.**

## Performance

- **Duration:** 11 min
- **Started:** 2026-06-09T14:53:26Z
- **Completed:** 2026-06-09T15:04:44Z
- **Tasks:** 2
- **Files modified:** 14

## Accomplishments

- Added `/v1/incidents` list/detail/ack/close endpoints backed by PostgreSQL lifecycle repository functions, with no built-in auth and no legacy alias.
- Added bounded strict Pydantic request/response models and SQLAlchemy-only filters for status, severity, rule, host, service, updated_since, limit, and opaque cursor.
- Added `/v1/rules` and `/v1/topology` allowlisted summaries with config hashes while preserving safe `/v1/plugins` output.
- Moved existing health, readiness, plugin listing, and Icinga2 ingress routes to `/v1` only.
- Added targeted API tests proving pagination, safe detail serialization, idempotent ack/close, config redaction, and route cutover.

## Task Commits

1. **Task 1 RED: incident operator API behavior tests** - `bd3493c` (test)
2. **Task 1 GREEN: incident operator REST workflows** - `b3c32be` (feat)
3. **Task 2 RED: /v1 config/status and route cutover tests** - `8f66e0f` (test)
4. **Task 2 GREEN: /v1 cutover and safe config summaries** - `48c6b8c` (feat)

## Files Created/Modified

- `app/api/routers/incidents.py` - New `/v1/incidents` router for list, detail, acknowledgement, and manual close actions.
- `app/api/routers/config_status.py` - New `/v1/rules` and `/v1/topology` safe summary router.
- `tests/test_incidents_api.py` - New Testcontainers-backed API tests for incident list/detail/action workflows and invalid input handling.
- `tests/test_config_status_api.py` - New API tests for rules/topology allowlists, hashes, and secret-scan assertions.
- `app/domain/incidents.py` - Added incident filter, response, and action request models.
- `app/persistence/incidents.py` - Added cursor encode/decode, filtered keyset list, and get-by-id helpers.
- `app/api/deps.py` - Added typed rules/topology config dependency helpers.
- `app/api/routers/health.py` - Moved health and readiness routes under `/v1`.
- `app/api/routers/ingress.py` - Moved Icinga2 event ingestion to `/v1/icinga2/events`.
- `app/api/routers/plugins.py` - Moved plugin listing to `/v1/plugins`.
- `app/main.py` - Loaded rules/topology config into app state and included incident/config routers.
- `tests/test_ingress_router.py` - Updated ingress route usage and route exposure assertions for `/v1` cutover.
- `tests/test_plugins_router.py` - Updated plugin route expectations for `/v1` and no legacy alias.
- `tests/test_health.py` - Updated health/readiness route expectations for `/v1` and no legacy aliases.

## Decisions Made

- Kept auth out of the API layer per D-10; deployment trust boundaries remain external to Correlia.
- Used `limit + 1` keyset pagination and a base64url cursor rather than offset pagination to keep list behavior stable under updates.
- Returned safe typed incident fields and bounded decision context; invalid persisted decision context is dropped instead of serialized.
- Computed topology status hash from the allowlisted summary shape because the existing compiled topology object has no raw config hash field.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## Known Stubs

None.

## Threat Flags

None - new REST, lifecycle mutation, pagination, and config/plugin status surfaces were covered by the plan threat model and implemented with the listed mitigations.

## User Setup Required

None - no external service configuration required.

## Verification

- `uv run pytest tests/test_incidents_api.py::test_list_incidents_filters_and_cursor_pagination tests/test_incidents_api.py::test_incident_detail_excludes_raw_payloads_and_secrets tests/test_incidents_api.py::test_ack_is_idempotent_and_keeps_incident_open tests/test_incidents_api.py::test_manual_close_is_idempotent_and_frees_open_slot -x` — passed: 4 tests.
- `uv run pytest tests/test_incidents_api.py -x` — passed: 5 tests.
- `uv run pytest tests/test_config_status_api.py tests/test_ingress_router.py::test_v1_icinga2_events_route_is_exposed_without_legacy_alias tests/test_plugins_router.py::test_v1_plugins_route_lists_safe_output_status_only tests/test_health.py::test_v1_health_and_readyz_routes_replace_legacy_paths -x` — passed: 5 tests.
- `uv run pytest tests/test_plugins_router.py tests/test_health.py -x` — passed: 6 tests.
- `uv run pytest tests/test_ingress_router.py -x` — passed: 33 tests.
- `uv run pytest tests/test_incidents_api.py tests/test_config_status_api.py tests/test_ingress_router.py::test_v1_icinga2_events_route_is_exposed_without_legacy_alias tests/test_plugins_router.py::test_v1_plugins_route_lists_safe_output_status_only tests/test_health.py::test_v1_health_and_readyz_routes_replace_legacy_paths -x` — passed: 10 tests.

## TDD Gate Compliance

- RED commits: `bd3493c`, `8f66e0f`.
- GREEN commits: `b3c32be`, `48c6b8c`.

## Next Phase Readiness

Plan 04-04 can add metrics/logging against the completed `/v1` API namespace. Plan 04-05 can broaden readiness using the existing `/v1/readyz` router and app-state config/plugin/lifecycle seams.

## Self-Check: PASSED

- Found created files: `app/api/routers/incidents.py`, `app/api/routers/config_status.py`, `tests/test_incidents_api.py`, `tests/test_config_status_api.py`, `.planning/phases/04-lifecycle-operator-apis-and-operability/04-03-SUMMARY.md`.
- Found task commits: `bd3493c`, `b3c32be`, `8f66e0f`, `48c6b8c`.
---
*Phase: 04-lifecycle-operator-apis-and-operability*
*Completed: 2026-06-09*
