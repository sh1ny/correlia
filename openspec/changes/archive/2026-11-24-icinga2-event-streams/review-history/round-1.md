# Review

## Metadata

- **Round:** 1
- **Prior round:** none
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-event-streams` proposal, FULL design and six spec deltas; main `source-ingress`, `secret-store`, `alert-state`, `durable-pipeline`, `process-roles` and `integration-icinga2` specs; architecture, M2 roadmap, ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029; archived `icinga2-ingest` rounds 1–4; project rules and the nine listed skills. Source: `admission.dart`, `ingress.dart`, `config_repository.dart`, `source_config.dart`, `bootstrap.dart`, `commitments.dart`, `pipeline.dart`, `ordering_key.dart`, `transition.dart`, the four existing Icinga2 ingest files, `ingest_workers.dart`, `registry.dart`, `output_relay.dart`, `console_access_policy.dart`, `alert_console_endpoint.dart` and `tool/icinga2_capture.sh`. Read-only; no tests or captures run. No shell tool was available to confirm tracked status with `git ls-files`.

## Findings

### Critical (blocking)

1. **D2 drops the fence needed to stop a missed recovery from resurrecting an alert.** On fresh Correlia state, process a sync OK at start 10:02 and a delayed stream CRITICAL at 10:01. OK first creates no alert or fence, so CRITICAL fires. CRITICAL first creates an alert, so the same OK resolves it. Both observations are eligible, unclamped and distinct; only processing order changed. `transition.dart:93–121` and the baseline “First observation is a recovery” scenario show why the resolved tombstone exists. Keep an authoritative fence for this case without publishing an event, or revise the convergence contract. Test both orders on an empty database; the existing six-order case ends in a newer WARNING and masks this defect.

2. **D10 repeats archived round 4 Critical 5.** Two admitted copies of one SOFT CRITICAL can pin on opposite sides of a policy publication, including when D5 retries a batch with an unknown commit outcome. The key has no policy dimension. `pipeline.dart:445–495` reserves the event ID before applying state; `transition.dart:93` ignores `info`. If `hard_only` wins, the stored event is informational and `soft_and_hard` cannot fire it; if `soft_and_hard` wins, the alert fires. D12’s claim that a shared key means the change already applied is likewise false for an informational delivery. Define policy ownership for one observation across revisions and test both commit orders, including the event, alert and subsequent sync.

3. **D1 does not preserve Icinga’s acceptance order across the supported fence.** With Correlia receipt times 10:02 for CRITICAL and 10:01 for OK, and Icinga starts 10:30 and 10:31 respectively, the existing clamp makes their effective times 10:07 and 10:06. The newer OK loses in either processing order. `ordering_key.dart:18–51` establishes this, and `integration-icinga2` already tests the analogous webhook limitation. Equal starts also do not establish acceptance order; receipt order is explicitly not guaranteed before 2.15. A sync whose last result is still beyond seven days is ineligible on every retry. Replace the unconditional latest-state guarantee with precise, tested conditions, or change the fence with an explicit ADR decision. A recent recheck in the nine-day scenario does not cover a passive service that never reported again.

4. **D1’s timestamp conversion can change published identity bytes within its accepted range.** The proposed `(x * 1e6).round()` does not recover every six-digit microsecond value below `2^33`. For example, the nearest binary64 value to `4294967296.000011` is the base plus approximately 11.4441 µs; multiplication rounds to `4294967296000011.5`, then `.round()` yields `4294967296000012`. One contemporary vector cannot validate the stated domain. Context and D1 also claim capture confirmation that A1 says has not happened. Before freezing D1/D11, prove the conversion and upstream serialization over the actual supported domain, with boundary vectors, and require at least one qualifying release to pass the real consumer path. Otherwise the release exclusion rule allows the change to ship with no working release.

5. **D6 cannot isolate the invalid inputs it promises to retain, and its batch arithmetic uses the wrong bytes.** D5 stores JSON values, so malformed JSON or invalid UTF-8 has no representation in `items`; converting duplicate-member JSON to a map can also erase the defect before pipeline validation. The webhook parser explicitly guards against that loss. A valid 300 KiB line or sync object fits its item limit but cannot fit any 256 KiB row. Conversely, `pipeline.dart:547–555` caps serialized canonical events multiplied by fanout, not raw input; even small input items can expand. The cited code also gives no basis for “100 items fit 10 s.” Define a bounded stored representation and disposition for every size/validation class, including malformed sync objects beside a valid recovery. Test exact encoded row bounds and worst-case normalized fanout rather than multiplying the raw cap.

6. **D7 leaves both storage pressure and upstream stalls without a sufficient bound.** `_fail` changes a row to `failed` without deleting its body (`pipeline.dart:704–738`); successful `done` rows also leave the pending count. A persistent format mismatch can keep pending near zero while failed rows accumulate, and D12’s triggered syncs can add more. This repeats round 2 Critical 4 and does not meet ADR 0016’s storage backpressure contract. The reader also measures lag only when it consumes lines: a stall in flush or a sync that stops stream reads produces no samples, and a newly connected reader can establish its baseline from already queued events. Specify a retained-work or storage bound and a watchdog independent of event receipts; test a blocked flush below the pending cap, an overloaded initial sync and sustained failures.

7. **D13 does not enforce either shutdown deadline or rollback.** Two-second per-statement limits plus a five-second idle limit do not cap the entire transaction, pool acquisition, or commit acknowledgement. Closing `HttpClient` does not cancel PostgreSQL work. D13 then waits for admission, status and lease release without assigning the latter two a deadline. It also permits an in-flight transaction to commit, while “Stop during an insert” requires that nothing commits. Specify an end-to-end cancellation/drain contract for every DB operation and distinguish a completed commit from an aborted transaction. Prove lock release with an independent connection, including active SQL and pool wait, not just a paused transaction.

8. **D4/D5/D12 do not define a coherent lease and status lifecycle.** A paused holder cannot close its old socket when its lease expires, so takeover cannot guarantee “at most one process runs” or one open upstream connection; the database fence only guarantees one authorized writer. Renewal checks holder and generation but not expiry, so an expired holder can renew before takeover without acquiring a new generation. There is also no acquisition path for a source with no lease row. Separately, the spec requires enabled/current-revision checks on every status write but requires the stale holder to set `stopped` after source removal, when that check necessarily fails. Define initialization, renewal after expiry, retirement and terminal-status authority; separate the connection and durable-writer guarantees. Exercise a paused holder, a quiet removed source and a rotation while a reader is between batches.

9. **D12 cannot substantiate `complete` for the entire sync or its five-minute recovery guarantee.** Counting `pending` and `failed` bodies does not distinguish “all rows done” from “none pending yet while enumeration is still open,” “a response failed after a partial admission,” or “a row was discarded later.” One status slot also has no rule for a new sync starting while the preceding sync is still applying. D3 itself allows enumeration to run for 15 minutes; D12 promises a new sync within five minutes but defines neither preemption nor scheduling when one is already active. `pipeline.dart:740–816` also shows that several transient failures never consume the five-attempt budget. Define one completion owner, an admission-closed boundary and the outcome of each admitted row, and specify which retries and deadlines apply during an in-progress sync or outage. Test truncated responses after a valid prefix, failure during an active sync, and takeover mid-sync. Reject upstream per-object errors explicitly; a 200 response in 2.16 does not prove that every requested object was read.

### Moderate

1. **D8’s reverse reuse check does not define what survives removal or rotation.** Publish password P, remove or rotate it, then introduce the same bytes under a bare-commitment use. Checking only the current stream passwords passes that publication, despite the requirement’s “whichever … was published first.” `config_repository.dart:186–200,314–409` also shows that a reference’s record or commitment row can represent the keyed scheme while a snapshot or outbox pin carries a bare one. Define the lifetime and authoritative inventory on both sides, including candidates in the same publication. Test removed or rotated passwords and a bare historical pin whose reference also has a keyed record. Reconcile “resolved only by the consumer” with publication’s need to validate stored material.

2. **D12’s gap update is not an exactly-once ledger.** `lastGapConnectionId IS DISTINCT FROM $c` deduplicates repetitions only until another ID is recorded. If a connection opens before its ID is durably recorded and the process dies, takeover has nothing to count; conversely, a late retry for an older ID can increment again after a newer gap. Two oversize lines on one live connection also conflict with counting each oversize line but deduplicating by connection. Define when a gap becomes representable, whether it counts connections or loss episodes, and which writer can advance it. Test the open-to-status crash window and repeated oversize lines on one connection.

3. **The status API has an unstated operational limit.** `console_access_policy.dart:9–19` excludes production, staging, non-loopback requests and worker-only roles. The delta promises status “readable through the API” and D12 chooses the endpoint over SQL/logs, but the endpoint cannot answer production operators. Specify the intended access explicitly and identify the supported production diagnostic path. Move “Owner sets up the stream” into the real-release capture test for permission and first-sync status; the owner’s day-long real installation exercise remains separate. No scenario-to-task map is present to show this separation.

4. **The design has not obtained or recorded required owner decisions.** D5, D9 and D10 say both `Important: yes` and `Chosen by: agent`, without an owner hand-back. S5’s approval of policy scope does not decide D10’s cross-revision dedup semantics. These decisions fix stored bytes, published event IDs or alert behavior. Resolve the substantive choices with the owner before recording them as decided. Also reconcile the roadmap’s still-listed `CheckResult` subscription with S2 before using the roadmap as an acceptance checklist.

5. **The baseline deltas leave incompatible contracts in force.** `source-ingress` still requires every source to hold credentials and have a request-rate budget. `durable-pipeline` still unconditionally retains late evidence and future quarantine events; the new delta forbids late reconcile events and does not define future reconcile storage. The alert-state baseline requires a state write to be in a transaction that commits its event, whereas confirmation intentionally writes no event. Amend the affected requirements, not just adjacent additions, and state which counters are disjoint: a stale, differing object is currently both `stale` and `diverged`, so the mixed-row sum cannot hold as written.

6. **The sync object identity and raw provenance contracts are incomplete.** D3 requests `name` and `host_name` but never specifies how a service query’s object name becomes the same short service identity used on the stream and webhook. The existing mapper hashes the complete host/service values (`mapper.dart:113–118`); using different name forms makes a sync repair a different alert. D5 also gives one raw row multiple items but no per-item receipt evidence; the current decoder gets one `observedAt` from the raw row (`pipeline.dart:385–407`). Define service-name extraction and receipt time across batching and unknown-outcome retry. Verify one real service through both stream and sync gives the same fingerprint, event ID and expected fence ordering.

7. **Several source claims do not support the design decisions as cited.** The `config_repository.dart:286–300` range is `_validateCommitments`, not secret reference enumeration; current discovery is in `bootstrap.dart:338–370` and import in `config_repository.dart:314–409`. The 64-source cap and eight-route cap are implemented in `bootstrap.dart:310–313` and `source_config.dart:310–314` but uncited in the bounds argument. The cited registry range shows registration; `ingest_workers.dart:42` establishes role filtering. D8’s timeout and CA/socket behavior remain assumptions until demonstrated with the actual client path; add a hostname-mismatch case alongside the trust-root case. Correct the evidence links and separate current behavior, design choices and unverified assumptions so the implementation does not reuse the wrong boundary.

8. **Carried constraints omit decisions that a later change can break without noticing.** C1–C5 do not carry immutable mode across disable/re-enable, exclusive CA/no proxy/no redirects, the historical bare-commitment exclusion, or the deliberate choice not to resolve absent objects. C2 also omits the no-transport-key exception to ADR 0016. Give each omitted constraint exactly one destination. Record the deployment compatibility boundary too: the current `_decoderFor` sends every Icinga2 row to the webhook decoder (`pipeline.dart:687–702`), so a pre-change worker left running can fail new stream rows.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

CHANGES_APPLIED: n/a

## Rebuttals

All findings fixed in the round 2 artifacts (design.md "Review findings answered", this change's round 1 table):

- C1 fixed: D2 silent tombstone (owner, 2026-11-23); alert-state "Reconcile observations confirm or repair", scenarios "Recovered object with no alert", "Older problem after a silent tombstone"; icinga2-event-streams "Recovery by sync before an older stream problem, on an empty database".
- C2 fixed: D10 counted, not stored (owner, 2026-11-23); scenario "Copies of one result under two policies".
- C3 fixed: D1 limits; requirement "Ordering holds within the clock and lateness limits"; scenario "Passive service not reported for nine days".
- C4 fixed: D17 shortest round-trip text (owner, 2026-11-23); boundary vectors; D16 real consumer run, one qualifying release required; Context no longer claims capture confirmation.
- C5 fixed: D5 lines stored as read with receipt time (owner, 2026-11-23); D6 encoded and fanout bounds, load-tier test.
- C6 fixed: D7 pending + failed cap and 30 s stall timer; "Retained work is bounded".
- C7 fixed: D13 own-backend termination at 4 s, pool and statement bounds; stop scenarios rewritten.
- C8 fixed: D4 create, no renew after expiry, local deadline, retire; "Fenced status writes".
- C9 fixed: D12 completion rules; D3 response errors; "One sync at a time", "Sync completion means applied".
- M1 fixed: D8 reuse digest table; secret-store "Reuse digests are kept for every published secret".
- M2 fixed: D12 gap table; "Gaps counted once per connection" scenarios.
- M3 fixed: D12 endpoint scope; "Consumer status" production scenario; real consumer run moved to the supported-releases requirement.
- M4 fixed: D5, D9, D10, D17 put to the owner; roadmap line in tasks.
- M5 fixed: MODIFIED source-ingress, durable-pipeline, alert-state requirements; disjoint row counters.
- M6 fixed: D3 short names + capture identity test; D5 per-item receipt time; durable-pipeline "Items received at different times".
- M7 fixed: Context citations corrected; PostgreSQL version as A4.
- M8 fixed: C6-C10 added, C2 extended.
