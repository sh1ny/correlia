# 0001. Serverpod 4.1 modular monolith with process roles

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: none

## Context

Correlia ingests webhooks and polled streams, runs a staged pipeline, correlates events into incidents and
serves a live console. The owner is one Dart/Flutter developer. The legacy Python service was a single
process; its state ownership was sound but its single-process task runner could not scale or survive
restarts (legacy audit 7.1). Serverpod 4.1 offers an ORM with migrations, endpoints, streams, a Relic web
server for custom routes, future calls (at-least-once, cron) and health probes.

## Decision

One Dart codebase (`correlia_server`) built on Serverpod 4.1, deployed as one binary that runs in one or
more **roles**: `api` (endpoints, webhook routes, console streams), `worker` (pipeline stages, outbox relays,
plugin host, scheduled jobs) and `all` (default for single-node installs). Instances coordinate only
through PostgreSQL (row claims with `FOR UPDATE SKIP LOCKED`, advisory locks); no in-memory state is
authoritative. CPU-heavy pipeline stages run in worker isolates inside the `worker` role. Redis is added only
when multiple `api` instances need Serverpod's cross-instance stream fan-out.

Rejected: microservices per stage (ingest, pipeline, correlation, notification) talking over NATS. It buys
independent scaling the project does not need yet and makes NATS a hard dependency; reversal would be a large
refactor of every stage boundary.

## Consequences

- One deployable, one migration stream, one config. Horizontal scale by adding `worker` instances.
- Every background loop must be claim-based and idempotent so that N instances are safe.
- Reversal cost: medium to high. The raw inbox and outbox are table boundaries, so moving ingest or output
  relays into separate services is mostly deployment work. Correlation is not: it relies on one transaction
  spanning alert state, incidents and outbox rows (ADR 0005, 0007) and on in-process plugin interfaces.
  Splitting it out would need a new consistency design, not just deployment.
