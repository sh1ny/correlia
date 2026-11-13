# Protocol load and transport regression evidence

## Deterministic transport regression

Before changing `bounded_channel.dart`, `mise run test -- test/unit/plugin/bounded_channel_test.dart` exited 1: 2 passed, 1 failed. `closed_delegate_write_fails_rpc` failed at `_GuardedSink.add` line 232 with `Bad state: Cannot add new events after calling close`. The guard cases `non_state_error_propagates` and `invalid_frames_still_fail` both passed unchanged.

After the D4 fix, the same command exited 0: `00:00 +3: All tests passed!`. The closed-sink case receives exactly one unavailable RPC error and completes, later writes are dropped, the stream is terminated and `frameFailure` stays null. The guard cases prove non-StateError propagation without incoming/connection-state mutation and no delegate writes for invalid frames.

## Supplementary SIGKILL reproduction

The unfixed sink failed 2/2 observed SIGKILL runs: the whole protocol file and the focused command `mise run test -- --tags plugin test/plugin/plugin_protocol_test.dart --name health_connection_lost_during_call --chain-stack-traces`. Both raised uncaught `Bad state: Cannot add event after closing` at `_GuardedSink.add` line 232. The chained stack identified grpc-dart `Http2TransportStream`'s outgoing-body listener. No retries or delays were added.

After the fix, `mise run test -- --tags plugin test/plugin/plugin_protocol_test.dart` exited 0: `00:09 +13: All tests passed!`, including the 20-call starvation test and the immediate SIGKILL test. This process evidence is supplementary; the fast-tier fake-transport and classifier tests prove the deterministic branches.

## Ten parallel load runs

2026-11-13, change branch `feat/plugin-health-timeout-classification`.
Started one `mise run test:all` alongside round 1. Ran the protocol file ten times with `mise run test -- --tags plugin test/plugin/plugin_protocol_test.dart`, in rounds of 4, 4 and 2 concurrent processes. The final `mise run check` also ran concurrently. Every protocol process exited 0, each with 13 tests passing: 130/130, 0 failures. Each starvation test performs 20 calls, so these repetitions exercised 200 stalled calls.

| Test | Passes | Failures |
|---|---:|---:|
| output_plugin_identifies_itself | 10 | 0 |
| plugin_without_output_kind | 10 | 0 |
| spike_probe_cookie_rejected | 10 | 0 |
| accepted_configuration | 10 | 0 |
| rejected_configuration | 10 | 0 |
| batches_within_limits | 10 | 0 |
| plugin_limits_above_host_bounds | 10 | 0 |
| mixed_outcomes_in_one_batch | 10 | 0 |
| malformed_batch_answer | 10 | 0 |
| plugin_reports_serving | 10 | 0 |
| health_call_stalls | 10 | 0 |
| health_call_stalls_under_load | 10 | 0 |
| health_connection_lost_during_call | 10 | 0 |

The concurrent all-tier run exited 1 with **448 passed, 1 failed**:

```text
03:00 +407 -1: test/e2e/ingress_e2e_test.dart: conflicting_credentials [E]
  TimeoutException after 0:00:30.000000: Test timed out after 30 seconds.
  dart:isolate  _RawReceivePort._handleMessage
09:23 +448 -1: Some tests failed.
Failing tests:
  test/e2e/ingress_e2e_test.dart: conflicting_credentials
Finished in 569.23s
[test:all] ERROR task failed
```

This is outside the protocol file and is reported without changing it (S3). Its root cause is not established by this run; concurrent load is an observation, not proof of causation. No protocol failures were hidden or retried.

## Existing health scenarios

`mise run test -- --tags plugin test/plugin/plugin_protocol_test.dart --name "plugin_reports_serving|health_call_stalls"` exited 0, `00:08 +3: All tests passed!`. The selector matches both original cases plus the new `health_call_stalls_under_load` case. All three passed.
