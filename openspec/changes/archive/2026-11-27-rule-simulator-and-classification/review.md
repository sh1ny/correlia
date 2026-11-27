# Review

## Metadata

- **Round:** 12
- **Prior round:** Round 11, APPROVE_WITH_CHANGES, changes applied.
- **Reviewer:** Cross-model CLI (OMP).
- **Reviewed:** FULL proposal, design, tasks, all five spec deltas, round 11 review, architecture, roadmap, ADRs 0016, 0021, 0028–0030 and 0032–0034, the seven requested skills, and cited source and tests. Git commands were unavailable. Checked paths against the local Git index and confirmed that the branch ref points to `702ea9f`; reviewed the amended files in the checkout rather than a `git show` diff. No tests run.
- **Note:** Re-check of the Required Changes only. Read the amended documents and relevant working-tree source and test excerpts. Git revision reads were unavailable, so citations to `1bfa471` were not verified. No tests run for the re-check.

## Findings

### Critical (blocking)

None.

### Moderate

1. **D7 still specifies the superseded false-leaf reason.** `design.md:104–109` says a false leaf carries `value_differs`. The amended proposal, simulator spec and test expect `no match: value fails <op>`. `matcher_condition.dart:369–394` assigns `valueFails` only when the field is present and the operator returns false. `rule_simulation.dart:493–510` appends the operator name. The code distinguishes false comparisons from missing fields and regex failures; the design would send a future implementation back to the old reason.
2. **The proposal promises an event the RPC does not return.** `proposal.md:34–39` promises the final enriched event, and the simulator spec's “No active matcher configuration” scenario says the event is returned unchanged. `rule_simulation_result.spy.yaml` returns a projection: kind, final labels and origins, links, severity, and routes. An operator cannot retrieve or inspect the full canonical result, including its identity and timestamps, from the CLI's JSON output either.
3. **A partially overwritten location action has an ambiguous trace.** A `location` action can stage `site=eu1` and `environment=prod` before a later action in the same rule sets `site=eu2`. `matcher_evaluation.dart:175–219` marks a location action superseded only if every key was overwritten. `rule_simulation.dart:337–347,455–485` therefore reports both staged values with a single `applied: true`, even though only `environment=prod` survives in the patch. The final labels are correct, but the trace cannot tell the operator which effect was applied.
4. **Several design citations no longer support the claims they accompany.** The cited `matcher_evaluation.dart:18–102,123–247` ranges no longer contain patch validation or `MatcherBatch.enrich`; those are at `:258–275` and `:320–445`. The cited `pipeline.dart:1059–1088` no longer shows the stream admission join; it is in `row_decode.dart:224–253`. The cited `config_repository.dart:161–179` shows the reserved-key lookup, not the guard's digest comparison at `:177–202`. The moved code still supports the decisions, but the current citations send maintainers to unrelated logic.
5. **The carried-constraints ledger omits D9's member-selection invariant.** The `Stored event keys and members` requirement protects it today, but `design.md` does not list it under “Carried constraints.” A future change that treats deterministic input order as sufficient would return a plausible but wrong trace for a historical row where the old pipeline retained the second member.
6. **The digest-fill resource table describes a one-time operation, contrary to D13.** `design.md:395` says the fill runs once and lists “Offline upgrade” as its timeout. `matcher_content_digest.dart:86–135,155–174` reads the suffix after `filled_through` and rewrites the watermark in the same transaction. The 60 s limit is for acquiring the lock, not for completing the fill. The release section and tasks 4.4–4.5 also omit step `0016`, although the fill queries its column. An operator or test author following that abbreviated sequence can mistake a lock-wait limit for a startup deadline or stop at schema step `0015`.

### Suggestions

None.

## Required Changes

1. Update D7 to name `valueFails` for a present value rejected by the operator and `no match: value fails <op>` as its serialized reason. Keep missing fields, skipped leaves and regex failures distinct.

   **Re-check: Applied.** D7 names `valueFails`, limits it to present values rejected by the operator, and gives the serialized reason and an example. It keeps `fieldMissing`, `not_evaluated`, and regex failures distinct.

2. Align the proposal and simulator scenarios with the typed result: name the returned projection, and say that with no active matcher the returned fields equal those of the input event, with no added routes. Do not promise a complete CloudEvent.

   **Re-check: Applied.** The proposal lists the projection and explicitly excludes a whole CloudEvent. The no-active-matcher scenario names the unchanged input fields—kind, labels, label origins, links, and severity—and requires an empty trace and no added routes. The spec separately restricts the noise hint to a simulated `classify` action.

3. Specify how the trace identifies which keys of a multi-key action survived within its rule. Add a mapped scenario in which `location` stages two labels and a later action overwrites one. Assert that the trace distinguishes the surviving key from the overwritten key, and align the implementation with that contract.

   **Re-check: Applied.** D10 and the mapped simulator scenario specify a per-label marker. The matcher tracks the last writer of each key and annotates the overwritten label; the simulator passes that detail through while keeping the partially surviving action staged and applied. `a_partly_overwritten_location_marks_the_overwritten_label` asserts `site=eu1 (overwritten later in its rule), environment=prod` and checks both final labels.

4. Refresh the cited ranges in Context, D9–D10, D13–D14, Release and upgrade, and the query-enrichment hand-off. Where a claim describes pre-change behavior, cite the pre-change revision and range instead of pointing at the changed checkout.

   **Re-check: Applied.** The previously accepted working-tree references stand. Checked the three remaining citations against the supplied `1bfa471` excerpts:

   - **Context, stored events:** `correlia_server/schema/0007_icinga2_reconcile.sql:27` defines the subject-expression index. The supplied inventory for steps `0001`–`0014` shows no other secondary index on `events`; its primary key is composite, not an index on `event_id` alone.
   - **Context, schema:** `correlia_server/lib/src/models/ingest_config_snapshot.spy.yaml:1-7` identifies the Serverpod model, its table, and its `publicJson` field.
   - **Context and Release and upgrade:** Context cites every supported case in the historical action dispatch and its `action_type` default. There is no `classify` case. The release section cites the same revision, persisted-reader entry point, and dispatch, with Context supplying the complete case list.

5. Add a carried invariant with one destination: `specs/rule-simulator/spec.md` → `Stored event keys and members`. State that the simulator selects a kept member only when the stored fields identify it, including for rows processed after the deterministic sort change.

   **Re-check: Applied.** C14 names that single destination and requires `ambiguous_member` when stored fields do not identify the kept member, including after D14. The destination’s excluded-label scenario exercises that post-change case.

6. Update the resource table, release sequence and tasks 4.4–4.5 to name steps `0015` and `0016`, distinguish the initial scan from later suffix fills, and state that the startup lock wait is capped at 60 s but total fill time grows with the unprocessed suffix. Map the existing offline-downgrade regression to that verification.

   **Re-check: Applied.** The resource table and release sequence name both steps, distinguish the initial scan from suffix fills, and separate the 60 s lock wait from fill time, which grows with the unprocessed suffix. Tasks 4.4–4.5 carry the schema sequence and lock distinction into implementation and docs; the operator guide describes the same sequence. Task 4.4 names `an_older_binary_publishing_after_the_fill_stores_its_content` in its verification, and the existing test covers restart after an older publisher adds a snapshot beyond the watermark.

## Rebuttals

## Verdict

VERDICT: APPROVE_WITH_CHANGES
CHANGES_APPLIED: yes
