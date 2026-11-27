# Dead letters, backpressure and retention

## Why

Correlia already keeps failed raw work and delivery attempts, but operators cannot replay failures through an API or bound storage during an outage. This change advances the M2 ingest exit criteria for DUR-4, DUR-9, DUR-10, DUR-11, DUR-12 and DUR-13. The owner's day-long check with real sources stays at milestone close, where it can cover the complete M2 pipeline.

## What Changes

- List and replay pipeline failures and delivery dead letters through typed operator RPCs, individually or in bounded batches by filter. Pipeline replay pins the configuration active at replay time. Delivery replay reuses the original delivery bytes and identity.
- Reject new webhook work under inbox or storage pressure with 429 or 503 and `Retry-After`. Pause pull admission without shedding committed work.
- Enforce the combined count and byte budgets for each output's unfinished deliveries and dead letters. Apply `discard_new` or `block_ingest` as configured. Record discards and make overflow visible to operators and healthy outputs.
- Partition the raw inbox, canonical events and outbox by time. Drop expired partitions only when every row is eligible; otherwise delete eligible rows in bounded transactions. Expire dead letters to `discarded` with a ledger count before reclaiming their data.
- Document operator calls, limits and upgrade steps. Change 9 uses the same operator API and pressure signals for its demo. The console check for DUR-4 stays with the M4 system page.

## Capabilities

### New Capabilities

- `dead-letter-operations`: credential-scoped inspection, replay and audit of pipeline failures and delivery dead letters.

### Modified Capabilities

- `durable-pipeline`: preserve automatic retry pins and make failed raw work replayable and retention-aware.
- `source-ingress`: apply shared inbox, database and blocking-output admission limits without breaking transport retry semantics.
- `output-delivery`: apply output storage budgets, expose overflow and retain terminal delivery evidence by policy.

## Impact

The server changes webhook and pull admission, the raw worker, output writes and relays, and background maintenance. Correlia's schema steps migrate the three existing SQL-owned tables. Generated Serverpod clients gain operator methods. The new RPCs are off by default and return neither bodies, delivery payloads nor secrets. No Flutter page or stable `/api/v1/` endpoint ships in this change.

## Decision Making

DECISION_MAKING: important

Source: setting

| ID | Decision | Choice | Rejected | Reversal cost | Important | Chosen by |
|---|---|---|---|---|---|---|
| S1 | Operator access before M4 | Opt-in typed Serverpod RPC with a dedicated machine credential scoped to dead-letter operations. Replay records the credential identity. | Development-only RPC and a host-local production CLI. | Medium | yes: security boundary and operator contract | user |
| S2 | Partition scope | Partition `raw_inbox`, `events` and `outbox` under ADR 0016. Keep the 7-day delivered-outbox default. | Partition only raw and events and defer outbox partitioning. | High | yes: stored data format and upgrade | user |
| S3 | DUR-4 console scope | Prove listing and replay through the operator API for M2. Document the console check for M4. Change 9 uses the same API. | Add a read-only dead-letter console view now. | Low | yes: operator-visible scope | user |
