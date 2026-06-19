---
phase: 08-vigilo-config-migration
plan: "02"
subsystem: config
tags: [vigilo, vde, yaml, migration, cli, argparse, pydantic, topology, plugins]

requires:
  - phase: 08-vigilo-config-migration
    provides: runtime topology regex capture-group support (tag_capture_groups) and enrichment

provides:
  - Standalone scripts/migrate_vigilo_config.py CLI
  - Vigilo/VDE rules-to-Correlia transform with priority inversion and fnmatch translation
  - Vigilo/VDE topology-to-Correlia transform with tag_capture_groups for hostname capture groups
  - Vigilo/VDE plugins-to-Correlia transform rejecting plaintext SMTP credentials and unknown options
  - Aggregated unsupported-field report with JSON and stderr output
  - Temporary staging and atomic promotion to --out-dir with backup restore
  - 38 unsupported-field fixture cases and 12 invalid-input-path cases pinned by tests

affects:
  - Phase 9 plugin and notification boundaries
  - Operator onboarding documentation

tech-stack:
  added: []
  patterns:
    - Fail-closed preflight scan on raw dicts before transformation
    - Reuse strict Correlia loaders as final validation gate
    - tempfile + os.replace for atomic output promotion
    - Source-specific email option allowlist with unknown-key rejection

key-files:
  created:
    - scripts/migrate_vigilo_config.py
    - tests/test_vigilo_config_migration.py
    - tests/fixtures/vigilo/rules_valid.yaml
    - tests/fixtures/vigilo/topology_valid.yaml
    - tests/fixtures/vigilo/plugins_valid.yaml
    - tests/fixtures/vigilo/plugins_with_unknown_email_option.yaml
    - tests/fixtures/vigilo/plugins_with_unknown_section.yaml
    - tests/fixtures/vigilo/plugins_with_no_outputs.yaml
  modified:
    - CONFIGURATION.md

key-decisions:
  - "Unknown Vigilo email plugin option keys are rejected as unsupported_plugin_option / CFG-06 rather than silently dropped."
  - "Rule action plugins are cross-checked against generated output plugin names to prevent migrations that produce valid-looking rules with no plugin."
  - "Vigilo priorities are inverted to Correlia ascending ranks so Correlia's lower-first RuleEngine preserves Vigilo's higher-first evaluation order."
  - "Generic non-output plugin sections (e.g. mystery_section) are rejected alongside the five enumerated Vigilo sections."

patterns-established:
  - "Preflight errors are aggregated across all three input files and domains before any output is written."
  - "Generated files are staged, validated through Correlia loaders plus generated email plugin instantiation, then atomically promoted."

requirements-completed: [CFG-01, CFG-02, CFG-03, CFG-04, CFG-05, CFG-06, CFG-07]

duration: 90min
completed: 2026-06-19
status: complete
---

# Phase 8 Plan 2: Vigilo/VDE Config Migration CLI Summary

**Standalone Vigilo/VDE-to-Correlia migration CLI that fails closed on unsupported semantics, rejects plaintext SMTP credentials, and atomically promotes only loader-validated config files.**

## Performance

- **Duration:** 90 min
- **Started:** 2026-06-19T00:00:00Z
- **Completed:** 2026-06-19T01:30:00Z
- **Tasks:** 3
- **Files modified:** 45

## Accomplishments

- Implemented `scripts/migrate_vigilo_config.py` with `--rules`, `--topology`, `--plugins`, `--out-dir`, and optional `--report-path`.
- Added 38 unsupported-field YAML fixtures and 12 invalid-input-path parametrized cases covering the full CFG-06 catalog.
- Transformed Vigilo rules with priority inversion, fnmatch-to-regex host/service patterns, `topology.*` tag prefixing, summary placeholder rewriting, and `create_incident` action objects.
- Transformed Vigilo topology into Correlia hostname/subnet rules, emitting `tag_capture_groups` for hostname capture groups.
- Transformed Vigilo email plugins into Correlia output plugin entries without emitting or copying plaintext credentials.
- Implemented temporary staging, Correlia loader validation, generated email plugin instantiation, and atomic promotion with backup restore.
- Updated `CONFIGURATION.md` with the new CLI command, behavior notes, and migration examples using `tag_capture_groups` and `name: create_incident`.

## Verification

- `uv run pytest tests/test_vigilo_config_migration.py -x` — 72 passed in 7.0s.
- `uv run pytest tests/test_topology_enrichment.py tests/test_vigilo_config_migration.py -x` — 104 passed in 7.2s.
- `uv run python scripts/migrate_vigilo_config.py --help` — prints usage and option descriptions.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add migration fixtures and CLI tests** — `8f12b20` (test)
2. **Task 2: Implement the migration CLI** — `c1d94b0` (feat)
3. **Post-Task-2 fix: reject rule actions referencing missing output plugins** — `46df9b9` (fix)
4. **Task 3: Update operator documentation** — `a03b71d` (docs)

