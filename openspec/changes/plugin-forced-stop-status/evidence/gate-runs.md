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
