# Proposal

## Why

M1 (Walking skeleton) promises that an Alertmanager webhook updates alert state behind ordering fences
and appears live in a Flutter web alert list. After `alertmanager-ingest-pipeline`, accepted alerts
become canonical events and output intents, but no alert state exists. Nothing decides that an old
recovery must not clear a newer problem (legacy B1). Nothing records when an alert was last seen, and the
console is still the placeholder page. This change retires two of M1's riskiest assumptions: the
authoritative fenced state model and the lossless `(txid, id)` change feed (ADR 0017).

It advances these M1 exit criteria:
- **Named scenarios:** ORD-1, ORD-2, ORD-3, ORD-5 (c-f state effects), ID-7 (b, c) state effects, UI-3,
  and DUR-1 extended to state and activity rollback.
- **The clean-clone `mise run check` / all-tiers gate.**

The user-verified criterion is that the owner points a real Alertmanager at a dev instance and sees the
alerts in the console and on a NATS subscriber. It is judged at the milestone close, after
`output-nats-plugin`, because NATS output does not exist until then. This change's console half is
proven by automated widget and e2e tests, and adds no `[user]` task.

## What Changes

- **Authoritative alert state.** A new authoritative alert state per (tenant, fingerprint), written only
  by a state mutation service inside the pipeline's existing per-raw-row transaction. Each row holds:
  - firing/resolved status and severity, updated in place;
  - an ordering fence of (effective source time, observed time, event id);
  - a monotonic `last_observed_at`;
  - an entity version.
- **Stale observations.** An observation older than the fence is recorded `stale` and changes nothing
  (B1 in both directions). Ties are broken deterministically by observed time, then event id.
- **Duplicate observations.** A duplicate of an eligible observation now advances only the alert's
  `last_observed_at`. A duplicate of a late or quarantined one advances nothing.
- **Atomic processing outcome.** The outcome of a raw row now includes alert-state and activity effects.
  A failure anywhere rolls all of them back with the events and outbox rows (DUR-1).
- **Activity ledger.** An append-only activity ledger, created by Correlia's schema step, with a
  `txid xid8` column and a `bigserial` id. Every visible alert state change writes one row, in the same
  transaction as the change.
- **Change feed.** A lossless change feed over the ledger:
  - opaque `(txid, id)` cursors, read only below the `pg_snapshot_xmin` watermark;
  - a REPEATABLE READ snapshot-plus-watermark handover;
  - a `held_back` flag on feed pages;
  - a Serverpod stream that pushes only wake-ups, with a per-api-instance watermark poll so a
    transaction that writes no activity cannot strand a client (UI-3).
- **Live alert list.** The Flutter web console replaces its placeholder with a minimal live alert list.
  It loads a bounded snapshot, follows the feed on each wake-up and on a 10 s safety pull, applies
  changes by entity version, and resumes from its cursor after a reconnect.
- **Unauthenticated console API, development only.** The console's read API is available only in run
  modes `development` and `test`, only to loopback clients, and never in the `worker` role. There is
  no authentication until M4.

## Capabilities

### New Capabilities

- `alert-state`: authoritative per-fingerprint alert state, covering:
  - ordering fences, effective source time and stale classification;
  - in-place severity;
  - `last_observed_at`;
  - entity versions;
  - the single writer.
- `change-feed`: the append-only activity ledger and the lossless `(txid, id)` feed, covering:
  - watermark reads;
  - snapshot handover;
  - held-back signalling;
  - wake-up streams and their liveness.
- `operator-console`: the operator console's live alert list and the exposure rules of its unauthenticated
  development-only read API.

### Modified Capabilities

- `durable-pipeline`:
  - **Atomic raw processing outcome** now includes alert state and activity effects in the one atomic
    commit (DUR-1 extended).
  - **Durable observation deduplication and quarantine** now lets a duplicate of an eligible
    observation advance the alert's `last_observed_at`, and only that (ORD-5 c-f).

## Impact

- **Server (`correlia_server`):**
  - a new `lib/src/state/` with the pure fence and transition logic and the mutation service;
  - a new `lib/src/feed/` with the feed reader, the watermark poller and the endpoint;
  - the state hook in `lib/src/pipeline/pipeline.dart`, in the ready branch of `processOne`;
  - a managed `alerts` model and migration;
  - schema step `0002` for the SQL-owned `activity` table and an events column that records the state
    outcome;
  - the first Serverpod endpoint and the first streaming method.
- **Client (`correlia_client`):** the first client-visible models (alert row, feed page, snapshot,
  wake-up), generated.
- **Console (`correlia_flutter`):** the alert list screen, a feed-following controller and widget tests.
  No routing or state-management package is added.
- **Docs:** `docs/` notes on the feed contract and the development-only console exposure.
- **Unaffected:** no new external dependency; output delivery and NATS.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Alert state and feed only; incidents stay in M3

- **Choice:** Build the state mutation service for alert rows and the activity ledger only. The
  incident tables, group locks, correlation and thresholds stay in M3. The service keeps its lock order
  (alert rows in fingerprint order) and its result counts (applied, stale, late, duplicate) so that M3
  adds group locks in front without changing callers.
- **Rejected:** Creating empty incident tables or group-lock scaffolding now. It would be untestable
  without correlation rules, and M3 owns that design.
- **Reversal cost:** low.
- **Important:** yes (binds future changes: M3 extends this service).
- **Chosen by:** agent.

### S2: Stale observations are still routed to outputs

- **Choice:** A `stale` observation is a new, valid observation. It keeps its event and output intents
  as today, and only its state effect is suppressed. Output consumers already order by event time
  fields and deduplicate by event id (ADR 0018).
- **Rejected:** Suppressing outputs for stale observations. Outputs would then depend on processing
  order, and the output-delivery contract would change.
- **Reversal cost:** medium.
- **Important:** yes (changes behaviour users see on outputs).
- **Chosen by:** agent.

### S3: The console API is unauthenticated and development-only until M4

- **Choice:** The roadmap gives M1's console no authentication: dev mode only, bound to localhost. The
  read endpoints and the stream:
  - answer only in run modes `development` and `test`;
  - answer only for loopback peers;
  - are refused in the `worker` role.

  Any other mode or peer gets an authorization failure. The ingest webhook is unaffected.
- **Rejected:**
  - Pulling M4 authentication forward. It is a milestone of its own.
  - Exposing the API unauthenticated in every mode. Alert text can carry secrets (D11), and the
    console has no access control.
- **Reversal cost:** low (M4 replaces the guard with authentication).
- **Important:** yes (security; changes behaviour users see).
- **Chosen by:** agent.

### S4: Freshness pull (UI-4) and operator actions stay in M4

- **Choice:** The list shows `last_observed_at` as of the snapshot and of each feed refresh of a row. The
  bounded freshness pull (UI-4), acknowledgements and entity-version conflicts on actions belong to M4.
  The feed carries only visible state changes, never `last_observed_at`.
- **Rejected:** Building UI-4 now. Its scenario is scheduled for M4, and M1's outcome needs only the
  list.
- **Reversal cost:** low.
- **Important:** no.
- **Chosen by:** agent.

## Release Notes

Adds authoritative alert state and a live development console.

### Added

- Managed alert storage and an append-only activity ledger with atomic schema upgrades.
- Nanosecond-precision ordering fences and pure, versioned alert transitions.
- Atomic pipeline state mutations, stale classification and freshness-only duplicate handling.
- Lossless snapshot/feed handover, wake-up streams and loopback-only development read APIs.
- Live firing-alert console with filtering, selectable rows, source links, bounded reconciliation and reconnect recovery.
