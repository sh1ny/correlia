# Proposal

## Why

The M1 close on 2026-11-14 found the agent-verified exit criterion "`mise run check` and every test tier except
`load` pass from a clean clone in WSL" failing again. Two `mise run test:all` runs at `48ad9a7` each passed 448
of 449 tests, and each failed on a different test with a different cause:

- `unconfigured_ingress_still_protects_token_paths` (`correlia_server/test/e2e/ingress_e2e_test.dart`) exceeded
  the default 30 s test timeout. No status or redaction assertion failed. Run alone, the file passes three runs
  of three, and each of its nine tests takes 11–16 s, mostly because the child server compiles
  `bin/main.dart` from source. Under the default test concurrency (half the cores, so three files at once on a
  6-core machine) one test can pass 30 s. The child harness itself allows 60 s for readiness and 30 s for
  shutdown. `ingress_e2e_test.dart` is the only e2e file that starts child servers and sets no test timeout;
  every other one sets 3 to 6 minutes. An earlier stressed run timed out on `conflicting_credentials` in the
  same file.
- `worker_killed_before_any_delivery` (`test/e2e/nats_burst_e2e_test.dart`) failed because its child server
  exited with `Address already in use` on its API port. `ChildServer._freePort` binds port 0, records the port
  and releases it; the child binds it seconds later, after compiling. Another process took the port in that gap.
  Every test that starts a child server is exposed to this.

Neither is a product defect: both live in the test harness. They block the M1 close all the same, and fixing
only the timeout would leave `test:all` failing at random. This change closes that M1 gap. The criterion is
agent-verified, so it is judged by re-running the M1 close from a clean clone; no `[user]` task is needed.

## What Changes

- Every test in `ingress_e2e_test.dart` gets an explicit test timeout that covers the child server's readiness
  and shutdown deadlines, matching the other e2e files.
- Every existing test that starts child servers is checked against a timeout budget (readiness plus shutdown
  per child in sequence); those below it, such as the three- and four-child tests, are raised.
- A tooling check fails when a test file that starts a child server leaves any of its tests on the default
  timeout, so the gap cannot come back in a new file.
- A child server whose startup fails because its pre-picked port was taken is started again on freshly picked
  ports, a bounded number of times. Any other startup failure still fails at once with the child's output.
- A child's reported exit is its final attempt's, and it counts as ready only when its own process owns the
  listener on its API port, so a retry never misleads a test that waits on exit, and another server answering
  on a stolen port is never mistaken for the child.
- The ingress security assertions are unchanged: an unconfigured server answers 503 and no path token or query
  secret appears in its output.
- Repeated `mise run test:all` runs under the default concurrency, and one from a clean clone, are recorded as
  evidence.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `workspace-tooling`: adds requirements that tests starting child servers budget their timeouts for the
  harness's own deadlines, that a lost pre-picked port is retried on fresh ports instead of failing the test, and
  that a child's exit and readiness describe the child the test owns.

## Impact

- Test harness: `correlia_server/test/support/child_server.dart` (`ChildServer` start, exit, readiness and stop).
- Tests: `ingress_e2e_test.dart` (timeouts only), timeouts of other child-server tests below budget, new
  harness tests for the retry, exit and ownership rules, and a `tool` test for the timeout rule.
- Product code, the plugin protocol, models, schema and migrations: unchanged.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Fix both causes in one change

- **Choice:** Fix the ingress timeout and the port race together, because either one alone fails the
  clean-clone gate.
- **Rejected:** Only the ingress timeout, as the OMP close run first proposed (`ingress-e2e-timeout-reliability`):
  the second full-suite run showed the port race failing a different file, so the gate would still fail.
  Two separate changes: twice the ceremony for one gate, with no independent value.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

### S2: Fix the harness, not weaken the tests

- **Choice:** Give the ingress tests a timeout sized like the other e2e files and retry only a lost-port startup.
  No assertion changes, no blanket test retries.
- **Rejected:** Retrying failed tests, which would hide real failures. Lowering the test concurrency, which
  slows every run and only makes both races rarer.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

### S3: Scope stays M1-sized

- **Choice:** The two observed causes, plus a guard against the missing-timeout gap recurring. Making the child
  start faster (for example a precompiled server snapshot shared by all e2e tests) is out of scope.
- **Rejected:** A precompiled child server: a larger change to the harness and the run modes, with no failure
  that needs it yet.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

## Release Notes

Makes child-server test deadlines and startup reliable under concurrent suite load.

### Added

- Detects missing explicit timeouts in child-server test files, with file and line diagnostics.

### Fixed

- Budgets existing child-server test timeouts for sequential startup and shutdown deadlines without changing ingress assertions.
- Retries only lost-port startup failures, preserves the logical child exit future, and requires API-listener ownership before readiness.
