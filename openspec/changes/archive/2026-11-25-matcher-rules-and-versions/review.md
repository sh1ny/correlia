# Review

## Round 6: original design

## Metadata

- **Round:** 6
- **Prior round:** REVISE. The owner approved counting pending routes in the existing capacity limit, the three moderate fixes, and this re-review.
- **Reviewer:** Independent Codex design reviewer
- **Reviewed:** Proposal, FULL design, matcher-rules spec, round 5 review, Specwright review instructions and template, roadmap M2 item 5, applicable ADRs, and cited tracked source. Static review.

## Findings

### Critical (blocking)

1. **The new capacity check can prevent workers from starting on a valid pre-upgrade database.** Under the current publisher, snapshot A can leave a pending pin with a source route to X and no outbox intent. Snapshot B can then activate with 64 different output IDs because the current check counts candidate outputs and live intents. If the pin is still pending at cutover, the new check counts 65 IDs and rejects B’s exact file before reaching the identical-startup return. A worker started without the file also refuses to start while an active snapshot or pending work exists. The rollout stops older workers before deploying the new ones, so no worker can drain the pin. Define how cutover handles this existing state, and add a populated-database scenario that proves the pending work can drain with its original pin and the exact active file can start. [Capacity check and identical return](correlia_server/lib/src/ingest/config_repository.dart#L186) · [Startup without bootstrap](correlia_server/lib/src/ingest/config_repository.dart#L479) · [Cutover design](openspec/changes/matcher-rules-and-versions/design.md#L228)

### Moderate

1. **The matcher routing design needs to distinguish stale stream observations from stale webhook observations.** The design groups both under a generic stale delivery gate. The pipeline suppresses routing for stale stream observations, and the durable-pipeline spec requires stale webhook observations to remain routable. State that matcher-added routes use the same delivery eligibility as source routes. Cover a matching stale webhook that gets both routes and a matching stale stream observation that gets neither. [Matcher routing design](openspec/changes/matcher-rules-and-versions/design.md#L224) · [Current routing gate](correlia_server/lib/src/pipeline/pipeline.dart#L698) · [Durable-pipeline requirement](openspec/specs/durable-pipeline/spec.md#L266)

### Suggestions

None.

## Verdict

`VERDICT: USER_OVERRIDE`

## Required Changes

`CHANGES_APPLIED: n/a`

After six consecutive REVISE rounds the owner accepted the design with D12 and the delivery-eligibility clarification: “A: upgrade refuses until old work drains”; “No, go to tasks”. The open findings from round 6 are listed above; the author incorporated both design/spec revisions. They were not re-reviewed, and this override does not authorize apply.

## Rebuttals

- **Round 5 first-pin race is addressed for publications under the new protocol.** The active-row lock serializes first pins with publication, and one inventory statement sees either the pending route or its committed intent. The spec covers both race orders and restart after the transition. The blocker above concerns state already admitted under the old protocol. [Lock and inventory design](openspec/changes/matcher-rules-and-versions/design.md#L221) · [Capacity scenario](openspec/changes/matcher-rules-and-versions/specs/matcher-rules/spec.md#L87)
- **All three round 5 moderate fixes are present.** The shared cutoff covers regex and non-regex work with a controlled-clock scenario. The publication requirement explicitly accepts the original expectation on identical restart. Matcher documents persist `language` and `version` and reject missing or unsupported discriminators. [Cutoff scenario](openspec/changes/matcher-rules-and-versions/specs/matcher-rules/spec.md#L108) · [Publication requirement](openspec/changes/matcher-rules-and-versions/specs/matcher-rules/spec.md#L59) · [Persisted matcher contract](openspec/changes/matcher-rules-and-versions/design.md#L213)

## Round 7: D13 implementation drift

- **Reviewer:** Codex design reviewer (`codex-cli 0.167.0`, model and thinking level unreported)
- **Scope:** D13 amendment to `design.md`, `specs/matcher-rules/spec.md`, and `tasks.md`. The round-6 override still covers the unchanged design.
- **Evidence:** Static review of the amendment, planning context and tracked PostgreSQL event storage and text projection SQL. No tests run.

### Findings

No critical or moderate findings.

Suggestion: Exercise an admitted pattern at the complexity limit through both Dart and the PostgreSQL lowering. Use a repeat over an atom whose lowering adds alternatives and grouping. Pair it with a just-over-budget parser rejection. Retain simple `{255}` and `((a{255}){255}){255}|b` cases. The boundary pair distinguishes reaching the limit from exceeding it.

### Verdict

VERDICT: APPROVE

CHANGES_APPLIED: n/a