# Proposal

## Why

M1's next slice must turn authenticated Alertmanager deliveries into durable canonical events and independently retryable output work; the existing event library and plugin spike do not ingest or persist alerts. This advances M1's durability/identity/security tests (DUR-1..3, ORD-5 transport and observation dedup, ID-6, ID-7b/c, SEC-1, SEC-5) and clean-clone gate; full alert-state effects, NATS burst proof and the owner's real-source/console/NATS criterion are judged after the following two changes, at milestone close, because those surfaces do not exist in this slice.

## What Changes

- Register source instances with source-scoped, rotatable bearer credentials, body limits and immutable normalization/routing configuration; provide a bounded startup JSON bootstrap and separate local secret file, not an unauthenticated admin API.
- Accept POST `/hooks/alertmanager/<instance>` (and an explicitly configured path-token form), authenticate before buffering, deduplicate exact deliveries and commit the raw inbox before returning 202.
- Decode Alertmanager webhook v4 batches into the existing canonical event/CloudEvents contract. Preserve timestamp evidence, full-label identity with explicit exclusions, per-alert status and visible upstream truncation evidence.
- Add PostgreSQL schema steps for unmanaged inbox/event/outbox tables, managed configuration/dedup/failure/attempt records, crash-safe claims, durable first-claim config pins and atomic event/dedup/outbox/inbox commits.
- Add per-output relays with fenced expiring claims, recorded attempts, bounded retries and durable dead letters; implement signed structured-CloudEvents webhook-out through a shared in-process output contract.
- Integrate ingress with api/all and background processing with worker/all; prove real HTTP, database concurrency, rollback, restart and redelivery behavior using the existing tiered harness.
- Correct the catalog's upstream-fingerprint-as-identity statement and record ADR 0024, restating ADR 0019 with fingerprint evidence in a namespaced extension while preserving stable canonical identities.

## Capabilities

### New Capabilities

- `source-ingress`: Source-scoped credentials, bounded HTTP admission, redaction and transport deduplication.
- `integration-alertmanager`: Webhook v4 field mapping, identity/time semantics and batch validation.
- `durable-pipeline`: Durable config pins, inbox processing, observation deduplication, failure evidence and atomic routed event commits.
- `output-delivery`: Immutable delivery intent, isolated at-least-once relays, attempts/dead letters and signed webhook output.

### Modified Capabilities

None. `canonical-event` supplies the event codec/identities unchanged; `process-roles` already assigns ingress and background subsystems to their roles.

## Impact

Server: `correlia_server/lib/server.dart`, runtime registry/adapter, new `lib/src/ingest/`, `lib/src/pipeline/`, `lib/src/output/`, model YAML, generated models, managed migrations and ordered `schema/` SQL. New integration documentation/config examples and `unit`, `db`, `e2e` tests reuse the embedded-Postgres harness. No NATS dependency or production external-plugin protocol is introduced. No Flutter/client-facing endpoints are added; generated client model changes follow normal generation.

## Decision Making

DECISION_MAKING: autonomous
Source: setting

### S1: Keep the roadmap boundary

- **Choice:** Deliver ingress, durable event/output processing and webhook-out here; alert state/freshness/activity/feed belongs to `alert-state-and-live-console`, external protocol/supervision/NATS to `output-nats-plugin`. Install no pretend state writer or no-op hook. This slice's DUR-1 test proves event/outbox rollback; the next change extends that same transaction and test to real alert state.
- **Rejected:** Fold the remaining M1 changes into this one; it obscures the independently checkable persistence boundary.
- **Reversal cost:** medium.
- **Important:** yes — binds future changes and changes visible behavior.
- **Chosen by:** agent.

### S2: Minimal real configuration, not the M2 rule system

- **Choice:** Immutable source/output snapshots with explicit output-id lists, startup publication and validation against their own registry. Keep matcher rules, enrichers, provisioning/UI, replay/reprocess, storage-budget policy and retention/partition maintenance in M2. Allocate the schema-step ownership and composite keys now so partitioning does not require a second table owner.
- **Rejected:** Mutable runtime settings or implementing the complete M2 rule/provisioning system now; the former breaks retry determinism, the latter exceeds this milestone slice.
- **Reversal cost:** medium.
- **Important:** yes — stored configuration contract and future-change boundary.
- **Chosen by:** agent.

### S3: Secret handling before admin authentication exists

- **Choice:** Source credentials persist only high-entropy token digests. Webhook signing keys live in a separate owner-readable secret file under versioned references; no plaintext signing key enters configuration rows, raw headers, events or logs. No public configuration/raw/failure API is added before access control exists.
- **Rejected:** Store recoverable credentials in ordinary config rows or expose a temporary unauthenticated setup endpoint; either creates a security debt in persisted data or a live access-control hole.
- **Reversal cost:** medium.
- **Important:** yes — security and operator-visible setup.
- **Chosen by:** agent.

## Release Notes

Establishes durable ingest schema ownership and clarifies upstream identity evidence.

### Added

- Forward-only SQL schema initialization after managed migrations, with composite-key inbox, event and outbox ownership and fresh/upgrade/failure coverage.
- ADR 0024 clarifies that upstream Alertmanager fingerprints are extension evidence, without changing canonical identity bytes.
- Bounded private bootstrap files, monotonic immutable snapshots, source-token rotation, historical signing-key commitments and retained-output admission limits.
