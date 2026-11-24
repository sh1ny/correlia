# Review

## Metadata

- **Round:** 5
- **Prior round:** round 4 REVISE (5 Critical, 7 Moderate), all answered in the revised artifacts
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, FULL design, seven spec deltas, corresponding main specs, this change’s rounds 1–4, and archived `icinga2-ingest` rounds 1–4. Architecture, roadmap, ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029, project rules, and the nine listed skills. Source: cited admission, ingress, configuration, bootstrap, commitments, pipeline, alert state, Icinga2 decoder/parser/mapper/facts, workers, registry, relay and console code; also schema runner, raw-inbox DDL, startup, production database config, capture tooling and legacy-secret fixtures. Read-only; no tests or captures run. Git index membership was not independently verified.

## Findings

### Critical (blocking)

1. **D22 narrows convergence in one spec but leaves it mandatory in another, and its replacement diagnostic misses duplicates.** The modified `alert-state` “State converges in any processing order” still makes the unconditional promise that D22 removes. Worse, consider a stream OK that applies, then a distinct CRITICAL with the same projected start and a later receipt that wins the fence. If Icinga’s final result is the OK, its next sync reports the already-keyed OK. `pipeline.dart:445–495` sends that copy down the duplicate path; `alert_state_service.dart:166–195` only refreshes freshness there. D2 defines disagreement counting for stale, late and future items, not eligible duplicates. The alert can stay firing without the `diverged` signal D22 promises. Carry the exception into the authoritative convergence requirement and define disagreement counting for a keyed sync copy without letting it mutate state or republish. Test that precise schedule.

2. **The publisher trigger and inventory boundary are not serialized against an in-flight old publication.** The schema runner takes advisory lock `1129271885`; `_publish` takes `1129271884` (`schema_steps.dart:91–125`, `config_repository.dart:119–130`). D8/D23 do not require acquiring the publication lock before sampling the active revision. An old publisher can insert its snapshot, hold the transaction open while the schema step samples the preceding revision, then commit while trigger DDL waits for the table lock. The resulting snapshot is above the boundary, passed no trigger and wrote no reuse inventory. A bare digest that survives only in that snapshot is never backfilled. Make the boundary capture and trigger installation one transaction serialized with publication. Test a publisher already in flight at cutover, not just an old process that starts afterward.

3. **The reuse inventory does not enumerate all historical digest locations represented by tracked fixtures.** D8 calls out snapshot credential and webhook signing digests, but M1 snapshot sources use `token_digest`, not `credentials[*].digest` (`secret_store_e2e_test.dart:185–207`). Also, the legacy plugin test seeds a bare plugin commitment in the pinned snapshot’s `outputs[*].secret_refs[*].commitment`; its plugin outbox row has no signing commitment and the test clears `ingest_secret_commitment` before seeding (`fileless_worker_test.dart:120–124,160–203`). Scanning modern credential fields, signing fields and the outbox signing columns leaves those digests undiscovered. A first password can then be accepted despite an existing bare digest of its bytes. Name and test both historical shapes, including a plugin pin whose snapshot is the only surviving copy of the digest.

4. **The silent tombstone protects Correlia’s alert but not the downstream firing event the specs forbid.** Both “Recovery by sync before an older stream problem” and “Older problem after a silent tombstone” forbid a firing publication or intent when the sync OK wins first. D2 changes reconcile effects, not routing for a stale ordinary stream observation. The current pipeline stores an eligible stale observation with its state outcome, then routes it like any other ready observation (`pipeline.dart:500–616`). An output can therefore see a firing event even though Correlia never fired and the silent tombstone emitted no recovery. Define whether stale stream state is routed, and align the two scenarios, pipeline contract and ADR with that decision. Verify the committed outbox as well as the fence.

5. **D13 still treats socket-close delivery as a deadline for PostgreSQL rollback.** Restricting the topology addresses the proxy and partition part of round 4 C4, but direct TCP and Unix sockets do not make the one-second client check an upper bound on abort and lock release. A backend can be inside commit/WAL I/O when the client closes, or be delayed before it can process the disconnect and release locks. Closing at second four leaves no margin even for an on-time check followed by cleanup. The 30-second test statement only proves cleanup for that interruptible statement. Keep the local 10-second deadline; qualify backend release on the backend being able to process cancellation and finish cleanup. Keep the independent-connection measurement, but do not describe it as a topology-wide guarantee.

