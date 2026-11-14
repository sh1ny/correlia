# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| plugin-supervision → Bounded plugin shutdown | Graceful worker stop | `correlia_server/test/e2e/nats_shutdown_e2e_test.dart` | `graceful_worker_stop` (unchanged; must stay green) | green |
| plugin-supervision → Bounded plugin shutdown | Plugin ignores shutdown | `correlia_server/test/plugin/plugin_supervision_test.dart` | `plugin_ignores_shutdown` | green |
| plugin-supervision → Bounded plugin shutdown | Plugin ignores shutdown (SIGSTOP delivery versus fixture EOF; reproduction path) | `correlia_server/test/plugin/plugin_supervision_test.dart` | `plugin_ignores_shutdown` (observed all-thread stop barrier) | green |
| plugin-supervision → Bounded plugin shutdown | Forced reason survives a later status write | `correlia_server/test/db/plugin_status_persistence_test.dart` | `mark_stopped_sets_forced_reason_last` | green |
| plugin-supervision → Bounded plugin shutdown | Removal in flight when shutdown begins | `correlia_server/test/plugin/plugin_supervision_test.dart` | `removal_in_flight_at_shutdown_keeps_forced_reason` | green |
| plugin-supervision → Bounded plugin shutdown | Launch overlapping shutdown | `correlia_server/test/plugin/plugin_supervision_test.dart` | `launch_overlapping_shutdown_records_forced_reap` | green |
| plugin-supervision → Bounded plugin shutdown | Cleanup fails after forced termination | `correlia_server/test/plugin/plugin_supervision_test.dart` | `cleanup_error_after_forced_stop_keeps_reason` | green |
| plugin-supervision → Restart with backoff | Cleanup error before shutdown still permits removal and relaunch (review regression) | `correlia_server/test/plugin/plugin_supervision_test.dart` | `cleanup_failure_before_shutdown_releases_slot` | green |
| plugin-supervision → Bounded plugin shutdown | Cleanup fails after forced termination during startup | `correlia_server/test/plugin/plugin_supervision_test.dart` | `startup_cleanup_failure_is_reported_without_replacing_startup_error` | green |
| plugin-supervision → Bounded plugin shutdown | Cleanup fails after forced termination during a handshake stall | `correlia_server/test/plugin/plugin_supervision_test.dart` | `handshake_cleanup_failure_survives_outer_timeout` | green |
| plugin-supervision → Restart with backoff | Pre-shutdown startup failure preserves its status cause | `correlia_server/test/plugin/plugin_supervision_test.dart` | `startup_failure_before_shutdown_preserves_status_class` | green |
| process-roles → Repeated worker stop | Stop called twice | `correlia_server/test/db/ingest_workers_stop_test.dart` | `stop_called_twice_completes_once` | green |
| process-roles → Repeated worker stop | Concurrent stops that succeed | `correlia_server/test/db/ingest_workers_stop_test.dart` | `concurrent_stops_both_complete` | green |
| process-roles → Repeated worker stop | Stop again after a failed stop | `correlia_server/test/db/ingest_workers_stop_test.dart` | `stop_after_failed_stop_completes` | green |
| process-roles → Repeated worker stop | Concurrent stop while the first fails | `correlia_server/test/db/ingest_workers_stop_test.dart` | `concurrent_stop_while_first_fails` | green |
| process-roles → Repeated worker stop | Pipeline stopped before start | `correlia_server/test/db/ingest_workers_stop_test.dart` | `pipeline_stop_before_start_and_twice` | green |

"Plugin ignores shutdown" is red until 1.1 adds the reap log line: the test gains an assertion that the line names
the child as force-terminated (D2), written in the same task. The races around it are proved deterministically by the
group 2 tests; the gate runs in 4.2 are supplementary. Its existing assertions are not changed or loosened.

Every new test names its tier tag (`testGroupTagsOverride`) and uses no sleeps. The worker stop tests drive real
`IngestWorkers` with a bootstrap whose output is the fixture plugin or a webhook output, as the existing
`plugin_supervision_test.dart` and `shutdown_order_test.dart` do.

## 1. Diagnostics and reproduction attempt (design D2, D3)

- [x] 1.1 In `PluginSupervisor._remove`, log one line through `log` after the child is reaped:
  `plugin-reaped output=<id> digest=<first 12 hex> pid=<pid|none> failed=<bool> forced=<bool> shutdown=<bool>`
  (`shutdown` is `_stopped.isCompleted`). No config, no secret. In `plugin_ignores_shutdown`, collect the
  supervisor's log lines (replace `log: (_) {}` in `startWorker` with a list sink) and every distinct status row
  `waitForStatus` sees (state, pid, `lastErrorClass`, `version`; add `version` to its `SELECT`). Pass both as
  `reason:` on the test's assertions. Add the assertion that exactly one `plugin-reaped` line for the SIGSTOPped
  pid has `forced=true`. Verify with
  `mise run test -- --tags plugin test/plugin/plugin_supervision_test.dart`: every test passes,
  `plugin_ignores_shutdown` included (flip its row green), and `mise run analyze` is clean.
