# Proposal

## Why

M2 (Icinga2, Thanos and the ingest track) brings the owner's real sources in and retires the risk that real
Icinga2 behaviour (soft and hard states, flapping, acknowledgements, downtimes) does not fit the canonical event
and identity model. `icinga2-ingest` (done) brought Icinga2 in through a shipped notification command, but a
webhook-only source loses any state change whose notification fails or is suppressed, and it cannot see SOFT
recoveries, so it can leave an alert stale with nothing to repair it. This is change 3 of M2, split from
`icinga2-ingest` by the owner on 2026-11-19 after three design-review rounds found ordering and resource problems
in the consumer. Those rounds (`openspec/changes/archive/2026-11-23-icinga2-ingest/review-history/round-{1,2,3}.md`)
are this change's starting input: every finding in them is answered in `design.md`.

It advances these M2 exit criteria:

- "Golden fixtures for Icinga2 (webhook and Event Streams) … pass. Fixtures are captured from real releases"
  (agent): the Event Streams half, captured from the official Icinga 2 images the webhook capture already
  supports (2.13 to 2.16).
- "Scenarios … pass as named tests" (agent): no named scenario is new here, but ORD-1, ORD-2, ORD-3 and ID-7 (a)
  are re-proven through the stream, and the consumer's own invariants get named tests.
