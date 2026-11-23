# Spec Delta

## ADDED Requirements

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
