# Review

## Metadata

- **Round:** 3
- **Prior round:** Rounds 1 and 2 both returned REVISE, each with four Critical and eight Moderate findings. After escalation, the owner chose to fix all findings and request round 3.
- **Reviewer:** cross-model CLI (OMP)
- **Reviewed:** Proposal, FULL design, prior review and rebuttals, four spec deltas, the main Alertmanager, source-ingress, durable-pipeline and canonical-event specs, architecture, ADRs 0008/0016/0019/0024/0029/0030, and the supplied project rules. Re-read the design’s source citations and followed the relevant code in `schema_steps.dart`, `ingest_records.dart`, `cloud_event.dart`, `0001_ingest.sql`, and the upgrade runbook.
- **Verification limits:** No referenced store or scenario-to-task map was declared. The read-only tool surface did not expose `git ls-files`; Git index membership was not independently verified. No Serverpod runtime or Thanos capture was exercised.

## Findings

### Critical (blocking)

1. **The publisher gate does not define a safe rollback.** D22 specifies upgrading every role before enabling generic sources, but does not say what operators may roll back after activation. Schema step 10 fences inserts, not worker startup or claims. The old schema runner iterates only its known steps (`schema_steps.dart:72–87,124–153`), and an older worker can claim and terminally fail a generic row. Simply removing the source is also unsafe while unpinned deliveries remain: first claim then fails with `source_not_configured` (`pipeline.dart:287–319,363–380`). Keep the owner’s publisher gate and documented rollout. Specify and test a supported rollback procedure: stop new generic deliveries without removing the source, drain accepted work with compatible workers, and state whether binary downgrade is unsupported on the upgraded database. Replay is not available in this change.

2. **Preview’s `batch_bound` prediction can be wrong under the existing worker contract.** D8 excludes deduplication and quarantine from the prediction but still promises to reproduce the per-row fan-out result from configured outputs. The worker skips repeated IDs and existing observations, counts only inserted events, and charges outputs only for eligible routed events (`pipeline.dart:498–545,640–670`). A sample of repeated copies of one large valid observation can exceed a preview sum of *payload × configured fan-out* while production charges one event and succeeds. Late evidence can likewise avoid the output charge. Specify whether the flag reports a conservative budget estimate or a result under explicit assumptions. Share the byte accounting and test both a batch of distinct eligible events that actually fails and a batch that production stores below the limit because some events do not count.

3. **D21 still allows roughly 100 MiB of retained event bytes before the worker’s budget check.** It counts UTF-8 text, not the structured bytes retained by each `CanonicalEvent` (`canonical_event.dart:546–559`). A label value with 150 NUL characters fits the canonical label limit; its JSON encoding uses 900 bytes. Copy it to 128 labels on each of about 850 items: a body under 1 MiB can yield roughly 98 MB of serialized label values while the corresponding text remains under 16 MiB. Each individual event fits the 256 KiB canonical limit. This is the expansion failure D21 is meant to prevent. Keep the cumulative decode budget, but charge retained structured bytes before accumulating the next event, or use a conservative pre-build charge that covers escaping and event overhead. Make the regression exercise escaped expansion and assert that decoding stops before building the full batch.

4. **The new snapshot cap can reject an unchanged, previously valid configuration.** D9 preserves bytes for files without mappings, but D15 applies the 128 KiB cap to normalized snapshots. The current parser permits 64 sources with four credentials each and 64 plugin outputs with eight secret references each (`bootstrap.dart:233–237,281–313,326–330`; `source_config.dart:229–230`). Publication adds a 64-character digest to each credential and expands each plugin reference into an object with a commitment (`source_config.dart:32–39`; `bootstrap.dart:111–126`). Those additions can exceed 64 KiB before source defaults are counted, while the file can still fit its existing 64 KiB limit. An unconditional activation cap can therefore block an upgrade restart or the next rotation. Define how existing snapshots remain usable and revisable, and qualify the ingress transfer bound if historical snapshots exceed it. Add a populated-upgrade test and a distinct test of `snapshot_bound` that keeps the prior revision active.

### Moderate

1. **The preview overflow acceptance case does not follow from the stated limits.** D8 caps each path at 256 bytes via D12, so 100 paths contribute at most 25,600 path bytes. Repeating an RFC 6901-escaped ancestor cannot by itself overflow 64 KiB before 100 entries. If the byte budget is for serialized diagnostics, specify the representation and exercise JSON escaping that expands it; otherwise make the scenario reachable under the stated accounting. The spec’s “alert then path order” also needs to match D8’s declaration and document order. Define those orders for canonicalized active mappings and drafts, add multiple errors in one alert, and reconcile S4’s promise of “every” field with the bounded result.