- [x] 1.2 [evidence] → evidence/reproduction.md — Try to reproduce the failure with the 1.1 diagnostics.
  First run `mise run test -- --tags plugin test/plugin/plugin_supervision_test.dart` ten times while
  `mise run test -- --tags e2e` runs alongside it. Then run up to five `mise run test:all`. Stop at the first
  reproduction. Record each run (command, result, wall time). For a reproduction, record the failure's reason
  text (log lines and status rows) and name the code path that produced the null reason. Verify the file lists
  every run, and either names the path or states that none of the runs reproduced it.
- [x] 1.3 Only if 1.2 named a path: write a deterministic regression test for that path in the cheapest tier that
  proves it, using existing seams (`beforeLaunch`, injected durations or clock, fixture plugin modes; no sleeps),
  see it fail, fix the path at its source, and see it pass. Add its row to the test map. If 1.2 named no path,
  tick this task with the note "not applicable: no reproduction (see evidence/reproduction.md)".
  Regression: the existing failing `plugin_ignores_shutdown` now observes all plugin threads stopped before
  beginning shutdown; assertions unchanged. The isolated red/green signal probe and path are recorded in
  `evidence/reproduction.md`.

## 2. Forced reason in the final shutdown write (design D1)

- [x] 2.1 Write `mark_stopped_sets_forced_reason_last` in `correlia_server/test/db/plugin_status_persistence_test.dart`
  (tag `db`):
  1. Write a row for key A with `lastErrorClass` `plugin_forced_stop`, then a second, clean write for A
     (`lastErrorClass` null).
  2. Write a row for key B with `plugin_connection_lost`.
  3. Call `markStopped(now, forcedKeys: {A})`.

  Expect A `stopped` with `plugin_forced_stop`, and B `stopped` with `plugin_connection_lost`. Verify with
  `mise run test -- --tags db test/db/plugin_status_persistence_test.dart` that it fails, because there is no
  `forcedKeys` parameter yet.
- [x] 2.2 Add the test seams of the design's Testing Strategy, with `///` docs saying they are test-only:
  - `@visibleForTesting` constructor hooks on `PluginSupervisor`:
    - in `_remove` before the connection is stopped (before the reap; holdable);
    - observing each status write and the final write, in order.
    - a failed-start cleanup barrier at both startup layers, released by the supervisor stop signal;
    - fixture arguments for the pre-handshake marker/SIGSTOP mode.
  - A `@visibleForTesting` cleanup-failure injection on `PluginLaunchCore`, raised after the SIGKILL.
  - An output-fixture config mode that, on configure, creates a marker file named in its config, then blocks
    and ignores the shutdown request. Add it to the Go fixture beside the existing config-driven modes, and
    rebuild through the fixture suite.

  Write seven `plugin`-tier regressions in `plugin_supervision_test.dart`. Each constructs `PluginSupervisor`
  directly with injected durations. The five shutdown-time cases assert:
  - the key's final row (`stopped`, `plugin_forced_stop`);
  - one `plugin-reaped ... forced=true shutdown=true` line;
  - that the observer saw the final write last.
  The pre-shutdown recovery case instead proves a new ready PID, one pre-shutdown forced-reap line, and a
  later clean final write that preserves the recovered row's error.
  The pre-shutdown startup-status case proves that forced failed-start cleanup does not replace the
  persisted startup cause.

  The tests:
  - `removal_in_flight_at_shutdown_keeps_forced_reason`:
    1. SIGSTOP a ready plugin.
    2. Let a sweep removal start through failed health checks under the short health interval and deadline.
    3. Hold it at the pre-stop hook, before the reap.
    4. Call `stop()` without awaiting it.
    5. Release the hook, then await `stop()`.
  - `launch_overlapping_shutdown_records_forced_reap`:
    1. Use the stalling fixture mode with a short start timeout and shutdown grace.
    2. Wait until the marker file exists, so the child is spawned and inside configure.
    3. Wait for the failed-start cleanup barrier after the deadline, then call `stop()`. The barrier waits
       for that stop signal before either startup layer can reap the child.
  - `cleanup_error_after_forced_stop_keeps_reason`:
    1. SIGSTOP a ready plugin and inject a cleanup failure.
    2. Hold the sweep's health-failure removal at the pre-stop hook, call `stop()`, then release the hook.
    3. Expect `stop()` to raise the injected error, with the row, log line and order as above.
  - `cleanup_failure_before_shutdown_releases_slot`: release the held failed removal before shutdown,
    observe a different ready PID, then stop cleanly; the cleanup error is not replayed forever.
  - `startup_cleanup_failure_is_reported_without_replacing_startup_error`: inject a configure-start cleanup
    failure, enter the abandonment barrier, then stop; report the cleanup error and keep `plugin_start_timeout`.
  - `handshake_cleanup_failure_survives_outer_timeout`: repeat before the handshake is printed; observe the
    retained core-start future's cleanup failure even when the outer timeout wins.
  - `startup_failure_before_shutdown_preserves_status_class`: let a handshake stall fail before shutdown,
    then assert its status cause matches durable startup health, not the cleanup mechanism.

  Waits use completers, the marker file's existence and the existing status polling, never sleeps. Verify with
  `mise run test -- --tags plugin test/plugin/plugin_supervision_test.dart`:
  - the original three fail before D1; the added four fail before their respective review fixes (see evidence);
  - every other test in the file passes.
