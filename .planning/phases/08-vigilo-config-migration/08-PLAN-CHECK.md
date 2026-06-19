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
