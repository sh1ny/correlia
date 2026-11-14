# Review

## Metadata

- **Round:** 2
- **Prior round:** Round 1 APPROVE_WITH_CHANGES; three required changes.
- **Reviewer:** fresh-context subagent (OMP)
- **Reviewed:** `proposal.md`, `specs/workspace-tooling/spec.md`, `design.md`, and round-1 `review.md`; `correlia_server/test/support/child_server.dart`, `ingest_bootstrap_e2e_test.dart`, `pipeline_lifecycle_e2e_test.dart`, `pipeline_recovery_e2e_test.dart`, child-harness consumer references, and `tool/lib/src/server_test_tags.dart`. Applicable testing skills read.
- Re-check limited to M1–M3. Source inspection only; no tests run or files changed.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

### Critical (blocking)

None.

### Moderate

**M1 — Existing timeouts violate the new cumulative-budget requirement. Resolved in planning.**

D1 now defines a cumulative budget, requires an inventory of existing child-server tests, and requires raising every insufficient timeout. It explicitly identifies the lifecycle, bootstrap, and recovery cases. The lexical guard is correctly described as presence-only, not proof of budget adequacy.

The current source confirms the cited sequential starts and insufficient three-minute timeouts. Updating them and committing the inventory remain implementation obligations; the revised plan no longer limits timeout changes to ingress.

**M2 — Replacing `exitCode` breaks callers already observing the previous future. Resolved in planning.**

D2 now specifies one stable logical-child exit future, completed only by the final attempt. Retry decisions belong to the attempt-exit handler, so intermediate bind failures cannot escape through futures already captured by the two existing `Future.any` callers.

Stop, kill, and stdin closure suppress further retries before awaiting an in-progress spawn, then act on that attempt. The spec covers both concurrent exit/readiness observation and teardown during a pending retry. These semantics address the existing callers without migration.

**M3 — HTTP 200 does not identify the child whose port was stolen. Resolved in planning.**

D4 requires both readiness success and API-listener ownership by the current attempt’s PID, using Linux socket inodes and process file descriptors. An unrelated listener’s 200 is ignored rather than accepted.

The spec and D3 require a deterministic competing HTTP listener returning 200, rejection of that false readiness, and replacement on fresh ports. The former “cannot happen” claim is removed. The mechanism is consistent with the harness’s direct server-VM PID.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

No outstanding planning edits. Round-1 Required Changes 1–3 are addressed by D1, D2, D4, and their corresponding specification scenarios. This approval covers the revised design, not implementation completion.

CHANGES_APPLIED: yes

## Rebuttals

- **M1 — fixed; accepted by reviewer.** The spec states the budget per child in sequence (“Child server tests budget their own deadlines”). D1 adds the budget formula, an inventory of every child-server test with raises for those below budget—including `pipeline_lifecycle` and `ingest_bootstrap`—and explicitly limits the lexical check to timeout presence. Context identifies the under-budget tests.
- **M2 — fixed; accepted by reviewer.** D2 moves retry decisions into the attempt-exit handler and makes `exitCode` one stable completer completed only by the final attempt. Stop, kill, and stdin closure set a stop flag first and act on an attempt being spawned. The new ownership requirement includes “Caller waits on exit and readiness together” and “Teardown while a retry is pending.” Context identifies both existing `Future.any` callers.
- **M3 — fixed; accepted by reviewer.** D4 accepts `/startupz` success only when the API listener’s socket inode belongs to the attempt PID. The stolen-API-port scenario and D3’s competing `HttpServer` returning 200 exercise rejection of another listener and retry onto fresh ports. The contradictory “cannot happen” claim is removed.