# Correlia

Event/alert aggregator and correlator: ingest alerts from monitoring systems, normalize and enrich them
into one canonical versioned event, publish them to outputs such as NATS, and correlate them into incidents
worked in a Flutter web console. Built on Dart, Serverpod and PostgreSQL.

**Status:** M1 rebuild in progress. Canonical events, durable Alertmanager ingestion/processing,
alert-state/live-console, signed webhook output and the NATS JetStream output are implemented.
Milestone acceptance remains separate; see `openspec/roadmap.md` and `docs/plan/`.

For an illustrated walkthrough of the implemented alert lifecycle, open
[`docs/project-preview.html`](docs/project-preview.html) in a browser (self-contained, offline).

The earlier Python implementation is kept on the local branch `legacy/python`.

The canonical event payload contract is generated and checked with
`mise run proto` and `mise run proto:check`. See
`docs/event-contract-tooling.md` for the generation, compatibility and offline
cache behavior.

## Local ingest setup

Use the pinned Linux toolchain through mise. `mise run setup` creates missing local Serverpod passwords;
`mise run run` starts the server. Configure `CORRELIA_INGEST_CONFIG` and `CORRELIA_INGEST_SECRETS`
with absolute paths to operator-owned files before starting. See the
[ingest pipeline guide](docs/ingest-pipeline.md) for secret generation, immutable revisions, sender setup,
schema upgrades/repair, retry semantics and SQL-only failure inspection.
For a local JetStream stream, plugin configuration and the Alertmanager-to-console demonstration,
see the [NATS output runbook](docs/runbooks/output-nats.md).

`mise run test` runs fast tests; `mise run check` is the project gate and `mise run test:all` includes
the non-load database, process and plugin tiers. Tests use only their own embedded PostgreSQL.
