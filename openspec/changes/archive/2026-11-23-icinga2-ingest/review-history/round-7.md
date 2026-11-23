# Review

## Metadata

- **Round:** 7
- **Prior round:** round 6 (omp) REVISE: 1 Critical (convergence promised the latest state even when it never reaches the fence: lost recovery, late reminder winning the insert), 5 Moderate (dedup scope is event ID; clamp column null ambiguity for old rows; no real host capture; dotted-path vector; resend versus rerun).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, four spec deltas, and round 6; baseline ingress, pipeline, alert-state, and canonical-event specs; project rules and listed skills; M2 roadmap and named acceptance scenarios; architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028, and 0029; cited ingest, pipeline, state, identity, schema, runtime, alert-model, and protobuf sources; historical snapshot fixture; archived Alertmanager D6 and capture script. Read-only review; no tests or captures run.

## Findings

### Critical (blocking)

1. **D6 strands pending work pinned to a historical M1 snapshot.** D6 assumes every pinned source object carries `kind`. The existing `m1_pending_raw_delivers_with_historical_signing_key` case in `correlia_server/test/e2e/secret_store_e2e_test.dart:246–368` seeds a real historical snapshot shape (`format_version: 1`, no source `kind`) and a pending row already pinned to it. `pipeline.dart:279–301` reads that immutable snapshot, not the current source row. Dispatching on its missing kind rejects work that currently succeeds. Interpret an absent kind as `alertmanager` **only** for historical v1 snapshots; retain bounded failure for unknown kinds and missing kinds in newer snapshots. Make the upgrade scenario explicitly exercise the old pin and assert it remains unchanged.

2. **D5 breaks old workers at schema activation, before any Icinga2 source exists.** The proposed column is `NOT NULL` without a default. The old `INSERT INTO events` (`pipeline.dart:445–458`) omits it. Any upgraded role can apply step 4 at startup (`runtime/serverpod_adapter.dart:31–36`), so starting a new API while old workers are still running makes their ordinary Alertmanager inserts fail. A not-null violation consumes the internal retry budget and can mark accepted rows `processing_exhausted` (`pipeline.dart:632–669`). D6 and the runbook gate the cutover on **source activation**, which is too late. Require all old `worker`/`all` processes to stop before any upgraded role applies step 4; document how admitted rows remain queued and resume under upgraded workers. No mixed-version mechanism is necessary if the cutover is explicitly offline for event writers.

3. **The release gate can certify whole-second timestamps.** D2 and “Two problems within one second” require three IDs in a sequence lasting less than a second. That sequence can cross a Unix-second boundary. The two CRITICAL samples can then have different whole-second timestamps, and the middle OK already differs by state. A sender using the rejected whole-second macro can therefore pass, then drop a refire when both CRITICAL samples really do land in the same second. Require the two HARD CRITICAL samples to share the same integer Unix second while carrying distinct, increasing microsecond change times through the shipped command. Check timestamp evidence as well as IDs for both shipped command definitions; DOWN → UP alone cannot prove host timestamp precision.

### Moderate

1. **D5 cannot preserve the exact effective time for unclamped Alertmanager evidence.** The fence compares nanoseconds (`state/ordering_key.dart`), but `pipeline.dart:46–49,456` truncates the legacy SQL `source_time` to microseconds. Both the proposed `LEAST` backfill and a new `timestamptz` column lose distinctions such as `t + 800 ns` versus `t + 900 ns`. That does not affect the existing fence, but it makes the persisted value unsuitable as its exact replacement for later readers. Either store exact effective time and backfill from retained canonical payloads, or explicitly limit the SQL value to microsecond queries and require exact-ordering readers to use exact evidence. Test the chosen semantics on both sides of the upgrade. Also scope “Later stages SHALL use the recorded effective time” to consumers of effective ordering time: ADR 0017 uses observed time for operational expiry, windows, and reminders.

2. **The unconditional delayed-notification scenario still contradicts the new convergence contract.** “Delayed notifications in any order” specifies neither eligibility nor ordering rank, yet expects the final CRITICAL to win. The same spec's reversed-receipt example shows how a coherent later transition can rank lower under the clamp; the final CRITICAL could also be late. State explicitly that the three observations are distinct, eligible, and unclamped, with strictly increasing source times. In the lost-recovery and torn-delivery scenarios, require the subsequent observation to outrank the fence, not merely to report a later source time. Qualify the unconditional “alert ends in Icinga 2's state” sentence in the design’s flow section.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Define historical v1 pinned-source dispatch and preserve the existing pending-row upgrade regression.
2. Move the worker cutover before schema step 4; specify backlog recovery and verify the documented upgrade sequence with pending Alertmanager work.
3. Make the release gate reject whole-second evidence even when the transition sequence crosses a second boundary; prove precision for the host and service commands.
4. Specify persisted effective-time precision and which consumers use it; cover sub-microsecond evidence before and after upgrade.
5. Align the delayed-notification and recovery scenarios with the committed-evidence ordering contract.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 6 C1:** The main convergence requirement now scopes the guarantee to committed, eligible, state-bearing evidence after event-ID deduplication. The lost-recovery and late-reminder cases address the original counterexamples. Remaining scenario and flow wording: Moderate 2.
- **Round 6 M1:** Resolved. The delta uses event-ID scope and limits fence updates to eligible, state-bearing observations.
- **Round 6 M2:** The backfill removes the original `NULL` ambiguity. Cutover compatibility and sub-microsecond fidelity remain open: Critical 2 and Moderate 1.
- **Round 6 M3:** The new per-release DOWN → UP scenario exercises the shipped host command. It closes the missing-host-capture finding, not the precision gate in Critical 3.
- **Round 6 M4–M5:** Resolved. The test asserts one persisted `*` for `state.state_type`; the failure table distinguishes resending the serialized document from rerunning the command.
- **Round 6 proposal rebuttal:** Resolved. The proposal now qualifies kind preservation on the pinned snapshot configuring the source. Historical snapshots without a kind are a separate compatibility issue.