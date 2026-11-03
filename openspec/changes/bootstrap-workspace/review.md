# Review

## Metadata

- **Round:** 7
- **Prior round:** Round 6, APPROVE_WITH_CHANGES; C1 critical, CHANGES_APPLIED: no.
- **Reviewer:** Fresh-context, read-only Codex reviewer.
- **Reviewed:** Commit 5f0f675 diff first; proposal, design, both delta specs, tasks and round-6 review; AGENTS.md; ADRs 0002 and 0014; all requested Serverpod 4.1.0 sources plus `pg_ctl.dart`; current test command, tier configuration and mise tasks; pinned Dart SDK process patch and upstream Linux process implementation. No files modified or runtime tests executed.

This verdict covers only the contents reviewed. Editing proposal, specs or design afterward, other than applying Required Changes or editing only the proposal’s Release Notes section, voids it.

## Findings

### Critical (blocking)

**C1a — The child `Process` object does not establish the claimed PID-reuse protection.**

Serverpod’s `Supervisor.start` launches `postgres -D …` directly with `ProcessStartMode.normal`; there is no intermediate process. However, D4’s assertion that it remains an “unreaped child” until shutdown is unsupported.

The pinned SDK’s `process_patch.dart` implements `Process.kill` as an `_ended` check followed by `_killPid(pid, signal)`. `_ended` becomes true when the Dart event loop receives the exit notification. Dart’s upstream Linux implementation reaps children on a separate thread before delivering that notification, and its kill operation uses the numeric PID. Thus, absence of the Dart completion does not prove that the PID remains reserved. [Dart Linux process implementation](https://github.com/dart-lang/sdk/blob/main/runtime/bin/process_linux.cc)

Concrete failure: the postmaster exits, the runtime reaps it, its PID is reused, and shutdown runs before the exit notification is processed. `Supervisor.stop` can then signal the replacement process. The fetched native source is upstream `main`, not the unavailable pinned revision; the pinned Dart patch itself provides no atomic identity guarantee. The amendment therefore has not demonstrated the protection explicitly required by round 6.

**C1b — Enabled stale-lock repair retains the pidfile-based signalling path and contradicts live-cluster refusal.**

In `embedded_postgres_impl.dart`, stale-lock repair runs **before** the live-`postmaster.pid` rejection. In `stale_lock_repair.dart:72–92`, matching pidfiles plus `isPostmasterOrphan` lead to `pg_ctl stop -m immediate`, followed by PID-based SIGTERM/SIGKILL if the numeric PID remains alive.

Consequences:

- A live postmaster left by a killed owner is stopped and restarted, contrary to D4’s explicit “fail … and signals nothing.”
- Identity verification and signalling remain separate operations. In particular, after awaiting `pg_ctl`, the fallback checks only PID liveness; a recycled unrelated PID can receive a signal.

A separate preflight could reject live or ambiguous state without sending a terminating signal, but D4 does not specify that boundary before repair. Its blanket claim that no path signals a process found through a pidfile is false for the selected configuration.

### Moderate

**M7 — The new tests do not exercise the remaining ownership failures.**

The stale-pidfile scenario with a spawned `sleep` checks an already-foreign PID. It does not exercise a verified postmaster exiting between verification and signalling, missing/mismatched supervisor metadata explicitly requested in round 6, or an existing live orphan encountered before startup.

Consequently, all three new scenarios can pass while C1a and C1b remain. Also, D4’s refusal of a surviving shared postmaster conflicts with the existing unconditional requirement that a killed test run’s successor recover and pass.

### Suggestions

None.

The proposed outer lock spans startup, tests and cleanup and therefore addresses overlapping cooperating `tool test` invocations. Serverpod’s attachment path is also supported: while the owner remains alive, stale repair leaves its postmaster alone; `startOrAttach` returns `launched: false`, the resolver exposes no stop callback, and ephemeral-test teardown drops its database without stopping the shared cluster.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **C1a:** Correct D4’s unreaped-child claim. Specify and substantiate a shutdown mechanism that binds signals to the owned process despite concurrent exit and reaping. A Dart `Process` object, completion check or repeated identity check alone is insufficient. Update State & Ownership and the Mechanism Ledger consistently.

2. **C1b:** Specify the non-signalling preflight before any potentially signalling recovery. Define refusal for live, foreign, missing or ambiguous ownership state. Ensure enabled recovery cannot bypass that refusal or reintroduce a verification-to-signal PID-reuse race.

3. **M7:** Extend the acceptance scenarios, task 3.2, test map and task 9.4 evidence to cover live-cluster refusal, missing/mismatched metadata and controlled exit/reuse races at the shutdown and recovery boundaries. Use disposable processes or deterministic injected boundaries only. Reconcile the killed-run recovery requirement with the chosen live-orphan policy.

CHANGES_APPLIED: no

## Rebuttals

- **M1:** Shutdown sequencing and failure handling. **Previously accepted by reviewer; carried forward.**
- **M2:** Separate cluster roots, identity assertions and isolation. **Previously accepted by reviewer; carried forward.**
- **M3:** Correlia startup indicator and readiness gate. **Previously accepted by reviewer; carried forward.**
- **M4:** Argument-sensitive fast selection and load exclusion. **Previously accepted by reviewer; carried forward.**
- **M5:** Independent temporary generation workspace. **Previously accepted by reviewer; carried forward.**
- **M6:** Stable roots, conditional deletion, stdin-EOF shutdown and child-held ownership handoff. **Previously accepted by reviewer; carried forward.**
- **C1:** **Not accepted by reviewer.** The amendment fixes unconditional fast-run cleanup and adds useful outer ownership locking, but the claimed child-handle safety is unproven and enabled stale-lock repair still signals pidfile-derived PIDs. The added scenarios do not cover those remaining paths.