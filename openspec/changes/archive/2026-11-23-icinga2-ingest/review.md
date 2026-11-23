# Review

## Metadata

- **Round:** 28
- **Prior round:** round 27 (omp) REVISE: 1 Critical (negative passive end hides a real change), 3 Moderate (gate evidence; volatile promise; optional field still required elsewhere).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, tasks and test map, all four spec deltas, round 26 and 27 dispositions, three baseline specs, architecture, ADRs 0016/0017/0020/0021/0024/0028/0029, project rules and four listed skills. Cross-checked `contrib/icinga2/`, sender, decoder, ingress, pipeline, alert-state code, operator docs, and upstream Icinga 2 check processing, notification execution and argument resolution. Static review; no tests or captures run.

## Findings

### Critical (blocking)

None.

### Moderate

1. **The volatile documentation still promises one event per check.** `design.md:707` and `specs/integration-icinga2/spec.md:168–176` retain the promise that D13 retracts. If two HARD DOWN checks finish before either queued command samples the object, both commands read the second timestamp and Correlia stores one event. Task 8.2 and its documentation check can still enforce the wrong contract. The volatile capture now waits for the first commit, but it should also require distinct, increasing, eligible execution ends; commit order alone does not make the second sample advance the fence.
2. **The sixth gate can accept a reminder that deduplicates against the wrong event.** `specs/integration-icinga2/spec.md:622–627` and task 9.2 require one firing *alert* per host and a committed duplicate outcome for each reminder. If the second HARD DOWN check erroneously emits a new event, a reminder using that second key still commits `duplicate_observation`. The result is one alert but two firing events and two sets of output intents. It passes the enumerated gate predicates even though it fails the first-DOWN scenario and conflicts with the different-ID negative fixture. Task 9.1 also needs to distinguish a newly inserted raw row from a transport-deduplicated 202 and from requests sent only to the recording receiver; neither has a new raw row.
3. **The optional timestamp’s `set_if` and value can disagree.** D13 (`design.md:527–532,557–560`) makes omission depend on `set_if`. Icinga 2’s [`ResolveArguments`](https://github.com/Icinga/icinga2/blob/v2.16.6/lib/icinga/macroprocessor.cpp#L498-L541) evaluates `set_if` and `value` separately. If a CUSTOM command’s predicate sees a usable time and a passive state transition with a negative execution end lands before the value read, the command passes the JSON empty string or an invalid argument instead of omitting it. The sender rejects the entire CUSTOM notification, even though its identity and source time do not use that field. The unchecked-service capture exercises stable absence, not this interleaving. Separately, the precision requirement at `spec.md:281–285` still says the command always sends the state change time.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Align Flow & State Gaps, the documentation requirement, task 8.2 and its check with D13: one observation per distinct, eligible live HARD timestamp actually sampled, not per check. Give the two-event capture distinct, increasing, eligible execution ends and retain its fence and version assertions.
2. Make the sixth gate require exactly one firing event per non-volatile host across the first HARD DOWN, second HARD DOWN and reminder; require each reminder’s decoded ID to match its first event and its own newly admitted raw row to finish with `duplicate_observation: 1`. Add broken evidence with two firing events and a reminder that duplicates the second. In task 9.1 and the test-map preamble, record DB evidence for newly admitted Correlia requests and represent transport duplicates, rejections and recorder-only requests separately.
3. Define one sample of the optional state timestamp per command, used for both omission and rendering. Pin the non-state path with an unusable selected timestamp and verify that it still delivers without the field; separately verify that an explicitly present invalid timestamp is rejected. Qualify the precision requirement so it applies to state change times that are sent, while `notification_time` remains mandatory.

CHANGES_APPLIED: yes

## Rebuttals

- The nonzero history discriminator fixes round 27’s blocking case. A negative historical result still establishes a state change; validity is checked separately on the selected timestamp. The negative-end and retained-state scenarios are mapped to automated captures.
- The owner’s optional-field choice is consistent with the mapper. D2/D3/D13, the observation-evidence requirement and task 7.3 now distinguish mandatory notification time from conditional state change time, preserve a non-null `StateFact` timestamp, and pin identical non-state keys and event IDs with or without the field. The unreleased sender’s changed timestamps are not a wire-identity compatibility break.
- The pending round-25 helper and sender implementation are not findings.
## Applied (orchestrator, apply group 7)

1. Flow & State Gaps, the documentation requirement and the volatile scenario now promise one observation per distinct, eligible sampled time, and the scenario's second check has a distinct, later, eligible execution end. Task 8.2's bullet names that limit.
2. The sixth gate requires exactly one firing event per non-volatile host, the reminder's id equal to it, and `duplicate_observation: 1` on the reminder's own new raw row. A new requirement, "First-problem gate evidence", has the capture record newly admitted rows apart from transport duplicates, rejections and recorder-only requests. Tasks 9.1 and 9.2 and the test-map preamble follow. New broken-evidence scenarios: "Second HARD check emits a second event" and "Transport duplicate counted as a reminder outcome".
3. `--last-state-change` now has a `set_if` that tests only the fixed notification type, so it is never passed for non-state types. Its `value` is the command's single read of the timestamps. This narrows "omit when unknown" on the command side only, and the owner's document contract is unchanged. New scenarios: "Non-state notification for an object with an unusable state change time" (capture) and "Invalid state change time on a non-state delivery" (decoder). The precision requirement now covers every state change time that is sent.
