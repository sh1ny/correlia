# Reproduction attempt

Diagnostics-only implementation; original forced-reason assertions unchanged.
Commands run through mise at default concurrency. Wall times below include setup/builds.

| Run | Command | Result | Wall seconds |
|---|---|---|---:|
| plugin 1 | `mise run test -- --tags plugin test/plugin/plugin_supervision_test.dart` | 12 passed | 23 |
| plugin 2 | same | 12 passed | 24 |
| plugin 3 | same | 12 passed | 22 |
| plugin 4 | same | 11 passed, plugin_ignores_shutdown failed; stopped repetition here | 17 |
| concurrent e2e 1 | `mise run test -- --tags e2e` | 53 passed, 1 unrelated failure | 446 |
| all 1 | `mise run test:all` | 461 passed | 523 |
| all 2 | same | 461 passed | 516 |
| all 3 | same | 461 passed | 487 |
| all 4 | same | 460 passed, plugin_ignores_shutdown failed | 485 |

The batch stopped the supervision repetitions on the first reproduction. Its already-scheduled full-tier phase also ran, stopping on the next reproduction; no fifth full run ran.

## First reproduction (plugin 4)

```text
Expected: not null
Actual: <null>
log:
plugin-reaped output=22222222-2222-4222-8222-222222222222 digest=68c65e501656 pid=1446983 failed=false forced=false shutdown=true
status:
state=starting pid=null lastErrorClass=null version=1
state=ready pid=1446983 lastErrorClass=null version=2
state=stopped pid=1446983 lastErrorClass=null version=4
```

Teardown additionally raised `Bad state: Future already completed` from `PipelineSubsystem.stop` (the already-planned group 3 fix).

Full run 4 showed the same states and flags, PID 1483974. Both took the voluntary `_remove` path with `connection.forcedStop == false`: no forced reason was ever written. This is not evidence of a later write clearing a forced reason.

## Unrelated concurrent e2e failure

`test/e2e/nats_dur3_e2e_test.dart`, `DUR-3 redelivery after the acknowledgement was lost`:

```text
Severity.error Attempting to execute query, but connection is not open.
package:postgres/src/v3/connection.dart 114:7 _PgSessionBase._verifyStateBeforeQuery
package:postgres/src/v3/connection.dart 133:5 _PgSessionBase.execute
test/e2e/nats_dur3_e2e_test.dart 72:37 main.<fn>
```

No changes made to that test or subsystem.

## Additional trace investigation

A scratch Dart probe sent SIGSTOP to 100 shell children and closed their stdin; all required SIGKILL after the injected 10 ms bound (no early exit observed).

Twelve focused runs of `plugin_ignores_shutdown`, with temporary child exit-code tracing and a `/proc/<pid>/status` observation immediately after SIGSTOP, all passed (135.77 seconds total). The observation changes timing; it does not establish a cause.

Twenty more focused runs with only temporary exit-code tracing (no `/proc` observation) all passed (224.14 seconds total). Command for both focused batches: `mise run test -- --tags plugin test/plugin/plugin_supervision_test.dart --plain-name plugin_ignores_shutdown`.

Ten full supervision-file runs with temporary child exit-code tracing all passed (188.08 seconds total). Command: `mise run test -- --tags plugin test/plugin/plugin_supervision_test.dart`.

Ten further supervision-file runs alongside another `mise run test -- --tags e2e` run, with temporary exit-code tracing, all passed. Combined wall time: 430.46 seconds. The concurrent e2e run finished with 43 passed and 11 failures outside this change (including the same closed-connection DUR-3 failure); no e2e code was changed.

## Extended investigation (owner-authorized)

The owner selected continued root-cause investigation after the bounded attempt.

- Twenty full supervision-file runs with in-memory lifecycle tracing alongside e2e load passed (509.01 seconds total). Individual wall seconds: 25, 23, 27, 24, 26, 27, 24, 24, 24, 22, 23, 23, 28, 33, 30, 30, 29, 24, 22, 20. The concurrent e2e run had 49 passes and five unrelated failures (548.86 seconds).
- A scratch plugin-tier test launched/configured a real output fixture, sent SIGSTOP and immediately stopped its connection, 100 times: all passed (19 seconds).
- A scratch test repeated the real worker lifecycle 50 times with lifecycle-entry tracing: all passed (272.56 seconds).
- Another 50 real worker stops with only post-exit tracing passed (274.19 seconds).

### Path identified: SIGSTOP acknowledgement is not an observed group stop

The failing test calls `Process.killPid(pid, ProcessSignal.sigstop)` and immediately starts worker shutdown. A successful signal send is not a barrier proving that every Go thread has stopped. The fixture has an independent stdin watcher that calls `os.Exit(0)` on EOF. Shutdown can close stdin while group-stop delivery is still in progress, letting a child exit cleanly before the test has established that it ignores shutdown. `_cleanup` then sees an exited child without issuing SIGKILL, `forcedStop` remains false, and `_remove` correctly persists no forced reason.

An isolated multithreaded Go child reproduced this ordering:

```go
package main
import ("io"; "os"; "fmt"; "runtime")
func main() {
  runtime.GOMAXPROCS(8)
  go func() { io.Copy(io.Discard, os.Stdin); os.Exit(0) }()
  fmt.Println("ready")
  select {}
}
```

A scratch Dart driver launched that child, awaited `ready`, sent SIGSTOP, closed stdin, and awaited exit with a 5 ms bound before using SIGKILL. Across 2,000 attempts, seven children exited cleanly without SIGKILL: attempts 43, 544, 566, 880, 1094, 1505 and 1688, all exit code 0 (21.73 seconds).

The same driver, changed only to await `T` in every `/proc/<pid>/task/*/stat` before closing stdin, observed zero unforced exits in 2,000 attempts (25.93 seconds). The barrier used asynchronous filesystem reads and a five-second deadline, no sleeps.

Commands: `mise exec -- go build -o /tmp/omp-pfs-trace/eof-child /tmp/omp-pfs-trace/eof-child.go`, then `mise exec -- dart /tmp/omp-pfs-trace/eof-driver.dart`, then the same driver with `--barrier`.

This directly proves the test's signal-delivery premise is racy. The original failed worker runs did not capture child exit codes, so attributing those particular exits to EOF remains an inference; their `forced=false` diagnostics are consistent with the isolated reproduction. The fix establishes actual group stop before shutdown, instead of misclassifying a clean exit as forced. The existing failing `plugin_ignores_shutdown` is the regression, with its assertions unchanged; no redundant new permanent test is added. D1 still protects actual forced reaps from later status writes.

After applying the observed all-thread stop barrier and removing all temporary tracing/probes, `mise run test -- --tags plugin test/plugin/plugin_supervision_test.dart` passed all 12 tests (21.17 seconds); `mise run analyze` reported no issues.
