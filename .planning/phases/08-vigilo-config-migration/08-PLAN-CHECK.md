# Phase 8 Plan Check — Fresh Iteration-5 Review

**Phase:** 8 — Vigilo Config Migration
**Plans reviewed:** `.planning/phases/08-vigilo-config-migration/08-01-PLAN.md`, `.planning/phases/08-vigilo-config-migration/08-02-PLAN.md`
**Reviewer:** `PlanCheckerPhase8Iter5` — fresh re-check, built goal-backward from the phase goal in `.planning/ROADMAP.md`, the requirement IDs CFG-01..CFG-07 in `.planning/REQUIREMENTS.md`, the locked decisions D-01..D-15 in `08-CONTEXT.md`, the VIGILO_COMPATIBILITY contract, and codebase cross-reference against `app/config/{rules,topology,plugins}.py`, `app/processing/enrichment.py`, `app/plugins/{loader,outputs/email}.py`, and `app/domain/events.py`.
**Status of prior checker/planner text in this file:** ignored. The verdict below is authored fresh from the current plan files and project context only.

## Verdict

**1 blocker, 1 warning, 1 nit.** The plans are mostly goal-complete against CFG-01..CFG-07 and D-01..D-15 and are nearly executable, but the email plugin transform is missing an explicit rule for unmapped option keys. The VIGILO_COMPATIBILITY contract forbids silent semantic drop, and the plan's catalog does not pin a rejection path for email option keys that the migration does not know how to translate. This is a goal-coverage gap because the migration's behavior on an unmapped email option is currently undefined by the plan.

## Plan-soundness summary

The plan set is mostly goal-complete. Every CFG requirement has at least one covering plan and acceptance criterion, the locked decisions D-01..D-15 are all implemented by the actions, the dependency graph is a clean two-wave chain (08-01 → 08-02), scope is well within budget (3 tasks × ≤9 files per plan), and the key wiring — staged YAML → `load_plugin_registry_config` → `load_plugin_registry` (instantiation) → `load_rules_config(known_plugins=...)` → `load_topology_config` — mirrors `app/main.py` exactly. The capture-group runtime support is coordinated across schema (`HostnameTopologyRule.tag_capture_groups`), compiled form (`CompiledHostnameRule.tag_capture_groups`), loader-time group-count validation, and enricher-time substitution, with subnet rules left unchanged per D-11.

The one substantive gap is in the email plugin transform. The catalog item 3 enumerates "any top-level section other than `outputs`" and four specific plaintext credential key names, but does not name a rule for email *option* keys that the migration does not know how to translate (`smtp_timeout`, `connection_pool_size`, custom Vigilo keys, etc.). Because `PluginRegistryEntry.options` accepts arbitrary scalar option keys (the per-option validator only checks the *value* type, not the key name), and because `SmtpOutputOptions` has `extra="forbid"`, an unmapped option key would either (a) be rejected by the CFG-07 round-trip `SmtpOutputPlugin` instantiation — if the migration passed it through unchanged — or (b) be silently dropped — if the migration emitted only the known option set. The plan's transform block says "smtp_host → host, smtp_port → port, pass through addresses/subject, and map use_tls to start_tls" but does not name "reject unknown option keys" or "pass through only the enumerated option set." The behavior is undefined by the plan; the VIGILO_COMPATIBILITY contract requires it not be silent.

## Requirement Coverage (CFG-01..CFG-07)

