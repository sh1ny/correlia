# Gate runs

Code head: `168a7a6f5ea106869cd3151fcb608b1cd461a45a` (groups 1–3 committed).
Default test concurrency; no retries or narrowed test selection. No product/test code changed between these runs.

## Workspace gate (4.1)

`mise run check` exited 0 in 182 seconds. OpenSpec: 15 passed, 0 failed. Analysis clean; 264 Dart files already formatted; generated code and protocol checks current. Tests: 213 fast server, 83 tooling, 19 Flutter widget tests; all passed. The running server also completed a hot reload after the code changes.

## Full-tier runs (4.2)

| Run | Checkout | Command | Result line | Command wall seconds | Tool-reported seconds | plugin_ignores_shutdown |
|---|---|---|---|---:|---:|---|
| 1 | change branch | `mise run test:all` | `09:51 +469 -1: Some tests failed.` | 638 | 597.22 | passed; only failure was health_call_stalls_under_load |
| 2 | change branch | `mise run test:all` | `09:19 +470: All tests passed!` | 601 | 562.84 | passed |
| 3 | change branch | `mise run test:all` | `10:12 +470: All tests passed!` | 657 | 615.66 | passed |
| 4 | fresh short-path clone | `mise run test:all` | `09:04 +470: All tests passed!` | 593 | 552.87 | passed |

All changed tests passed in all four runs. Every db-tier test passed in all four runs. All plugin-tier tests passed in runs 2–4; run 1 had the supplementary health stress failure below. The expanded reporter interleaves active test labels, so not every passing test's individual name appears in the console output; the complete-run failure list identifies only the health stress test.

## Owner-directed out-of-scope exception

The session instruction explicitly permits recording tests outside this change's scope without expanding scope. This exception is applied to the unchanged supplementary health stress test in run 1, rather than claiming all four runs were completely green. Its file, the `health` method and `classifyHealthFailure` were not changed by this change. Its test comment identifies deterministic classifier tests as the proof and this run as supplementary stress coverage.

`test/plugin/plugin_protocol_test.dart:264`, `health_call_stalls_under_load`:

```text
Expected: throws <Instance of 'OutputPluginException'> with `error class`: 'plugin_health_timeout'
  Actual: <Instance of 'Future<OutputPluginHealth>'>
   Which: threw OutputPluginException:<plugin_connection_lost>
          stack package:correlia_server/src/plugin/output_plugin_connection.dart 443:7 OutputPluginConnection.health
                ===== asynchronous gap ===========================
                test/plugin/plugin_protocol_test.dart 273:7 main.<fn>
          which has `error class` with value 'plugin_connection_lost' which is different.
                Expected: plugin_health_tim ...
                  Actual: plugin_connection ...
                                 ^

test/plugin/plugin_protocol_test.dart 273:7 main.<fn>
```

The unchanged classifier gives observed connection loss precedence over timeout. This evidence does not diagnose why that connection failed under load. No health-classification fix, assertion weakening, test retry or extra gate run was introduced. The owner should carry this stress failure into the M1 close follow-up.

## Fresh clone and cleanup

Created with `git clone --no-hardlinks --branch feat/plugin-forced-stop-status /home/bgshi/Development/dart/correlia /tmp/omp-pfs-clone`.
The fresh clone resolved to the code head above. Trusted its mise configuration, ran `mise run setup` successfully, then ran the fourth full-tier gate.

After tests exited, a scratch Dart helper used the installed `serverpod_embedded_postgres` `EmbeddedPostgres.attach`/`stop` API, restricted to `/tmp/omp-pfs-clone/correlia_server/.serverpod/`. It verified each pidfile's PID command line belonged to that exact clone before stopping it:

```text
Stopped clone-owned cluster /tmp/omp-pfs-clone/correlia_server/.serverpod/test/pgdata pid=1736314
Fresh clone removed after stopping its owned clusters.
```

The original checkout's shared test cluster was left running. No unrelated PostgreSQL was connected to or signaled. No push, PR or roadmap close was run.

## Authorized pre-ship fix (round 1)

The first pre-ship review passed with one P2: the cleanup-error test could let a sweep reap the child before shutdown began. The owner selected fixing it before archive. The test now holds the sweep removal before the reap and releases it only after `stop()` begins, as the removal-in-flight test already does.

This ordering deterministically exposed a second error-propagation gap: after the tracked removal consumes the original cleanup error, shutdown revisits the same connection, whose repeated `stop()` returned early. The synchronized test failed because `stop()` completed normally instead of throwing the injected error. Repeated connection stops now await the original cleanup future, retaining that error without repeating cleanup.

Supplementary verification after this fix:

- `mise run test -- --tags plugin test/plugin/plugin_supervision_test.dart test/plugin/plugin_supervision_secrets_test.dart test/plugin/plugin_lifecycle_test.dart test/plugin/plugin_protocol_test.dart`: 31 passed, 30.30 seconds (including the health stress test).
- `mise run test -- --tags db test/db/ingest_workers_stop_test.dart test/db/plugin_status_persistence_test.dart test/db/plugin_relay_shutdown_test.dart test/db/shutdown_order_test.dart`: 14 passed, 8.06 seconds.
- `mise run analyze`: no issues; `mise exec -- dart fix --apply correlia_server`: nothing to fix.

The four full-tier runs above predate this review fix; they are not represented as runs of the later head. The focused regressions prove the changed cleanup ordering and error propagation.

## Authorized pre-ship fix (round 2)

The next review identified a P1: replaying a connection's cleanup error forever prevented the sweep retry from releasing the slot. It also identified a startup-cleanup reporting gap against the unchanged shutdown specification. The owner selected fixing the retry and honoring the full existing specification, not narrowing it.

