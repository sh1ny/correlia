# Review

## Metadata

- **Round:** 22
- **Prior round:** round 21 (omp) REVISE: 1 Critical (gate required DOWNTIMECANCELLED, which stock removal does not send), 1 Moderate (unconditional shipping of both architectures).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, all four spec deltas and four baseline specs; project rules and relevant skill guidance; M2 roadmap and named acceptance scenarios; architecture and ADRs 0016/0017/0020/0021/0024/0028/0029; cited Correlia ingest, pipeline, state, identity, schema, runtime, model and protobuf sources; Alertmanager capture precedent; round 21 and related prior findings. Cross-checked Icinga 2 notification dispatch, macro resolution and capture inputs against upstream source. No tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **An unqualified macro can bypass the command’s timestamp helper.** D3 (`design.md:186–193`) binds the function as `$correlia_last_state_change$`. Icinga’s [`ResolveMacro`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/macroprocessor.cpp#L81-L107) selects the first matching custom variable, and [`PluginNotificationTask`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/methods/pluginnotificationtask.cpp#L39-L55) places user, notification, service and host before command. A service variable with that name and a valid six-decimal value bypasses the helper without a validation error. For a prompt HARD CRITICAL → OK → HARD CRITICAL sequence, both CRITICAL deliveries then get the same event ID: the recovery can resolve the alert and the final problem is discarded as a duplicate. The same lookup ambiguity affects any text or setting helper bound this way.

### Moderate

1. **The capture harness can reject or repair test inputs before they reach the command.** The verbose-burst scenario (`integration-icinga2/spec.md:93–95`) calls for 1 MiB of output per passive check. Icinga 2 v2.13.0’s [`EnsureValidBody`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/remote/httpserverconnection.cpp) limits the *whole REST body* to 1 MiB for an ordinary API user, so the JSON envelope pushes each request over the limit. Separately, if the invalid-UTF-8 scenario uses that REST path, [`JsonDecode`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/json.cpp) repairs the bytes before `ProcessCheckResult` sees them. The burst can fail before any notification is queued, and the UTF-8 case can pass without exercising the sender’s repair path.
2. **A 202 alone can qualify an architecture whose notifications fail processing.** The five gates are release-level, while the per-architecture check requires only one 202 (`integration-icinga2/spec.md:494–505`). Real ingress returns 202 after raw admission, before decoding (`openspec/specs/source-ingress/spec.md:41–46`). A valid x64 capture set plus an arm64 artifact that posts a document with a missing required field can therefore qualify both pairs, even though the arm64 row fails in the worker.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Bind generated argument values and presence predicates explicitly to the shipped command’s helpers, rather than unqualified resolver lookup. Capture a real notification with a same-named service variable and prove the command still sends the actual state-change time and preserves all three event IDs.
2. Specify a capture path that delivers the intended large and invalid-byte inputs to the command. For REST-driven bursts, fit the full request inside the upstream limit or explicitly configure sufficient capacity in the isolated capture instance. Inject the invalid-byte vector after REST JSON decoding and verify that the malformed bytes reach the sender’s encoding helper.
3. For every advertised release/architecture pair, require the exact artifact’s smoke delivery to receive 202 **and** produce the expected canonical event. Fail qualification if that raw row fails decoding.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 21 Critical 1 — downtime token:** Addressed. The gate covers expiry and manual removal of triggered downtime using the token the release emits. Both upstream versions checked dispatch `DOWNTIMEEND`; untriggered removal sends nothing.
- **Round 21 Moderate 1 — artifact publication:** Addressed. Both targets are built, but publication is conditional per architecture, with a one-architecture scenario. The remaining finding concerns what qualifies a pair, not which artifacts are published.