### Moderate

1. **Retirement can strand a sync that the interrupted-read fix never revisits.** D12 recovers a failed interruption write before the next sync or on takeover. If the database drops during cancellation and a publication removes the source before it returns, there need not be another holder. An open `reading` row has no `endedAt`, so the supervisor’s same-rules prune never makes it eligible. Finalize orphaned reads for retired sources once no live generation owns them, then apply the existing outstanding-row and retention checks. Test retirement during the outage, with no reconnect.

2. **The backfill has a bounded snapshot loop, not a bounded inventory procedure.** D8 defines a 500-snapshot cursor but no bounded scan or completion checkpoint for commitment rows, credential rows and outbox pins. Outbox history scales with deliveries, not revisions. A failure in that pass can leave the inventory perpetually pending or tempt an implementation to advance the revision mark before all inputs are durable. Specify bounded, resumable passes and one atomic completion condition. Extend the large-history case to retained pins and interruption between passes.

3. **Unknown-commit retry is not harmless for sync accounting or failed rows.** D5 and C2 say observation dedup absorbs the retry. It suppresses duplicate ordinary events, not duplicate raw rows: a committed bad line whose acknowledgement is lost can consume two failed slots and raise two resync requests; a duplicated sync batch can add the same objects twice to progress. Define `rowsAdmitted` and object-count semantics for this case, and state which effects may repeat. Add a committed-but-unacknowledged admission case to the database evidence map.

4. **The setup delta still tells operators to upgrade only workers.** D23 and C10 say all roles; “Event Streams setup documentation” says all workers before publishing. The trigger also does not keep old workers from claiming new stream rows: `_decoderFor` in `pipeline.dart:687–702` sends every Icinga2 row to the webhook decoder. State the all-role cutover and the no-old-worker rollback boundary in the setup requirement, and assert both in its documentation check.

5. **Several acceptance assertions are mapped below the layer that can prove them.** The fast ordering group cannot prove the reloaded fence, committed key omission across policy revisions, or the absence of an outbox intent after a tombstone. Map these assertions to database cases while keeping pure ordering permutations fast. Round 4 M3’s log assertion also has no log-surface test in the map: assert the fallback identifier and absence of the rejected name in captured log output, not just the stored sample. D24 requires a measured drain rate in the docs, but the load entry only measures whether one worst-case batch meets its deadline; add a sustained run with a defined measurement interval.

6. **The lag wording still promises more than D24’s narrowed contract.** With a large initial backlog and input matching drain, the first sample can establish a permanently high baseline, excess lag can stay below 60 seconds, and no read stall need occur. The consumer can remain behind indefinitely. “Backlog queued before the subscription’s first line” also does not stipulate how lag evolves, so its unconditional no-disconnect assertion is ambiguous. State the time bound only once a measured trigger persists, and give the initial-backlog test separate cases for constant and increasing excess lag. No upstream memory bound is needed.

7. **The carried-constraint ledger omits sync lifecycle rules that prevent the failures this round addresses.** Carry the `readEndAt IS NULL` recovery rule independently of phase to “An interrupted sync is closed before the next one”; a future phase-based cleanup would miss a failed-but-open read. Carry the condition that progress survives while admitted rows remain outstanding to “Sync counts survive late rows”; a later age-only prune would lose their committed counts. Each needs one destination.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

CHANGES_APPLIED: n/a

## Rebuttals

D22’s equal-start exclusion and D24’s upstream memory exception stand. The blockers concern conflicting contracts and missing visibility, not those owner decisions. Round 4’s trigger, interrupted-read marker, topology distinction, sync spacing, diagnostic identifier bound, scoped webhook requirement, exact time text and carried entries are present. The cutover race, retirement path, backend cleanup promise and evidence gaps above remain.

The earlier source and generation admission fences, per-item receipt-time representation, default-mode snapshot compatibility, late-copy and policy-skip key exclusions, key-before-alert lock order, and bad-sync-object isolation remain intact.No finding is rebutted; each is fixed in round 6 (design.md, "This change's review round 5"). The owner chose
(2026-11-23) "Revise, round 6", "Store, don't route" for C4 (D25), "Take publication lock" for C2 (D26) and
"Idempotent admission" for M3 (D27). C1, C3, C5 and M1, M2, M4-M7 are fixed by the agent within the decisions
already made.