| Requirement | Plan / Task coverage | Status |
|-------------|----------------------|--------|
| **CFG-01** — CLI with `--rules`, `--topology`, `--plugins`, `--out-dir` → `rules.yaml` / `topology.yaml` / `plugins.yaml` | 08-02 frontmatter + Action 2 CLI block + Task 1 fixtures + Task 2 implementation + acceptance criterion 1 | Covered |
| **CFG-02** — strict Correlia rule schema (severities, host/service patterns, topology tag keys, summary placeholders, action objects) | 08-02 Action 2 rule transform + Action 1 fixtures + acceptance criteria 2 and 3 | Covered |
| **CFG-03** — strict hostname/subnet topology schemas | 08-01 (schema/compiler) + 08-02 Action 2 topology transform + acceptance criterion 5 | Covered |
| **CFG-04** — regex capture-group substitution (or fail clearly) | 08-01 D-07/D-08/D-09 implementation + 08-02 D-10 emit + unsupported-catalog `topology_capture_group_missing_target.yaml` + 08-01 acceptance criteria | Covered |
| **CFG-05** — email output rewrite without plaintext SMTP credentials | 08-02 Action 2 plugin transform + 4 individual credential fixtures + aggregate `plugins_with_credentials.yaml` + D-04/D-05/D-06 + acceptance criterion 6 — **but the unknown-option-key rule is not named (see Blocker 1)** | Partially covered |
| **CFG-06** — non-zero exit with clear unsupported-field error | 08-02 D-12/D-13 preflight + aggregated report + parametrized `test_unsupported_fields_fail` + 36-row `UNSUPPORTED_FIELD_CASES` + 12-row `INVALID_INPUT_PATH_CASES` + `test_unsupported_field_catalog_table_complete` + `test_report_shape` — multi-input aggregation not pinned by a named test (see Warning 1) | Covered |
| **CFG-07** — validate generated files with Correlia loaders before success | 08-02 Action 2 staging block (`load_plugin_registry_config` → `load_plugin_registry` instantiation → `load_rules_config(known_plugins=...)` → `load_topology_config`) + `test_generated_files_load_and_instantiate` + acceptance criterion 16 | Covered |

No requirement is silently dropped; the cross-check against `.planning/REQUIREMENTS.md` and `.planning/ROADMAP.md` Requirement Coverage table shows all seven CFG requirements are mapped exactly once and are the only ones assigned to Phase 8.

## Dimension Pass/Fail Tally

| Dimension | Result | Note |
|-----------|--------|------|
| 1. Requirement coverage | FAIL | CFG-05 partially covered: the unknown-email-option-key rule is not named in the plan; behavior on an unmapped key is undefined and could silently drop semantics in violation of VIGILO_COMPATIBILITY. |
| 2. Task completeness | PASS | All 6 `<task>` entries have `<files>`, `<action>`, `<verify>` with `<automated>`, and `<done>`. TDD tasks name the tests before the implementation. |
| 3. Dependency correctness | PASS | `08-01` `depends_on: []` (Wave 1); `08-02` `depends_on: ["08-01"]` (Wave 2). Acyclic, no forward references. |
| 4. Key links planned | PASS | 08-01 wires `CompiledHostnameRule.tag_capture_groups` → `StaticTopologyEnricher`. 08-02 wires staged YAML through the same loader chain `app/main.py:129-153` uses, including `load_plugin_registry` instantiation per Research Pitfall 3. |
| 5. Scope sanity | PASS | 3 tasks/plan, ≤9 files/plan (08-01 = 3, 08-02 = 9). Well within budget. |
| 6. Verification derivation | PASS | must_haves truths are user-observable. Artifacts map to truths; key_links connect the wiring. |
| 7. Context compliance | PARTIAL | D-01..D-15 locked decisions are honored, but the VIGILO_COMPATIBILITY "must not silently drop" contract is not explicitly extended to the email option keyspace. The plan's CFG-05 transform wording enumerates only the known mappings. |
| 7b. Scope reduction | PARTIAL | The plan does not silently version down any decision, but the email option keyspace is silently narrowed: keys not enumerated in the transform block have no defined behavior. |
| 7c. Architectural tier compliance | PASS | 08-RESEARCH.md responsibility map assigns each capability to the correct tier. |
| 8. Nyquist (8a/8b/8c/8d) | PASS | No `08-VALIDATION.md`; deeper checks do not apply. All `<automated>` blocks are runnable `uv run pytest ...` commands on focused test files. The phase-verify block embeds AST-driven `python -c` checks that assert `UNSUPPORTED_FIELD_CASES` has exactly 36 elements and `INVALID_INPUT_PATH_CASES` has exactly 12, plus a `pytest --collect-only` check that pins parametrized test counts — these are hard bindings between the catalog and the fixture count. |
| 9. Cross-plan data contracts | PASS | 08-02 emits `tag_capture_groups` keys in `topology.*` form (D-10), rewrites bare `match.tags` and `window.group_by` topology keys to `topology.*`, and the `_KNOWN_NORMALIZED_FIELDS` allowlist exactly matches the constant in `app/config/rules.py:84-94`. 08-01's loader rejects non-`topology.`-prefixed capture-group keys. |
| 10. AGENTS.md compliance | SKIPPED | No `AGENTS.md` in the working directory. |
| 11. Research resolution | PASS | 08-RESEARCH.md open questions resolved inline; priority inversion named as a planner decision; `tag_capture_groups` shape resolved; unsupported-field catalog fully specified. |
| 12. Pattern compliance | PARTIAL | Most patterns honored (`tempfile.mkdtemp` + `os.replace`, `yaml.safe_dump(sort_keys=True)`, `load_plugin_registry` instantiation, `safe_log_extra`, `fnmatch.translate`). The "must not silently drop" pattern from VIGILO_COMPATIBILITY is not extended to the email option keyspace in the catalog or the fixtures. |

