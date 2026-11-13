# Unchanged health status capture

Command: `mise exec -- dart run test/plugin/health_status_probe.dart` from `correlia_server`, 2026-11-13. Exit 0.

The throwaway probe used a byte-for-byte copy of `output_plugin_connection.dart` at baseline `8da8c13`, with only raw-error print statements added inside the existing health catch handlers. Production code was not modified. It opened one real `stall-health` fixture connection, made 50 health calls with a 100 ms deadline, and blocked the isolate for 300 ms immediately after starting each call using a Stopwatch-bounded synchronous loop. The copied library and probe were deleted after the run.

Versions: grpc-dart 5.2.0 (`pubspec.lock`), grpc-go v1.75.1 (fixture `go.mod`).

| Raw outcome | Count | Mapped class |
|---|---:|---|
| GrpcError code 4, message `Deadline exceeded` | 50 | plugin_health_timeout |
| TimeoutException | 0 | plugin_health_timeout |
| Other GrpcError | 0 | plugin_connection_lost |
| Success | 0 | — |

Each indexed call 0–49 produced the same code/message above. The original line-385 `plugin_connection_lost` path was reached 0 times. This run did not capture the non-deadline status from the reported M1 failure; it cannot identify that historical status. It confirms that starvation alone does not deterministically force that completion, as anticipated by design D3. The classifier tests supply deterministic branch proof.
