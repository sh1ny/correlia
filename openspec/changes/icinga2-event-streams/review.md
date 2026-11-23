# Review

## Metadata

- **Round:** 5
- **Prior round:** round 7 REVISE (2 Critical, 6 Moderate), all answered in the revised artifacts
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, FULL design, seven spec deltas and corresponding main specs; architecture index and ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029; current review rounds 1–7 and archived `icinga2-ingest` rounds 1–4; project rules and nine listed skills. Source: admission, ingress, config repository, source model, bootstrap, startup, workers, commitments, pipeline, ordering key, alert transition and persistence, Icinga2 facts/parser/mapper/decoder, runtime registry, output relay, console policy and endpoint, schema runner and inbox/outbox DDL, historical-secret fixtures, and capture launcher. Read-only; no tests or captures run. `git ls-files` was unavailable, so index membership was not independently verified.

## Findings

### Critical (blocking)

1. **A successful upstream response can put the API password in `raw_inbox`, despite the secret-store contract.** The new secret-store requirement explicitly prohibits secret bytes in raw rows. D5/D6 and “Lines are stored as read” require byte-preserving storage even for malformed stream lines. An authenticated 200 subscription that emits a malformed line containing the password therefore persists it in a failed raw row; `pipeline.dart:704–738` retains the body on failure. A well-formed acknowledgement carrying the password in its comment also reaches the event description under D11. The round 7 e2e addition exercises only a 401, which never reaches either path. Define the credential-echo exception to exact raw preservation and enforce it before admission and diagnostic sampling. Test a successful subscription that returns both kinds of line; inspect raw rows, events, outbox, status and both log sinks.

2. **D28’s receipt-time exception does not cover the state divergence introduced by a stale stream key.** Start with a firing alert fenced at 10:06. A recovery starting at 10:30 arrives on the stream at 10:00 and in sync at 10:02. `ordering_key.dart:18–51` gives the copies effective times 10:05 and 10:07. Stream first: D25 stores the stale event and keeps its key, so D2 makes the eligible sync copy a duplicate and the alert stays firing. Sync first: it repairs the alert and the stream copy is a duplicate. These are copies of one result, not D22’s distinct equal-start case. D1 already excludes this clock fault from its latest-result promise, but `alert-state` “Silent confirms keep no key” and D28 still say only fence receipt time can differ. Carry D1’s clamp qualification into the merged alert-state contract, explicitly document that a keyed stale stream copy can prevent repair of that result, and add both committed schedules alongside the inverse stale-sync case. No change to D22 or D25 is needed to make the narrower guarantee accurate.

### Moderate

1. **Admission retry idempotence has no precedence over backpressure or the revision fence.** Suppose a batch takes the last available slot, commits, and loses its acknowledgement. D7 pauses before flushing at the cap; D5 checks the revision and lease before the inserts; D27 promises to report the prior commit. A retry can therefore pause until disconnect or report `config_changed` for a batch that already committed. Specify a bounded receipt lookup for an unknown outcome independent of the gates on *new* inserts. Test a lost acknowledgement that fills the cap and one followed by a settings-changing publication; neither retry may insert under the old revision.

2. **The status API can report a dead enabled source as `connected` indefinitely.** If the last worker dies while connected and an `api` process survives, the lease expires but D12 only updates the status on takeover or retirement. An enabled source with no worker gets neither. The same issue affects production SQL inspection, which D12 names as the production diagnostic path. Derive effective liveness from lease expiry using database time, without making the API a status writer. Test an enabled source whose holder dies and is never replaced.

3. **Round 7’s resource fixes bound current holders, not all retained state or database backends.** D13 allows a PostgreSQL backend to outlive the socket close and the lease; a takeover can open a new session while the old backend survives. The “at most 64 dedicated consumer sessions” assertion is valid for healthy holder-owned client sessions, not all PostgreSQL backends. Separately, D12’s progress pruner covers held sources and sources absent from the active configuration, but not an explicitly disabled source that remains listed. Scope the connection sizing claim to client-owned sessions and state the lingering-backend headroom risk. Give disabled sources the same progress pruning rule as removed sources and test both.

4. **The tombstone bound uses current installation size, but D2 allocates state for historical object identities.** Sync two disjoint sets of 100,000 healthy services in succession, deleting the first set upstream before the second sync. D2 creates 200,000 tombstones, although the installation never contained more than 100,000 services at once. C6 deliberately preserves absent objects, the baseline requires only a *minimum* tombstone lifetime, and the design names no tombstone reclamation path. State the bound in terms of distinct identities seen over the actual retention interval, or document growth with historical identities until reclamation exists. D21’s raw-row exception does not cover `alerts`.

5. **`hard_only` can leave a missed eligible recovery unrepaired while reporting a clean sync.** Start with a firing HARD CRITICAL, miss an OK during a gap, and reconnect after a newer SOFT CRITICAL has become `last_check_result`. D3 fetches only that result, D10 skips it, and D2 excludes `soft_info` from `diverged`; the old firing alert remains and the sync can say `complete`. D1’s delivered-and-applicable scope allows this outcome, but the reconnect repair wording does not tell operators about it. Document that sync cannot recover eligible transitions superseded by a skipped result, and add the reconnect scenario without changing the owner’s policy.

6. **D28 and D30 have no carried destinations.** C17/C30 preserve key deletion, but neither carries the receipt-time exception; C22 carries equal-start and upstream-queue limits but not the shared-namespace attribution exception. A later change can restore unconditional convergence or make attribution changes emit repair events without touching any carried entry. Give each constraint one destination: `alert-state` “Silent confirms keep no key” for the qualified D28 rule, and “Displayed source in a shared namespace” for D30. Align the unchanged “Applied observations update state in place” requirement with the silent-confirm exception: it currently requires writing the observation’s display fields.

### Suggestions

None.

## Verdict

VERDICT: USER_OVERRIDE

Reviewer verdict for round 8: REVISE (2 Critical, 6 Moderate). Rounds 1 to 8 were all REVISE and each was
escalated to the owner. After round 8 the owner chose to proceed (2026-11-23): "Fix, then write tasks" (option
text: "Apply every fix, run no 9th design review, write tasks.md and rely on the pre-ship review of the code").

Open findings: every round 8 finding below is fixed in the artifacts (design.md, "This change's review round 8";
D31, D32 and C33 to C36) but has not been re-reviewed at design level. The pre-ship review checks them in code.

## Required Changes

CHANGES_APPLIED: n/a

## Rebuttals

Round 7 C1’s stale-reconcile reservation deletion and database scenario are present. C2’s shared-source attribution exception covers the reported webhook/sync schedule. M1’s source-first acquisition and persistent counters, M2’s contended-stop fallback, M3’s cross-generation spacing and cancelled deferral, M4’s holder-only dedicated connection, M5’s real-client 401 test, and M6’s 20-entry-plus-summary bound are present. The findings identify adjacent cases those fixes do not cover.

Earlier fixes retained include publication and generation fencing, late and policy-skipped key omission, stale-stream outbox suppression, historical reuse inventory cutover, and failure accounting before decode. The outbox containment rationale is supported by `pipeline.dart:360–372,580–609`: the webhook commitment is read from the pinned snapshot and written alongside that same pin. The findings do not require reversing D22’s equal-start exclusion or D24’s upstream-queue exception.