# Review

## Metadata

- **Round:** 5
- **Prior round:** Round 4, APPROVE_WITH_CHANGES: M1–M5 accepted; M6 partially applied because replacement startup lacked an ownership handoff.
- **Reviewer:** Fresh-context, read-only Codex reviewer.
- **Reviewed:** Proposal, design, both delta specs, round-4 review and author rebuttals; AGENTS.md; architecture and constraining ADRs 0001, 0002, 0003 and 0014; M1 roadmap and milestone plan; mise.toml, MCP configs and .gitignore; requested convention skills; cited Serverpod argument parsing, startup, shutdown, task-manager and health sources; embedded-Postgres configuration, stale-lock repair, process-identity and attached-supervisor sources; relevant scratch-template configuration and entry point. No files modified or runtime tests executed.

This verdict covers only the contents reviewed. Editing proposal, specs or design afterward, other than applying Required Changes or editing only the proposal’s Release Notes section, voids it.

## Findings

### Critical (blocking)

None.

### Moderate

None outstanding. The round-4 ownership-handoff finding is addressed in the design and its acceptance scenario.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **M1 — Applied and re-checked.** D7 retains one runtime-owned callback, sequential reverse-order stopping, continuation after individual failures and combined error propagation. The shutdown scenarios assert these behaviors. Serverpod’s task-manager and shutdown implementations support the chosen ordering.

2. **M2 — Applied and re-checked.** D8 and the ownership table use separate cluster roots with sibling `pgdata` and `run` directories. The specs assert database and socket confinement, side-by-side isolation and deletion after shutdown.

3. **M3 — Applied and re-checked.** D17 adds Correlia’s startup indicator; D16 waits on `/startupz`. The gated-subsystem scenario asserts that startup remains unhealthy until subsystem startup completes. This corrects Serverpod’s early built-in startup indication.

4. **M4 — Applied and re-checked.** D4 applies the fast preset when arguments select no tag and excludes load unless explicitly selected. The reporting-only and explicit-load scenarios preserve those distinctions.

5. **M5 — Applied and re-checked.** D5 specifies an independent temporary workspace, copied lockfile, offline dependency resolution and exclusion of checkout package configuration. The clean-clone scenario asserts successful comparison without changing the checkout.

6. **M6 — Applied and re-checked.** D8, D16, State & Ownership, Failure & Visibility and the Mechanism Ledger now specify a child-held root lock acquired before Serverpod construction and retained until process exit. Replacement startup waits for ownership release; timeout fails visibly before cluster access. Abrupt child death releases the lock and leaves recovery to Serverpod’s existing data-directory mechanism.

   The new “Re-run while the previous server is still stopping” scenario asserts waiting, successful handoff and safe deadline failure. Repeated interruption, child termination, bounded root count and untouched-decoy assertions remain present.

CHANGES_APPLIED: yes

## Rebuttals

- **M1:** Fixed in D7, the shutdown sequence, failure handling and process-roles shutdown scenarios. The owner’s `shutdownTasks` choice remains unchanged. **Accepted by reviewer.**

- **M2:** Fixed through sibling-directory cluster roots, identity assertions and side-by-side isolation scenarios. **Accepted by reviewer.**

- **M3:** Fixed through D17’s additional startup indicator, D16’s readiness wait and the gated-subsystem scenario. **Accepted by reviewer.**

- **M4:** Fixed through D4’s argument-sensitive fast preset and load exclusion, with reporting-only and explicit-load scenarios. **Accepted by reviewer.**

- **M5:** Fixed through D5’s self-contained temporary generation workspace and unchanged-checkout assertions. **Accepted by reviewer.**

- **M6:** Stable per-test roots, conditional teardown deletion and next-run Serverpod recovery address abandoned-root accumulation. **Accepted by reviewer.**

- **M6 (round 3 follow-up):** Test-only stdin-EOF shutdown addresses a harness dying while its child remains alive. The mode guard and retained interruption assertions cover the intended boundary. **Accepted by reviewer.**

- **M6 (round 4 follow-up):** The child-held kernel lock supplies the missing ownership handoff. Acquisition precedes Serverpod construction, release follows process exit, and timeout prohibits cluster access. The controlled shutdown-overlap scenario now tests the previously uncovered race. **Accepted by reviewer.**