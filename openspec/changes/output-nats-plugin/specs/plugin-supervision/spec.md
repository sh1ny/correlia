# Spec Delta

## Purpose

Keeps configured external plugins running in the worker role: verified launches, readiness, health,
restart with backoff, a crash-budget circuit, bounded shutdown, and persisted, inspectable status.

## ADDED Requirements

### Requirement: Verified plugin launch
Before every launch the supervisor SHALL verify:
- the executable resolves inside the configured plugin directory;
- it is a regular file owned by the server's user and not writable by group or others;
- its SHA-256 equals the pinned digest.

A failed check SHALL prevent the launch and record its error class.

#### Scenario: Pinned executable launches
- **WHEN** a plugin output names an owner-only executable in the plugin directory whose SHA-256 matches its pin
- **THEN** the supervisor launches it, and the instance reaches `ready` after handshake, metadata, configuration and a serving health check

#### Scenario: Replaced or unsafe executable
- **WHEN** the executable's bytes change after the pin, it is group-writable, it is a symlink out of the plugin directory or it is missing
- **THEN** no process is started, the instance records error class `plugin_executable_rejected` and enters restart backoff

### Requirement: Restart with backoff
When a ready plugin exits, fails startup or fails 3 consecutive health checks, the supervisor SHALL stop that process and restart it after a capped exponential backoff. The backoff starts at 1 s, doubles up to 60 s and resets after 10 minutes of continuous readiness.

#### Scenario: DUR-8 plugin crashes mid-stream
- **WHEN** a ready plugin process is killed while a batch is unanswered
- **THEN** the supervisor records the crash, restarts the plugin after the first backoff step, the instance returns to `ready`, and the batch's events are delivered again with unchanged ids and bytes

#### Scenario: Repeated startup failure grows the delay
- **WHEN** a plugin fails startup on every attempt
- **THEN** successive restart delays are 1 s, 2 s, 4 s and so on, never exceeding 60 s, measured on the injected clock

### Requirement: Crash budget circuit
More than 5 crashes or startup failures of one instance within 10 minutes SHALL open its circuit: the instance becomes `degraded`, receives no deliveries, and is retried once every 5 minutes. A probe that reaches `ready` and stays ready for 60 s SHALL close the circuit.

#### Scenario: DUR-8 crash budget exceeded
- **WHEN** a plugin crashes 6 times within 10 minutes
- **THEN** its instance is `degraded`, its status row says so, one `plugin_degraded` activity entry is written, and no batch is sent to it while degraded

#### Scenario: Degraded plugin recovers
- **WHEN** a degraded plugin's probe launch reaches `ready` and stays ready for 60 s
- **THEN** the instance becomes `ready`, one `plugin_recovered` activity entry is written and deliveries resume

### Requirement: Fair instance slots
The supervisor SHALL run instances only for definitions with due work, within 16 per worker and 4 per output, and SHALL admit waiting runnable definitions round-robin in a fixed key order. A definition waiting on either cap SHALL get a slot from that cap's scope: the longest-held ready instance there hands over after 60 s and its current batch. An unfinished circuit probe SHALL NOT be handed over, idle instances SHALL free their slot after 60 s, and failing instances at once.

#### Scenario: More busy outputs than slots
- **WHEN** 17 plugin outputs each have a steady stream of due work and every plugin is healthy
- **THEN** every output delivers within a bounded time measured on the injected clock, and while one waits its status shows `instance_limit`

#### Scenario: Idle active output releases its slot
- **WHEN** 16 outputs hold every slot, one of them has had no due work for 60 s, and a 17th output gets due work
- **THEN** the idle instance stops, the 17th output's instance starts in its slot and delivers, and the idle output starts again when it next has due work

#### Scenario: More live definitions than one sweep page
- **WHEN** raw work pinned under snapshot A is held after pinning, snapshot B activates with changed definitions for the same 64 outputs, and both generations then create due work, giving 128 live definitions
- **THEN** every definition is found by the supervisor's sweep and delivered, never more than 16 instances run at once, and no activation was refused

#### Scenario: Five busy definitions of one output
- **WHEN** one output has five healthy definitions with continuously due work, the worker's other 12 slots are free, and time is measured on the injected clock
- **THEN** the fifth definition takes over a slot from its own output within the stated bound, every one of the five delivers repeatedly, and the output never runs more than 4 instances

