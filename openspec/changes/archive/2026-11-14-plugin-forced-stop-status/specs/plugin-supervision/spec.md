# Spec Delta

## MODIFIED Requirements

### Requirement: Bounded plugin shutdown
After the relay stops sending on worker shutdown, the supervisor SHALL request each plugin's graceful shutdown, force termination after a bounded grace, reap every child and mark its rows `stopped`. Its final status write SHALL await all its prior status writes and set `plugin_forced_stop` as the last error class of keys whose children were forced after shutdown began. It SHALL write no status afterward, log every reap without secret or configuration values, and report shutdown errors.

#### Scenario: Graceful worker stop
- **WHEN** a worker with a ready NATS plugin receives SIGTERM
- **THEN** no new batch is sent after shutdown starts, the plugin exits, the status row reads `stopped` and no child process of the worker remains

#### Scenario: Plugin ignores shutdown
- **WHEN** a plugin does not exit after the shutdown request
- **THEN** it is force-terminated after the grace period, its `stopped` status row records `plugin_forced_stop`, a log line names it as force-terminated and worker shutdown completes

#### Scenario: Removal in flight when shutdown begins
- **WHEN** a removal of a plugin that ignores shutdown is still in progress when worker shutdown begins, and finishes after it
- **THEN** the key's final row reads `stopped` with `plugin_forced_stop`, and no status write of the supervisor follows its final write

#### Scenario: Launch overlapping shutdown
- **WHEN** a plugin launch is in progress when worker shutdown begins, and its child does not exit on request and is force-terminated as the startup is abandoned
- **THEN** a log line names that child as force-terminated, the key's final row reads `stopped` with `plugin_forced_stop`, and no status write of the supervisor follows its final write

#### Scenario: Cleanup fails after forced termination
- **WHEN** a child is force-terminated during shutdown and the cleanup that follows raises an error
- **THEN** the key's final row reads `stopped` with `plugin_forced_stop`, and worker shutdown still reports the error

#### Scenario: Forced reason survives a later status write
- **WHEN** a plugin key's row has been written with no error after its child was force-terminated during shutdown, before the shutdown's final status write
- **THEN** the final write leaves that row `stopped` with `plugin_forced_stop`, and rows of keys whose children exited on request keep their own last error class

#### Scenario: Earlier writes settle before the final write
- **WHEN** earlier status writes of the supervisor are still pending during worker shutdown
- **THEN** they all settle before its final status write marks its rows `stopped`, and no status write of that supervisor follows the final write

#### Scenario: Reap diagnostics
- **WHEN** the supervisor reaps a child that exited on request or was force-terminated
- **THEN** a log line identifies its output, definition digest, process id and whether termination was forced, without any secret or configuration value