## Findings

### Blocker 1 (goal coverage) — Email option keyspace: silent drop vs. rejection is undefined

- **Dimension:** Requirement coverage / context compliance
- **Location:** `08-02-PLAN.md` Unsupported-Field Catalog item 3, Action 2 plugin transform, acceptance criterion 6
- **What the plan claims to enforce (CFG-05 + VIGILO_COMPATIBILITY):** The migration rewrites supported Vigilo email output plugin configuration into Correlia output plugin schema and exits non-zero with a clear unsupported-field error for Vigilo semantics Correlia cannot preserve. The VIGILO_COMPATIBILITY contract forbids silently dropping semantics.
- **What is actually pinned:** Catalog item 3 lists "any top-level section other than `outputs`" and four specific plaintext credential key names (`smtp_username`, `smtp_password`, `username`, `password`). The plugin transform block names "smtp_host → host, smtp_port → port, pass through addresses/subject, and map use_tls to start_tls." No catalog row covers an email-output *option* key that is not a known translation and not a credential.
- **Why a blocker, not a warning:** `app/config/plugins.py:22` defines `options: dict[str, Any] = Field(default_factory=dict, max_length=20)`; the per-option validator `_validate_option_value` only checks the *value* type, not the key name. `PluginRegistryEntry` has `extra="forbid"` only at the top level, so a `options: {smtp_timeout: 30, connection_pool_size: 10, custom_vigilo_key: foo}` entry would pass `load_plugin_registry_config`. The plan's transform block enumerates only the known mappings; an implementation that emits the enumerated set and silently drops the rest would pass CFG-07 round-trip validation (since `SmtpOutputOptions` only knows about its declared fields and would either accept the dropped set with no errors, or — if the implementation passed through all source options — reject them with `SmtpOutputOptions`'s own `extra="forbid"`). Both paths leave the user with a generated `plugins.yaml` whose behavior diverges from the Vigilo source on unmapped keys, which is exactly the silent drop the VIGILO_COMPATIBILITY contract forbids. The plan must choose: (a) reject unmapped option keys with a `CFG-06` error and exit non-zero, or (b) emit only the known set and document the omitted keys as intentionally not preserved. Either is fine for the goal, but the plan must pin one.
- **Fix (advisory):** Add a catalog row "unsupported plugin option key" with a fixture like `plugins_with_unknown_email_option.yaml` containing an email output with `options: {smtp_timeout: 30}` and assert `unsupported_plugin_option` / `CFG-06`. Alternatively, document the known-set policy in the catalog, the transform block, and the acceptance criteria, and add a test that exercises a Vigilo source with an unknown option key to assert it is omitted (with a recorded "skipped option" entry in the report, if D-13 is interpreted to cover this).

### Warning 1 (testability) — Multi-input aggregation property of D-13 is not pinned by a named test

- **Dimension:** Verification derivation / testability
- **Location:** `08-02-PLAN.md` Action 1 + acceptance criterion 7 ("Unsupported fields from multiple input files appear together in one structured report")
- **What the plan claims to enforce (D-13):** Errors are aggregated across all input files and domains into a structured report before the script exits non-zero.
- **What is actually pinned:** The 36 `UNSUPPORTED_FIELD_CASES` rows test a single bad fixture at a time (against two valid companions) and assert the expected `(code, requirement)` is present. The 12 `INVALID_INPUT_PATH_CASES` rows test a single bad path shape per case. `test_report_shape` pins the JSON top-level keys (`ok`, `errors`, `generated: null`) and the per-error `code` and `requirement` keys. None of these independently asserts that, in a single run, the report contains the union of issues from N bad inputs across N domains.
- **Why a warning, not a blocker:** The implementation description explicitly says "Accumulate `MigrationIssue` records with `domain`, `location`, `code`, `message`, and `requirement`, and return exit code `1` when any issue exists" (Action 2 of 08-02), and the JSON report shape is pinned. A regression that reported only the first encountered error per domain would actually pass every existing per-case test, because each of the 36 `UNSUPPORTED_FIELD_CASES` rows has exactly one bad fixture (the first error is the expected error) and `test_report_shape` only inspects top-level keys. The aggregation property is only observable in the multi-input case the plan does not test. Goal-level semantics are still sound; the test that proves the multi-input union specifically is not in the plan.
- **Suggested fix (advisory):** Add a named test (e.g., `test_report_aggregates_issues_across_inputs_and_domains`) that runs the CLI with a `rules_with_min_hosts.yaml` + `topology_capture_group_missing_target.yaml` + `plugins_with_credentials.yaml` triad and asserts the resulting `errors` list contains at least one entry for each of `unsupported_rule_min_hosts`, `missing_topology_target_tag`, and `plaintext_smtp_credentials`.

