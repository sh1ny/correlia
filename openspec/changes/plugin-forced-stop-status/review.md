# Review

## Metadata

- **Round:** 3
- **Prior round:** Round 2 APPROVE_WITH_CHANGES; C1 and M2 outstanding
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Prior review and Round 2 response; design.md, tasks.md, both specification deltas; `plugin_supervisor.dart` constructor, launch, removal, persistence and shutdown paths; `OutputPluginConnection.start` and its catch; `PluginLaunchCore` lifecycle and cleanup. Read-only design re-check of the four Required Changes. No files modified or tests run.

## Findings

### Critical (blocking)

None outstanding.

### Moderate

None outstanding.

The revised launch test waits for the fixture’s configure marker before calling `stop()`. This places shutdown after spawning and beyond `_launch`’s pre-start shutdown guards (`plugin_supervisor.dart:254-255` and its guard before `OutputPluginConnection.start`). The configure deadline then enters the startup catch (`output_plugin_connection.dart:357-370`), where the proposed reap-outcome preservation applies.

The revised removal test holds `_remove` before `connection.stop()`, rather than before persistence. Calling supervisor `stop()` completes `_stopped` synchronously before waiting for tracked operations (`plugin_supervisor.dart:581-610`). Releasing the hook therefore permits the forced reap only after shutdown begins.

The supervisor constructor accepts injectable `durations` and `pollInterval`; startup passes `startTimeout` and `shutdownGrace` to the connection. Failed-start cleanup currently calls `core.stop()`, whose grace is two seconds rather than the injected shutdown grace. That does not invalidate the configure-marker sequencing or forced-reap coverage: `PluginLaunchCore._cleanup` retains the child PID and sets `forcedStop` before subsequent cleanup can fail.

### Suggestions

None; review limited to the four prior findings.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Close C1’s ownership gaps** in design, tasks and test map. Preserve child identity and forced-reap outcome across failed startup and cleanup errors; record the forced key independently of successful status persistence or ancillary cleanup. Add deterministic regression scenarios for both paths. Retain error propagation. **Accepted by reviewer.**
2. **Bound D1 bookkeeping:** track only unsettled status operations, retire settled entries during normal operation, and describe the shutdown drain/fence ordering. Do not retain all historical instances or tails. **Accepted by reviewer.**
3. **Add deterministic supervisor-level D1 coverage:** hold a removal across shutdown initiation, release it, and verify the final stopped reason after all writes settle. Cover a shutdown-overlapping launch and assert that no subsequent supervisor status write occurs. Map these tests explicitly rather than relying on D3 reproduction. **Accepted by reviewer.**
4. **Specify and test failed-stop behavior:** qualify the successful concurrent-stop scenario; add sequential and concurrent cases where the initial stop fails. Assert that the first caller receives the error, later callers wait and complete normally, and remaining cleanup is attempted without rerunning component stops. **Accepted by reviewer.**

CHANGES_APPLIED: yes

## Rebuttals

- **C1 — accepted by reviewer.** D1 preserves startup PID and forced-reap outcome through exception fields, reads removal outcomes in a `finally`, and records forced keys independently of status persistence. Testing Strategy and task 2.2 now reach an actual spawned child blocked in configure. The cleanup-failure scenario injects failure after SIGKILL and checks the final row, diagnostic and write ordering while retaining shutdown error propagation.

- **M1 — accepted by reviewer.** Acceptance from Round 2 stands. D1 and State & Ownership retain only unsettled writes, retire entries on settlement, and explicitly order operation completion, remaining removals, fence closure, write drain and final `markStopped`.

- **M2 — accepted by reviewer.** Both incorrect synchronization boundaries are corrected in Testing Strategy and task 2.2. The configure marker replaces the ineffective `beforeLaunch` hold. The pre-stop removal hook replaces the post-reap pre-write hold. Both scenarios assert the final forced reason, a shutdown-time forced-reap diagnostic and final-write ordering.

- **M3 — accepted by reviewer.** Acceptance from Round 2 stands. The process-roles delta, D4 and task 3.1 distinguish successful concurrent stops from sequential and concurrent failed stops. They require first-caller error propagation, later-caller waiting and normal completion, remaining cleanup, and once-only component stops.

**Round 2 response (author):**

- C1 and M2: fixed. The design's Testing Strategy and task 2.2 now hold at the right points.
  - Launch overlap: the stalling fixture mode creates a marker file on configure. The test waits for the marker, so the child is spawned and inside configure, and only then calls `stop()`. The startup then fails at the injected short start timeout, and its cleanup force-terminates the child after shutdown began.
  - Removal in flight: the hook moved to `_remove` before the connection is stopped, before the reap. `stop()` is called while the removal is held there, then the hook is released, so the forced reap happens after shutdown began.
  - The tests construct `PluginSupervisor` directly with injected short durations.

**Reviewer disposition — accepted by reviewer.** The revised documents resolve the outstanding design-review findings. Acceptance verifies the planned sequencing against current source; implementation and runtime verification remain unchecked tasks.