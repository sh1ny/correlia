# Review

## Metadata

- **Round:** 19
- **Prior round:** round 15 (omp) REVISE: 2 Critical (invalid UTF-8 argv from a byte cut stops the Dart runtime before main; DART_VM_OPTIONS parsed before main), 4 Moderate (file bounds are prechecks and sync CA load blocks the deadline; author cut changes identity; Icinga logs argv on failure; double parsing loses microseconds).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, all four spec deltas and relevant baseline specs, round 18, project rules and listed skills, M2 roadmap and named acceptance scenarios, architecture, ADRs 0016/0017/0020/0021/0024/0028/0029, cited ingest/pipeline/state/identity/schema/runtime/model/protobuf sources, and the Alertmanager capture precedent. Cross-checked Icinga 2 v2.13.0 argument resolution and failure logging, and Boost string replacement. Read-only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **A path credential still reaches argv and Icinga’s failure log.** D3 (`design.md:156–161,208–215`) screens the configured URL for `@`, `?` and `#` before argv, but does not constrain the path. An operator adapting the documented Alertmanager path-token URL (`docs/ingest-pipeline.md:115`) can change the integration segment to `icinga2` and leave `/<token>` on the end. That URL passes the pre-launch check. Ingress rejects it with 401 under D12, and [Icinga’s failed-command handler](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/methods/pluginnotificationtask.cpp#L66-L76) logs the full argv, including the reusable token. D12 protects admission, not the log. Enforce the credential-free `/hooks/icinga2/<source-uuid>` path before constructing argv, or construct the path from a validated source UUID. Add a real-command rejection case for a copied path-token URL.

### Moderate

1. **The versioned output contract does not say where author and comment are published.** `integration-icinga2/spec.md:253–257` names `annotations["icinga2.notification_type"]`, but `:409–423,445–449` requires only “bounded author and comment.” The frozen event has no dedicated author or comment field; annotations and description have different bounds (`proto/correlia/event/v1/event.proto`, `CanonicalEvent`). One implementation could put the comment in `description`, another in an annotation, and both could pass the current scenarios. Consumers would read different fields and get different truncation. Define the exact published fields, omission rules and bounds, then assert them on emitted canonical payloads.
2. **The release gate can pass without executing the ARM64 artifact.** The sender must ship for both `linux-x64` and `linux-arm64` (`integration-icinga2/spec.md:58–62`), but D3’s proof and the supported-release gate are keyed only by Icinga release (`design.md:247–255`; `integration-icinga2/spec.md:459–469`). All five gates could pass on x64 while the ARM64 artifact fails to launch or deliver. Require at least one real Icinga launch and accepted POST using each exact release artifact. State support by architecture where the qualified environments differ; no need to duplicate the decoder matrix.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Keep path credentials out of Icinga argv and failure logs by validating or constructing the credential-free route before launch. Prove rejection through the shipped command.
2. Specify and test the canonical output fields, omission rules and bounds for notification author and comment.
3. Gate each shipped architecture’s artifact on a real-command launch and accepted delivery.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 18 C1 — NUL in a file path:** Addressed in the design. Decoded settings are checked before filesystem or network operations, and the new scenario uses a valid prefix file.
- **Round 18 M1 — quadratic dollar handling:** Addressed in the design. Icinga’s DSL `String#replace` uses Boost `replace_all`, which buffers replacements rather than shifting the remaining string for every match. The macro pass receives no literal `$`; the burst includes dollar-only inputs.
- **Round 18 M2 — burst confounded by ingress caps:** Addressed. The recording receiver admits all 50 requests independently of production limits; the signed-overload scenario remains separate.
- **Round 18 M3 — missing cancellation evidence:** Addressed. Downtime cancellation is one of the five listing gates, missing evidence fails the matrix, and the no-release case uses the same gates.
- **Round 18 M4 — credentials in the URL:** Userinfo, query and fragment are screened before argv. Path credentials are not; Critical 1 identifies the remaining leak.