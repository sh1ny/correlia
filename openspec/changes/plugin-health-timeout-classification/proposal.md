# Proposal

## Why

The M1 close on 2026-11-13 found the agent-verified exit criterion "`mise run check` and every test tier except
`load` pass from a clean clone in WSL" failing. `mise run test:all` passed 439 of 440 tests. The failure was
`health_call_stalls` in `correlia_server/test/plugin/plugin_protocol_test.dart`: a plugin that never answers a
health call was reported as `plugin_connection_lost`, not `plugin_health_timeout`. The test passes alone, 20 runs
of 20, and failed only under the load of the full suite. The previous M1 close saw a different test in the same
file fail once under load.

This is a product defect, not only a slow test. The "Health call stalls" scenario of `plugin-output-protocol`
requires `plugin_health_timeout`. `OutputPluginConnection.health` reports only gRPC `deadlineExceeded` and the
client-side timer as a timeout, and maps every other gRPC status to `plugin_connection_lost`. The host sends its
deadline to the plugin, so a stalled plugin can end the call itself with its own status when the deadline
expires. Under load that answer can arrive before the host's own timer fires, and its code need not be
`deadlineExceeded`. A plugin that is merely slow is then reported as a lost connection. At startup that error
class is what the supervisor records for the failed start, so operators are pointed at the wrong cause.

This change closes that M1 gap. The criterion is agent-verified, so it is judged by re-running the M1 close from
a clean clone; no `[user]` task is needed.

## What Changes

- A health call whose own deadline has elapsed fails as `plugin_health_timeout`, whatever status ends it, as long
  as the plugin connection itself is still up.
- `plugin_connection_lost` is kept for real loss: the connection already failed or stopped, the plugin process
  exited, or the transport broke before the deadline.
- The exact status a stalled plugin returns under load is captured once and recorded in the design, so the rule
  rests on evidence, not on a guess.
- `plugin_protocol_test.dart` is made reliable under full-suite load. The stall test asserts the classification
  without depending on which of the two timers fires first. The file is run repeatedly under parallel load as
  proof.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `plugin-output-protocol`: "Plugin health reporting" states that a call ended at or after its deadline is a
  health timeout even when the plugin or the transport ends it with another status, and that only a real
  connection loss is `plugin_connection_lost`.

## Impact

- Code: `correlia_server/lib/src/plugin/output_plugin_connection.dart` (`health`). The supervisor
  (`plugin_supervisor.dart`) keeps its behaviour and only receives the right class.
- Tests: `correlia_server/test/plugin/plugin_protocol_test.dart` and, if needed, the Go stall fixture under
  `correlia_server/test/plugin/fixtures/go/`.
- Plugin protocol (`correlia.plugin.v1`), the `output-nats` plugin, schema and migrations: unchanged.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Fix the classification, not only the test

- **Choice:** Change `health` so a call that ends at or after its deadline on a live connection is
  `plugin_health_timeout`, and make the test assert that.
- **Rejected:** Loosen the test to accept either class, which hides a defect against the "Health call stalls"
  scenario. Retry the test on failure, which hides it too. Lengthen the test deadline, which makes the race rarer
  without removing it.
- **Reversal cost:** low (one classification rule and its tests)
- **Important:** yes: it changes an error class operators see on plugin status rows
- **Chosen by:** agent

### S2: The deadline decides, not the status code

- **Choice:** Classify by whether the call's own deadline has elapsed on a still-live connection, not by a list of
  gRPC codes.
- **Rejected:** Add `cancelled` and `unknown` to the codes treated as a timeout, which depends on the plugin's
  language and gRPC version and would also misreport a real cancellation that happens before the deadline.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

### S3: Scope stays M1-sized

- **Choice:** Fix health classification and the reliability of `plugin_protocol_test.dart` only. Other flaky tests
  found while proving it are reported and get their own change.
- **Rejected:** A general test-flakiness sweep, which has no evidence behind it yet and would delay the M1 close.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent
