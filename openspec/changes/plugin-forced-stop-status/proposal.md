# Proposal

## Why

M1's exit criterion "`mise run check` and every test tier except `load` pass from a clean clone in WSL" is
agent-verified. On 2026-11-14 it was still failing at random. The gate runs of `e2e-child-server-reliability`
ran `mise run test:all` four times. Run 3 failed on a test outside that change's scope, in the plugin
supervision suite:

- `plugin_ignores_shutdown` (`correlia_server/test/plugin/plugin_supervision_test.dart:281-292`):
  1. It starts a worker with the fixture output plugin, waits for a `ready` status row, and SIGSTOPs the
     plugin process.
  2. It stops the ingest workers and waits for the `stopped` row.
  3. It expects `lastErrorClass` to record the forced stop.

  In the failing run the `stopped` row had no `lastErrorClass` at all (`plugin_ignores_shutdown` at line 290:
  `Expected: not null, Actual: <null>`). The spec scenario "Plugin ignores shutdown" requires that "its forced
  stop is recorded". An operator reading the status row after such a shutdown would not learn that a plugin had
  to be killed.
- The test's teardown then called `IngestWorkers.stop()` a second time. That throws `Bad state: Future already
  completed` from `PipelineSubsystem.stop` (`correlia_server/lib/src/pipeline/pipeline.dart:781-785`), which
  completes its stop completer without checking it. The relay and the plugin supervisor already guard theirs.

The failure is rare. It was seen once in four full runs. It did not reproduce in:
- 15 runs of the test alone under eight CPU burners;
- 5 runs of its whole file under load;
- 3 full `test:all` runs with temporary logging of every supervisor removal and status write.

In every logged run the child was force-terminated and the `stopped` row carried `plugin_forced_stop`. The code
has several ways one plugin key can get a status write after the forced one:
- an idle release or a failure removal still in flight when shutdown begins;
- a relaunched instance with its own status queue;
- the shutdown-time removal itself.

The status table keeps one upserted row per host and plugin, so any later write replaces the reason. Which
path the failing run took is not known yet.

This change closes that M1 gap without depending on the unknown path. The forced reason is written by the
supervisor's last status write of a shutdown, so no earlier write can clear it. Each reaped child is logged and
the test reports what it saw, so a recurrence can be diagnosed. A reproduction attempt runs first, and if it
finds the path, that path gets its own regression test and fix. The criterion is agent-verified, so it is
judged by re-running the M1 close from a clean clone; no `[user]` task is needed.

## What Changes

- The plugin supervisor remembers which children it force-terminated after shutdown began. It records this at
  every place a child is reaped, including a startup abandoned during shutdown and a cleanup that fails after
  the SIGKILL. Its final shutdown status write, which already marks every row of the host `stopped`, also sets
  `lastErrorClass` to `plugin_forced_stop` on those keys' rows in the same statement. It runs only after every
  earlier status write has settled, and a fence stops any status write after it.
- The supervisor logs one line per child it reaps (output, definition digest, pid, whether the removal was a
  failure, whether the child was force-terminated). The line holds no secret and no config.
- `plugin_ignores_shutdown` captures the supervisor's log and every distinct status row it polls, and puts both
  into its failure message.
- `PipelineSubsystem.stop` returns at once when the pipeline was never started, and waits for the first stop
  when it has already been stopped.
- `IngestWorkers.stop` runs once. The first caller still gets any stop error. A second call waits for the first
  to finish and completes without error, stopping no component again.
- A reproduction attempt with the new diagnostics runs before the fix. If it finds the path, that path gets a
  deterministic regression test and a fix at its source.
- Repeated `mise run test:all` runs and one from a clean clone are recorded as evidence.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `plugin-supervision`: "Bounded plugin shutdown" makes the recorded forced stop durable. The reason is set by
  the shutdown's final status write and is never cleared later in that shutdown. Each reaped child is logged.
- `process-roles`: adds that stopping the worker's subsystems a second time is a no-op that does not throw.

## Impact

- Product code:
  - `correlia_server/lib/src/plugin/plugin_supervisor.dart`: the forced-reap record, the reap log line and the
    final write;
  - `plugin_status_repository.dart`: `markStopped` takes the forced keys;
  - `correlia_server/lib/src/pipeline/pipeline.dart`: `stop` is guarded;
  - `correlia_server/lib/src/ingest/ingest_workers.dart`: `stop` runs once.
- Tests:
  - `plugin_supervision_test.dart`: diagnostics only, no assertion weakened;
  - a status repository test in `test/db/plugin_status_persistence_test.dart`;
  - stop idempotence tests on the `db` tier.
- Unchanged: schema, migrations, models, the plugin protocol and the go-plugin handshake.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Make the invariant hold whatever the race was

- **Choice:** Write the forced reason in the shutdown's last status statement, and try first to reproduce the
  race with diagnostics. If the attempt finds the path, fix it at its source as well.
- **Rejected:** Block the change until the race is reproduced. It reproduced once in about thirty runs across
  four methods, so the M1 close would wait an open-ended time. Also rejected: retry or loosen the test's
  assertion, which would hide a real loss of the operator-visible reason.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

### S2: Fix the second-stop throw in the same change

- **Choice:** Make `PipelineSubsystem.stop` and `IngestWorkers.stop` safe to call twice.
- **Rejected:** A test-only fix (teardown skips a stopped worker). The product has the same exposure: a role
  shutdown that retries a stop after an error would also throw.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

## Release Notes

Preserves forced-stop status and makes plugin shutdown failures diagnosable.

### Changed

- Plugin shutdown diagnostics identify each reaped child and whether termination was forced, without logging configuration or secrets.
- The forced-shutdown regression waits for every plugin thread to stop before requesting shutdown, avoiding a race between signal delivery and the fixture's stdin-EOF exit.

### Fixed

- The final supervisor status write restores forced-stop reasons after in-flight writes, including failed startup and cleanup; shutdown still reports cleanup errors.
- Worker stops run each subsystem once, preserve errors for the first caller, and let later callers finish normally; pipelines also stop safely before start.
- Cleanup errors remain visible when a sweep removal overlaps shutdown and the supervisor revisits the same reaped connection.
