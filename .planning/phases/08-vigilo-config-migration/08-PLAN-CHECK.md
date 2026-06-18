# Phase 8 Plan Check

**Phase:** 8 — Vigilo Config Migration
**Plans reviewed:** `08-01-PLAN.md`, `08-02-PLAN.md`
**Iteration 1 Status:** Superseded by Iteration 2 revision below.
**Iteration 2 Revision Status:** ADDRESSED (0 active blockers, 0 active warnings; all five findings addressed in plan files).

## Scope of Review

Verified goal-backward coverage of CFG-01..CFG-07 against the locked decisions D-01..D-15, Phase 8 success criteria, and the research/pattern guidance. Validated task structure (files/action/verify/done), dependency ordering (08-01 before 08-02), scope sanity, must_haves derivation, key-link wiring, threat-model coverage, and acceptance-criteria completeness.

Coverage of CFG-01..CFG-07 across the two plans:

| Req | Plan(s) | Coverage |
|-----|---------|----------|
| CFG-01 | 08-02 | Covered — CLI flags and three output files (08-02 acceptance criteria, action 2) |
| CFG-02 | 08-02 | Covered after Iteration 2 — severities, host/service patterns, `match.tags` key prefixing, `window.group_by` topology-key prefixing, summary rewrite, priorities, and actions. |
| CFG-03 | 08-01, 08-02 | Covered — strict hostname/subnet schema and transform |
| CFG-04 | 08-01, 08-02 | Covered — coordinated schema + compiler + enricher in 08-01, transform in 08-02 |
| CFG-05 | 08-02 | Covered — fixed email class path, TLS mapping, credential fail-closed |
| CFG-06 | 08-02 | Covered — preflight catalog, aggregated report, non-zero exit |
| CFG-07 | 08-02 | Covered — staged temp-dir validation through the three loaders plus `load_plugin_registry` instantiation |

Decision coverage D-01..D-15: all 15 decisions are referenced in the plan source-coverage audits (08-01 rows for D-07/D-08/D-09/D-10/D-11; 08-02 rows for D-01..D-15). No deferred-idea scope creep detected (env-reference placeholders, multi-file flags, and `\1` tag template syntax are explicitly excluded).

Task structure: every `<task>` carries `<files>`, `<action>`, `<verify>` (with `<automated>`), and `<done>`. Dependency graph acyclic; wave assignment consistent with `depends_on`. Scope: 3 tasks per plan, 2 files modified in 08-01 and 1 new test file, 8 fixture files plus 1 new test module plus 1 new script plus 1 doc update in 08-02 — within budget.

Threat models in both plans cover the meaningful trust boundaries (operator YAML → loader, staging dir → `--out-dir`, plugin-class translation, credential handling) and are consistent with the locked decisions.

## Anti-Findings Considered and Rejected

- **No `*VALIDATION.md` / no project `AGENTS.md`:** Out of scope for this plan check; the phase plans themselves do not require either.
- **08-02 missing `<tasks>` block:** Confirmed present at `08-02-PLAN.md` lines 156-184 (`Task 1`, `Task 2`, `Task 3`); not a finding.
- **Scope creep on deferred ideas:** The plans correctly avoid emitting env-reference placeholders, multi-file flags, and `\1` tag template syntax, all of which are listed in the deferred-ideas section of `08-CONTEXT.md`.
- **Dependency graph:** `08-01` has `depends_on: []` and `08-02` has `depends_on: ["08-01"]`; waves are consistent and acyclic.
- **Must-have truth wording:** All `must_haves.truths` are user-observable (CLI invocation, rule field shapes, validation behavior) rather than implementation details.
- **Key-links wiring:** `08-02-PLAN.md` `key_links` correctly connect the generated outputs to the loaders (`load_plugin_registry_config` → `load_plugin_registry` → `load_rules_config` known_plugins → `load_topology_config`), which is the exact loader chain `app/main.py:129-153` runs at startup.
- **Threat models:** Both plans cover the relevant trust boundaries and the threat register IDs are consistent with D-04..D-15.

## Resolved Historical Items from Iteration 1

