# 0027. Plugin intent byte-limit admission

- Status: accepted (2026-11-12)
- Date: 2026-11-12
- Supersedes: none (refines [0025](0025-plugin-protocol-v1-output-contract-and-supervision.md) D4)
- Chosen by: user (oversized-intent policy approved 2026-11-12)

## Context

ADR 0025 D4 bounds plugin batches and records an attempt for each intent admitted to transport. A plugin may negotiate a batch byte limit smaller than a retained event. Such an event cannot fit any batch for that instance. Leaving it at the queue head would prevent later fitting work from progressing.

Accepted ADR 0025 remains immutable. This refinement distinguishes admission-time rejection from a transport attempt; its other queue, lease, deadline and completion decisions remain in force.

## Decision

Before transport, plugin acquisition compares each candidate payload's byte length with the smaller of the host and negotiated plugin batch byte limits. An individually oversized intent becomes retained `dead` work with reason `payload_too_large`. Its exact payload and prior attempt count remain unchanged, and the rejection creates no delivery-attempt record or transport attempt. Existing attempt history is retained.

The rejection belongs to the same bounded claim transaction as fitting candidates. It shares the acquisition deadline and the final generation-checked readiness-permit fence. Readiness loss or expiry before commit rolls back the terminal update as well as any claimed rows. A transaction containing only oversized rejections still commits those rejections without returning a transport batch.

An oversized candidate does not block later fitting candidates. A candidate that individually fits but would overflow the current batch's aggregate byte budget remains queued for a later batch; it is not rejected for that aggregate overflow.

These terminal rows are not automatically replayed. Admission-time dead letters can therefore have zero attempts; future counters and replay/retention work must not infer that every dead letter was transported.

## Alternatives and reversal cost

Rejected: exceeding the negotiated byte limit, which violates the plugin contract; or leaving an unsendable oldest intent queued indefinitely, which stalls its definition. Reversal cost is medium: changing the terminal policy changes retained-work semantics and requires an explicit replay decision for already rejected intents.

## Consequences

The host enforces negotiated limits without spending transport attempts or sacrificing the progress of fitting work. Operators retain the rejected bytes and reason. The distinction between an admission rejection and an attempted delivery remains visible in the durable outbox and attempt ledger.