- [x] 2.3 Implement D1:
  - Read `forcedStop` in a `finally` in `_remove`.
  - Carry `reapedPid` and `reapedForcibly` on startup failures from `OutputPluginConnection.start`, without
    changing the startup error or its class. Record and log them in `_launch`.
  - Add the forced-key set, the unsettled-write set, and the fence and drain ordering in `stop`.
  - Make `markStopped(now, forcedKeys:)` set the reason in the same `UPDATE`.

  Update the `///` docs of the changed members. Verify each of the following, and flip the eight group 2 rows
  green:
  - 2.1 and 2.2 pass.
  - `mise run test -- --tags plugin test/plugin/plugin_supervision_test.dart test/plugin/plugin_supervision_secrets_test.dart test/plugin/plugin_lifecycle_test.dart`
    passes.
  - `mise run test -- --tags db test/db/plugin_status_persistence_test.dart test/db/plugin_relay_shutdown_test.dart test/db/shutdown_order_test.dart`
    passes.
  - `mise run analyze` is clean.

## 3. Idempotent stop (design D4)

- [x] 3.1 Add D4's `@visibleForTesting` hook on `IngestWorkers`. It is called as each component's stop begins,
  with the component's name, and can count calls and throw. Write
  `correlia_server/test/db/ingest_workers_stop_test.dart` (tag `db`), each test with its own timeout. Each test
  starts real `IngestWorkers` with a webhook-output bootstrap, as `shutdown_order_test.dart` does, and counts
  component stops through the hook:
  - `stop_called_twice_completes_once`: `stop()`, then `stop()` again. Both complete without error, and each
    component's stop ran once.
  - `concurrent_stops_both_complete`: two `stop()` calls without awaiting between them, then `Future.wait`.
    Both complete without error, and each component's stop ran once.
  - `stop_after_failed_stop_completes`: the hook throws on the pipeline's stop. The first `stop()` raises that
    error after the supervisor's stop also ran. A later `stop()` completes without error. Each component's stop
    ran once.
  - `concurrent_stop_while_first_fails`: as above, but the second `stop()` is called while the first is held in
    the hook (completer). The first raises, the second completes without error after the first finished, and
    each component's stop ran once.
  - `pipeline_stop_before_start_and_twice`: a `PipelineSubsystem` stopped before `start` completes without
    error; a started one stopped twice completes both calls without error.

  Verify with `mise run test -- --tags db test/db/ingest_workers_stop_test.dart` that the tests fail on
  `Bad state: Future already completed`, a null check or a repeated component stop.
- [x] 3.2 Implement D4:
  - `PipelineSubsystem.stop` returns when `_stopping` is null, and completes `_stopping` only when it is not
    completed.
  - `IngestWorkers.stop` memoizes the first run's future. The first caller gets its error; later calls await it
    and ignore the error.

  Update the `///` docs. Verify each of the following, and flip its five rows green:
  - 3.1 passes.
  - `test/db/shutdown_order_test.dart` and the `plugin` tier file still pass.
  - `mise run analyze` is clean.

## 4. Gate

- [x] 4.1 Run `mise run check`. Verify it passes with 0 failures.
- [x] 4.2 [evidence] → evidence/gate-runs.md — Run `mise run test:all` three times on the change branch at the
  default concurrency. Then run it once from a fresh `git clone` of the branch into a scratch directory with a
  short path, because embedded Postgres sockets fail on long paths: run `mise run setup` first, and delete the
  clone afterwards. Record per run:
  - totals, the result line and wall time;
  - any failure with its output;
  - the `plugin_ignores_shutdown` result.

  Verify that in all four runs every test this change touched and every `plugin` and `db` tier test passes. A
  failure outside that scope does not fail this task: record its test, output and run, and name it in the
  workflow follow-up for the owner.
  Owner-directed session exception: run 1's unchanged supplementary health stress test failed; all changed
  tests passed in all four runs, and runs 2–4 passed 470/470. See `evidence/gate-runs.md`; no scope expansion.

## Workflow follow-up

- Archive the change and finish locally (`finish: local`).
- Do not run `/specwright-roadmap close`; the owner re-runs the M1 close from a clean clone, where this change's
  criterion is judged.
- Carry run 1's `plugin_protocol_test.dart: health_call_stalls_under_load` failure into the owner's M1-close
  follow-up; it expected `plugin_health_timeout` but observed `plugin_connection_lost`.
