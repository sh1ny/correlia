# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| workspace-tooling → Child server tests budget their own deadlines | Slow but healthy child under full-suite load | `tool/test/server_test_timeouts_test.dart` | `every server child test declares its own timeout` | green |
| workspace-tooling → Child server tests budget their own deadlines | Child never becomes ready | `correlia_server/test/e2e/child_server_harness_e2e_test.dart` | `never_ready_fails_with_harness_error` | green |
| workspace-tooling → Child server tests budget their own deadlines | New child server test without a timeout | `tool/test/server_test_timeouts_test.dart` | `a test without a timeout is reported with its line` | green |
| workspace-tooling → Child server startup survives a lost port | Port taken between pick and bind | `correlia_server/test/e2e/child_server_harness_e2e_test.dart` | `lost_api_port_is_retried_on_fresh_ports` | green |
| workspace-tooling → Child server startup survives a lost port | Port lost on every attempt | `correlia_server/test/e2e/child_server_harness_e2e_test.dart` | `port_lost_on_every_attempt_fails_after_three` | green |
| workspace-tooling → Child server startup survives a lost port | Startup fails for another reason | `correlia_server/test/e2e/child_server_harness_e2e_test.dart` | `non_bind_startup_failure_gets_one_attempt` | green |
| workspace-tooling → A child's exit and readiness describe the child the test owns | Caller waits on exit and readiness together | `correlia_server/test/e2e/child_server_harness_e2e_test.dart` | `exit_and_readiness_race_sees_retried_attempt` | green |
| workspace-tooling → A child's exit and readiness describe the child the test owns | Another server answers on the stolen API port | `correlia_server/test/e2e/child_server_harness_e2e_test.dart` | `stolen_api_port_answering_200_is_not_ready` | green |
| workspace-tooling → A child's exit and readiness describe the child the test owns | Teardown while a retry is pending | `correlia_server/test/e2e/child_server_harness_e2e_test.dart` | `stop_during_pending_retry_starts_no_further_attempt` | green |

"Slow but healthy child under full-suite load" cannot be forced deterministically. Its proof is the real-tree
`tool` check (every child-server test has its own timeout) together with the D1 budget inventory (2.3); the
repeated `test:all` runs in 4.2 are supplementary evidence. "Child never becomes ready" is behaviour the harness
already has; its new test starts green and guards it through the D2 rework.

The harness tests in `child_server_harness_e2e_test.dart` are `@Tags(['e2e'])`, each with its own timeout (D1),
start real `bin/main.dart` children on the shared cluster, and use the injectable port picker (D3). No sleeps:
wait on futures, the child's exit, or readiness.

## 1. Timeout presence check (design D1)

- [x] 1.1 Write `tool/test/server_test_timeouts_test.dart` against a lexical function in
  `tool/lib/src/server_test_timeouts.dart` (exported from `tool/lib/correlia_tool.dart`), modelled on
  `untaggedWithServerpodCalls` (`tool/lib/src/server_test_tags.dart`). It returns the 1-based lines of `test(`
  calls without a direct `timeout:` argument, for a source that is tagged `e2e` or names `ChildServer`, and
  nothing when the file has a library `@Timeout(...)`. Cases: a test without a timeout is reported with its
  line; tests with `timeout:` (literal or a constant) pass; a file neither tagged `e2e` nor naming `ChildServer`
  is ignored; mentions in comments and strings are not calls; a `@Timeout` library annotation covers the file;
  `group(` is not a `test(`. Add `every server child test declares its own timeout`, which scans every
  `correlia_server/test/**/*_test.dart` and fails naming each file and line. Verify with
  `mise exec -- dart test` in `tool/`: the unit cases fail on the missing function, and the real-tree test then
  names the nine `ingress_e2e_test.dart` tests (the expected red).
- [x] 1.2 Implement the function with `///` docs. Verify the unit cases pass and the real-tree test still names
  exactly the `ingress_e2e_test.dart` tests (plus any other offender it finds, listed in the 2.3 inventory).

## 2. Timeouts within budget (design D1)

- [x] 2.1 Add `timeout: const Timeout(Duration(minutes: 3))` to every test in
  `correlia_server/test/e2e/ingress_e2e_test.dart` (one child each: budget 2.5 minutes), through one file-level
  constant as `roles_e2e_test.dart` does. Change no assertion. Verify the real-tree check of 1.1 no longer names
  the file, and `mise run test -- --tags e2e test/e2e/ingress_e2e_test.dart` passes. Flip the
  "Slow but healthy child" row green once 2.3 is done.
- [x] 2.2 State the budget rule (`n × (readiness deadline + 30 s shutdown) + 60 s`, children started together
  count once) in the `///` doc comments of `ChildServer.start` and `ChildServer.startOnSharedCluster`. Verify with
  `mise run analyze`.
- [x] 2.3 [evidence] Inventory every test that starts children (directly or through `output_process.dart`,
  `nats_process.dart`, `interrupted_harness.dart`): file, test, children in sequence, readiness deadlines,
  budget, current timeout, new timeout. Raise every timeout below its budget, including
  `pipeline_lifecycle_e2e_test.dart`'s three-child test, `ingest_bootstrap_e2e_test.dart` and
  `pipeline_recovery_e2e_test.dart`. Verify every row has new timeout ≥ budget, and the raised files pass under
  `mise run test -- --tags e2e <files>` (and `--tags db` for `kill_recovery_test.dart` if raised).
  → evidence/timeout-inventory.md
- [x] 2.4 Make the real-tree check of 1.1 green: every offender it names is either raised in 2.3 or given its
  budgeted timeout. Verify `mise exec -- dart test` in `tool/` passes, then flip the "New child server test
  without a timeout" and "Slow but healthy child" rows green.