2. **The generic path contract still has an unimplementable branch and an unreachable acceptance case.** `EventValidationError` is sealed (`validation.dart:4–18`); an ingest-library `GenericFieldError` cannot extend it without changing the library boundary. Define where the structured error lives and which catch handles it. `event_too_large` comes from event construction, before the commit-stage catch; that catch does have a real `batch_bound` path (`canonical_event.dart:546–559`; `pipeline.dart:661–670,733–743`). Test one reachable failure per stage with one exact path result per case. Also specify that a stored sender segment comes from the mapping allow-list, not that *no* payload key can ever appear: the preceding requirement expressly permits a configured key such as `labels`.

3. **Mapping format 1 still leaves payload behavior open.** The display spec rejects a copied non-scalar but does not define whether numbers, booleans or `null` are accepted, how accepted values become strings, or which copied fields may be absent. D11 also leaves the count for an unmapped subtree outside a nested `items` array unclear. These choices change whether the same delivery commits and what is published. Define the accepted types and missing-value behavior for each display form, and establish one leaf-count rule for both scopes. Add cases for missing versus null, a nested `items` path with sibling metadata, and a payload with more than 1,000 items. For time, state separate exact inclusive maxima for seconds and milliseconds and test the last accepted value, the first rejected value, and exponent notation.

4. **The Thanos capture plan does not specify the evaluator or a bounded resolution procedure.** The existing script starts a receiver and Alertmanager, then injects explicit `endsAt` via Alertmanager’s API (`tool/alertmanager_capture.sh:64–114`). D18 replaces that with real Rulers but does not identify the query endpoint they evaluate against. Nor does “replacing the rule file” say whether to keep the same rule and labels and make its expression stop firing, or remove the rule and wait for expiration. Specify the query dependency, readiness checks and finite wait for Ruler-originated firing and resolved notifications. Record the before/after per-replica counters in the committed capture evidence; the manifest fields currently do not require them. A1’s fallback to Correlia-side exclusions also needs to agree with the mandatory Ruler-drop scenario.

5. **Some claims and carried constraints still point to the wrong evidence or destination.** The outcome is JSON stored in a `text` column (`0001_ingest.sql:12`), not a JSON column. The row-budget claim must state the insertion and eligibility conditions from Critical 2. D1 attributes `[n]` indexing to ADR 0008, which specifies dotted paths but does not define that indexing syntax. C5 puts the no-Thanos-kind constraint in “One source per Thanos tenant,” which does not carry it; split the constraints so each has its own destination. Carry S4’s no-write boundary in the preview requirement itself, and update the mechanism ledger’s no-cache rationale to use the serialized snapshot bound, not the file cap.

### Suggestions

None.

## Verdict

VERDICT: REVISE

The remaining blockers concern accepted-work safety, preview correctness, and resource bounds. None requires reversing the owner’s source-time, first-claim pinning, Thanos integration, or publisher-gate decisions.

## Required Changes

CHANGES_APPLIED: n/a

## Rebuttals

Round-2 re-check:

- **Critical 1 — fixed.** Admission asserts an unset pin; the pipeline scenarios distinguish activation before and after first claim. The removal case now distinguishes pinned from unpinned rows.
- **Critical 2 — partial.** D22 adds and tests an old-publisher fence and documents the role upgrade order. Rollback with accepted generic work remains open.
- **Critical 3 — partial.** D8 limits the preview prediction and adds an over-budget scenario, but the proposed calculation still disagrees with the worker’s actual charges.
- **Critical 4 — partial.** D21 checks ordinary repeated-pointer expansion during decoding, but unescaped text does not bound retained structured bytes.
- **Moderate 1 — partial.** Integer-only input and separate rendering rules are now explicit. Exact per-unit endpoints and the accepted precision boundary are not exercised.
- **Moderate 2 — partial.** D12 now distinguishes structural sender paths, canonical paths and no path, and cuts at segment boundaries. The sealed error type and commit-stage scenario still need correction.
- **Moderate 3 — partial.** D8 and the spec add a combined cap and overflow count. The ordering and over-cap case still do not agree; S4 still promises every diagnostic.
- **Moderate 4 — prior issues fixed.** Severity constants, table inputs, missing values, static constant/output validation and native ID semantics are addressed. Display coercion and optionality remain unspecified.
- **Moderate 5 — prior issue fixed.** The file, snapshot and lookup bounds are distinguished, and file-backed rejection is covered. The new snapshot cap creates an upgrade compatibility issue.
- **Moderate 6 — tenant case fixed; capture evidence partial.** Distinct transport keys allow both tenant-header deliveries to reach processing. The drop-run scenario now calls for independent counters, but the committed evidence and executable capture sequence are not specified.
- **Moderate 7 — fixed.** C7’s destination distinguishes replay from retry, and C8 names one durable no-cache destination.
- **Moderate 8 — fixed for the cited round-2 issues.** The retry, endpoint and receiver ranges now support the narrowed claims, and D17 states the global dev/test impact. Remaining claim mismatches are listed above.