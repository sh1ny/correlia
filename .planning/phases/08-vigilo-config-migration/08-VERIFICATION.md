---
phase: 08-vigilo-config-migration
verified: 2026-06-19T18:00:00Z
status: passed
score: 10/10 must-haves verified
behavior_unverified: 0
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 8/10
  gaps_closed:
    - "D-05: substring ${...} and {env: ...} placeholder syntax in allowed email plugin option values is now rejected"
    - "D-14: _promote now removes a newly-created --out-dir on failure, including the narrow mkdtemp-failure path"
  gaps_remaining: []
  regressions: []
gaps: []
human_verification: []
---

# Phase 8: Vigilo Config Migration Verification Report

**Phase Goal:** Maintainers can translate supported Vigilo/VDE YAML into strict Correlia config and get clear failures whenever Vigilo semantics cannot be preserved.

**Verified:** 2026-06-19T18:00:00Z

**Status:** `passed`

**Re-verification:** Yes — after 08-03 gap-closure execution plus an additional working-tree fix for a narrow D-14 edge case.

**Code under verification:**
- HEAD commit `5d253de3` — `fix(08-03): close D-05 substring placeholders and D-14 out_dir creation gaps`
- Plus uncommitted working-tree changes:
  - `scripts/migrate_vigilo_config.py` — `_promote` refactored to guard the `tempfile.mkdtemp` failure path
  - `tests/test_vigilo_config_migration.py` — added `test_promote_removes_new_out_dir_on_mkdtemp_failure`

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | CFG-01/D-01/D-02/D-03: CLI accepts exactly one YAML file per `--rules`, `--topology`, `--plugins`, plus `--out-dir` | ✓ VERIFIED | `scripts/migrate_vigilo_config.py:_build_parser` uses `_SingleUseAction`; `_validate_input_path` rejects directories, globs, missing files, and non-YAML; 12 input-path cases pass |
| 2 | CFG-02: Vigilo rules rewritten into strict Correlia rule schema with inverted priorities, fnmatch host/service patterns, topology-prefixed tags/group_by, rewritten placeholders, and `create_incident` actions | ✓ VERIFIED | `test_migrate_rules`, `test_migrate_rules_prefixes_*`, `_transform_rules`; priorities `100/50/10` become `1/2/3` |
| 3 | CFG-03/CFG-04/D-10/D-11: Vigilo topology rewritten into hostname/subnet rules; capture groups emit `tag_capture_groups`; subnets remain literal | ✓ VERIFIED | `test_migrate_topology`; `topology_valid.yaml` produces `tag_capture_groups: {topology.datacenter: 1}` for capture-group hostname and literal subnet tags |
| 4 | CFG-05/D-04/D-06: Plaintext SMTP credentials are not copied into generated plugin config | ✓ VERIFIED | `_CREDENTIAL_KEYS` preflight rejects `smtp_username`, `smtp_password`, `username`, `password`; credential fixtures fail with `plaintext_smtp_credentials` / CFG-06; generated `plugins.yaml` contains no credential keys |
| 5 | D-05: Generated `plugins.yaml` must not contain `${...}` or `{env: ...}` placeholder syntax | ✓ VERIFIED | `_ENV_VAR_PLACEHOLDER_RE.search(value)` and `_ENV_KEY_PLACEHOLDER_RE.search(value)` reject substring occurrences; fixture `plugins_with_placeholder_option.yaml` contains `subject_prefix: "[${ENV}]"` and `from_address: "{env: OPS_EMAIL}"`; `test_plugin_option_placeholders_fail_before_output` passes |
| 6 | CFG-06/D-12/D-13: Unsupported Vigilo semantics are preflight-scanned, aggregated across all inputs, reported clearly, and cause non-zero exit before output promotion | ✓ VERIFIED | 41 `UNSUPPORTED_FIELD_CASES` + 12 `INVALID_INPUT_PATH_CASES` parametrized tests pass; `test_report_aggregates_issues_across_inputs_and_domains` covers multi-domain aggregation; report shape has `ok`, `errors`, `generated` |
| 7 | CFG-07: Generated YAML is staged and validated through Correlia loaders plus generated email plugin instantiation before promotion | ✓ VERIFIED | `_validate_staged` calls `load_plugin_registry_config`, `load_plugin_registry`, `load_rules_config(known_plugins=...)`, `load_topology_config`; `test_generated_files_load_and_instantiate` passes |
| 8 | D-14: Failed migrations must leave `--out-dir` untouched, including not creating it | ✓ VERIFIED | `_promote` tracks `created_out_dir`, removes newly-promoted files without backups, restores pre-existing files from backup, and removes the output directory if it created it and it is now empty; `test_promote_does_not_create_out_dir_on_failure` passes; additional `test_promote_removes_new_out_dir_on_mkdtemp_failure` covers the narrow path where `tempfile.mkdtemp` raises after `out_dir.mkdir()` |
| 9 | D-15: Failed migrations must leave no partial or corrupted output files | ✓ VERIFIED | `_promote` tracks promoted files in `promoted: list[str]` and unlinks any newly-promoted target without a backup on exception; `test_promote_rolls_back_new_files_on_mid_promotion_failure` passes |
| 10 | CFG-04/D-07/D-08/D-09: Runtime topology supports hostname regex capture-group substitution, applied after literal tags with empty/None skipping and 256-character bound | ✓ VERIFIED | `HostnameTopologyRule.tag_capture_groups`, `CompiledHostnameRule.tag_capture_groups`, `load_topology_config` group-index validation, `StaticTopologyEnricher._apply_rule` derived-tag logic; 6 capture-group tests pass |

