# 0005. Durable staged pipeline on PostgreSQL with transactional outboxes

- Status: proposed
- Date: 2026-11-03
- Supersedes: none

## Context

The legacy service processed each webhook synchronously and delivered notifications as in-memory asyncio
tasks. That caused several problems (legacy audit 6, 7.1, 7.5; lesson P0.3):
- no retry;
- no visibility into the backlog;
- work lost on restart;
- metrics that counted work which later rolled back.

The rebuild adds outputs (NATS, webhooks, chat, ticketing). They must not lose events, and they must not
block ingest.

## Decision

Stages: **ingest → raw inbox → decode → normalize → enrich → classify → route → (alert state + correlation)
and (outbox → outputs)**.

### Processing
- **Ingest:**
  - Ingest authenticates the source, writes the raw body to `raw_inbox` with `state = pending`, and
    returns 202.
  - Request headers are not stored, apart from a per-source allowlist. Credentials are never stored
    (ADR 0009).
  - Pull sources write to the same inbox.
  - Exact transport retries are deduplicated at the inbox (ADR 0012).
- **Claims:**
  - Workers claim inbox rows with `FOR UPDATE SKIP LOCKED`.
  - Events for one fingerprint are processed in source order: a fingerprint maps to one of N lanes, and a
    lane is claimed by one worker at a time.
  - There is no global order. Concurrency across fingerprints is handled by the incident mutation protocol
    (ADR 0007), not by lanes.
- **Config pinning:**
  - When a raw row is first claimed, it records the active configuration version (ADR 0008).
  - A retry after a crash or a transient failure reuses that pinned version, so a retry is deterministic.
- **One transaction per batch:** the transaction that commits processed events also commits:
  - the alert-state changes;
  - the correlation results;
  - one outbox row per routed output;
  - notification intents;
  - `raw_inbox.state = done`.
- **Relays:**
  - Each output has its own relay, attempt records and dead-letter state.
  - Relays claim outbox rows by status with `SKIP LOCKED`, never by an id cursor.
  - Delivery is at-least-once. Event ids are deterministic (ADR 0012), so consumers can dedupe; NATS uses
    them as `Nats-Msg-Id`.
- **Failures:**
  - A decode or normalize failure marks the raw row `failed` and writes a `pipeline_failures` row. Raw row
  states: `pending`, `processing`, `done`, `failed`, `discarded` (terminal: `done`, `discarded`).
  - That row points to the raw row, the pinned config version and the error class.
  - Enrichment failures are soft: they are recorded on the event (`pipeline.enrichment_errors`).

### Retention never deletes unfinished work
- **Eligibility:**
  - Only rows in a terminal state can expire: raw rows `done`, outbox rows `delivered`, and events not
    referenced by any pending or dead-lettered outbox row.
  - A raw row that is `pending`, `processing` or `failed`, or that is referenced by a pipeline failure, is
    never deleted by retention.
- **Partitions:**
  - Time partitions are dropped only when they hold no ineligible row.
  - Otherwise the retention job deletes the eligible rows and keeps the partition.
- **Dead letters:**
  - Pipeline failures and dead-lettered deliveries have their own retention (default 14 days, configurable).
  - A dead letter keeps its referenced raw row or event alive until it expires.
  - Expiry is one transaction: the dead letter is removed, the raw row (or outbox row) moves to the terminal
    state `discarded`, and the activity ledger records the discard with a count. `discarded` rows are
    retention-eligible like `done` rows. It is a visible, policy-driven discard, never a silent one.

### Storage budgets and backpressure
- **Ingest budget:**
  - Ingest has a budget: pending inbox age and count (defaults 30 s / 50k rows) plus a database-size
    watermark (default 85 % of the configured disk budget).
  - Above it, webhooks get 429/503 with `Retry-After`, and pull sources pause.
  - Accepted work is never dropped to make room.
- **Output budget:**
  - Each output has one storage budget covering its pending **and** dead-lettered rows together, by count
    and bytes (defaults 500k rows / 1 GiB).
  - At the budget the output is `overflowing`, and its **overflow policy** applies:
    - `discard_new` (default): new deliveries for that output are not stored. They are counted per
      interval and the count is written to the activity ledger. Ingest, correlation and other outputs carry
      on.
    - `block_ingest` (opt-in, for outputs that must never miss anything): ingest backpressure starts, as at
      the ingest budget.
  - Overflow raises a Correlia self-alert, routed to the other outputs.
  - Output isolation is guaranteed within the budget. Beyond it, the policy decides, and the outcome is
    always recorded.

### Replay and reprocessing are different operations
- **Delivery replay:** re-sends existing outbox payloads byte for byte, with the same ids. It never touches
  alert or incident state.
- **Pipeline replay** of a failed raw row: processes it with its pinned config version, as if for the first
  time. It may change state, subject to alert ordering (ADR 0007).
- **Reprocess:** runs stored raw rows through the current config.
  - By default it is a dry run (simulator output only).
  - "Apply" is an explicit admin action. It emits events with a new `pipeline.generation` and a
    `reprocessed_from` link. Their ids include the generation (ADR 0012).
  - Their state effects go through normal ordering, so a reprocessed old event can never override newer
    state.
  - Notifications triggered by applied reprocessing are marked as reprocess-originated, and policies may
    suppress them (the default is to suppress).

Rejected:
- Synchronous processing in the webhook request (legacy).
- A NATS/JetStream backbone between stages: a hard dependency, and two sources of truth.

Reversal cost: medium.

## Consequences

- Postgres is the durability spine. Partitioning and retention are part of M2, not deferred hardening.
- Counters distinguish received, deduplicated, duplicate observations, committed, routed, attempted,
  delivered, dead-lettered, overflow-discarded and expired.
- End-to-end latency is ingest-to-commit plus relay pickup. LISTEN/NOTIFY wakes relays to keep it low.
- Long transactions hold back retention and the change feed (ADR 0007). Pipeline transactions have a
  statement and transaction timeout.