**Plan metadata:** to be recorded in final docs commit.

## Files Created/Modified

- `scripts/migrate_vigilo_config.py` — Standalone CLI with preflight, transforms, staging, validation, and atomic promotion.
- `tests/test_vigilo_config_migration.py` — CLI, transform, unsupported-field, input-path, report-shape, multi-input aggregation, and loader round-trip tests.
- `tests/fixtures/vigilo/` — 41 YAML fixtures including valid inputs, unsupported-field cases, and edge-case missing-output-plugins.
- `CONFIGURATION.md` — Updated migration command section, porting notes, and examples.

## Decisions Made

- Rejected unknown Vigilo email plugin options as CFG-06 failures per the accepted planning risk, rather than documenting a known-set-only omission policy.
- Added a cross-domain check ensuring every rule action plugin is defined in `plugins.outputs` to close a CFG-07 gap where empty outputs would bypass `load_rules_config` plugin validation.
- Used `fnmatch.translate()` for host/service wildcard translation, producing anchored regex patterns.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Unknown Vigilo email plugin option keys**
- **Found during:** Task 2 implementation
- **Issue:** Plan did not define behavior for unmapped Vigilo email plugin options (e.g. `smtp_timeout`).
- **Fix:** Added `unsupported_plugin_option` / `CFG-06` rejection and the `plugins_with_unknown_email_option.yaml` fixture/test.
- **Files modified:** `scripts/migrate_vigilo_config.py`, `tests/test_vigilo_config_migration.py`, `tests/fixtures/vigilo/plugins_with_unknown_email_option.yaml`
- **Verification:** `uv run pytest tests/test_vigilo_config_migration.py -k unknown_email_option -x` passes.
- **Committed in:** `c1d94b0`

**2. [Planner Accepted Risk] Multi-input aggregation test**
- **Found during:** Task 1 test design
- **Issue:** Plan accepted that multi-input aggregation was not pinned by a named end-to-end test.
- **Fix:** Added `test_report_aggregates_issues_across_inputs_and_domains` running bad rules + bad topology + bad plugins together.
- **Files modified:** `tests/test_vigilo_config_migration.py`
- **Verification:** Part of `uv run pytest tests/test_vigilo_config_migration.py`.
- **Committed in:** `8f12b20`

**3. [Planner Accepted Risk] Generic non-output section rejection**
- **Found during:** Task 1 fixture design
- **Issue:** Plan only enumerated five non-output section names.
- **Fix:** Added `plugins_with_unknown_section.yaml` fixture (`mystery_section`) and asserted it produces `unsupported_plugin_section`.
- **Files modified:** `tests/test_vigilo_config_migration.py`, `tests/fixtures/vigilo/plugins_with_unknown_section.yaml`
- **Verification:** Part of `uv run pytest tests/test_vigilo_config_migration.py`.
- **Committed in:** `8f12b20`

**4. [Rule 2 - Missing Critical] Action plugin must exist in generated outputs**
- **Found during:** Final review after Task 2
- **Issue:** With empty `outputs`, `load_rules_config(known_plugins=frozenset())` skips plugin-name validation, allowing rules to migrate with no plugin.
- **Fix:** Added `_extract_output_names` and `_check_action_plugins_exist` helpers to reject `unknown_action_plugin` / `CFG-06` before staging.
- **Files modified:** `scripts/migrate_vigilo_config.py`, `tests/test_vigilo_config_migration.py`, `tests/fixtures/vigilo/plugins_with_no_outputs.yaml`
- **Verification:** `uv run pytest tests/test_vigilo_config_migration.py::test_action_plugin_must_exist_in_outputs -x` passes.
- **Committed in:** `46df9b9`

---

**Total deviations:** 4 auto-fixed (3 missing critical, 1 planner-accepted risk)
**Impact on plan:** All fixes close correctness gaps identified during execution or accepted during planning. No scope creep.

## Issues Encountered

- Early `CONFIGURATION.md` edit corrupted the plugin YAML code fence by inserting the migration bash block in the wrong location; rewrote the docs section cleanly.
- Stub script for RED commit initially had `import sys` after `sys.path` usage; fixed before committing.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Phase 8 migration CLI is complete and tested.
- Phase 9 can rely on generated `plugins.yaml`, `rules.yaml`, and `topology.yaml` shapes.

---
*Phase: 08-vigilo-config-migration*
*Completed: 2026-06-19*

## EXECUTION COMPLETE
