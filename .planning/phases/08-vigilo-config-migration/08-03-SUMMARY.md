---
phase: 08-vigilo-config-migration
plan: 08-03
subsystem: config-migration
tags: [vigilo, migration, yaml, plugins, placeholders, atomic-promotion]

requires:
  - phase: 08-vigilo-config-migration
    provides: 08-02 CLI and transform implementation that this gap closure amends

provides:
  - D-05 placeholder rejection for ${...} and {env: ...} forms in allowed email plugin option values
  - D-15 mid-promotion rollback that removes newly-promoted generated files on failure
  - Regression tests pinning both behaviors

affects:
  - 08-vigilo-config-migration

tech-stack:
  added: []
  patterns:
    - Recursive value scanning under an allowlist of email plugin option keys
    - Fail-closed transform guard that rejects unsupported placeholder syntax before mapping
    - Best-effort rollback tracking promoted files separately from backed-up pre-existing files

key-files:
  created:
    - tests/fixtures/vigilo/plugins_with_placeholder_option.yaml
  modified:
    - scripts/migrate_vigilo_config.py
    - tests/test_vigilo_config_migration.py

key-decisions:
  - "Detect ${...} only as a full-string match and {env: ...} as a mapping key, recursing through allowed email option lists and dicts"
  - "Run placeholder scanning only under _ALLOWED_EMAIL_CONFIG_KEYS so credential and unknown-option errors keep their existing codes"
  - "Track successful os.replace calls in _promote and unlink newly-promoted targets without backups on later failure"

patterns-established:
  - "Defensive transform guard: _transform_plugins scans raw allowed config values before remapping so bool({env: X}) cannot bypass detection"

requirements-completed: [CFG-05, CFG-06, CFG-07]

duration: 19 min
completed: 2026-06-19
status: complete
---

# Phase 8 Plan 3: D-05/D-15 Gap Closure Summary

**Fail-closed plugin placeholder rejection and atomic promotion rollback for the Vigilo config migration CLI**

## Performance

- **Duration:** 19 min
- **Started:** 2026-06-19T11:45:00Z
- **Completed:** 2026-06-19T12:03:58Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Rejected `${...}` string and `{env: ...}` mapping placeholders in allowed Vigilo email plugin option values before staging or promotion.
- Added recursive scanning in `_preflight_plugins` and a raw-value guard in `_transform_plugins` so generated `plugins.yaml` cannot carry unsupported placeholder syntax.
- Fixed `_promote` to track completed `os.replace` calls and remove newly-promoted files when a later replacement fails, while preserving backup restore for pre-existing targets.
- Added fixture and regression tests for both gaps, bringing `tests/test_vigilo_config_migration.py` from 72 to 76 passing tests.

## Task Commits

Each task was committed atomically:

1. **Task 1: Reject D-05 plugin option placeholder syntax before transform**
   - `30b2268` test(08-03): add failing D-05 placeholder rejection regression test and fixture
   - `acd6ed0` feat(08-03): reject D-05 plugin option placeholders in preflight and transform
2. **Task 2: Roll back newly-promoted files on D-15 mid-promotion failure**
   - `a66ed40` test(08-03): add failing D-15 mid-promotion rollback regression test
   - `86ceb27` feat(08-03): roll back newly-promoted files on D-15 mid-promotion failure
3. **Follow-up fix: raw-config transform guard and Iterator import**
   - `cfe8136` fix(08-03): scan raw config values in transform guard and import Iterator

## Files Created/Modified
- `scripts/migrate_vigilo_config.py` - Added `_iter_unsupported_placeholders`, wired placeholder scanning into `_preflight_plugins`, added raw-value guard in `_transform_plugins`, and tracked promoted files in `_promote` for rollback.
- `tests/test_vigilo_config_migration.py` - Added `test_plugin_option_placeholders_fail_before_output`, `test_transform_plugins_rejects_placeholder_in_allowed_options`, and `test_promote_rolls_back_new_files_on_mid_promotion_failure`; extended `UNSUPPORTED_FIELD_CASES`.
- `tests/fixtures/vigilo/plugins_with_placeholder_option.yaml` - Fixture containing `smtp_host: ${SMTP_HOST}` and a `{env: OPS_EMAIL}` entry under `to_addresses`.

## Decisions Made
- Detect `${...}` only when it occupies the entire string value; detect `{env: ...}` as a mapping key. This matches the D-05 locked decision and avoids rejecting benign substrings.
- Limit recursive scanning to `_ALLOWED_EMAIL_CONFIG_KEYS` so plaintext credentials and unknown options continue to fail with their existing codes (`plaintext_smtp_credentials`, `unsupported_plugin_option` for unknown keys).
- Implement rollback as best-effort file removal rather than a fully atomic rename, because the existing backup/restore contract must be preserved for pre-existing files.

## Deviations from Plan

None - plan executed exactly as written.

A follow-up fix (`cfe8136`) moved the `_transform_plugins` guard to scan raw config values before remapping and added the `Iterator` import that lint flagged. This was not a deviation in scope; it tightened the implementation without changing the plan's acceptance criteria.

## Issues Encountered
- `ruff` flagged undefined `Iterator` after adding `_iter_unsupported_placeholders`; fixed by importing it from `collections.abc`.
- Initial `_transform_plugins` guard scanned generated `options`, which would miss a placeholder in `use_tls: {env: TLS}` because `bool({env: TLS})` evaluates to `True` before the guard ran. Moved the guard to scan raw allowed `config` values before mapping and added a direct regression test.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 8 migration CLI now honors all locked decisions D-01 through D-15.
- A new verification run can be executed against the committed code.

## Self-Check: PASSED
- `tests/fixtures/vigilo/plugins_with_placeholder_option.yaml` exists and contains both rejected placeholder forms.
- `test_plugin_option_placeholders_fail_before_output` passes.
- `test_promote_rolls_back_new_files_on_mid_promotion_failure` passes.
- `uv run pytest tests/test_vigilo_config_migration.py -x` passes (76 tests).
- `uv run ruff check scripts/migrate_vigilo_config.py tests/test_vigilo_config_migration.py` passes.
- All commits reference plan ID `08-03`.
- 08-01/08-02 plans and summaries were not modified.

## EXECUTION COMPLETE
