# Review

## Metadata

- **Round:** 6
- **Prior round:** Round 5, APPROVE_WITH_CHANGES; M1–M6 applied, CHANGES_APPLIED: yes.
- **Reviewer:** Fresh-context, read-only Codex reviewer.
- **Reviewed:** Proposal, design, both delta specs, tasks and round-5 review; AGENTS.md; ADRs 0002 and 0014; amendment commit db0cffd; requested Serverpod 4.1.0 sources and supporting process-identity, binary-resolution and shutdown sources; PostgreSQL 16 `pg_ctl` source; current test command, command tests, tier configuration, database smoke test and mise tasks; Serverpod testing and Dart CLI skills. No files modified or runtime tests executed.

This verdict covers only the contents reviewed. Editing proposal, specs or design afterward, other than applying Required Changes or editing only the proposal’s Release Notes section, voids it.

## Findings

### Critical (blocking)

**C1 — A data-directory argument does not establish ownership of the process being stopped.**

D4 authorizes shutdown whenever `.serverpod/test/pgdata/postmaster.pid` exists. PostgreSQL’s `get_pgpid()` reads its first integer; `do_stop()` then calls `kill(pid, sig)` without checking the live process’s executable, data directory or start time. With `-m fast`, that signal is SIGINT. `-D` selects the pidfile, not a verified process identity. [PostgreSQL 16 source](https://github.com/postgres/postgres/blob/REL_16_STABLE/src/bin/pg_ctl/pg_ctl.c)

Concrete failure: an abruptly terminated cluster leaves `postmaster.pid`; its PID is subsequently recycled to another same-user process, potentially Hindsight’s postmaster. A later **fast-only** `tool test` never starts Serverpod or invokes stale-lock repair, but its unconditional post-run cleanup reads that stale file and signals the unrelated process. Reporting a failed stop afterward cannot undo the signal.

Serverpod’s existing recovery has an additional boundary that the amendment omits: `stale_lock_repair.dart` requires matching native and supervisor pidfiles and `isPostmasterOrphan()`, which checks the live process against the recorded executable and data directory.

The proposed fake-stopper test, ordinary decoy sockets and task 9.4’s surviving port-5432 listener do not exercise recycled-PID rejection. The amendment therefore does not yet satisfy the spec’s prohibition on signalling another PostgreSQL.

### Moderate

None.

Concurrent runs on one clone are explicitly unsupported. Nevertheless, the proposed cleanup can stop another run’s active shared cluster; any ownership correction must ensure an overlapping invocation fails or waits before cluster access and cannot clean up the current owner’s cluster.

### Suggestions

None.

The remaining amendment is feasible: `integration` exclusion and an executable-call-aware tier-tag guard can enforce the intended fast loop. The pinned bundle contains `pg_ctl`; resolution must follow Serverpod’s cache overrides and bundle/platform selection. Awaiting the completed test subprocess avoids racing that run’s ordinary shared-cluster consumers. The separate kill-test and e2e roots remain outside D4 cleanup.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **C1:** Amend D4, State & Ownership and the Mechanism Ledger to require verified live cluster identity before any stop signal, with safe refusal when identity is missing, mismatched or ambiguous. Specify protection against PID reuse between verification and signalling; mere pidfile existence, `kill(pid, 0)` or `pg_ctl -D` is insufficient. Define exclusive ownership spanning test startup through cleanup so another invocation cannot attach during shutdown or stop an active owner’s cluster.

2. Extend task 3.2 and the workspace-tooling acceptance scenarios to cover a stale pidfile referencing a live unrelated process, missing/mismatched ownership metadata, and overlapping invocations. Assert that the unrelated process receives **no signal**, including after a fast-only run. Use disposable controlled processes, never Hindsight. Retain successful cleanup, failed-test exit preservation, stop-failure reporting and isolation from kill-test/e2e roots. Include these checks in the evidence collected by task 9.4.

CHANGES_APPLIED: no

## Rebuttals

- **M1:** Fixed in D7, shutdown sequencing, failure handling and process-roles scenarios. **Previously accepted by reviewer; carried forward.**
- **M2:** Fixed through sibling-directory cluster roots, identity assertions and side-by-side isolation scenarios. **Previously accepted by reviewer; carried forward.**
- **M3:** Fixed through D17’s startup indicator, D16’s readiness wait and gated-subsystem scenario. **Previously accepted by reviewer; carried forward.**
- **M4:** Fixed through argument-sensitive fast selection and load exclusion. **Previously accepted by reviewer; carried forward.**
- **M5:** Fixed through the independent temporary generation workspace and unchanged-checkout assertions. **Previously accepted by reviewer; carried forward.**
- **M6:** Stable roots, conditional teardown deletion and next-run recovery address abandoned-root accumulation. **Previously accepted by reviewer; carried forward.**
- **M6 (round 3 follow-up):** Test-only stdin-EOF shutdown addresses an orphaned child server. **Previously accepted by reviewer; carried forward.**
- **M6 (round 4 follow-up):** Child-held root locking supplies ownership handoff for kill-test/e2e children. **Previously accepted by reviewer; carried forward.**
- **C1:** Open; no rebuttal or correction reviewed.