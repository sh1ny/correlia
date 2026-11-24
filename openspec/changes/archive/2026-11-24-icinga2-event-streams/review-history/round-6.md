# Review

## Metadata

- **Round:** 5
- **Prior round:** round 5 REVISE (5 Critical, 7 Moderate), all answered in the revised artifacts
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, FULL design, seven spec deltas, corresponding main specs, architecture ADR index, ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029, current review rounds 1–5, archived `icinga2-ingest` rounds 1–4, project rules, and the nine listed skills. Source: admission, ingress, configuration repository, source model, bootstrap and startup, commitments, pipeline, alert-state service and ordering, Icinga2 parser/mapper/facts/decoder, workers, registry, relay, console policy and endpoint, schema runner and inbox/outbox DDL, capture launcher, and historical-secret fixtures. Read-only; no tests or captures run. Git index membership was not independently verified.

## Findings

### Critical (blocking)

1. **D22’s equal-start exception does not cover a fence divergence at distinct starts.** Take two eligible, unclamped HARD CRITICAL results from one source: A starts at 10:00; B starts at 10:01. B’s sync copy is received at 10:02 and its delayed stream copy at 10:03. Process B-sync → B-stream → A: B-sync creates the firing alert and keeps its key, B-stream is a duplicate, and the fence retains B’s 10:02 receipt. Process A → B-sync → B-stream: B-sync confirms silently and deletes its key, so B-stream can reserve it and advance the fence to 10:03. In both schedules the same copy of B is processed first. The revised `alert-state` requirement still promises the same final fence, and its duplicate rule says the first delivery supplies the evidence. D2’s key deletion and `ordering_key.dart:43–51` produce the opposite result. Prove this schedule against committed fences and either preserve the promised evidence or explicitly scope the fence guarantee without weakening D1’s latest-state guarantee.

2. **D8’s outbox pass requires a cursor the deployed table does not have.** D26 correctly serializes the publisher and cutover, but D8 records the highest outbox `id` and resumes in `id` order. `schema/0001_ingest.sql:30–50` defines the outbox key as `(created_at, delivery_id)`; `pipeline.dart:565–616` supplies the timestamp from a worker clock and the delivery ID as a random UUID. There is no insertion-order `id`, and the publication lock does not freeze outbox insertion. As written, the step cannot take the promised boundary or complete the required pass; silently dropping the pass would violate the secret-store contract. Define an indexed cursor using the actual schema and prove why every relevant pin is covered across backfill interruption and concurrent outbox writes, or specify the migration needed for the proposed cursor.

3. **Sync failure accounting has no defined path for rows rejected before decoding.** The delta explicitly permits a row to pin after its source is removed and fail `source_not_configured`. `pipeline.dart:339–355` takes that exit before selecting a decoder, and `_recordError` can also call `_fail` without a decoded batch (`:740–785`). D5 puts `origin` and `syncId` only inside the body; D12 requires every failure to update the right sync or raise the stream resync number. No flow gives those early exits and the retry-exhaustion transaction authoritative access to that metadata. A sync row admitted before removal can therefore become terminal while its progress still reports it outstanding, blocking completion or retention; sending it to the stream failure path would also raise a spurious resync request. Define how failure handling obtains trusted admission metadata independently of pinned-source lookup and item decoding. Prove both early refusal and retry exhaustion with committed raw, progress and resync records.

### Moderate

1. **Retired-source maintenance is not fenced against reactivation, and can leave false status when no holder returns.** D12 gives the supervisor permission to close and prune after checking retirement and lease expiry, but specifies no transaction or lock order for that check. Publication can re-enable the UUID and a new holder can acquire it between the check and cleanup; cleanup can then fail the new sync or remove live lease and status state. Conversely, if the source stays retired after a database outage, the supervisor closes the sync but no holder is authorized to clear an old `connected` status or account for its final gap. Define the supervisor’s conditional writes under the source and lease locks, and what status readers see when no holder returns. Extend the outage test with a concurrent re-enable case.

