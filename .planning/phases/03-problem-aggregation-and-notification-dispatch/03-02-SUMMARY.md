---
phase: 03-problem-aggregation-and-notification-dispatch
plan: 2
subsystem: processing
tags: [asyncio, task-runner, plugins, smtp, mailpit, pydantic, yaml, aiosmtplib]

# Dependency graph
requires:
  - phase: 02-icinga2-ingress-topology-and-rule-decisions
    provides: normalized events, rule decisions, plugin protocol style, strict YAML config patterns
  - phase: 03-problem-aggregation-and-notification-dispatch plan 1
    provides: durable incident aggregation result fields consumed by notification dispatch
provides:
  - Deterministic AsyncIOTaskRunner with named handler registration, payload copying, failure logging, and drain
  - Strict trusted YAML output plugin registry with deterministic config hash and safe listing
  - Mailpit-compatible async SMTP output plugin backed by aiosmtplib
  - Targeted tests for task runner, plugin registry, and SMTP output behavior
affects:
  - phase 03 plan 3 notification dispatcher and API wiring
  - phase 04 plugin/status operator APIs

# Tech tracking
tech-stack:
  added: [aiosmtplib]
  patterns:
    - "All async background submission goes through TaskRunner; raw asyncio.create_task is isolated to app/processing/task_runner.py"
    - "Output plugins are trusted declarative YAML entries loaded through app.plugins.outputs.* class-path allowlisting"
    - "Plugin listing returns configured name/type/status/config_hash only, never options or secrets"

key-files:
  created:
    - app/processing/task_runner.py
    - app/config/plugins.py
    - app/plugins/loader.py
    - app/plugins/outputs/__init__.py
    - app/plugins/outputs/email.py
    - tests/test_task_runner.py
    - tests/test_plugin_registry.py
    - tests/test_smtp_output.py
  modified:
    - app/plugins/interfaces.py
    - pyproject.toml
    - uv.lock

key-decisions:
  - "Task handlers accept one copied mapping payload, keeping the TaskRunner seam serializable and Celery-ready."
  - "Plugin YAML uses a full class_path field but validates the app.plugins.outputs.* prefix before import."
  - "SMTP connection settings live in per-plugin registry options, so Settings remains unchanged and no global SMTP singleton is introduced."
  - "SMTP verification uses a real local Mailpit-compatible SMTP endpoint implemented with asyncio instead of a Docker container."

patterns-established:
  - "Strict Pydantic v2 config models plus yaml.safe_load for plugin registries."
  - "PluginRegistry eagerly loads configured plugins once and caches instances by configured name."
  - "OutputPlugin exposes NotificationEnvelope and PluginStatus protocol methods; registry combines status with non-secret configured metadata."

requirements-completed:
  - TSK-01
  - TSK-02
  - NOT-01
  - NOT-02
  - NOT-03

# Metrics
duration: 8min
completed: 2026-06-09
---

# Phase 03 Plan 02: Task Execution and Output Plugin Summary

**Named asyncio task execution plus trusted YAML-loaded output plugins, including aiosmtplib SMTP delivery compatible with Mailpit.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-06-09T06:11:01Z
- **Completed:** 2026-06-09T06:18:28Z
- **Tasks:** 2 implementation tasks after the approved dependency checkpoint
- **Files modified:** 11

## Accomplishments

- `AsyncIOTaskRunner` registers named coroutine handlers, copies mapping payloads before scheduling, rejects unknown/duplicate tasks with `TaskSubmissionError`, retrieves handler exceptions in done callbacks, and drains outstanding tasks deterministically.
- `PluginRegistry` loads strict YAML registry entries once, rejects duplicate names and unsafe class paths, caches instances by configured name, and lists only safe status fields plus `config_hash`.
- `SmtpOutputPlugin` sends real `EmailMessage` notifications through `aiosmtplib` to a Mailpit-compatible SMTP endpoint, rendering incident id, rule, group key, severity, summary, affected hosts, and services.
- Targeted tests cover task dispatch/failure behavior, source safety assertions, plugin registry validation/listing/cache behavior, and SMTP message capture through a real local SMTP endpoint.

## Task Commits

| Task | Name | Commit | Type | Key files |
| ---- | ---- | ------ | ---- | --------- |
| 2 | Implement deterministic named async task execution | `299cb74` | feat | `app/processing/task_runner.py`, `tests/test_task_runner.py` |
| 3 | Load trusted output plugins and send Mailpit-compatible SMTP messages | `4356133` | feat | `pyproject.toml`, `uv.lock`, `app/plugins/interfaces.py`, `app/config/plugins.py`, `app/plugins/loader.py`, `app/plugins/outputs/email.py`, `tests/test_plugin_registry.py`, `tests/test_smtp_output.py` |

