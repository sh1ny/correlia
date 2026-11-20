# Review

## Metadata

- **Round:** 21
- **Prior round:** round 20 (omp) REVISE: 1 Critical (line anchors admit multiline settings), 2 Moderate (architecture evidence not required in the release record; Notice-level launch logging undocumented).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, all four spec deltas and four baseline specs; project rules and listed skills; M2 roadmap and named acceptance scenarios; architecture and ADRs 0016/0017/0020/0021/0024/0028/0029; cited ingest, pipeline, state, identity, schema, runtime, model and protobuf sources; Alertmanager capture precedent; round 20 and relevant earlier findings. Cross-checked Icinga 2 notification dispatch, macro resolution and string handling against upstream source. No tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **The release gate requires a token that the stock downtime-removal path does not emit.** `integration-icinga2/spec.md:483–488,502–504` requires an actual cancellation to produce `DOWNTIMECANCELLED` before a release can qualify. The enum-to-string table cited in round 8 is not evidence that cancellation dispatches that enum. In [Icinga 2 v2.13.0](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/checkable.cpp) and [v2.16.6, the latest published release checked](https://github.com/Icinga/icinga2/blob/v2.16.6/lib/icinga/checkable.cpp), `Checkable::StaticInitialize` connects `Downtime::OnDowntimeRemoved` to `NotifyDowntimeEnd`. That handler requests `NotificationDowntimeEnd` for a triggered downtime and sends nothing for one that never triggered. `PluginNotificationTask::ScriptFunc` passes that enum through `NotificationTypeToStringCompat`, which renders it `DOWNTIMEEND`. With the shipped command forwarding the macro unchanged, the gate rejects releases with this dispatch path even though Correlia receives and can route their downtime-end event. Nor can the webhook distinguish cancellation from expiry on those releases.

### Moderate

1. **The shipping contract still requires both binaries even if only one architecture qualifies.** `integration-icinga2/spec.md:58–63` unconditionally requires shipping linux-x64 and linux-arm64. D3 Proof (`design.md:255–264`) forbids shipping an artifact with no qualifying pair, while the release record permits a nonempty list containing only one architecture (`integration-icinga2/spec.md:483–496`). If x64 qualifies and arm64 does not, shipping arm64 violates D3 and omitting it violates the spec. Keep both build targets, but make publication conditional per architecture.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Align the downtime mapping, setup documentation and release gate with actual dispatch. Capture expiry and manual removal of an already-triggered downtime through the shipped command. On releases that emit `DOWNTIMEEND` for both, assert both route as informational downtime events without changing alert state and document that the webhook cannot tell them apart. Require `DOWNTIMECANCELLED` only where real dispatch evidence establishes it; do not synthesize it for the gate.
2. Separate build targets from shipping requirements. Require publication only for architectures with at least one qualified release pair, and cover the case where exactly one architecture qualifies.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 20 C1 — multiline settings:** Addressed in design. Both DSL patterns use Boost buffer anchors `\A` and `\z`, and the real-Icinga scenario checks argv, logs and absence of a request.
- **Round 20 M1 — missing architecture evidence:** Addressed in the release record. Each advertised pair requires a recorded 202 from the exact artifact, and missing evidence fails the matrix. The unconditional shipping clause remains inconsistent with that policy; see Moderate 1.
- **Round 20 M2 — Notice-level launch logging:** Addressed. D3 and the documentation requirement name launch logging for successful deliveries as well as the failure log and process list.