### Nit 1 (testability) — Generic unknown plugin section rejection is named broadly, pinned narrowly

- **Dimension:** Pattern compliance / testability
- **Location:** `08-02-PLAN.md` Unsupported-Field Catalog item 3 ("any top-level section other than `outputs` including `task_runner`, `inputs`, `llm`, `enrichers`, or `processor`")
- **What the plan claims to enforce:** Any non-`outputs` top-level plugin section is rejected with `unsupported_plugin_section` / `CFG-06`.
- **What is actually pinned:** Five named fixtures cover the five enumerated section names. `test_unsupported_field_catalog_table_complete` pins the catalog-row-to-fixture mapping, but not "rejection applies to *any* unknown section name, not just the five enumerated ones."
- **Why a nit, not a warning or blocker:** The implementation description uses the word "any", so the goal-level behavior is clearly intended to be generic. A hard-coded `if section in {"task_runner", "inputs", "llm", "enrichers", "processor"}` implementation would pass all five fixtures and `test_unsupported_field_catalog_table_complete`. The testability for the "any" quantifier is bounded by the implementation's wording rather than an end-to-end test.
- **Suggested fix (advisory):** Add a single parametrized row (or extra fixture) with an unknown sixth section name (e.g., `plugins_with_unknown_section.yaml` with top-level `mystery_section:`) and assert the same `unsupported_plugin_section` / `CFG-06` code.

## Other dimensions — all pass

The remaining dimensions (1 except for CFG-05, 2, 3, 4, 5, 6, 7c, 8, 9, 11) all pass. The blocker is localized to the email plugin transform; everything else is sound.

## Recommendation

`08-01-PLAN.md` and `08-02-PLAN.md` are mostly goal-complete against CFG-01..CFG-07 and D-01..D-15. Plan soundness is not yet approved for execution: the blocker on the email option keyspace must be resolved (either by adding a `CFG-06` rejection rule and a named fixture, or by explicitly naming the "known-set only" policy in the catalog, the transform block, the acceptance criteria, and a test that exercises an unmapped key). The single warning and single nit are testability observations that can be addressed in the same revision if desired, but the blocker is the gating item.

## Structured issues

```yaml
issues:
  - dimension: requirement_coverage
    severity: blocker
    plan: "08-02"
    description: "CFG-05 plugin transform and the VIGILO_COMPATIBILITY 'must not silently drop' contract. Catalog item 3 rejects non-output top-level sections and four named credential keys, but does not name a rule for email option keys the migration does not know how to translate (e.g., smtp_timeout, connection_pool_size, custom Vigilo keys). app/config/plugins.py:22 accepts arbitrary scalar option keys in PluginRegistryEntry.options, and SmtpOutputOptions' own extra='forbid' would either reject a pass-through implementation or be silently narrowed by a known-set implementation. Both paths violate the VIGILO_COMPATIBILITY contract on unmapped keys unless one is explicitly chosen and pinned."
    fix_hint: "Either (a) add a catalog row 'unsupported plugin option key' with a fixture and assert unsupported_plugin_option / CFG-06, or (b) document the known-set-only policy in the catalog, the transform block, and the acceptance criteria, and add a test that exercises a Vigilo source with an unknown option key to assert it is omitted (with a recorded 'skipped option' entry in the report, if D-13 is interpreted to cover this)."

  - dimension: verification_derivation
    severity: warning
    plan: "08-02"
    description: "D-13 aggregation claim ('errors aggregated across all input files and domains into one structured report') is implemented in the action and pinned in the JSON report shape, but no named test exercises the multi-input union property end-to-end. The 36 per-case fixtures each test one bad input; a regression that reported only the first encountered error per domain would still pass them."
    fix_hint: "Add a single named test that runs the CLI with bad rules + bad topology + bad plugins together and asserts the report contains codes from all three domains."

  - dimension: pattern_compliance
    severity: info
    plan: "08-02"
    description: "Unsupported-field catalog item 3 says 'any top-level section other than outputs' is rejected, but only five section names (task_runner, inputs, llm, enrichers, processor) have named fixtures. An implementation that hard-codes those five strings would pass the catalog fixture test; the 'any' quantifier is not directly pinned."
    fix_hint: "Add one extra fixture with an unknown section name and assert the same unsupported_plugin_section / CFG-06 code."
```

