# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| plugin-output-protocol → Plugin health reporting | Plugin reports serving | `correlia_server/test/plugin/plugin_protocol_test.dart` | `plugin_reports_serving` | green |
| plugin-output-protocol → Plugin health reporting | Health call stalls | `correlia_server/test/plugin/plugin_protocol_test.dart` | `health_call_stalls` | green |
| plugin-output-protocol → Plugin health reporting | Stalled plugin ends the call itself | `correlia_server/test/unit/plugin/health_failure_classification_test.dart` | `non_deadline_status_at_or_past_deadline_is_health_timeout` | green |
| plugin-output-protocol → Plugin health reporting | Stall classification under load | `correlia_server/test/plugin/plugin_protocol_test.dart` | `health_call_stalls_under_load` | red |
| plugin-output-protocol → Plugin health reporting | Connection lost during a health call | `correlia_server/test/unit/plugin/health_failure_classification_test.dart` and `correlia_server/test/plugin/plugin_protocol_test.dart` | `observed_connection_loss_wins_for_every_completion` and `health_connection_lost_during_call` | red |
| plugin-output-protocol → Plugin health reporting | Request write races transport closure | `correlia_server/test/unit/plugin/bounded_channel_test.dart` | `closed_delegate_write_fails_rpc` | red |
| plugin-output-protocol → Plugin health reporting | Existing transport guards | `correlia_server/test/unit/plugin/bounded_channel_test.dart` | `non_state_error_propagates`, `invalid_frames_still_fail` | green |

"Health call stalls" and "Plugin reports serving" ride along unchanged in the MODIFIED requirement. Their tests
already pass when run alone, so they start green and are re-run in 3.4. The deterministic regression proof for
the M1 failure is the classifier row (design D3). `health_call_stalls_under_load` is supplementary stress
evidence at the real process boundary.

The pure observed-loss classifier test owns the connection-loss precedence proof. The SIGKILL test is supplementary process-boundary coverage: a pre-deadline `unavailable` may use D2 before process/stream loss is observed.

## 1. Capture the status a stalled plugin returns under starvation

- [x] 1.1 [evidence] Before changing `health`, run a throwaway probe against the unchanged code. The probe makes 50 health calls to the `stall-health` fixture with a 100 ms timeout and blocks the isolate for 300 ms after each call with a `Stopwatch`-bounded loop.
  - Record each outcome: `TimeoutException`, or `GrpcError` with its code and message.
  - Note the grpc-go and grpc-dart versions.
  - Record whether the code-385 path (`plugin_connection_lost`) was reached.
  - Delete the probe afterwards; it is not committed.
  - Verified by the file existing, non-empty, with the counts per outcome. It answers design.md's Open Question; that design was subsequently amended under the owner-approved D4 scope expansion. → evidence/health-status-capture.md

## 2. Classification rule (design D1, D2)

- [x] 2.1 Write `correlia_server/test/unit/plugin/health_failure_classification_test.dart` (fast tier, no tags) against a `classifyHealthFailure({required Object error, required Duration elapsed, required Duration deadline, required bool connectionFailed})` function. It returns the error class string. Cases:
  - `non_deadline_status_at_or_past_deadline_is_health_timeout`: `GrpcError` codes `unknown`, `cancelled`, `unavailable` and `internal`, each at elapsed = deadline and past it, with the connection live, are `plugin_health_timeout`.
  - `observed_connection_loss_wins_for_every_completion`: with `connectionFailed: true`, `TimeoutException`, `GrpcError(deadlineExceeded)` and `GrpcError(unavailable)`, before and after the deadline, are all `plugin_connection_lost`.
  - `timeout_completions_on_live_connection_are_health_timeout`: `TimeoutException` and `GrpcError(deadlineExceeded)` before the deadline are `plugin_health_timeout`.
  - `non_deadline_status_before_deadline_stays_connection_lost`: `GrpcError(unavailable)` one millisecond before the deadline is `plugin_connection_lost` (D2).

  Verify with `mise run test -- test/unit/plugin/health_failure_classification_test.dart`: it fails because the function does not exist (compile error naming `classifyHealthFailure`), the expected red.
