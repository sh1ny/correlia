# Spec Delta

## MODIFIED Requirements

### Requirement: Bounded plugin shutdown
On worker shutdown the supervisor SHALL stop after the relay has stopped sending. It SHALL request each plugin's graceful shutdown and force termination after a bounded grace period. It SHALL reap every child and mark its status rows `stopped`. A child force-terminated after shutdown began, whether during its startup, its removal or a failing cleanup, SHALL leave `plugin_forced_stop` as the last error class of its key's `stopped` row. That reason SHALL be set by the supervisor's final status write of the shutdown, after every earlier status write of that supervisor has settled, and the supervisor SHALL write no status after it. Errors of the shutdown SHALL still be reported. The supervisor SHALL log each child it reaps with its output, definition digest, process id and whether it was force-terminated, and no secret or configuration value.

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