## ISSUES FOUND


## Gap-Closure Review of 08-03-PLAN.md

**Phase:** 8 — Vigilo Config Migration
**Plan reviewed:** `.planning/phases/08-vigilo-config-migration/08-03-PLAN.md` (gap-closure plan, 2 tasks)
**Source-of-truth gaps:** `.planning/phases/08-vigilo-config-migration/08-VERIFICATION.md` — D-05 (placeholder syntax emitted verbatim) and D-15 (newly-promoted files not rolled back on mid-promotion failure).
**Reviewer:** `GapPlanCheckerPhase8` — fresh goal-backward check that the plan's two tasks actually close the two named gaps with executable, scoped, and testable work, without re-opening executed plans 08-01/08-02.

**Status of prior checker text in this file:** the iteration-5 review above remains a historical record of the 08-01/08-02 plan check. The section below is the fresh review of the 08-03 gap-closure plan and uses a separate verdict.

## Verdict

**Verdict: PASSED (0 blockers, 1 non-material warning).** The gap-closure plan is goal-complete against D-05 and D-15. Task 1 adds the missing fixture and a test that proves preflight rejection of `${...}` strings and `{env: ...}` mappings inside allowed email option values, with a recursive preflight helper scoped to `_ALLOWED_EMAIL_CONFIG_KEYS`. Task 2 adds a targeted `_promote` regression test that monkeypatches `os.replace` to fail mid-promotion and asserts the originally-empty `out_dir` is left with no generated YAML. The `depends_on: ["08-02"]` is correct, the scope is 2 tasks × ≤3 files modified + 1 fixture, and the plan does not touch 08-01/08-02 or their SUMMARY files. One testability wrinkle in Task 1's third `<verify>` command — the `-k` filter drops the explicit `test_migrate_email_plugin` node from that one line — is non-material because the plan's own acceptance-criteria `<verify>` block re-runs the full module, and the second `test_unsupported_fields_fail` invocation in the same Task 1 verify block already covers the unknown-option and credential parametrizations. Not a blocker.

## Gap coverage

| Gap | Decision evidence | Plan task | Plan evidence |
|---|---|---|---|
| **D-05** — generated `plugins.yaml` must not contain `${...}` or `{env: ...}` placeholder syntax; such source values must fail pre-promotion. | `08-VERIFICATION.md` Gap 1 (lines 9–23) + `08-CONTEXT.md` D-05. | Task 1 | New fixture `tests/fixtures/vigilo/plugins_with_placeholder_option.yaml` with `smtp_host: ${SMTP_HOST}` and a `to_addresses` list item shaped as `{env: OPS_EMAIL}`; new test `test_plugin_option_placeholders_fail_before_output` runs `_run_cli` and asserts non-zero exit, `report["ok"] is False`, `report["generated"] is None`, no `rules.yaml`/`topology.yaml`/`plugins.yaml` under `out_dir`, and an `unsupported_plugin_option` / CFG-06 error naming both locations. |
| **D-15** — failed migrations must leave `--out-dir` with no partial or corrupted output files, even if promotion itself fails after one successful `os.replace`. | `08-VERIFICATION.md` Gap 2 (lines 24–38) + `08-CONTEXT.md` D-14/D-15. | Task 2 | New test `test_promote_rolls_back_new_files_on_mid_promotion_failure` monkeypatches `scripts.migrate_vigilo_config.os.replace` to call the real replacement for `rules.yaml` and then raise `OSError` for the next target; it then asserts `_promote(staging, out_dir)` raises and `out_dir` contains none of the generated YAML files. |

The plan's Source Coverage Audit table correctly maps every gap-source row to a task and explicitly excludes D-01..D-04, D-06..D-13 as already verified. No deferred idea from `08-CONTEXT.md` (first-class `{env: ...}` secret references, multi-file/directory flags, `` template syntax) is pulled in — the action block in Task 1 explicitly says "Do not expand, rewrite, redact into generated config, or accept `{env: ...}` as a secret-reference type; first-class secret references are explicitly deferred in `08-CONTEXT.md`." That matches D-05's intent (fail-closed, do not emit) without smuggling in deferred work.

