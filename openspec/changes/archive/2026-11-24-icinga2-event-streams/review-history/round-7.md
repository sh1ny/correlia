# Review

## Metadata

- **Round:** 5
- **Prior round:** round 6 REVISE (3 Critical, 6 Moderate), all answered in the revised artifacts
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-event-streams` proposal, FULL design and seven spec deltas; corresponding main specs and architecture index; ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029; current review rounds 1–6 and archived `icinga2-ingest` rounds 1–4; project rules and nine listed skills. Source: ingest admission, ingress, configuration repository, source model, bootstrap, startup and workers; secret commitments; pipeline; alert-state service, ordering key and transition; Icinga2 decoder, mapper, facts and webhook parser; runtime registry, output relay, console policy and endpoint; schema runner, inbox/outbox DDL, historical-secret fixtures and capture launcher. Read-only; no tests or captures run. Git index membership could not be independently verified with the available tools.

## Findings

### Critical (blocking)

1. **D2 leaves a stale reconcile observation’s reserved key behind, contrary to the durable-pipeline delta.** D2 deletes the reservation only when the reconcile observation “writes silently,” meaning confirm or tombstone. Its separate stale branch only refreshes freshness. The existing pipeline reserves the key before determining staleness (`pipeline.dart:445–500`); a literal implementation therefore leaves a key with no event. This can suppress a valid later copy: a sync result received at 10:00 with start 10:30 clamps to 10:05 and is stale against a 10:06 fence. Its stream copy received at 10:02 clamps to 10:07 and could pass the fence, but the leftover key sends it down the duplicate path. This does not require broadening D22 or D28: the delta already requires stale reconcile items to leave no key. Specify the disposition of every reservation and test the stale-sync → eligible-stream sequence against committed keys, state and outbox intents.

2. **D28 leaves display convergence false for explicitly shared namespaces.** Take an older HARD CRITICAL from webhook source W and a newer HARD CRITICAL from stream source S’s sync, for one service in a shared namespace. Both are eligible and unclamped; their starts differ. Process W → S: D2 silently advances the fence and preserves W’s `sourceInstance`. Process S → W: S creates the alert and stale W preserves S’s `sourceInstance`. The alert-state service projects the source instance into alert state (`alert_state_service.dart:21–35,220–227`), and `transition.dart:109–125` treats it as a visible display field. D1 scopes its latest-result promise to one source, but the modified `alert-state` convergence requirement and D28 still promise convergent display fields without that qualification. Either reconcile a changed projection as a visible change, or explicitly scope display convergence and document that the alert’s displayed source can differ from its fence’s source. Prove the chosen contract in both schedules.

### Moderate

1. **Round 6’s retirement lock fix does not preserve the counters that reactivation must continue.** D4 says a re-enabled UUID continues its generation; D12’s retention deletes the lease, status and resync rows after 30 days absent. A re-added UUID then starts at generation 1 and loses its previous connection and request sequences. D12 also says the sweep shares acquisition’s source → lease lock order, but D4’s acquire predicate checks only the lease row. Specify the source check and lock in acquisition, and retain the monotone counters or explicitly define a reset epoch and how late pipeline failures are handled. Test reactivation after pruning, not just reactivation racing the sweep.

2. **Round 6’s shutdown split treats database reachability as proof that lease release succeeded.** D13 allows the final writes to time out and the lease to expire. A reachable database can still have the lease row locked by the backend of a closing admission transaction—the exact cleanup whose duration D13 declines to guarantee. The revised `process-roles` scenario requires release whenever the database is reachable, and Event Streams’ “Stop while reading” has no qualification at all. Require consumer stop before pipeline stop; distinguish successful final writes from expiry on timeout or failure. Cover reachable-but-contended shutdown and carry this distinction into the shutdown documentation.

3. **The 60-second sync spacing and per-subscription sync promise need one rule across takeovers.** If A starts a sync and dies a second later, B can acquire after the 30-second lease expires and subscribe before the 60-second spacing expires. “After each successful subscription” and takeover say B starts a sync; the spacing requirement says it cannot start yet. The flapping scenario limits starts but does not specify what happens if the socket closes before a deferred sync can start. Make the last start authoritative across generations, define when a deferred sync runs or is cancelled, and test takeover inside the spacing window.

4. **The database connection budget counts sources but not standby workers.** D13 starts a consumer for every enabled source in every worker process and gives each consumer a dedicated connection. The resource table budgets 64 connections for 64 sources, but two workers can occupy 128 before Serverpod pools or shutdown connections, even though only 64 consumers hold leases. That can exhaust PostgreSQL connections and prevent the pipeline from draining the work the consumers are waiting on. Limit long-lived sessions to holders, or state and enforce a budget that includes contenders, worker replicas and pool headroom. The single-worker 64-source stop test does not cover this case.

5. **The test map does not prove the password contract on the real consumer path.** The e2e TLS entry covers trust, host matching, redirects and environment overrides. It does not map “Stream password and CA”: authentication failure with an echoed password, followed by inspection of API/status, durable rows and console and persistent logs. The database backfill cases cannot detect a transport exception that logs an upstream response body or authorization material. Map the echo case explicitly to e2e with both logging sinks enabled.

6. **D3 bounds the bad-object sample, not the diagnostics it emits.** D3 and D20 require logging every bad object. A schema mismatch across a 100,000-object installation can write 100,000 records per sync while retaining only 20 samples; the failure can recur on every interval. This moves growth from the inbox to logs. Bound per-sync logging to the sample plus aggregate counts, and assert the log bound as well as the stored sample.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

CHANGES_APPLIED: n/a

## Rebuttals

Round 6’s same-source fence schedule is now covered; D28’s remaining issue is shared-namespace display attribution, not the owner’s receipt-time exception. The snapshot-backed replacement for the outbox pass matches the production insert path, and D29 covers both early refusal and retry exhaustion. The split lost-ack cases, supervisor receipt cleanup, scoped lag language, database proof for committed keyed divergence and webhook identity distinction are present. Retirement fencing and shutdown still have the gaps above. No finding requires reversing D22’s equal-start exclusion or D24’s upstream queue exception.No finding is rebutted; each is fixed in round 8 (design.md, "This change's review round 7"). The owner chose
(2026-11-23) "Revise, round 8" and "Scope display" for C2 (D30). C1 and the Moderate findings are fixed by the
agent within the decisions already made.