Task 1 was the blocking human dependency-legitimacy checkpoint. It was resumed with approval for the exact package name `aiosmtplib`; no Task 1 code commit was expected or created.

## Files Created/Modified

- `app/processing/task_runner.py` - TaskRunner protocol, TaskHandler alias, TaskSubmissionError, AsyncIOTaskRunner implementation.
- `tests/test_task_runner.py` - Behavior tests for named dispatch, payload copying, unknown task rejection, exception logging, drain, and `asyncio.create_task` confinement.
- `app/plugins/interfaces.py` - PluginStatus, NotificationEnvelope, and OutputPlugin protocol alongside existing input/topology protocols.
- `app/config/plugins.py` - Strict YAML registry config models, duplicate-name rejection, trusted class path validation, bounded options, and deterministic config hash.
- `app/plugins/loader.py` - PluginRegistry cache/list/get seam and trusted class import restricted to `app.plugins.outputs.*`.
- `app/plugins/outputs/__init__.py` - Output plugin package export.
- `app/plugins/outputs/email.py` - `SmtpOutputPlugin` and SMTP option validation using `aiosmtplib`.
- `tests/test_plugin_registry.py` - Registry loading, caching, safe listing, invalid config, missing/non-output class, and unsafe source-pattern tests.
- `tests/test_smtp_output.py` - Real local SMTP endpoint capture test for Mailpit-compatible message delivery and safe status output.
- `pyproject.toml` - Added `aiosmtplib>=5.1.1` via `uv add aiosmtplib`.
- `uv.lock` - Updated by uv with `aiosmtplib==5.1.1`.

## Decisions Made

- Handler call shape is `handler(payload_mapping)`, not `handler(**payload)`, to preserve one serializable task payload object at the runner boundary.
- Registry config stores `class_path` and validates `app.plugins.outputs.*` before loading; plugin YAML cannot select arbitrary modules.
- `PluginRegistry.list_plugins()` returns dict rows rather than plugin objects so operators never see SMTP options, credentials, rendered body, or exception traces.
- SMTP tests use an actual asyncio TCP SMTP server that speaks the Mailpit-compatible SMTP subset needed by `aiosmtplib`; no SMTP mocks are used.

## Deviations from Plan

None - plan executed exactly as written after the dependency checkpoint approval.

## Issues Encountered

- Context7 CLI fallback was unavailable (`ctx7 not found`) for `aiosmtplib` docs lookup. The installed `aiosmtplib 5.1.1` runtime signature was inspected before using `aiosmtplib.send`.

## Authentication Gates

None.

## Known Stubs

None.

## User Setup Required

None for tests. Runtime SMTP delivery requires operators to configure an output plugin entry pointing at their Mailpit-compatible SMTP endpoint.

## Verification

- `uv run pytest tests/test_task_runner.py -x` — PASSED (4 tests).
- `uv run pytest tests/test_plugin_registry.py tests/test_smtp_output.py -x` — PASSED (11 tests).
- `uv run pytest tests/test_task_runner.py tests/test_plugin_registry.py tests/test_smtp_output.py -x` — PASSED (15 tests).

## Next Phase Readiness

- Phase 03 Plan 03 can wire durable notification dispatch through `TaskRunner.submit(...)`, `PluginRegistry.get_plugin(...)`, and `OutputPlugin.send_notification(...)`.
- Rules can validate configured output names using `PluginRegistry.names`/config outputs without adding unsafe dynamic YAML execution.

## Self-Check: PASSED

- [x] No prior `03-02` commits existed before resuming from the package checkpoint.
- [x] `app/processing/task_runner.py`, `app/config/plugins.py`, `app/plugins/loader.py`, `app/plugins/outputs/email.py`, `tests/test_task_runner.py`, `tests/test_plugin_registry.py`, and `tests/test_smtp_output.py` exist.
- [x] Task commits exist: `299cb74` and `4356133`.
- [x] Targeted plan verification passed: `uv run pytest tests/test_task_runner.py tests/test_plugin_registry.py tests/test_smtp_output.py -x`.
- [x] Project-wide build/test/lint/typecheck/format gates were not run.

---
*Phase: 03-problem-aggregation-and-notification-dispatch*
*Completed: 2026-06-09*