**Score:** 10/10 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/migrate_vigilo_config.py` | Standalone Vigilo/VDE migration CLI | ✓ VERIFIED | 1295 lines; `--help`, preflight, transforms, staging, validation, promotion, JSON report |
| `app/config/topology.py` | Strict `tag_capture_groups` schema and loader validation | ✓ VERIFIED | `HostnameTopologyRule.tag_capture_groups`, `CompiledHostnameRule.tag_capture_groups`, group-count check in `load_topology_config` |
| `app/processing/enrichment.py` | Runtime capture-group substitution | ✓ VERIFIED | `_apply_rule` applies derived tags after literal tags, skips empty/None, rejects >256 chars |
| `tests/test_topology_enrichment.py` | Regression coverage for schema and enrichment | ✓ VERIFIED | 32 tests covering capture groups, override diagnostics, empty captures, overlong captures, subnet rejection |
| `tests/test_vigilo_config_migration.py` | CLI, transform, failure aggregation, validation-failure output preservation tests | ✓ VERIFIED | 77 passed; 41 unsupported-field + 12 invalid-input-path cases |
| `tests/fixtures/vigilo/*.yaml` | Valid and unsupported Vigilo inputs | ✓ VERIFIED | 43 fixtures present |
| `CONFIGURATION.md` | Operator-facing migration documentation | ✓ VERIFIED | Updated with CLI, priority inversion, `tag_capture_groups`, credential rejection, unsupported-field catalog |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| `scripts/migrate_vigilo_config.py` | `app.config.plugins.load_plugin_registry_config` | Called on staged `plugins.yaml` | ✓ WIRED | `_validate_staged` |
| `scripts/migrate_vigilo_config.py` | `app.plugins.loader.load_plugin_registry` | Called on staged `plugins.yaml` | ✓ WIRED | `_validate_staged` instantiates generated email plugin |
| `scripts/migrate_vigilo_config.py` | `app.config.rules.load_rules_config` | Called on staged `rules.yaml` with `known_plugins` | ✓ WIRED | `_validate_staged` |
| `scripts/migrate_vigilo_config.py` | `app.config.topology.load_topology_config` | Called on staged `topology.yaml` | ✓ WIRED | `_validate_staged` |
| `app/config/topology.py` | `app/processing/enrichment.py` | `CompiledHostnameRule.tag_capture_groups` | ✓ WIRED | Enricher consumes compiled capture-group mapping |
| `scripts/migrate_vigilo_config.py:_preflight_plugins` | `tests/fixtures/vigilo/plugins_with_placeholder_option.yaml` | Reject substring `${...}` / `{env: ...}` before staging | ✓ WIRED | Fixture rejected as `unsupported_plugin_option` / CFG-06 |
| `scripts/migrate_vigilo_config.py:_promote` | `tests/test_vigilo_config_migration.py::test_promote_rolls_back_new_files_on_mid_promotion_failure` | Monkeypatched `os.replace` regression | ✓ WIRED | Newly-promoted files removed on mid-promotion failure |
| `scripts/migrate_vigilo_config.py:_promote` | `tests/test_vigilo_config_migration.py::test_promote_does_not_create_out_dir_on_failure` | Monkeypatched `os.replace` regression | ✓ WIRED | Missing `--out-dir` is not created on first-replace failure |
| `scripts/migrate_vigilo_config.py:_promote` | `tests/test_vigilo_config_migration.py::test_promote_removes_new_out_dir_on_mkdtemp_failure` | Monkeypatched `tempfile.mkdtemp` regression | ✓ WIRED | Missing `--out-dir` is not created on `mkdtemp` failure |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `app/config/topology.py` → `CompiledHostnameRule.tag_capture_groups` | Capture-group mapping | `load_topology_config` compiles from YAML | Yes | ✓ FLOWING |
| `app/processing/enrichment.py` → derived tags | `match.group(group_index)` | Hostname regex match at runtime | Yes | ✓ FLOWING |
| `scripts/migrate_vigilo_config.py` → generated `plugins.yaml` | `options.*` values | Vigilo source `config` values; rejected if they contain `${...}` or `{env: ...}` | Yes | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| D-05 substring placeholder rejection | `uv run pytest tests/test_vigilo_config_migration.py::test_plugin_option_placeholders_fail_before_output tests/test_vigilo_config_migration.py::test_transform_plugins_rejects_placeholder_in_allowed_options -x` | 2 passed | ✓ PASS |
| D-14 out_dir not created on first-replace failure | `uv run pytest tests/test_vigilo_config_migration.py::test_promote_does_not_create_out_dir_on_failure -x` | 1 passed | ✓ PASS |
| D-15 mid-promotion rollback | `uv run pytest tests/test_vigilo_config_migration.py::test_promote_rolls_back_new_files_on_mid_promotion_failure -x` | 1 passed | ✓ PASS |
| Narrow D-14 mkdtemp-failure rollback | `uv run pytest tests/test_vigilo_config_migration.py::test_promote_removes_new_out_dir_on_mkdtemp_failure -x` | 1 passed | ✓ PASS |
| Topology enrichment regression | `uv run pytest tests/test_topology_enrichment.py -x` | 32 passed | ✓ PASS |
| Migration CLI regression | `uv run pytest tests/test_vigilo_config_migration.py -x` | 77 passed | ✓ PASS |
| Combined Phase 8 regression | `uv run pytest tests/test_topology_enrichment.py tests/test_vigilo_config_migration.py -x` | 109 passed | ✓ PASS |
| Full workspace regression | `make test` | 531 passed in 52.36s | ✓ PASS |
| Lint gate | `make lint` | All checks passed! | ✓ PASS |
| Typecheck gate | `make typecheck` | Success: no issues found in 50 source files | ✓ PASS |
| CLI help | `uv run python scripts/migrate_vigilo_config.py --help` | Prints usage, options, priority-inversion note, credential rejection | ✓ PASS |

### Probe Execution

No phase-declared probes found; skipped.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| CFG-01 | 08-02 | CLI with `--rules`, `--topology`, `--plugins`, `--out-dir` | ✓ SATISFIED | `test_cli_generates_files`, parser flags, 12 input-path cases |
| CFG-02 | 08-02 | Rewrite supported Vigilo rules into strict Correlia schema | ✓ SATISFIED | `test_migrate_rules`, transform tests |
| CFG-03 | 08-01/08-02 | Rewrite supported Vigilo topology into strict hostname/subnet schemas | ✓ SATISFIED | `test_migrate_topology`, subnet literal-only tests |
| CFG-04 | 08-01/08-02 | Preserve hostname-derived topology tags via regex capture groups, or fail clearly | ✓ SATISFIED | `tag_capture_groups` schema/enrichment, missing-target-tag fixture |
| CFG-05 | 08-02/08-03 | Rewrite email output config without copying plaintext SMTP credentials or unsupported placeholders | ✓ SATISFIED | Credential keys rejected; substring `${...}`/`{env: ...}` rejected; fixture `plugins_with_placeholder_option.yaml` |
| CFG-06 | 08-02/08-03 | Exit non-zero with clear unsupported-field errors | ✓ SATISFIED | 41 unsupported-field + 12 invalid-input cases, aggregated report |
| CFG-07 | 08-02/08-03 | Validate generated files with Correlia loaders before success | ✓ SATISFIED | `_validate_staged`, `test_generated_files_load_and_instantiate`; D-15 rollback protects validated output on promotion failure |

### Locked Decisions

| Decision | Status | Evidence |
|----------|--------|----------|
| D-01: single YAML file per flag; reject dirs/globs/missing/non-YAML | ✓ HONORED | `_validate_input_path`, `_SingleUseAction`, 12 invalid-input tests |
| D-02: mirror single-file loader contract and settings shape | ✓ HONORED | CLI loads one file per domain; output filenames match settings paths |
| D-03: multi-file/directory sources out of scope | ✓ HONORED | No `--rules-dir` etc.; such inputs rejected as invalid paths |
| D-04: fail-closed on plaintext SMTP credentials | ✓ HONORED | `_CREDENTIAL_KEYS` preflight; credential fixtures fail |
| D-05: do not emit `${...}`/`{env: ...}` placeholders | ✓ HONORED | `_ENV_VAR_PLACEHOLDER_RE.search(value)` and `_ENV_KEY_PLACEHOLDER_RE.search(value)` reject any substring occurrence; fixture `plugins_with_placeholder_option.yaml` includes `subject_prefix: "[${ENV}]"` and `from_address: "{env: OPS_EMAIL}"` |
| D-06: credentials configured outside migration artifact | ✓ HONORED | No credential values emitted; docs advise external secret handling |
| D-07: `tag_capture_groups` strict `dict[str, int]` | ✓ HONORED | `HostnameTopologyRule` field with `Field(default_factory=dict)` |
| D-08: derived tags applied after literal tags | ✓ HONORED | `_apply_rule` literal loop before capture-group loop |
| D-09: group index `>=1` and `<= pattern.groups`; skip empty/None; bound to 256 | ✓ HONORED | Pydantic validator + loader check + enrichment skip/length checks |
| D-10: capture group + `target_tag` emits `tag_capture_groups: {topology.<target_tag>: 1}` | ✓ HONORED | `_transform_topology` hostname capture-group branch |
| D-11: subnet rules literal-only, reject `tag_capture_groups` | ✓ HONORED | `SubnetTopologyRule` has no capture field; `extra="forbid"`; test rejects |
| D-12: explicit preflight scan for unsupported semantics | ✓ HONORED | `_preflight_rules`, `_preflight_topology`, `_preflight_plugins` |
| D-13: errors aggregated across all inputs/domains | ✓ HONORED | `test_report_aggregates_issues_across_inputs_and_domains` |
| D-14: stage, validate, then atomically promote; on failure `--out-dir` left untouched | ✓ HONORED | `_promote` tracks `created_out_dir`, restores backups, rolls back newly-promoted files, and removes the directory if newly-created and empty; covered by `test_promote_does_not_create_out_dir_on_failure` and `test_promote_removes_new_out_dir_on_mkdtemp_failure` |
| D-15: no partial/corrupted output files on failure | ✓ HONORED | `_promote` tracks promoted files and unlinks newly-promoted targets without backups on exception |

### D-05/D-14 Hotfix Details

**D-05 — Substring placeholder rejection**

The 08-03 gap-closure commit `5d253de3` changed placeholder detection from full-string matching to substring scanning:

- `scripts/migrate_vigilo_config.py:55` — `_ENV_VAR_PLACEHOLDER_RE = re.compile(r"\$\{[^}]*\}")`
- `scripts/migrate_vigilo_config.py:56` — `_ENV_KEY_PLACEHOLDER_RE = re.compile(r"\{env:[^}]*\}")`
- `scripts/migrate_vigilo_config.py:827` and `:829` — `_iter_unsupported_placeholders` uses `.search(value)` instead of `.match(value)` for the `${...}` and `{env: ...}` string checks
- `tests/fixtures/vigilo/plugins_with_placeholder_option.yaml` contains:
  - `smtp_host: "${SMTP_HOST}"` (exact full-string form)
  - `from_address: "{env: OPS_EMAIL}"` (substring `{env: ...}` form)
  - `to_addresses: ["ops@example.com", env: OPS_EMAIL]` (mapping-with-env-key form)
  - `subject_prefix: "[${ENV}]"` (substring `${...}` form)
- `tests/test_vigilo_config_migration.py:364-388` — `test_plugin_option_placeholders_fail_before_output` asserts all four forms are rejected as `unsupported_plugin_option` / CFG-06 and no output directory is created

**D-14 — `--out-dir` left untouched on failure**

The 08-03 gap-closure commit `5d253de3` introduced `created_out_dir` tracking and removal of a newly-created empty output directory in `_promote`'s exception handler. During final verification, an additional narrow path was identified and fixed in the working tree: `tempfile.mkdtemp(..., dir=out_dir.parent)` could raise after `out_dir.mkdir()` succeeded, leaving the newly-created directory behind.

Working-tree fix in `scripts/migrate_vigilo_config.py:1123-1167`:
- `backup_dir` is now declared as `str | None = None`
- `out_dir.mkdir(parents=True, exist_ok=True)` and `backup_dir = tempfile.mkdtemp(...)` moved inside the same `try` block
- The `finally` block only removes `backup_dir` when it is not `None`
- The exception handler removes the output directory if it was newly created and is now empty

Regression coverage:
- `tests/test_vigilo_config_migration.py:596-618` — `test_promote_does_not_create_out_dir_on_failure` (first `os.replace` fails)
- `tests/test_vigilo_config_migration.py:564-593` — `test_promote_rolls_back_new_files_on_mid_promotion_failure` (second `os.replace` fails)
- `tests/test_vigilo_config_migration.py:620-645` — `test_promote_removes_new_out_dir_on_mkdtemp_failure` (added in working tree; `tempfile.mkdtemp` fails after `out_dir.mkdir()`)

### Anti-Patterns Found

No `TBD`, `FIXME`, `XXX`, `TODO`, `HACK`, or placeholder comments were found in the modified files. No stub implementations, hardcoded empty data, or console-only handlers were identified.

### Human Verification Required

None. All phase-8 behaviors are covered by automated tests.

### Gaps Summary

No gaps remain. All CFG-01..CFG-07 requirements are satisfied, all D-01..D-15 locked decisions are honored, and the full workspace regression suite (531 tests), lint, and typecheck gates pass.

---

_Verified: 2026-06-19T18:00:00Z_
_Verifier: Claude (gsd-verifier)_

## VERIFICATION PASSED