## Dimension Pass/Fail Tally

| Dimension | Result | Notes |
|---|---|---|
| 1. Requirement coverage (CFG-05, CFG-06, CFG-07) | PASS | Frontmatter `requirements: [CFG-05, CFG-06, CFG-07]` matches the Source Coverage Audit and is the only requirement set Phase 8 owns. |
| 2. Task completeness (Files / Action / Verify / Done for each auto task) | PASS | Both tasks have all four required XML fields. `<action>` prose is fully specified (verified via raw read). |
| 3. Dependency correctness | PASS | `depends_on: ["08-02"]` exists; no cycles; Wave 3 = max(deps) + 1 = 3. Plan 08-02 was the migration-script scaffolding plan, which both gaps build on. |
| 4. Key links planned | PASS | `must_haves.key_links` wires `_preflight_plugins → fixture` (pattern `unsupported_plugin_option`) and `_promote → test` (pattern `os.replace`). The fixture-test wiring is concrete (file paths, test name, assertion shape). |
| 5. Scope sanity | PASS | 2 tasks; 2 modified files; 1 created fixture. Well below the 2–3 tasks/plan target. |
| 6. Verification derivation | PASS | `must_haves.truths` are user-observable ("generated plugins.yaml never contains ${...}", "if _promote fails ... `--out-dir` returns to its pre-promotion state"). `artifacts` map to those truths, and `key_links` connect the artifact that does the work to the test that proves it. |
| 7. Context compliance (D-05, D-15) | PASS | Locked decisions D-05 and D-15 are both delivered; deferred ideas (first-class `{env: ...}` references, multi-file flags, `` templates) are explicitly excluded. |
| 7b. Scope reduction detection | PASS | Action text for Task 1 reads "Do not expand, rewrite, redact into generated config, or accept `{env: ...}` as a secret-reference type" — this is a hard rejection, not a "v1 / static / placeholder" reduction. Action text for Task 2 reads "for each successfully promoted name without a backup, unlink the target" — full unlink, not a stub. |
| 7c. Architectural tier compliance | PASS | N/A — the script is a CLI; no tier map in `08-RESEARCH.md` for this phase. Logic is placed in the migration CLI module (`scripts/migrate_vigilo_config.py`) and the test module, both of which are the right homes. |
| 8. Nyquist compliance | PASS | Each task has `<verify>` with `<automated>` pytest commands. The Wave 0 slot is implicit in 08-02 (the test file already exists with parametrized `_run_migration_expect_issue` scaffolding; the new test composes with that). Sampling: Task 1 and Task 2 each have 2–3 pytest verify lines; no consecutive window of 3 implementation tasks without `<automated>`. |
| 9. Cross-plan data contracts | PASS | Only one plan (08-03) and only the migration script's internal data path. No cross-plan pipeline. |
| 10. AGENTS.md compliance | PASS | No `AGENTS.md` was loaded for this repo; the plan's coding choices (recursive preflight, unlink-on-rollback, TDD red-first) match the existing 08-02 patterns (dataclass-based `MigrationIssue`, `_run_cli` harness, `UNSUPPORTED_FIELD_CASES` parametrization). |
| 11. Research resolution | PASS | N/A — `08-RESEARCH.md` has no `## Open Questions` section, so this dimension is vacuously satisfied. |
| 12. Pattern compliance | PASS | `08-PATTERNS.md` patterns for `MigrationIssue`, the recursive preflight shape, and the `_run_migration_expect_issue` test helper are all reused; the plan adds the new fixture in the same naming family (`plugins_with_<reason>.yaml`) and the new test names follow the `test_<behavior>_<expected_outcome>` convention. |

## Plan-Goal Trace

