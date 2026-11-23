# Review

## Metadata

- **Round:** 17
- **Prior round:** round 15 (omp) REVISE: 2 Critical (invalid UTF-8 argv from a byte cut stops the Dart runtime before main; DART_VM_OPTIONS parsed before main), 4 Moderate (file bounds are prechecks and sync CA load blocks the deadline; author cut changes identity; Icinga logs argv on failure; double parsing loses microseconds).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, all four spec deltas, round 16, four baseline specs, project rules and listed skills, M2 roadmap and named acceptance scenarios, architecture and ADRs 0016/0017/0020/0021/0024/0028/0029, cited ingest/pipeline/state/identity/schema/runtime/model/protobuf sources, and the Alertmanager capture precedent. Cross-checked Icinga 2 v2.13.0 and Dart 3.13.7 source. Read-only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **The byte cap does not bound the work done inside Icinga before launch.** D3 (`design.md:149–158`) walks the original text with `substr` and claims a 200 KiB output costs no more than a 16 KiB one. Icinga’s [`StringSubstr`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/string-script.cpp#L26-L42) copies the receiver into `String self` on every call; [`String`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/string.cpp#L32-L34) copies its backing string. At one call per ASCII byte, inspecting a 16 KiB prefix of a 200 KiB value copies about 3.1 GiB of input per notification, before assembling the output. [`PluginUtility::ExecuteCommand`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/pluginutility.cpp#L24-L82) resolves arguments before it creates the timed subprocess. Neither deadline protects Icinga’s notification workers from that work. A burst of verbose checks can delay unrelated notifications before any request reaches Correlia. Take the bounded prefix once before iterating, avoid rebuilding the result byte by byte, and qualify the preprocessing path under a burst. A single long-output delivery reaching 202 does not prove this bound.

### Moderate

1. **Two environment scenarios still contradict the launch contract.** `integration-icinga2/spec.md:97–99` promises status 2 for direct execution with *any* environment variable set, including the `DART_VM_OPTIONS=--help` case that Dart handles before `main`. At `:150–152`, the hostile variables are still set on the sender itself, yet the test expects delivery. Use an inert variable for the direct-exec rejection, and put the proxy, CA and key-log variables on the Icinga process for the test through `/usr/bin/env -i`. The corrected runtime-options scenario already demonstrates the right boundary.
2. **The launch budget omits the operator-provided arguments.** D3 (`design.md:120–123,149–171`) caps notification fields, then claims a per-argument maximum and a total argv budget. It does not bound `--url`, credential or CA path arguments, or the sender path, nor state the UTF-8 and NUL constraints for those values. They cross the same C-string boundary before sender validation. A malformed path can name a different file; a sufficiently long setting can fail the first exec even with an empty service environment. Define supported pre-launch bounds and encoding for these settings, and include the settings, terminators, and pointer overhead in the documented budget.
3. **The trusted-directory rule does not cover the files actually read.** D3 (`design.md:208–216`) and `integration-icinga2/spec.md:131–137` restrict directory writability, but a file in such a directory can itself be writable by another user, or a symlink can resolve through an untrusted directory. The path precheck can pass while a different principal controls the bytes read, including the CA that defines whom the sender trusts. Directory permissions also do not make a readable credential file private. Apply the documented trust rule to the full resolved path and file contents, and state who may read credential files. The path-precheck design does not need an opened-descriptor guarantee if those setup constraints are explicit.

### Suggestions

- Remove “changing its kind” from the baseline `source-ingress/spec.md:136–138` rotation-during-read scenario through the delta. D10 makes that publication fail, so it cannot commit during the read or cause the in-flight request to return 401. Keep credential removal, disablement, and path-token revocation in the scenario.

## Verdict

VERDICT: REVISE

## Required Changes

1. Bound copying and computation in the Icinga-side sanitizer before process launch. Qualify verbose-output bursts through the real command and retain the UTF-8, NUL, dollar-sign, and identity assertions.
2. Make both remaining environment scenarios consistent with the pre-`main` runtime boundary and the supported `/usr/bin/env -i` launch path.
3. Include all configured arguments in the pre-exec encoding and size contract. Verify that invalid settings cannot silently select a different file or destination.
4. Document trusted path resolution and file writability for CA and credential inputs, and private readability for credentials. Keep the regular-file guarantee scoped to the path precheck.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 16 C1 — invalid names become valid prefixes:** Addressed in design. Names are rejected before argv construction rather than repaired, and display text and authors replace NUL without dropping the suffix. The real-Icinga scenarios cover both cases.
- **Round 16 M1 — environment and loader scope:** The first-exec loader scope is now explicit, and the runtime-options test places the variables on Icinga. Moderate 1 identifies two remaining scenario contradictions.
- **Round 16 M2 — launch budget:** Names are capped without truncation and the unconditional `E2BIG` claim is gone. Moderate 2 identifies settings still missing from the budget. Critical 1 concerns work before exec, not argv size.
- **Round 16 M3 — opened-file type:** The design now accurately promises a path precheck and caps bytes read. Moderate 3 concerns the deployment assumptions that make that narrower contract safe.