Two new regressions first failed: `cleanup_failure_before_shutdown_releases_slot` could not observe a new ready PID, and `startup_cleanup_failure_is_reported_without_replacing_startup_error` saw shutdown complete normally instead of reporting the cleanup error.

Connection cleanup errors are now reported once to an awaiting stop; retries still await completion but can finish removal and relaunch. The supervisor retains the first tracked error occurring during shutdown. Failed-start exceptions carry any cleanup failure and its stack separately, including cleanup inside the launch core, preserving the original startup class while allowing shutdown to report the cleanup error. The recovery test preserves the existing health-error retention policy rather than requiring a ready row to erase its historical health error.

Verification:

- Plugin supervision, historical secrets, lifecycle, protocol, host and acquisition files: **39 passed**, 72.14 seconds.
- Worker-stop, status-persistence, relay-shutdown and shutdown-order db files: **14 passed**, 28.62 seconds.
- Analysis clean; `dart fix --apply` had nothing to fix.

The full-tier runs above predate both review fixes. These focused runs cover the revised error propagation, successful relaunch after a failed removal, and unchanged startup classification.

### Design re-check corrections within round 2

The design re-check found that an outer handshake timeout could discard the inner core-start exception and its cleanup failure. A new pre-handshake marker/SIGSTOP fixture and `handshake_cleanup_failure_survives_outer_timeout` first failed because shutdown emitted no cleanup error. Retaining and observing the core-start future after serialized cleanup fixes the loss while preserving `plugin_start_timeout`.

All three startup-overlap tests now wait for an abandonment barrier entered after timeout. Both cleanup layers wait for the supervisor's stop signal before reaping, so the test no longer has to beat its three-second deadline. This is a test-only seam; production startup deadlines are unchanged. The design re-check's documentation corrections describe failed-removal retry scope, loop-ordered waiting/prune writes, broader tracked shutdown failures and the test's deliberate status erasure. Pre-shutdown startup cleanup failures also emit a bounded, value-free diagnostic.

Final focused verification of these corrections: **40 plugin tests passed** (38.37 seconds), **14 db tests passed** (7.70 seconds), and `dart fix --apply` found nothing to fix.

A new `mise run check` on this corrected code exited 0: 15 OpenSpec items, 213 fast server tests, 83 tooling tests and 19 widget tests passed; analysis and generated-code checks were clean. Command time: 148.18 seconds.

## Final-code fresh-clone gate

After the revised design was approved, the complete second fix round was committed as
`7c74c223f7001c15cea4e2283a83dc4e27331150`. The passing final `mise run check` above exercised that same code
before the commit; only its commit message and review/evidence bookkeeping were added afterward.

A new fresh clone of that exact head at `/tmp/omp-pfs-clone` ran `mise run setup`, then `mise run test:all`
at default concurrency. Exit 0, **473 passed**, result line `12:58 +473: All tests passed!`.
Command wall time: **799 seconds**; tool-reported time: **791.24 seconds**.
All changed tests, all plugin and db tests, and `plugin_ignores_shutdown` passed. No failures were reported,
including in the supplementary health stress test that failed in original run 1.

The clone-owned cluster at `/tmp/omp-pfs-clone/correlia_server/.serverpod/test/pgdata` (PID 1796327) was stopped
through the same ownership-checked attach/stop helper, and the clone was removed. This fifth full-tier run
supplements rather than replaces the four original runs or their recorded failure.

## Third pre-ship fix round: preserve pre-shutdown startup status

The final pre-ship review of `c0057b7` found P1 F1: `_recordReap` set `forcedError` for a child
reaped during failed startup before shutdown, so the later status write replaced its startup cause
with `plugin_forced_stop`. The owner authorized a third fix round beyond the configured two.

Test-first: `startup_failure_before_shutdown_preserves_status_class` failed with a backoff row recording
`plugin_forced_stop`, while its reap log correctly said `forced=true shutdown=false`.
The fix moves per-instance forced-error assignment into the connection-removal path; startup reaps still
contribute diagnostics and shutdown-time forced keys, but do not replace the normal startup status cause.

The first post-fix run exposed an incidental test assumption: a handshake stall retained
`plugin_handshake_error` rather than `plugin_start_timeout`. Both are existing startup causes, depending
on which deadline wins. The regression now reads status and durable startup-health causes in one joined
database snapshot, checks that health names a startup cause, and requires status to preserve that exact
cause. It still rejects the original forced-stop overwrite; production startup classification is unchanged.

Verification after the fix and the cause-preservation assertion:
- Focused six-file plugin run: **41 passed**, 42.70 seconds.
- Focused four-file database run: **14 passed**, 8.31 seconds.
- `dart fix --apply correlia_server`: applied one curly-braces lint fix to the new removal-path assignment.
- `mise run check`: exit 0, 149.48 seconds; 15 spec items passed, analysis and generated/format checks
  clean, **213 fast**, **83 tool**, and **19 widget** tests passed.

### Fresh-clone proof of the third-round code

A fresh `/tmp/omp-pfs-clone` at `1fabc7b3142fa2956e62ad6565d8f49274602100` ran setup and
`mise run test:all` at default concurrency: exit 0, **474 passed**, result
`10:08 +474: All tests passed!`. Command wall time was **616 seconds**; tool time was **616.60 seconds**.
This includes the new startup-status regression and every changed plugin/db test.

The ownership-checked helper stopped only the clone's
`/tmp/omp-pfs-clone/correlia_server/.serverpod/test/pgdata` cluster (PID 1832328), then the clone was removed.
This sixth full-tier run supplements the earlier runs and their recorded out-of-scope failure.