- [x] 2.2 Implement `classifyHealthFailure` in `correlia_server/lib/src/plugin/output_plugin_connection.dart`, `@visibleForTesting`, as a switch on the error that follows design D1's order. Document it with `///`.
  - In `health`, start a `Stopwatch` immediately before `checkHealth`.
  - Route `TimeoutException` and `GrpcError` through `classifyHealthFailure`, with `connectionFailed: _stopped || _failure.isCompleted` read at the moment of failure.
  - Update the `health` doc comment to state the rule.
  - Verify: 2.1's tests pass, `plugin_protocol_test.dart` still passes, and `mise run check` passes. Flip the "Stalled plugin ends the call itself" row green (the "Connection lost" row turns green in 3.2).

## 3. Real-process coverage (design D3)

- [ ] 3.1 Add `health_call_stalls_under_load` to `correlia_server/test/plugin/plugin_protocol_test.dart`.
  - On one `stall-health` connection, 20 iterations each start `health(timeout: 100 ms)`, block the isolate for 300 ms with a `Stopwatch`-bounded synchronous loop (no `sleep`, no `Future.delayed`), then expect `plugin_health_timeout`.
  - Add a short comment: the test is supplementary stress evidence, and the deterministic proof is the classifier test.
  - Verify with `mise run test -- --tags plugin test/plugin/plugin_protocol_test.dart`. Flip the row green.
- [ ] 3.2 Add `health_connection_lost_during_call` to `plugin_protocol_test.dart`.
  - On a `stall-health` connection, start `health(timeout: 2 s)`, then send `SIGKILL` to the connection's own child (`connection.pid`; never a process matched by name).
  - Expect `plugin_connection_lost`, and expect `connection.failure` to complete.
  - Apply D4 to `_GuardedSink.add` in `bounded_channel.dart`: use a separate `try` around only delegate `add`, catch only `StateError`, set `_failed` first, then route `const GrpcError.unavailable('plugin transport closed')` and the original stack through `_Stream._fail`. Never set `frameFailure` for this transport error.
  - The guard's FormatException branch must return before the delegate write; `_fail` runs outside the protected try and its own failures propagate.
  - Before the fix, add and run fast-tier `bounded_channel_test.dart` using hand-written connector/connection/stream fakes via the public connector. Prove a pre-closed sink yields exactly one incoming unavailable error, terminates the stream, leaves `frameFailure` null, drops later writes and closes safely. This closed-sink test is the red-to-green proof. Guard tests start green: non-StateError delegate failures propagate with no incoming error/close or termination, a later write still reaches the delegate and `frameFailure` stays null; oversized/compressed frames set `frameFailure`, emit FormatException and never reach the delegate. Listen before writing. Record the red result and 2/2 unfixed SIGKILL failures in `evidence/protocol-load-runs.md`.
  - Keep SIGKILL supplementary (unfixed sink failed 2/2 observed runs). The observed-loss classifier test is the deterministic precedence proof.
  - Verify with the same command, then flip the "Connection lost during a health call" row green.
- [ ] 3.3 [evidence] Run `plugin_protocol_test.dart` 10 times, in rounds of 4 parallel runs, alongside one `mise run test:all` started at the same time. Record pass/fail counts per test and any failure output. Verified by 0 failures in the file across all runs. Report any other flaky test found, without fixing it here (S3). → evidence/protocol-load-runs.md
- [ ] 3.4 Re-run `plugin_reports_serving` and `health_call_stalls` with `mise run test -- --tags plugin test/plugin/plugin_protocol_test.dart --name "plugin_reports_serving|health_call_stalls"`. Verified by both passing. Their rows stay green.

## 4. Gate

- [ ] 4.1 [evidence] Run `mise run check` and `mise run test:all` on the change branch. Record the totals and the result line of each. Verified by both passing with 0 failures. → evidence/gate-runs.md

## Workflow follow-up

- Archive the change and finish locally (`finish: local`).
- Re-run `/specwright-roadmap close` for M1 from a clean clone; this change's criterion is judged there.