```
Phase 8 goal (ROADMAP.md): "Maintainers can translate supported Vigilo/VDE YAML into strict Correlia config and get clear failures whenever Vigilo semantics cannot be preserved."

  D-05 (CONTEXT.md) = "do not emit ${...}/{env: ...} placeholders"
    → Task 1 preflight rejects both forms with unsupported_plugin_option / CFG-06
    → Test: test_plugin_option_placeholders_fail_before_output (asserts report.ok=False, generated=None, no files in out_dir)
    → Fixture: plugins_with_placeholder_option.yaml
    → Acceptance criterion: "_preflight_plugins recursively scans allowed email option values, including list items and mappings"
    → Traced: the plan is concrete enough that an executor will produce the recursive scan in scripts/migrate_vigilo_config.py:_preflight_plugins; the test will fail without it (RED) and pass with it (GREEN). ✓

  D-15 (CONTEXT.md) = "no partial/corrupted output files on failure"
    → Task 2 _promote tracks successful os.replace calls and unlinks newly-promoted targets on later failure
    → Test: test_promote_rolls_back_new_files_on_mid_promotion_failure (monkeypatches os.replace to fail on second call, asserts out_dir empty)
    → Acceptance criterion: "_promote preserves existing backup restore behavior and additionally unlinks newly-promoted files that had no pre-existing backup"
    → Traced: with the current _promote (scripts/migrate_vigilo_config.py:1083–1113), the test will fail because rules.yaml remains after topology.yaml raises; with the planned unlink loop, the test will pass. ✓
```

## Detailed gap-by-gap assessment

### D-05 (Task 1)

- **Fixture shape.** The plan asks for the new fixture to embed both `smtp_host: ${SMTP_HOST}` (exact `${...}` string) and a `to_addresses` list item shaped as `{env: OPS_EMAIL}` (exact `{env: ...}` mapping). Both forms are explicitly named in the test assertion. This is sufficient to pin D-05: an executor who copies the `plugins_valid.yaml` shape and substitutes these two values produces a fixture that exercises both literal forms.
- **Pre-existing fixture check.** `tests/fixtures/vigilo/plugins_with_credentials.yaml` is the closest sibling (same email config keys) — the executor should mirror its layout, which the plan directs. ✓
- **Recursive scan requirement.** The current `_preflight_plugins` at `scripts/migrate_vigilo_config.py:894–940` only iterates `for key in config:` and never descends into values. The plan's acceptance criterion explicitly states "scans allowed email option values, including list items and mappings, rather than only checking `smtp_host` strings" — this is a real structural change, not a key-list edit. The action block calls for a "small recursive preflight helper used by `_preflight_plugins` only for keys in `_ALLOWED_EMAIL_CONFIG_KEYS`," which is implementable against the existing helper structure.
- **Error code reuse.** The plan reuses `unsupported_plugin_option` / CFG-06 for the placeholder-value case. This is consistent with the threat-model entry T-08-03-03 ("reuses `unsupported_plugin_option` / CFG-06 rather than adding a new report surface") and matches D-05's intent of "must not emit" — the operator needs a clear, identifiable failure, not a new code family. ✓
- **Test asserts both pre-staging and pre-promotion failure.** `report["generated"] is None` + `not (out_dir / ...).exists()` covers both staging failure (no staging write) and promotion failure (no out_dir write). The plan does not assert "staging dir does not exist" because that is not part of the public contract; `report["generated"] is None` is the canonical signal. ✓
- **Regression protection.** The Task 1 verify block runs `test_unsupported_fields_fail -k plugins_with_placeholder_option` to pin the new fixture in the parametrized catalog, plus a second `-k` line that re-runs the unknown-option and credentials parametrizations. The plan's acceptance-criteria `<verify>` block re-runs the full module to catch any regression in `test_migrate_email_plugin` or the other plugin fixtures. ✓

### D-15 (Task 2)

- **Test precision.** The test monkeypatches `scripts.migrate_vigilo_config.os.replace` — this is a module-attribute monkeypatch, not a global one, and Python's `os.replace` calls in `_promote` resolve through the module-level `os` binding (`scripts/migrate_vigilo_config.py:1083–1113`). The test will work. ✓
- **Test scaffolding needs.** Staging dir with the three YAMLs, empty `out_dir`, monkeypatched `os.replace` that delegates to the real `os.replace` for `rules.yaml` and raises for the next call. The plan's action block describes each step in order. The post-condition assertion ("`out_dir` contains none of the generated YAML files afterward") is exact: with current `_promote`, `out_dir/rules.yaml` would remain; with the fix, it must be unlinked. ✓
- **Production change scope.** The plan's action block for Task 2 is targeted: track which `os.replace` calls succeeded, unlink newly-promoted targets that have no backup, keep the existing backup-restore branch intact, re-raise the original exception. This is a tight, minimal change to `_promote`. ✓
- **Regression protection.** The Task 2 verify block runs `test_cli_generates_files` (full happy path) and `test_validation_failure_leaves_existing_out_dir_untouched` (pre-promotion failure leaves pre-existing files). The acceptance-criteria verify block runs the full module. ✓
- **No contract drift.** The plan does not propose switching to atomic temp-dir-then-rename, which would be a larger refactor of the staged-then-promoted contract. The chosen fix preserves the existing staged-validate-promote contract and only closes the mid-promotion branch. ✓