2. **D27’s receipt retention and lost-acknowledgement test do not match the admission protocol.** D5 assigns one `origin` per raw row and D6 isolates each bad stream line. The lost-ack scenario instead puts an invalid stream line and sync objects in one batch and refers to the sync’s failed-row count. Use separate origin-correct cases: verify one failed raw row and one resync increment for the stream batch, and one `rowsAdmitted` increment for the sync batch. Also, the holder is the only named pruner of `icinga2_admitted_batch`, and the retirement sweep omits it. A removed or permanently disabled source can leave its final hour of receipts forever. Give expired receipts a bounded cleanup path that does not require a holder, and carry that retry/retention boundary to one destination.

3. **Round 5’s lag correction did not reach the residual-risk requirement.** “Sustained read lag closes the connection” now correctly allows an indefinitely behind consumer when excess lag stays below the threshold. The adjacent “Icinga 2’s own queue is not bounded by Correlia” still says the rules *shall* limit how long any consumer that falls behind stays connected; D7, D24 and the bounds table repeat that claim. The constant-excess scenario disproves it. Scope the duration bound everywhere to a measured trigger that persists. Also, the scenario’s claim that the consumer “pauses only at the retained-work cap” excludes the insert and in-flight-slot pauses explicitly allowed by D7.

4. **The shutdown delta still promises lease release where D13 explicitly allows expiry.** `process-roles` “Shutdown order” requires a connected consumer to release its lease before pipeline shutdown. D13 skips final writes when it cannot reach the database, and the Event Streams outage scenario requires local stop within 10 seconds followed by natural expiry. A connected worker receiving SIGTERM during a database outage cannot satisfy both. Require consumer stop before pipeline stop, and distinguish successful lease release from expiry on an unreachable database in the role-level assertion.

5. **The committed keyed-divergence scenario is still mapped only to the fast tier.** “Keyed sync copy of the losing result” asserts a durable duplicate classification, unchanged persisted version, no event or outbox intent, and a committed `diverged` increment. The fast map names keyed divergence; the database row covers fence reload and stale/tombstone outbox suppression, not this duplicate path. An in-memory test passes even if `pipeline.dart`’s duplicate branch bypasses sync accounting. Map the full scenario to a database test; keep the pure ordering permutations fast.

6. **D3’s identity citation conflates fingerprint and event ID across the webhook boundary.** D3 names stream, sync and webhook, then says the real-service capture proves the same fingerprint and event ID “through both.” `mapper.dart:108–118` supports shared identity fields, but `:15–28` gives the webhook a different observation-key domain from D1, and ADR 0021 includes the source instance in event identity. Specify that stream and sync from the same source share an event ID; a webhook in an explicitly shared namespace shares only the fingerprint. Otherwise the capture can be read as requiring an identity change that S1 and the proposal reject.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

CHANGES_APPLIED: n/a

## Rebuttals

Round 5’s publisher-lock handshake, historical digest field coverage, stale-stream routing rule, local-stop versus backend-cleanup distinction, all-role upgrade instructions, captured-log assertion, and sustained drain-rate measurement are present. The keyed duplicate now has a `diverged` rule, and the retired-read and lost-acknowledgement cases have mechanisms. The findings identify remaining gaps in those mechanisms, their evidence, or the merged contracts. They do not require reversing D22’s equal-start exclusion or D24’s upstream-memory exception.No finding is rebutted; each is fixed in round 7 (design.md, "This change's review round 6"). The owner chose
(2026-11-23) "Revise, round 7", "Scope the fence" for C1 (D28) and "Side table by raw id" for C3 (D29). C2 is
answered by the agent: outbox pins are copies of their retained snapshots' commitments, so the outbox pass is
dropped (C29) with a containment test. The Moderate findings are fixed by the agent within the decisions
already made.
