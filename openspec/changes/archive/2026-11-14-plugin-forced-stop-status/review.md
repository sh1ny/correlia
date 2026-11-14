# Review

## Metadata

- **Round:** 5 (read-only re-check of the Round 4 required changes)
- **Prior round:** 4. It required fixes for M1, M2 and the m1–m3/m5 documentation, plus the m2 log line.
- **Reviewer:** cross-model CLI (Claude Code, Opus 5.5)
- **Tier:** FULL
- **Files reviewed:**
  - Change artifacts: `proposal.md`, `design.md`, `tasks.md`, `specs/plugin-supervision/spec.md`, `specs/process-roles/spec.md`, `evidence/gate-runs.md`
  - Implementation: `correlia_server/lib/src/plugin/plugin_host.dart` (start, `stopWithGrace` and `_cleanup` of `PluginLaunchCore`), `output_plugin_connection.dart`, `plugin_supervisor.dart`, `plugin_status_repository.dart`
  - Tests and fixture: `correlia_server/test/plugin/plugin_supervision_test.dart` lines 130–533; `test/plugin/fixtures/go/cmd/output-production/main.go`
  - Project rules: AGENTS.md lines 60–112 (tiers, no-sleep rule, Dart rules)
- **Limits:** I only read files. I did not run tests, builds, lint, formatters or analysis, and I edited nothing. I did not open any `/tmp` path. The timing claims below come from reading the code, not from running it. The workflow follow-up's carried failure, `plugin_protocol_test.dart: health_call_stalls_under_load`, is outside this re-check.

## Findings

### Critical

None.

### Moderate

None. M1 and M2 are fixed, details below.

**M1: the retained core-start future is fixed.**
- `OutputPluginConnection.start` now keeps `starting = core.start()` and wraps it in the outer timeout (`output_plugin_connection.dart:260-263`). After the barrier-guarded `core.stopWithGrace`, the catch awaits `starting` and takes `PluginStartupException.cleanupFailure` from it (`:402-408`).
- The error class is still chosen from the outer `error`, so a handshake stall still reports `plugin_start_timeout` (`:409-416`).
- Ordering is safe. `stopWithGrace` is serialized behind `start()` (`plugin_host.dart:234-238, 493`), so by the time `starting` is awaited it has already settled. The core's failure cleanup has already SIGKILLed the child and recorded `_forcedStop` (`:448-473`). The later `_cleanup` finds `_process == null`, so it does not call the injection a second time (`:524-552`).
- `reapedPid` and `reapedForcibly` are read after `stopWithGrace` (`:398-401`), so they reflect the forced reap.
- The fixture's `--stall-handshake-marker` writes its PID and SIGSTOPs itself before `plugin.Serve` (`main.go:133-139`).
- `handshake_cleanup_failure_survives_outer_timeout` checks four things: `stop()` throws the same injected error, the final row is `stopped`/`plugin_forced_stop`, health still records `plugin_start_timeout`, and there is exactly one forced shutdown reap line (`plugin_supervision_test.dart:486-519`).
- D1 (`design.md:69-72`) and the Failure Modes table (`:232`) are updated. The outer timeout is kept, as required.

**M2: the start-timeout race in the launch tests is fixed.**
- `beforeStartupCleanup` is a `@visibleForTesting` barrier. It runs before failed-start cleanup in both layers: the core (`plugin_host.dart:452-457`) and the wrapper (`output_plugin_connection.dart:390-395`). The supervisor passes it `_stopped.future` (`plugin_supervisor.dart:357-359`), and production passes null.
- The test's barrier marks itself entered and then waits for the stop signal (`plugin_supervision_test.dart:413-418`). The test waits for that entry before calling `stop()` (`:459, :484`).
- So the timeout can still fire first, but neither layer can reap the child before `_stopped` completes. `shutdown=true` and the retained cleanup error no longer depend on wall-clock timing.
- The handshake case enters the barrier twice, once from each layer. Both calls wait for the same stop signal, so it does not matter which layer's timeout fires first.
- The remaining waits are bounded event waits (inotify, completers, status polling), not sleeps. This meets AGENTS.md:87.
- The Testing Strategy (`design.md:255-256, 272-276, 284-288`) and task 2.2 match the code.

### Minor (fixed)

- **m1:** D1 now limits the retry claim to failed removals (`design.md:73-75`).
- **m2:** a failed startup cleanup before shutdown logs the fixed line `plugin supervisor startup cleanup failed`, which holds no values (`plugin_supervisor.dart:391-396`). The Failure Modes table records it (`design.md:234`).
- **m3:**
  - D1 step 1 and a diagram note say that `writeWaiting` and `prune` bypass `_persist` and are ordered by the loop await (`design.md:81, 179`).
  - The broader set of shutdown errors (removal, health and recovery operations) is in the Failure Modes table (`:233`) and in proposal Impact (`proposal.md:85-86`).
- **m5:**
  - The stale Context line numbers are gone.
  - The erasure technique is documented (`design.md:270-271`).
  - The diagram now has a failure branch with the error re-raised after the final write (`:184-197`).
  - Task 2.2 lists six regressions and their red states.
  - Proposal Impact names `output_plugin_connection.dart`, `plugin_host.dart` and the Go fixture.

### Suggestions

- **S1:** The configure-stall fixture now SIGSTOPs itself after writing the marker (`main.go:49-52`). The Testing Strategy (`design.md:260-261`) and task 2.2 (`tasks.md:75-76`) still say it "blocks and ignores the shutdown request". The behaviour is effectively the same, but the wording could name the SIGSTOP.
- **S2:** `gate-runs.md:96` records a passing `mise run check` on the corrected code but names no commit, and the working tree is still uncommitted. After committing, record that head's hash for 4.1. The full-tier runs are already disclosed as predating the review fixes; one `test:all` on the final head would close that gap.
- **S3 (Round 4 m4, still optional):** `PluginSupervisor.stop` is not memoized. A repeated direct call would issue a second `markStopped`. D4 prevents this in production through `IngestWorkers.stop`.
- **S4:** `OutputPluginConnection.start` declares `late final Future<void> starting`, assigned as the try block's first statement. Assigning it before the `try` would remove the theoretical `LateInitializationError` path at `:403`. This is cosmetic.

## Verdict

All Round 4 required changes are applied, and the specification is unchanged and not narrowed. Nothing new blocks shipping; the remaining items are optional suggestions.

VERDICT: APPROVE
CHANGES_APPLIED: n/a

## Required Changes

None.

## Rebuttals/Disposition

- **Round 4 Required Change 1 (M1, retained core-start future and handshake cleanup error):** accepted, applied and checked. See M1 above. The outer timeout is kept and `plugin_start_timeout` is preserved.
- **Round 4 Required Change 2 (M2, failed-start cleanup barriers hold reaping until shutdown):** accepted, applied and checked. The test-only seam (option 1) holds reaping at both startup layers until `_stopped` completes. Production startup deadlines are unchanged.
- **Round 4 Required Change 3 (m1–m3, m5 documentation and the m2 log line):** accepted, applied and checked. See Minor above.
- **Round 4 m4 (optional):** not applied. That is acceptable because it was optional; carried as S3.
- **Specification:** unchanged. No requested change narrows it.