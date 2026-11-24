# process-roles Specification

## Purpose

Defines how the single Correlia server binary is started in a process role (`api`, `worker` or `all`), which
subsystems each role runs, how its health is reported and how it shuts down.

## Requirements

### Requirement: Role selection at startup
The server SHALL start in exactly one role, `api`, `worker` or `all`, chosen by an operator setting read at
startup. When no role is set, the role SHALL be `all`. The role in force SHALL be written to the startup log.

#### Scenario: Role set explicitly
- **WHEN** the server is started with the role setting `worker`
- **THEN** it runs in the `worker` role and its startup log names the role `worker`

#### Scenario: No role set
- **WHEN** the server is started without a role setting
- **THEN** it runs in the `all` role and its startup log names the role `all`

#### Scenario: Unknown role
- **WHEN** the server is started with the role setting `frontend`
- **THEN** it exits with a non-zero status before opening any listener or database connection, and its error
  output names the value `frontend` and the valid roles `api`, `worker`, `all`

### Requirement: Role selection keeps the other startup options
Choosing a role SHALL NOT change how any other startup option is read: the run mode, server id, logging
mode and migration options given on the command line keep their meaning in every role.

#### Scenario: Production mode with a role
- **WHEN** the server is started with run mode `production` and role `api`
- **THEN** it runs in run mode `production` and role `api`

#### Scenario: Startup options rejected as a whole
- **WHEN** the server is started with a command-line option it does not recognise, together with run mode
  `production`
- **THEN** it exits with a non-zero status naming the unrecognised option, rather than starting in a default
  run mode

### Requirement: Subsystems per role
Each subsystem SHALL declare the roles it runs in, and the server SHALL start exactly the subsystems of its
role. The console and HTTP ingress subsystems run in `api` and `all`; background subsystems run in `worker`
and `all`.

#### Scenario: api role
- **WHEN** the server starts in role `api`
- **THEN** the console is served and no background subsystem is started

#### Scenario: worker role
- **WHEN** the server starts in role `worker`
- **THEN** background subsystems are started and a request for the console is answered with 404

#### Scenario: Subsystem fails to start
- **WHEN** a subsystem of the role fails while starting
- **THEN** the server exits with a non-zero status and its error output names that subsystem

### Requirement: Health endpoints in every role
In every role the server SHALL answer `/livez`, `/readyz` and `/startupz` on its API port, without
authentication: 200 when healthy, 503 when not. `/readyz` SHALL report 503 while the database is unreachable.
`/startupz` SHALL report 503 until every subsystem of the role has started and the server is ready to stop
them on shutdown.

#### Scenario: Healthy server
- **WHEN** a server in any role has finished starting and its database is reachable
- **THEN** `/livez`, `/readyz` and `/startupz` each answer 200

#### Scenario: Subsystem still starting
- **WHEN** a subsystem of the role has not finished starting
- **THEN** `/startupz` answers 503, and it answers 200 once that subsystem has started

#### Scenario: Database unreachable
- **WHEN** the server's database stops accepting connections after startup
- **THEN** `/readyz` answers 503 while `/livez` still answers 200

### Requirement: Graceful shutdown
On SIGTERM or SIGINT the server SHALL stop accepting requests, then stop its started subsystems one at a time
in the reverse of their start order, waiting for each to finish, and only then close its database connections
and exit. A SIGTERM shutdown that completes
without error SHALL exit with status 0.

#### Scenario: SIGTERM
- **WHEN** a running server receives SIGTERM
- **THEN** it stops its subsystems in reverse start order, each finishing before the next starts stopping,
  all before its database connections close, and exits with status 0

#### Scenario: Subsystem fails to stop
- **WHEN** a background subsystem raises an error while stopping
- **THEN** the remaining subsystems are still stopped and the remaining shutdown steps still run, the error is
  logged with the subsystem's name, and the process exits with status 1

### Requirement: Repeated worker stop
Stopping the worker's ingest subsystems SHALL happen once. The first stop request SHALL report any error of that stop, as "Graceful shutdown" requires, after attempting to stop every subsystem. A further stop request, during or after the first, SHALL wait for the first to finish, SHALL complete without error whether the first succeeded or failed, and SHALL NOT stop any component a second time. A pipeline that was never started SHALL stop at once without error.

#### Scenario: Stop called twice
- **WHEN** the ingest workers have been stopped successfully and stop is called again
- **THEN** the second call completes without error and no subsystem's stop runs twice

#### Scenario: Concurrent stops that succeed
- **WHEN** a second stop is called while a first stop, which will succeed, is still stopping the subsystems
- **THEN** both calls complete after the subsystems have stopped, neither throws, and no subsystem's stop runs twice

#### Scenario: Stop again after a failed stop
- **WHEN** a subsystem raises an error while the first stop runs, and stop is called again after the first call has failed
- **THEN** the first call raises that error after the other subsystems were stopped, the second call completes without error, and no subsystem's stop runs twice

#### Scenario: Concurrent stop while the first fails
- **WHEN** a second stop is called while a first stop is running in which a subsystem raises an error
- **THEN** the first call raises that error, the second call completes without error after the first has finished, and no subsystem's stop runs twice

#### Scenario: Pipeline stopped before start
- **WHEN** a pipeline subsystem that was never started is stopped
- **THEN** the stop completes at once without error

### Requirement: Event Streams consumers run in background roles

Event Streams consumers SHALL run only in the `worker` and `all` roles, start after the pipeline and stop
before it. The pipeline and its database pool SHALL remain available throughout consumer shutdown so
the pipeline can still claim admitted rows.

#### Scenario: api role
- **WHEN** a server in role `api` starts with a stream source configured
- **THEN** it holds no lease and opens no connection to Icinga 2

#### Scenario: Shutdown order
- **WHEN** a `worker` with a connected consumer receives SIGTERM while the database is reachable and the lease row is free
- **THEN** the consumer stops and releases its lease before the pipeline stops, and the process exits as the graceful shutdown requirement states

#### Scenario: Shutdown with the lease row locked
- **WHEN** a `worker` with a connected consumer receives SIGTERM while another backend still holds the lease row lock
- **THEN** the consumer stops before the pipeline stops, its final write times out, its lease is left to expire, and the process exits as the graceful shutdown requirement states

#### Scenario: Shutdown with the database unreachable
- **WHEN** a `worker` with a connected consumer receives SIGTERM while the database is unreachable
- **THEN** the consumer stops before the pipeline stops, its lease is left to expire, and the process exits as the graceful shutdown requirement states
