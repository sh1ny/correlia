# Review

## Metadata

- **Round:** 9
- **Prior round:** Round 8, APPROVE (CHANGES_APPLIED: n/a).
- **Reviewer:** Fresh-context, read-only Codex reviewer.
- **Reviewed:** `git show HEAD`, `git show HEAD~1`, planning diff from `77820ff`; proposal, design, both delta specs, tasks and round-8 review; AGENTS.md; ADRs 0002 and 0014; Serverpod 4.1.0 embedded startup, supervisor, attach, identity and options sources; environment configuration parsing and Serverpod shutdown; uncommitted `child_server.dart` and `kill_recovery_test.dart`. No files modified or runtime tests executed.

This verdict covers only the contents reviewed. Subsequent planning edits other than applying Required Changes or editing only the proposal’s Release Notes section void it.

## Findings

### Critical (blocking)

**C2 — The external cluster’s startup failure paths still signal PostgreSQL.**

D7, State & Ownership and task 8.1 promise that nothing stops or signals `.serverpod/test-external/`, including when the library cannot start or attach. The selected API does not provide that guarantee:

- `supervisor/supervisor.dart`: `Supervisor.start()` catches readiness failures and calls `supervisor.stop()`. A startup timeout while PostgreSQL remains alive therefore sends SIGINT, escalating to SIGTERM and SIGKILL.
- `embedded_postgres_impl.dart`: after starting the supervisor, failure in `_ensureDatabase()` also calls `supervisor.stop()`.
- Neither cleanup is conditional on `detach` or `repairStaleLocks`. Those options disable signal hooks and stale-lock repair, respectively.

Consequently, a cold start or restart after reboot can signal PostgreSQL before the harness receives an exception. Catching that exception and failing with the root’s name cannot enforce the recorded “never signals” decision. The live-cluster attach path itself does not stop PostgreSQL; the defect is the implicit cleanup during startup.

### Moderate

None.

### Suggestions

None.

The planned external-database child can exercise Serverpod’s ordered shutdown and exit-0 SIGTERM path: an empty `SERVERPOD_DATABASE_DATA_PATH` clears the configured path in the inspected parser. Task 8.2 explicitly requires subsystem completion before pool closure and exit 0; the test map agrees.

D8, State & Ownership and task 9.4 consistently permit the external cluster to linger. The development-mode exit-143 limitation is explicitly recorded in D7, the diagrams and Risks; it is the owner-retained exception, not a newly discovered omission.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Amend D7 and task 8.1 to use a concrete cluster-start mechanism that cannot invoke PostgreSQL shutdown on readiness or database-initialization failure. The current `startOrAttach(detach: true, repairStaleLocks: false)` call is insufficient. If retaining that API requires accepting its implicit failure cleanup, obtain an explicit owner revision of the existing “never signals” decision and record that exception instead.
2. Update State & Ownership and the Mechanism Ledger to match the selected mechanism. Explicitly cover fresh start, live attach, restart after reboot and startup failure; require verification that the promised signal policy holds on those failure paths.

CHANGES_APPLIED: no

## Rebuttals

- **M1–M6:** Previously accepted by reviewer; carried forward.
- **C1/C1a:** Withdrawals previously accepted by reviewer; carried forward. No replacement shared-cluster shutdown mechanism is approved.
- **C1b:** Withdrawal previously accepted by reviewer; carried forward. Serverpod’s existing stale-lock repair remains the owner-chosen baseline.
- **M7:** Withdrawal previously accepted by reviewer; carried forward.
- **C2:** Open; no edits applied.