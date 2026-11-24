# Icinga 2 Event Streams

## MODIFIED Requirements

### Requirement: Consumer database sessions end their own work

Each consumer SHALL admit rows over its own database connection, outside the shared pool, opened with Serverpod's
database settings (a Unix socket for the embedded database, TCP with the configured TLS otherwise). Its session
SHALL check the client connection every second and end a transaction idle for 5 seconds; over TCP it SHALL also
set keepalives and a 10-second TCP user timeout.

#### Scenario: Stop during a stalled insert
- **WHEN** the worker is stopped while an insert transaction holds its locks and is idle between statements, over the embedded database's Unix socket
- **THEN** within 5 seconds an independent connection sees the locks released and none of the insert's rows, and stop returns within 10 seconds

#### Scenario: Stop during a running statement
- **WHEN** the worker is stopped while the insert transaction runs an interruptible statement that a test hook makes last 30 seconds with its statement timeout lifted
- **THEN** within 5 seconds of the stop an independent connection sees the session gone and its locks released

Verification: drive the four-second Dart abort and inspect the ten-second stop timer with a manual clock. Separately verify PostgreSQL's configured one-second connection check. Witness cancellation and transaction/session lock release on an independent connection before releasing the fixture's blockers. The 30-second sleep stages the blocking statement; elapsed runner time is not a test assertion.

#### Scenario: Insert finishing as stop begins
- **WHEN** an insert's commit and the stop happen at the same moment
- **THEN** the insert either committed wholly or left no row, and no other session's work is affected

### Requirement: Consumer stops within the shutdown deadline

On stop or lease loss, the consumer SHALL close its HTTP connections, and its database connection no later than
4 seconds after stop began, so the worker's stop returns within 10 seconds for all its consumers together.
PostgreSQL then ends the session and releases its locks once its backend can process the closed connection; no
release time is promised for every backend state or topology, and the documentation SHALL state this.

#### Scenario: Many sources
- **WHEN** a worker running 64 stream consumers is stopped, each with an insert in flight
- **THEN** stop returns within 10 seconds

Verification: hold all 64 admissions, manually drive the individual abort deadlines, and verify stop completes and disarms its shared ten-second timer without firing it or releasing the admission gates.

#### Scenario: Stop while reading
- **WHEN** the worker is stopped while the consumer waits for the next line
- **THEN** the socket is closed, stop returns within 10 seconds, and the lease is released if the final write commits within its 1-second timeout, or else left to expire

#### Scenario: Lease row still locked at stop
- **WHEN** the worker is stopped while a closing admission's backend still holds the lease row lock on a reachable database
- **THEN** the final write times out after 1 second, stop returns within 10 seconds, the lease expires by itself, and the status records the stop or expiry, never a release that did not commit

#### Scenario: Two workers, 64 sources
- **WHEN** two workers run with 64 enabled stream sources
- **THEN** at most 64 client-owned dedicated consumer sessions exist across both, one per lease holder, and a worker holding no lease has none

#### Scenario: Session settings of the dedicated connection
- **WHEN** a consumer opens its database connection, over the embedded database's Unix socket and over TCP
- **THEN** the session reports a 1-second client connection check and a 5-second idle-in-transaction timeout, and over TCP its keepalive and TCP user timeout settings

#### Scenario: Database unreachable at stop
- **WHEN** the worker is stopped while the database is unreachable
- **THEN** stop returns within 10 seconds and the lease expires by itself
