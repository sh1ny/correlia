# Review

## Metadata

- **Round:** 11
- **Prior round:** REVISE. The owner moved the demo and its two blockers to `enrichment-demo`.
- **Reviewer:** cross-model CLI (OMP)
- **Reviewed:** FULL proposal, design, all five spec deltas, roadmap, architecture, ADRs 0016, 0021, 0028–0030 and 0032–0033, relevant main specs, all seven requested skills, and the cited source ranges. Checked cited paths against the Git index because `git ls-files` was unavailable. No external planning store was referenced. Demo and query enrichment were reviewed only as hand-offs. Read-only; no tests run.

## Findings

### Critical (blocking)

None.

### Moderate

1. **The retained-member guarantee still contradicts D9.** D9 and the new excluded-label scenario now correctly return `ambiguous_member` even for a post-change row. But `design.md:268` still says the simulator finds the kept member of **any** stored row, `proposal.md:46–49` makes the same claim without qualification, and the stored-draft scenario promises a member without requiring that it be identifiable. The deterministic pipeline order does not remove the simulator's ambiguity under the chosen lookup rule.
2. **The regex regression expects the wrong error when earlier events exhaust the row budget.** The simulator spec's “The pipeline's regex budget ran out” scenario expects a later event to record `regex_timeout`. `matcher_regex_worker.dart:171–195` returns `regex_budget` if an earlier call made the row's regex worker unavailable or left no budget before the later call starts. A later call can return `regex_timeout` if it starts with some budget remaining and overruns it; that is a different setup.
3. **The stored-key contract does not say how to reject a malformed `observed_at`.** D8 fixes the Round 10 partial-key problem, but the invalid-key scenario covers only event IDs and dispositions. The CLI accepts a timestamp from the operator; a permissive parser can normalize an invalid calendar date or interpret a zone-less value in the machine's local zone, querying a different primary key instead of reporting `invalid_input`. ADR 0021 specifies strict calendar and offset validation for canonical timestamps; `pipeline.dart:68–72,761` establishes the microsecond projection the lookup must use.
4. **D13's long-history test can build a small digest table, and its paging prescription permits repeated scans.** Many snapshot revisions can have identical matcher content. Because the fill uses `ON CONFLICT DO NOTHING`, a fixture with many revisions but few distinct digests can legitimately produce a sequential scan under default planner settings. Also, “pages of 100 ordered by ID” permits `OFFSET` paging, which repeatedly walks prior rows and does not provide the one-pass fill promised by the resource table.
5. **The stored-event context overstates what happens to future-dated stream items.** `design.md:34–36` says a future-dated event is stored, without restricting that claim to non-stream inputs. The cited `pipeline.dart:752–766` constructs a retained effect; it does not insert one. The stream gate at `pipeline.dart:594–611` counts and skips a future-dated item before retention. Without that distinction, a stored-stream simulator case can expect a row that cannot exist.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

C11 now preserves the stream gates, D8 rejects orphaned key fields, and the NUL citation correctly distinguishes direct pinned-matcher evaluation from worker coverage. D9 resolves the excluded-label behavior; the remaining changes align the other artifacts with it. The demo hand-off preserves both Round 10 blockers and both remaining demo findings. The query-enrichment hand-off remains self-contained, and the roadmap places the demo, query enrichment, and dead letters in changes 7, 8, and 9 respectively.

## Required Changes

1. Qualify the retained-member claim in the proposal, D14, and the stored-draft scenario: select the kept member only when D9's projection identifies it; otherwise return `ambiguous_member`. Carry that invariant to the rule-simulator requirement that defines stored-event simulation.
2. Change the stored row-budget scenario to exhaust the regex budget on earlier events and assert a stored `regex_budget` diagnostic beside a successful fresh simulation. Keep the existing scenario for the call that itself returns `regex_timeout`.
3. Specify the stored-key timestamp contract in D8 and the simulator and CLI specs: reject invalid calendar dates and missing or invalid offsets before lookup, then project valid timestamps to the stored UTC microsecond key. Add a field-error case for malformed `observed_at`, including a timestamp without an offset.
4. In D13, require keyset paging by snapshot table ID, with each page starting after the last ID read. Populate the long-history plan test with distinct matcher digests before asserting use of the primary-key index under default planner settings.
5. Restrict the stored-quarantine claim and scenario to non-stream events. Cite `pipeline.dart:594–611` for stream count-and-skip behavior and `pipeline.dart:776–783` for non-stream quarantine insertion.

CHANGES_APPLIED: yes

## Rebuttals