## Testability wrinkle (warning, non-material)

Task 1's third verify command:

```
uv run pytest tests/test_vigilo_config_migration.py::test_migrate_email_plugin tests/test_vigilo_config_migration.py::test_unsupported_fields_fail -k "plugins_with_unknown_email_option or plugins_with_credentials or plugins_with_placeholder_option" -x
```

Pytest's `-k` applies to the entire test expression, so `test_migrate_email_plugin` is deselected from this specific invocation (its name contains no keyword from the `-k` filter). What actually runs is the parametrized `test_unsupported_fields_fail` nodes matching the filter. This means the line does not directly assert that `test_migrate_email_plugin` still passes — only the unknown-option/credentials/placeholder parametrizations. However:

1. The plan's acceptance-criteria `<verify>` block (after `</tasks>`) re-runs the full module: `uv run pytest tests/test_vigilo_config_migration.py -x`. That run covers `test_migrate_email_plugin` and all other regression tests.
2. The Task 1 verify block's third line is a strict superset of the second line's parametrized set: line 2 runs only the `plugins_with_placeholder_option` parametrization, while line 3 runs that plus `plugins_with_unknown_email_option` and `plugins_with_credentials`. The third line's only unique added value over line 2 is the explicit `test_migrate_email_plugin` node, which the `-k` filter then deselects. So line 2 is a strict subset of line 3's parametrized coverage, and line 3 is redundant rather than broken.

So the line is redundant rather than broken. I am noting it as a warning (test-design clarity, not a coverage gap). If the planner wants to tighten the line, the simplest fix is to drop the redundant third line entirely or change it to `test_migrate_email_plugin test_unsupported_fields_fail` without a `-k` filter. **Not a blocker.**

## Acceptance-criteria coverage check

The plan's `<acceptance_criteria>` block enumerates 7 bullets. Each one is a verifiable, file- or test-scoped statement:

1. Fixture exists with both placeholder forms. → Test 1's fixture create. ✓
2. New test proves CLI failure with `unsupported_plugin_option` / CFG-06 for both forms. → Test 1's assertions. ✓
3. `_preflight_plugins` recursive scan of values/lists/mappings. → Action block 1. ✓
4. `_transform_plugins` continues to map only accepted values. → Action block 1 explicitly states "Do not expand, rewrite, redact into generated config, or accept `{env: ...}`." ✓
5. New test monkeypatches `os.replace` to fail on second call and asserts no generated YAML remains. → Test 2. ✓
6. `_promote` preserves backup restore and additionally unlinks newly-promoted files. → Action block 2. ✓
7. No changes to 08-01/08-02 plans or their SUMMARY files. → Plan frontmatter `gap_closure: true` and Execution Context preamble. ✓

All seven acceptance criteria are pinned to a concrete code/test location. No "we'll know it when we see it" language.

## Threat-model coherence

The plan's STRIDE table (T-08-03-01 through T-08-03-03) maps to:
- Information disclosure / placeholder syntax: mitigated by the recursive preflight. ✓
- Tampering / partial output: mitigated by the unlink-on-rollback. ✓
- Repudiation: accepted (existing report shape is reused, no new report surface). ✓

No leftover threats. The threat model is small, accurate, and aligned with the two gaps.

## Structured issues

```yaml
issues:
  - dimension: test_design
    severity: warning
    plan: "08-03"
    task: 1
    description: "Task 1's third <verify> command combines an explicit test node 'test_migrate_email_plugin' with a -k filter that does not match that test, so the test is deselected from that one invocation. The full module verify in the acceptance-criteria <verify> block still runs test_migrate_email_plugin, so coverage is intact; the third line is redundant with the second line that already exercises the unknown-option/credentials/placeholder parametrizations. This is a test-clarity issue, not a coverage gap."
    fix_hint: "Either drop the third verify line (the second line and the module-wide verify already cover the same ground) or remove the -k filter to make the line's intent ('exercise the valid email transform alongside the rejection parametrizations') explicit."
```

## VERIFICATION PASSED