## 3. Lost-port retry, stable exit and owned readiness (design D2, D3, D4)

- [x] 3.1 Write fast-tier unit tests in `correlia_server/test/unit/support/child_server_test.dart` (no tags) for
  two pure functions to add to `test/support/child_server.dart`: the bind-failure matcher (true for the captured
  Serverpod `Failed to bind socket` line and for the `SocketException ... Address already in use, errno = 98`
  text, both taken from the failing run in proposal.md; false for a migration error, a config error and empty
  output), and the `/proc` ownership parser (given `/proc/net/tcp6` and `/proc/net/tcp` texts and a set of fd
  link targets, it finds the listening, state `0A`, entry for a port and reports whether `socket:[<inode>]` is
  among the links; non-listening entries and other ports are ignored; IPv4 and IPv6 forms both parse). Verify
  `mise run test -- test/unit/support/child_server_test.dart` fails on the missing functions.
- [x] 3.2 Implement both functions with `///` docs. Verify 3.1 passes.
- [x] 3.3 Write `correlia_server/test/e2e/child_server_harness_e2e_test.dart` with the seven harness tests of the
  test map, against an `@visibleForTesting` `portPicker` parameter on `start`/`startOnSharedCluster` and an
  `attempts` getter:
  - `never_ready_fails_with_harness_error`: `readyTimeout` shorter than compilation; expect a `StateError`
    containing `not ready in` and the child's output, raised before the test's own timeout.
  - `lost_api_port_is_retried_on_fresh_ports`: the picker's first API port is held by a bound `ServerSocket`;
    expect readiness, `attempts == 2`, `apiPort` not the held port, and `/startupz` 200 on the new port.
  - `port_lost_on_every_attempt_fails_after_three`: every API port the picker returns is held; expect a failure
    naming 3 attempts and containing the bind error, and `exitCode` completed with a non-zero code.
  - `non_bind_startup_failure_gets_one_attempt`: an ingest config path that does not exist; expect exit 1,
    `attempts == 1`, and the bootstrap error in `output`.
  - `exit_and_readiness_race_sees_retried_attempt`: the first API port held; run the same `Future.any`
    pattern as `ingest_bootstrap_e2e_test.dart:67-73`; expect the readiness branch to win (`-999`).
  - `stolen_api_port_answering_200_is_not_ready`: the first API port held by a test `HttpServer` answering 200
    to every path; expect readiness only after a second attempt, `attempts == 2`, `apiPort` not the stolen port,
    and the test server's request count shows it was polled.
  - `stop_during_pending_retry_starts_no_further_attempt`: the first API port held; the picker's call for the
    second attempt calls `child.kill()`; expect `attempts == 2` at most, no third spawn, `exitCode` completing
    once, and no child process left (`processesNaming` of the log path empty).

  Every test has its own timeout (D1) and tears down through `tearDownChildren`. Verify with
  `mise run test -- --tags e2e test/e2e/child_server_harness_e2e_test.dart`: the six red rows fail for the
  missing parameter or behaviour, `never_ready_fails_with_harness_error` passes.
- [x] 3.4 Rework `ChildServer` per D2 and D4: keep the spawn inputs; one `Completer<int>` behind `exitCode`;
  the attempt exit handler decides retry or completion; `apiPort`, `webPort` and `pid` read the current attempt;
  `waitUntilReady` polls the current attempt within one deadline and counts a 200 only when the ownership parser
  confirms the attempt's pid owns the API listener; `closeStdin`, `stop` and `kill` set the stop flag first and
  act on an attempt being spawned; the final failure's output starts with the attempts line; one log line per
  retry names the lost port. Update the `///` docs of every changed member. Verify 3.3 passes (flip its six red
  rows green), `never_ready_fails_with_harness_error` stays green, and the existing callers pass:
  `mise run test -- --tags e2e test/e2e/ingest_bootstrap_e2e_test.dart test/e2e/pipeline_lifecycle_e2e_test.dart test/e2e/root_handoff_e2e_test.dart test/e2e/health_e2e_test.dart`
  and `mise run test -- --tags db test/db/kill_recovery_test.dart`.

## 4. Gate

- [x] 4.1 Run `mise run check`. Verify it passes with 0 failures, including the 1.1 real-tree check.
- [x] 4.2 [evidence] Run `mise run test:all` three times on the change branch at the default concurrency, then
  once from a fresh `git clone` of the branch into a scratch directory (`mise run setup` first; delete the clone
  afterwards). Record per run: totals, the result line, wall time, any failure with its output, retry lines from
  the harness log (lost ports seen), and the five slowest e2e tests with their timeouts; name any test within
  25% of its timeout. Verify, in all four runs: every `e2e` test and every other test that starts a child server
  passes, every test this change touched passes, and the only lost-port retry lines are the ones the harness
  tests cause on purpose. A failure outside that scope does not fail this task: record its test, output and
  run in the evidence, with a pointer to the follow-up change that owns it. (Amended 2026-11-14, owner: run 3
  failed `plugin_ignores_shutdown` in `plugin_supervision_test.dart`, a plugin-supervision defect outside this
  change's harness-only scope, owned by a separate M1 change; the full clean-clone gate is still judged at the M1
  close.) → evidence/gate-runs.md

## Workflow follow-up

- Archive the change and finish locally (`finish: local`).
- Re-run `/specwright-roadmap close` for M1 from a clean clone; this change's criterion is judged there.
- The `plugin_ignores_shutdown` failure (stopped status without a reason; `PipelineSubsystem.stop` not safe to
  call twice) is fixed by a separate M1 change before that close.
