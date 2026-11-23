# Review

## Metadata

- **Round:** 26
- **Prior round:** round 25 (omp) APPROVE_WITH_CHANGES, changes applied and re-checked (yes); voided by the apply-time D13 amendment.
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, tasks, four spec deltas, round 25 dispositions, three baseline specs, architecture, ADRs 0016/0017/0020/0021/0024/0028/0029, project rules and four listed skills. Cross-checked `contrib/icinga2/`, sender and decoder sources, pipeline and alert-state code, timestamp vectors, operator docs, and upstream Icinga 2 v2.13.0 and v2.16.6 source. Static review only; no tests or captures run.

## Findings

### Critical (blocking)

1. **A host created after daemon startup can report an old problem time for its first HARD DOWN and never open an alert.** D13 equates “no state-value change yet” with `last_state_change < 1`. In v2.16.6, [`checkable.ti`](https://github.com/Icinga/icinga2/blob/v2.16.6/lib/icinga/checkable.ti) defaults both timestamps to `Application::GetStartTime()`. [`daemoncommand.cpp`](https://github.com/Icinga/icinga2/blob/v2.16.6/lib/cli/daemoncommand.cpp) loads and activates startup objects before `Application::Run()` sets that clock; [`ConfigObjectUtility::CreateObject`](https://github.com/Icinga/icinga2/blob/v2.16.6/lib/remote/configobjectutility.cpp) also supports creating objects in the running daemon. The first DOWN leaves `last_state_change` unchanged because the initial host state already maps to DOWN. On a daemon up more than seven days, a runtime-created host can therefore send daemon startup time instead of its fresh first HARD DOWN time. The helper accepts that positive default, the pipeline marks the delivery `late`, and reminders keep using the same old time. The zero-only capture does not cover this path.

2. **The required unchecked-service CUSTOM capture cannot succeed on a clean startup-configured service.** The same initialization order leaves both timestamps at zero before the first check. `correlia_live_state_change` then yields no time, and `SenderArguments.parse` rejects `--last-state-change` before opening a connection. The spec explicitly requires this CUSTOM notification to receive 202 without `output` (`integration-icinga2/spec.md:531`). The mapper already uses `notification_time` for both identity and source time on CUSTOM; the unused mandatory state timestamp is what prevents delivery. A capture against a runtime-created service with positive defaults would hide the startup failure.

### Moderate

1. **`last_hard_state_change` is not stable while the state value stays unchanged.** In v2.16.6, [`Checkable::ProcessCheckResult`](https://github.com/Icinga/icinga2/blob/v2.16.6/lib/icinga/checkable-check.cpp) writes `last_hard_state_change` on `hardChange || is_volatile`. A startup-configured volatile host can remain HARD DOWN with `last_state_change == 0` across successive checks. A reminder after another DOWN check then gets a different D2 key, emits another event and output intent, and advances the fence instead of only refreshing freshness. This happens with coherent reads; D4’s torn-read caveat does not cover it. S3 still keeps SOFT problems informational, but does not prevent this HARD duplicate.

2. **A release can qualify without proving D13.** The new red test-map row names the first-DOWN capture, but `Supported Icinga 2 releases` and tasks 9.2–9.3 still qualify pairs on the old five predicates plus one artifact delivery. The same-second host sequence can start from an already-UP host and pass without exercising the fallback. A pair can satisfy the written qualification rule while dropping a new host’s first problem.

3. **D13 contradicts D3’s optional-text sentinel.** D13 says `correlia_text` returns the two-character JSON literal `""` on failure. D3 and the shipped helper use a zero-length DSL string to make `set_if` omit absent text. Applying D13 literally would include `"output": ""` instead of omitting `output`, failing the unchecked CUSTOM capture even after the timestamp issue is fixed. The compiled-sender choice is unchanged; the argument contract is not consistent.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Define how the command distinguishes a real state transition from an initialized timestamp; do not infer that from `>= 1`. Prove both startup-configured and runtime-created first-HARD-DOWN cases with source times equal to the actual first HARD check, one firing event, and a deduplicated reminder. Include a runtime case with a daemon-start timestamp outside the lateness horizon.
2. Make notifications that do not use state-change time deliverable without inventing one. If that changes the required fields of D3’s user-chosen document, obtain the owner’s decision and reconcile the spec, sender, and decoder. Capture a CUSTOM notification on a clean startup-configured service before its first result; assert 202, one informational event, omitted `output`, and no alert mutation.
3. Define volatile behavior before freezing D2 keys. Either preserve one key across unchanged checks and reminders, or explicitly scope the guarantee and document the additional events and fence effects. Capture a second HARD DOWN check before the reminder.
4. Make first-DOWN delivery and reminder deduplication explicit release-qualification predicates in the spec and group 9. Require negative matrix evidence in which the existing five gates pass but the first-DOWN predicate fails.
5. Correct D13’s sentinel wording: absent optional text uses an empty DSL string and is omitted; an unusable required argument uses the encoded JSON empty string and is rejected. Specify `1 <= seconds < 2^32` as the **shipped formatter’s input domain** in the precision scenarios and setup docs, and keep the wider decoder range and D2 vectors intact.

CHANGES_APPLIED: n/a

## Rebuttals

- The fallback does not replace a real `last_state_change` within the formatter’s supported range. The defects are the converse: a positive initializer can masquerade as a real change, and the fallback timestamp can move without a state-value change.
- The `2^32` bound does not conflict with the `8589934592.*` or year-10000-boundary vectors: those exercise exact wire decoding, not Icinga’s double formatter. Known-input command captures must use the formatter’s domain.
## Dispositions (orchestrator, apply group 7)

- **C1 (initializer taken for a transition):** Accepted. D13 now detects a real state value change from the per-state result times (`last_state_up` for hosts; `last_state_ok`, `last_state_warning`, `last_state_critical` for services), which Icinga 2 sets only from results and leaves at 0 otherwise, and sends `last_hard_state_change` only for a HARD object with no change. The initializers are never sent. New scenarios "First check result of a new host is DOWN" (startup and runtime host, second HARD check, reminder) and "Initialized state change time of a runtime-created host" (an eight-days-old initializer, the lateness case).
- **C2 (unchecked CUSTOM undeliverable):** Accepted. This changed D3's user-chosen document, so it went to the owner, who chose on 2026-11-20 to make `last_state_change` optional for non-state notification types. The spec, sender and decoder now agree (new requirement "State change time is required only for state notifications", tasks 7.2 and 7.3), and the CUSTOM capture asserts no `last_state_change`, one `comment` event and no alert.
- **M1 (volatile):** Accepted, as a scoped guarantee. D13 documents that a volatile object with no state value change yet gets one observation per HARD problem check, on one alert with no version change. Scenario "Volatile host with no state change yet" and the documentation requirement "State change time limits are documented" cover it.
- **M2 (release gates):** Accepted. The first problem of a new object is the sixth gate ("First problem of a new object qualifies a release"), with two negative matrix scenarios in which the other five gates pass.
- **M3 (sentinel wording):** Accepted. D13 now names two failure values: an empty DSL string, which is omitted, and a JSON `""`, which is refused. The formatter's domain is stated as an input domain in the spec ("State change time of a new object", "Time outside the formatter's domain") and in the documentation requirement. The decoder range and the D2 vectors are unchanged.