1. **Resolved item 1 — 08-01 per-task verify/test ordering.** Loader tests are now part of Task 1, enrichment tests are now part of Task 2, and Task 3 is a focused regression pass.
2. **Resolved item 2 — 08-01 `tag_capture_groups` key-prefix coverage.** `test_load_topology_config_rejects_capture_group_key_without_topology_prefix` is now named in Task 1 action, verify, artifact coverage, and acceptance criteria.
3. **Resolved item 3 — 08-02 `window.group_by` topology-key rewriting.** Rule transform instructions now preserve normalized fields while prefixing bare topology keys to `topology.*`; fixture, test, source coverage, and acceptance criteria now pin the behavior.
4. **Resolved item 4 — 08-02 `match.tags` key-prefix coverage.** `test_migrate_rules_prefixes_match_tags_keys` is now included in the test artifact list and Task 1/Task 2 verify blocks.
5. **Resolved item 5 — 08-02 report-shape coverage.** `test_report_shape` and acceptance criteria now pin `ok`, `errors[].code`, `errors[].requirement`, and failure `generated: null`.

## Iteration 1 Rationale (Superseded)

The iteration-1 review found the plans substantively correct: requirement coverage was complete, decisions were honored, dependency ordering was right, scope was within budget, and the threat model covered the meaningful risks. Its five requested changes were mechanical coverage and specificity fixes around per-task test ordering, tag-prefix enforcement, `group_by` rewriting, `match.tags` prefixing, and report-shape pinning.

The Iteration 2 revision applies those requested changes in the two plan files and records the current status above.

## ITERATION 1 SUMMARY (SUPERSEDED)

1. **Resolved item 1 — 08-01 per-task verify/test ordering.** `08-01-PLAN.md` now keeps loader tests in Task 1, enrichment tests in Task 2, and full regression checks in Task 3.
2. **Resolved item 2 — 08-01 capture-group key-prefix coverage.** `test_load_topology_config_rejects_capture_group_key_without_topology_prefix` is now named in Task 1 action, verify, artifact coverage, and acceptance criteria.
3. **Resolved item 3 — 08-02 `window.group_by` topology-key rewrite coverage.** The rule transform, fixture instructions, focused test, source coverage, and acceptance criteria now require bare topology keys to become `topology.*`.
4. **Resolved item 4 — 08-02 `match.tags` key-prefix coverage.** `test_migrate_rules_prefixes_match_tags_keys` is now included in artifact coverage and Task 1/Task 2 verify blocks.
5. **Resolved item 5 — 08-02 JSON report-shape coverage.** `test_report_shape` and acceptance criteria now pin `ok`, `errors[].code`, `errors[].requirement`, and failure `generated: null`.

## Revision Note — Iteration 2

Applied by `PlannerPhase8Iter2` after reading the current Phase 8 plans, context, research, pattern map, requirements, roadmap, state, and iteration-1 plan check.

- Finding 1: addressed in `08-01-PLAN.md` by keeping loader tests in Task 1 and enrichment tests in Task 2 as their own red→green cycles; Task 3 now remains a regression pass instead of the first place named tests appear.
- Finding 2: addressed in `08-01-PLAN.md` by naming `test_load_topology_config_rejects_capture_group_key_without_topology_prefix` in Task 1 action, verify, artifact coverage, and acceptance criteria.
- Finding 3: addressed in `08-02-PLAN.md` by requiring explicit `window.group_by` rewriting for bare topology keys, adding fixture coverage, adding `test_migrate_rules_prefixes_group_by_topology_keys`, and pinning acceptance criteria.
- Finding 4: addressed in `08-02-PLAN.md` by adding `test_migrate_rules_prefixes_match_tags_keys` to the test artifact list and Task 1/Task 2 verify blocks.
- Finding 5: addressed in `08-02-PLAN.md` by pinning the JSON report shape in planner decisions and acceptance criteria, and adding `test_report_shape` to the test artifact list and Task 1/Task 2 verify blocks.

**Remaining active issue count after revision:** 0 blockers, 0 warnings; total remaining issues are below 5.

## PLAN CHECK REVISION 2 COMPLETE
