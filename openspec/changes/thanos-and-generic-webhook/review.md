# Review

## Metadata

- **Round:** 5
- **Prior round:** Rounds 1–4 returned REVISE. Round 4 closed three of round 3’s four Critical findings and left one Critical and six Moderate findings. The owner authorized this focused re-check past the cap (J1a), including removal of the preview row-budget estimate.
- **Reviewer:** cross-model CLI (OMP)
- **Reviewed:** Current proposal, FULL design, four spec deltas, round-4 review, main Alertmanager/source-ingress/durable-pipeline/canonical-event specs, architecture, project rules, and ADRs 0008/0016/0019/0024/0029.
- **Verification limits:** The read-only interface did not expose `git show` or `git ls-files`. I reviewed the current artifacts against the seven named findings, but could not independently verify the `68ca3cd` diff or establish that cited source paths were tracked before reopening them. Source evidence below is attributed to round 4. No external context store was declared. No runtime or capture was exercised.

## Findings

### Critical (blocking)

None. D8 and the normative Mapping preview requirement remove the production row-budget estimate and define decode results under preview metadata.

### Moderate

1. **The proposal and acceptance scenario do not fully reflect the revised preview contract.** `proposal.md:42–44,115–117` still says preview returns the events it “would produce,” without the qualification now required by D8 and the spec. `Results computed with preview metadata` says that a sample *may* decode differently in production; a test checking only the label and absent estimate would pass even if both paths always used preview metadata. The remaining issue is the contract wording and its boundary proof, not the removal of the estimate.
2. **A1 still reads as selecting a fallback before the owner decides.** `design.md:414–419` first says the setup relies on `excluded_identity_labels` if Ruler cannot drop its label, then says apply stops for an owner decision and the drop run remains required. The latter agrees with the Alertmanager delta and S1; the former gives the implementer a contradictory instruction on the same failure path.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. In the proposal’s Mapping preview bullet and S4, describe events and decode failures as computed with preview metadata, not as predictions of production results. In `Results computed with preview metadata`, retain the label and no-estimate assertions and add a deterministic boundary case: hold the sample and mapping fixed, vary only the serialized receipt metadata across two production contexts, and assert acceptance at or below the per-event byte limit and `event_too_large` above it. Assert the preview result against its own specified metadata.
2. In A1, remove the statement that the setup automatically relies on `excluded_identity_labels` if Ruler cannot drop the label. Preserve the explicit stop, owner decision, and mandatory drop-run evidence under the current S1. The exclusion mechanism can remain documented without becoming an automatic fallback.

CHANGES_APPLIED: yes

## Rebuttals

- **Critical 1 — partly fixed; no longer blocking.** D8 specifies the nil UUID and call-time preview metadata and explains why production serialization can produce a different byte count. The Mapping preview requirement and C11 label the results and omit the row-budget estimate. This addresses the provenance-dependent sizing problem identified in round 4 (`pipeline.dart:419–436`, `canonical_event.dart:412–464`). The proposal wording and boundary acceptance proof remain open under Moderate finding 1. The estimate must not be restored.
- **Moderate 1 — fixed; accepted by reviewer.** D8 and Resource Bounds cap collection at 100 retained entries, not just the response. D8 orders body diagnostics first, then by alert index, path UTF-8 bytes, and code, and applies the 64 KiB response cut to that prefix. `Dense unmapped subtree` asserts the collector maximum, the body entry followed by 99 alert paths, and the exact overflow count of 199901.
- **Moderate 2 — fixed; accepted by reviewer.** D11 and `Unmapped payload fields` agree that selecting an ancestor covers its leaves even when the field fails. D13 and `Display fields copy or take a constant` distinguish verbatim strings from number and boolean JSON text. `Fields are selected by JSON Pointer` rejects duplicate members before evaluation in both modes. The delta adds the duplicate mapped-member, wrong-typed object with children, and paired seconds-boundary scenarios.
- **Moderate 3 — fixed; accepted by reviewer.** D12 and `Generic decode failures name paths, never values` store `/*` when the first rendered segment does not fit, distinct from the empty root pointer. The delta tests a 300-byte first key and truncation before a multibyte or escaped segment crossing 256 bytes.
- **Moderate 4 — partly fixed.** D18 and the Alertmanager delta require the pinned release × run × status matrix, fixture/manifest correspondence, and sent-alert evidence from both replicas. The manifest includes the query image and digest, and D18 supplies valid URL settings instead of depending on receiver rewriting. Negative scenarios cover a missing matrix cell despite matching files and entries and a missing replica counter increase. The delta gates the support claim and keeps the drop run mandatory; A1’s conflicting fallback clause remains open under Moderate finding 2.
- **Moderate 5 — fixed; accepted by reviewer.** D22 takes the publication advisory lock before replacing the gate, matching the step-5 lock order cited in round 4. `Older publication in flight during the schema step` starts with a version-1 transaction that already inserted its snapshot, requires the step to wait, and checks rejection of a subsequent version-1 insert. D22 distinguishes the new-publication fence from the equal-snapshot no-op and does not treat it as proof that old processes stopped.
- **Moderate 6 — fixed; accepted by reviewer.** C12 carries the enabled-through-drain and binary-downgrade constraints to `Generic sources drain before removal`. C13 carries the per-state-change observation id to `Generic alert identity`; its reused-id scenario demonstrates the lost resolution. The component diagram marks admission unpinned, and the sequence diagram names `EventPointerError` for the sender-pointer branch.
Author's note (required changes applied):

- **Required change 1 — applied.** The proposal's preview bullet and S4 now describe events and decode failures as computed with preview metadata, not a prediction of production results. `Results computed with preview metadata` keeps the label and no-estimate assertions and adds the boundary case: the same sample and mapping, decoded in production with shorter and longer receipt metadata, are accepted and fail `event_too_large` respectively, and the preview result matches a decode under its stated metadata.
- **Required change 2 — applied.** A1 no longer names an automatic fallback: if Ruler cannot drop the label, apply stops and the owner decides; the drop run stays required; `excluded_identity_labels` stays documented as the second option only.

## D13 amendment review (round 6)

Codex (`codex-cli 0.167.0`, isolated read-only route) reviewed the
owner-confirmed D13 amendment and approved with changes, with no critical
findings. All three required changes were applied: retain diagnostic path
bounds and test the `/*` boundary in both modes; cite the alert-state write
and PostgreSQL text column; carry the summary-only exception to the durable
spec and prove NUL is preserved in copied labels and descriptions.
