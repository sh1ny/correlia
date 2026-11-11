# Correlia

Event/alert aggregator and correlator: ingest alerts from monitoring systems, normalize and enrich them
into one canonical versioned event, publish them to outputs such as NATS, and correlate them into incidents
worked in a Flutter web console. Built on Dart, Serverpod and PostgreSQL.

**Status:** M1 rebuild in progress. Canonical events, durable Alertmanager ingestion/processing and signed
webhook output are implemented. Alert-state/live-console and NATS output remain later roadmap slices;
this does not claim their milestone acceptance. See `openspec/roadmap.md` and `docs/plan/`.

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

`mise run test` runs fast tests; `mise run check` is the project gate and `mise run test:all` includes
the non-load database, process and plugin tiers. Tests use only their own embedded PostgreSQL.
