# Review

## Metadata

- **Round:** 27
- **Prior round:** round 26 (omp) REVISE: 2 Critical (initializer taken for a transition; unchecked CUSTOM undeliverable), 3 Moderate (volatile keys; release gates; sentinel wording).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, tasks, four spec deltas, round 26 dispositions, three baseline specs, architecture, ADRs 0016/0017/0020/0021/0024/0028/0029, project rules, and four listed skills. Cross-checked the command definitions, sender arguments, Icinga2 parser and mapper, pipeline, alert-state transition, and operator docs. Read upstream result processing at v2.13.0, v2.14.0, v2.15.0, and v2.16.6, with supporting host, service, passive API, notification, and retention sources. Static review; no daemon captures or tests run.

## Findings

### Critical (blocking)

1. **D13 can mistake a real transition for an initializer and lose an eligible HARD problem.** D13 tests `last_state_up > 0` and the analogous service fields. In upstream [`apiactions.cpp`](https://github.com/Icinga/icinga2/blob/v2.16.6/lib/icinga/apiactions.cpp), the passive API copies `execution_end` without a positivity check. [`ProcessCheckResult`](https://github.com/Icinga/icinga2/blob/v2.16.6/lib/icinga/checkable-check.cpp) replaces only zero and orders results by `execution_start`; `SaveLastState` stores the supplied end. The v2.13.0 endpoint has the same behavior. A host can therefore record a real UP result with `execution_end = -1`, then enter SOFT DOWN at a current time `t1` and HARD DOWN on a subsequent result at `t2`. Its real `last_state_change` is `t1`, but D13 selects `t2` because `last_state_up` is negative. If the confirming passive result supplies an end more than 24 hours ahead, the pipeline quarantines the problem instead of opening the alert from the eligible `t1`. The formatter's range check cannot help: `t2` is inside its domain. The same misclassification applies to a service returning to UNKNOWN after a non-UNKNOWN result with a negative end.

### Moderate

1. **The sixth gate's capture format cannot establish its database predicates.** Task 9.1 records requests, HTTP statuses, Icinga 2 logs, and canonical events. A 202 with no second event does not prove a `duplicate_observation`: transport deduplication can return 202 without creating a raw row, and a failed or pending raw row also has no event. The duplicate count is in `raw_inbox.outcome_json` (`pipeline.dart:601–616`); the alert's status, version, and fence are not in the canonical event. The prescribed evidence cannot prove either host's reminder outcome or the volatile scenario's unchanged version. The gate also does not explicitly require the unchecked CUSTOM request to omit both fields or leave alert state untouched, although its separate scenario does.

2. **D13 promises one event per volatile check, but the command samples live state.** D4 explicitly permits queued notifications to run late. If two HARD DOWN checks complete before either command reads the live object, both commands read the second `last_hard_state_change` and produce the same key. The first check then has no separate event, even with coherent reads and distinct execution ends. The spec and documentation requirement currently promise one published event per check. The fence-without-version result is correct for a newer eligible observation from the same source, not a guarantee that each check yields one.

3. **The optional field is still required by another normative clause and by the operator field table.** The new requirement permits non-state omission, but “Icinga2 webhook observation evidence” still says any missing time fails decoding. `docs/ingest-pipeline.md:254` calls `last_state_change` required, and tasks 7.3 and 8.2 do not explicitly update that table. Also, D13's unqualified “no key changes for deliveries accepted before” conflates identical wire documents with successive command versions: a round-25 runtime-host DOWN sent while the daemon-start time was still eligible could commit under that initializer; the amended command's reminder carries the first HARD result time and has a different ID. This is a pre-release sender change, not a decoder compatibility break.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Separate the history test from timestamp validity. For normal check processing, a nonzero per-state time is evidence of a result even if that time cannot itself be formatted; validate the selected timestamp separately. Add a passive regression covering a negative historical marker and a later in-range real transition, plus a retained-state restart capture showing that an unchanged problem keeps its key. Scope the guarantee to intact retained state and state maintained by normal check processing.
2. Extend task 9.1 and the sixth gate to capture the known execution ends independently of the webhook, correlate requests to terminal raw outcomes, and record the relevant committed alert state and event counts. Require the unchecked CUSTOM body to omit both fields and leave alert state unchanged. Add a negative fixture where a reminder has 202 and no event but does not have a committed `duplicate_observation` outcome.
3. Scope volatile publication to distinct, eligible live HARD timestamps actually sampled by the command. Make the two-event scenario wait for the first delivery to commit before submitting the second check; assert the second event advances the fence without increasing the version.
4. Reconcile the observation-evidence requirement, D2/D13, the operator field table, and tasks: `notification_time` always required; `last_state_change` required only for PROBLEM and RECOVERY and validated whenever present. Keep state timestamps non-null in `StateFact`. Pin non-state key and event-ID equality with the field present versus absent, and distinguish unchanged IDs for identical wire documents from changed timestamps emitted by the amended command.

CHANGES_APPLIED: n/a

## Rebuttals

- With ordinary positive result times, a complete retained snapshot preserves the discriminator, state type, and both change timestamps together. For a non-volatile object that has never changed value, the first SOFT→HARD step sets `last_hard_state_change`; an unchanged HARD result does not move it. The finding is about accepted passive timestamps, not that normal fallback.
- The owner's optional-field choice is consistent with the mapper: non-state keys use type, notification time, and delivered author, and their source time is notification time. The pending round-25 helper and argument parser are not findings by themselves.
## Dispositions (orchestrator, apply group 7)

Round 27 was the second REVISE in a row. The owner chose on 2026-11-20 to apply the changes and run round 28.

- **C1 (negative passive end hides a real change):** Accepted. The history test is now `!= 0` on the per-state times. It is a separate step from the validity check of the chosen time, and an invalid chosen time never falls through to the other timestamp. The guarantee is scoped to Icinga 2's own check processing and intact retained state. New scenarios "Earlier result with a negative execution end" and "Retained state across a restart".
- **M1 (gate evidence too thin):** Accepted. Task 9.1 records the driver's execution ends, each request's terminal raw outcome, the committed alert state and the event counts. The gate requirement says it is judged on that evidence and requires the CUSTOM body to omit both fields and leave alert state unchanged. New negative scenario "Reminder accepted without a committed duplicate outcome".
- **M2 (volatile promise):** Accepted. One observation is now promised per distinct, eligible time a command samples. The scenario submits the second check only after the first delivery's raw row commits, and asserts that the fence moves while the version does not.
- **M3 (optional field still required elsewhere):** Accepted. The observation-evidence requirement now says "missing required". D2 names which times are required. D13 keeps `StateFact` non-null and pins equal non-state keys with the field present or absent (scenario "Non-state key without the state change time"). It separates identical wire documents from the unreleased round 25 command's times. Task 7.3 updates the operator field table.