#### Scenario: Probe under slot contention
- **WHEN** a degraded definition's probe takes 5 s to start and then serves healthy batches while other definitions wait for slots
- **THEN** it is not handed over before its 60 s of readiness, its circuit closes with exactly one `plugin_recovered` entry, and the waiting definitions are admitted afterwards within the stated bound

#### Scenario: Healthy definition at the end of a long queue
- **WHEN** 300 definitions have due work, most of them fail startup again and again, 16 slots are busy, and one healthy definition sorts last in the key order, measured on the injected clock
- **THEN** the healthy definition is admitted and delivers within the round-robin bound, never more than 16 instances run, and the supervisor's memory holds state only for running instances

#### Scenario: Healthy definition behind unavailable historical ones
- **WHEN** an output has 4 historical definitions whose plugins cannot launch, each holding queued work, and its active definition gets due work
- **THEN** one of the failing instances yields its slot, the active definition's work is delivered, and the historical intents keep zero new attempts

### Requirement: Durable supervision history
A definition's backoff step, crash window and circuit state SHALL survive its instance leaving a slot, so that readmission continues them instead of starting fresh, and SHALL be kept outside memory once the instance stops.

The owning supervisor SHALL prune its health rows only when no queued or delivering work remains. Another host's health SHALL be removed by status cleanup only after its last status row expires following more than 24 h without a heartbeat; a stopped row older than 60 s SHALL NOT authorize cross-host deletion.

Owner-local stopped-row expiry SHALL retain a status row while its host/output/definition key has a health row, preserving the anchor for later cross-host expiry.

#### Scenario: Failing definitions cycle through slots
- **WHEN** 40 definitions whose plugins fail startup take turns in 16 slots, measured on the injected clock
- **THEN** each one's restart delays keep doubling across readmissions, a definition that fails 6 times within 10 minutes opens its circuit even though the failures happened in different slots, and the supervisor holds in memory only the instances that are running

#### Scenario: Live host with only stopped instances
- **WHEN** a host has only stopped status rows older than 60 s but less than 24 h, and its definition has queued work and saved non-zero backoff and crash history, and another host prunes status
- **THEN** the first host's status and supervision history survive unchanged for readmission

#### Scenario: Dead host after owner-local pruning
- **WHEN** a host with queued work prunes its stopped status row older than 60 s while the same key has supervision history, then becomes silent and another host prunes more than 24 h later
- **THEN** the owner's prune keeps both rows, and the later cross-host prune removes both status and health without removing queued work

### Requirement: Persisted plugin status
The supervisor SHALL keep one status row per running plugin instance with:
- output, definition digest, worker process identity and state;
- plugin name, version and process id;
- restart count, last error class and a heartbeat.

Ready instances and waiting definitions SHALL refresh their rows at least every 15 s. Starting SHALL be written at launch; backoff, degraded and stopped rows SHALL be written on transitions and MAY age while their worker remains alive.

Every 60 s, a supervisor SHALL prune its own stopped rows older than 60 s only when the same host/output/definition key has no health row. Another host's rows SHALL expire only after more than 24 h without a heartbeat.

A row whose heartbeat is older than 60 s SHALL read as stale.

#### Scenario: Status of a ready plugin
- **WHEN** a plugin instance is ready
- **THEN** its status row shows state `ready`, the plugin's reported name and version, its process id and a heartbeat no older than 15 s

#### Scenario: Worker killed
- **WHEN** the worker is killed with SIGKILL
- **THEN** its status rows remain, their heartbeat stops advancing, and after 60 s the status query reports them stale rather than ready

### Requirement: Bounded plugin shutdown
On worker shutdown the supervisor SHALL stop after the relay has stopped sending. It SHALL request each plugin's graceful shutdown and force termination after a bounded grace period. It SHALL reap every child and mark its status rows `stopped`.

#### Scenario: Graceful worker stop
- **WHEN** a worker with a ready NATS plugin receives SIGTERM
- **THEN** no new batch is sent after shutdown starts, the plugin exits, the status row reads `stopped` and no child process of the worker remains

#### Scenario: Plugin ignores shutdown
- **WHEN** a plugin does not exit after the shutdown request
- **THEN** it is force-terminated after the grace period, its forced stop is recorded and worker shutdown completes
