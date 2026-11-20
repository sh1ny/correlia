# Review

## Metadata

- **Round:** 25
- **Prior round:** round 24 (omp) REVISE: 1 Critical (nonexistent `long_output` macro and absent output break the text helper), 2 Moderate (matrix does not re-evaluate gate predicates; D8 wording contradicts source-instance projection).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, four spec deltas, four baseline specs, round 24 and relevant earlier findings, project rules and applicable skill guidance, M2 roadmap and acceptance scenarios, architecture and ADRs 0016/0017/0020/0021/0024/0028/0029, cited Correlia ingest/pipeline/state/identity/schema/runtime/model/protobuf source, and the Alertmanager capture precedent. Cross-checked Icinga 2 v2.13.0 source. Static review only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

None.

### Moderate

1. **A delayed service notification can permanently attach the previous check’s output to the refire event.** D3 reads `$service.output$` (`design.md:195`), and the projection publishes it as the description (`integration-icinga2/spec.md:366–370`). Icinga’s [`Notification::BeginExecuteNotification`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/notification.cpp#L443-L450) queues the triggering check result. [`Service::ResolveMacro`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/service.cpp#L223-L264) reads `state` from the live service but `output` from that queued result. In the design’s refire scenario, the delayed RECOVERY can therefore publish a CRITICAL event whose description says `OK: disk recovered`. The subsequent PROBLEM is deduplicated, so its actual failure text never reaches outputs. The alert fence is correct; the published diagnostic is misleading.
2. **The release matrix still omits the exact-value predicate of the production clock gate.** “Production notification clock keeps microseconds” requires both exact round trips for known inputs and a live sample whose microsecond part is not a multiple of 10 (`integration-icinga2/spec.md:269–271`). “Every capture decodes” requires only the live-sample predicate for that gate (`:511–513`). A formatter that shifts every timestamp by one microsecond can still produce three event IDs, distinct same-second notification times, and a sample not divisible by 10. The matrix would qualify evidence that fails the exact-value scenario and changes the frozen event IDs.
3. **The 15-second Icinga timeout starts termination; it does not guarantee the sender has been killed.** D3 calls it an outer bound and says it kills a stalled sender at 15 s (`design.md:140–141,261,583`). On Linux, Icinga’s [`Process::DoEvents`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/process.cpp#L1037-L1070) sends SIGTERM at that threshold. [`GetNextTimeout`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/process.cpp#L1200-L1206) schedules SIGKILL at `1.1 × timeout`, nominally 16.5 s here. A child that does not exit on SIGTERM can remain alive past the stated outer bound.
4. **The source configuration does not reject an identity option that Icinga2 cannot honor.** `_parseSource` currently accepts and parses `excluded_identity_labels` for every source (`source_config.dart:216–225,270–280`). D12 makes path tokens Alertmanager-only, but neither the ingress delta nor the decoder design restricts this other Alertmanager option. An operator can copy a source template with `excluded_identity_labels: ["service"]`, publish it successfully, and still get separate alerts by service because the Icinga2 fingerprint always includes the service name. Reject the inapplicable option rather than letting activation imply it took effect.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Source the service description from the live object’s last check result rather than the queued trigger, or explicitly define and expose the description as trigger-time evidence. Extend the delayed RECOVERY-after-refire scenario with different OK and CRITICAL outputs and assert which description is published after deduplication. Do not promise atomic reads.
2. Require the matrix to compare every committed known timestamp input with its decoded output for both shipped commands, in addition to checking live clock resolution. Add a negative fixture with distinct same-second times and event IDs but a one-microsecond mismatch against a known input.
3. Distinguish the sender’s 10-second deadline from Icinga’s SIGTERM and SIGKILL thresholds. Document 15 s as the configured termination threshold and 16.5 s as the nominal Linux escalation threshold, not an exact wall-clock kill guarantee.
4. Scope `excluded_identity_labels` to Alertmanager at bootstrap validation. Add a scenario that rejects it on an `icinga2` source with a bounded field error and leaves the prior snapshot active.

CHANGES_APPLIED: yes

## Rebuttals

- **Round 24 C1 — nonexistent `long_output` and absent output:** Addressed. The command uses the multiline `output` macro, omits absent text, and requires real multiline recovery and no-output CUSTOM captures. Moderate 1 concerns which check result supplies valid output, not whether the macro exists.
- **Round 24 M1 — matrix only checked evidence presence:** The matrix now re-evaluates gate evidence and rejects the collapsed same-second state capture. Moderate 2 identifies a remaining predicate omitted from that re-evaluation.
- **Round 24 M2 — cross-source projection:** Addressed. D8 scopes the no-visible-change case to one source instance and explicitly preserves version and activity changes when a newer observation changes the projected source instance.