- The user-verified criterion (the owner's real Icinga2 and Alertmanager/Thanos feeding a dev instance for a day)
  is judged at the M2 close, because it also needs Thanos and enrichment. This change documents the Event
  Streams setup the owner uses for it.

## What Changes

- **Source mode.** An `icinga2` source gets a `mode`: `webhook` (the default, today's behaviour) or
  `event_streams`. A stream source has no inbound credentials, and its webhook route answers 401 like an
  unknown source. One source uses one path.
- **Event Streams consumer.** For each enabled stream source, one worker process holds a lease and opens
  `POST /v1/events` to the configured Icinga 2 API. It subscribes to a fixed, state-bearing type set:
  `StateChange`, `AcknowledgementSet`, `AcknowledgementCleared`, `DowntimeStarted`, `DowntimeRemoved` and
  `Flapping`. It does not consume `CheckResult` (S2). Lines are validated in the consumer, then admitted
  durably in bounded batches through a new consumer admission path. That path is fenced by the lease generation
  and the active configuration revision.
- **State sync.** After the stream is subscribed, the consumer reads the current state of every host and service
  (separate host and service projections) and admits it as reconcile observations. It re-syncs on every
  reconnect and periodically. A reconcile observation that agrees with the alert only confirms it (no event is
  published); one that disagrees repairs it and is published. A recovery for an object with no alert leaves a
  silent resolved tombstone that fences older problems.
  Tombstone cleanup honors the receipt times of pending work. A durable cutoff prevents new inserts of
  older receipts once it is safe to reclaim a fence, including from webhook sources.
- **One ordering rule for stream and sync.** Every Icinga2 stream or sync state observation takes its state,
  state type and source time from one check result (`vars_after` and `execution_start`). That is the order in
  which Icinga 2 itself accepts results, so all evidence of a source falls into one total order.
- **Soft/hard policy per source** (`state_type_policy`: `hard_only` by default, or `soft_and_hard`), for
  stream sources only. Under `hard_only` a SOFT problem is counted and not stored. The webhook keeps SOFT problems
  informational.
- **Bounded ingest** (S3): a per-source cap on pending and failed raw rows stops reading, a 30-second read stall
  or a sustained read lag (Icinga's event timestamps behind the clock) closes the connection, so Icinga drops its
  queue. A sync on reconnect then
  repairs state.
- **Consumer status.** A durable per-source status (state, last connect, last sync and its outcome, gap count,
  lag, last error class) is readable through the API, with idempotent gap counting across takeovers.
- **Secrets** (S4): an Icinga 2 `ApiUser` password, stored encrypted with a keyed commitment, and a required CA
  bundle. A password reference may not share bytes with any secret that has a bare SHA-256 commitment.
- **Golden fixtures** for every event type consumed and for the sync responses, captured from the official
  Icinga 2 images by extending the existing capture tooling, plus a version-matrix test.
- **Documentation**: an Event Streams setup section in `docs/ingest-pipeline.md` (the API user, permissions, CA,
  limits, and what a gap can lose), and an example `ApiUser` in `contrib/icinga2/`.

## Capabilities

### New Capabilities

- `icinga2-event-streams`: the Event Streams consumer and state sync. This covers the subscription, line
  validation and batching, the per-source lease and fenced admission, the backpressure and lag disconnect,
  reconnect and periodic sync, consumer status and gaps, stream and sync decoding and observation evidence, the
  soft/hard policy, and the stream fixtures and supported releases.

### Modified Capabilities

- `source-ingress`: the `icinga2` source `mode` and the stream connection settings in configuration format
  version 2; credentials and request budgets apply to webhook-mode sources only; a stream source's webhook route refuses deliveries; consumer admission as a second, credential-less
  way into `raw_inbox`.
- `secret-store`: password secrets with keyed commitments, and the rule against sharing bytes with a
  bare-commitment use.
- `alert-state`: reconcile observations (confirm without publication, repair with publication, silent
  tombstone) through the same fence; a silent write commits with its raw row.
- `durable-pipeline`: stream and sync rows decode by their stored format; reconcile observations are stored and
  routed only when they change the alert; late and future reconcile observations are counted, not stored.
- `process-roles`: the consumer runs in the worker role and stops within the shutdown deadline.

## Impact

- Server: new `correlia_server/lib/src/ingest/icinga2/stream/` (HTTP client, line reader, parsers, consumer,
  lease, status), changes in the source model and bootstrap parser, admission, pipeline routing, the alert-state
  service and the worker registry; one Serverpod migration (lease and status tables) and possibly one Correlia
  schema step. The stream client is built on `dart:io` with exclusive TLS trust.
- Configuration: new source fields (`mode`, `api` settings, `state_type_policy`); no change for existing
  webhook and Alertmanager sources.
- Outputs: stream sources publish the same event kinds as the webhook (`alert`, `state`, `ack`, `downtime`)
  under new observation-key domains; a reconcile repair is an ordinary published event.
- Tooling: the Icinga2 capture tool gains stream and sync scenarios; fixtures go under
  `test/unit/ingest/fixtures/icinga2/<release>/stream/`.
- Docs: `docs/ingest-pipeline.md`, `contrib/icinga2/`.
- No change to the canonical event format, to webhook or Alertmanager identity bytes, or to the console.

## Decision Making

DECISION_MAKING: important
- **Source:** setting

### S1: One ingest path per Icinga2 source

- **Choice:** An `icinga2` source has `mode: webhook` (default) or `mode: event_streams`. A stream source's
  webhook route refuses every delivery with 401, as for an unknown source.
- **Rejected:** Both paths on one source (each change would be published twice under different event ids,
  because the two paths carry different evidence); a new kind `icinga2_api` (kinds are immutable, so moving a
  source to the stream would need a new source UUID and namespace).
- **Reversal cost:** medium (configuration format).
- **Important:** yes, because it binds a configuration key.
- **Chosen by:** user (owner, 2026-11-23: "One path per source")

### S2: `CheckResult` events are not consumed

- **Choice:** The stream subscribes to `StateChange` and the acknowledgement, downtime and flapping types only.
  Silence is detected by connection health and periodic sync. The roadmap's `CheckResult` item is dropped
  for this reason.
- **Rejected:** Opt-in `CheckResult` as freshness only (more volume and tests for little gain); `CheckResult` as
  published observations (about 100 times the volume on outputs, and every change it shows is also a
  `StateChange`).
- **Reversal cost:** low (adding a subscribed type later is additive).
- **Important:** yes, because it changes behaviour users see and narrows the roadmap item.
- **Chosen by:** user (owner, 2026-11-23: "Not consumed")

### S3: The consumer bounds its own ingest now

- **Choice:** A per-source cap on pending raw rows stops reading, and a sustained read lag closes the
  connection; a sync on reconnect repairs state. Change 7's global ingest budget later becomes a further reason
  to pause.
- **Rejected:** Moving change 7 ahead of this one (reorders the roadmap for one trigger the consumer can
  provide itself); disconnecting on lag only (a stuck pipeline could grow `raw_inbox` until the lag trips).
- **Reversal cost:** low.
- **Important:** yes, because it is chosen ahead of the budget design it must later fit.
- **Chosen by:** user (owner, 2026-11-23: "Own bound now")

### S4: Password authentication with a pinned CA

- **Choice:** Correlia authenticates as an Icinga 2 `ApiUser` with a password, stored encrypted with a keyed
  commitment (ADR 0028), over TLS that trusts only a configured CA bundle. A password reference may not share
  bytes with any bare-commitment use.
- **Rejected:** Also supporting client certificates now (more secret types and capture work, no current need);
  certificates only (harder setup for the owner).
- **Reversal cost:** low (certificate auth can be added as another credential type).
- **Important:** yes, because it binds a configuration and secret contract.
- **Chosen by:** user (owner, 2026-11-23: "Password + pinned CA")

### S5: The soft/hard policy applies to stream sources only

- **Choice:** `state_type_policy` (`hard_only` default, `soft_and_hard`) is a stream-source option. The webhook
  keeps SOFT problems informational (`icinga2-ingest` S3), because Icinga 2 sends no notification when a SOFT
  problem recovers.
- **Rejected:** The policy on webhook sources (a SOFT problem sampled by a notification would fire forever).
- **Reversal cost:** low.
- **Important:** no. The roadmap already places the policy here, and `icinga2-ingest` S3 settled why the
  webhook cannot have it.
- **Chosen by:** agent
