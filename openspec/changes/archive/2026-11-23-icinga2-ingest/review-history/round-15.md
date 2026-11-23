# Review

## Metadata

- **Round:** 15
- **Prior round:** round 14 (omp) REVISE: 2 Critical (recursive macro expansion of function results; inherited environment shadows command settings), 3 Moderate (author/comment unbounded before launch; whole-run deadline and file input bounds; scenarios not pinned to notification type).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, four spec deltas, and round 14; baseline source-ingress, durable-pipeline, alert-state, and canonical-event specs; project rules and listed skills; M2 roadmap, named acceptance scenarios, architecture, and ADRs 0016, 0017, 0020, 0021, 0024, 0028, and 0029; cited ingest, pipeline, state, identity, schema, runtime, model, and protobuf sources; archived Alertmanager D6 and capture script; Icinga 2 v2.13.0 and pinned Dart 3.13.7 runtime sources. Read-only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **A valid UTF-8 recovery can be dropped before the sender reaches `main`.** D3 (`design.md:126–136`) cuts text by byte count, appends a marker in Icinga, and leaves UTF-8 repair to the sender reading `/proc/self/cmdline`. The pinned Dart runtime converts *every* argv value into a Dart string before invoking `main` ([`main_impl.cc:1062–1074`](https://github.com/dart-lang/sdk/blob/3.13.7/runtime/bin/main_impl.cc#L1062-L1074), [`dartutils.cc:49–70`](https://github.com/dart-lang/sdk/blob/3.13.7/runtime/bin/dartutils.cc#L49-L70)). That conversion rejects invalid UTF-8 ([`dart_api_impl.cc:2911–2924`](https://github.com/dart-lang/sdk/blob/3.13.7/runtime/vm/dart_api_impl.cc#L2911-L2924)). If the cut splits a multibyte character, appending the marker leaves the incomplete sequence *inside* the argument. Reading raw argv in `main` cannot repair it. An otherwise valid RECOVERY can therefore leave its alert firing. The dollar-sign scenario does not require a cut through a multibyte character, so it can pass without finding this.

2. **Moving settings to argv does not make the compiled sender independent of inherited settings.** D3 (`design.md:110–121`) sets no command environment. Icinga copies its inherited environment into the child ([`process.cpp:104–136`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/process.cpp#L104-L136)), and the pinned Dart executable parses `DART_VM_OPTIONS` before `main`, explicitly including executables with appended AOT snapshots ([`main_impl.cc:1197–1225`](https://github.com/dart-lang/sdk/blob/3.13.7/runtime/bin/main_impl.cc#L1197-L1225)). Startup options can bypass application startup, including a successful help exit. That breaks the core invariant that exit 0 means Correlia returned 202: Icinga can report command success without a request. The proposed environment tests do not cover the AOT launcher.

### Moderate

1. **The file limits are prechecks, not read limits, and the deadline does not cover synchronous I/O.** D3 (`design.md:158–162`) checks path type and size before open. A regular file that grows after `stat` can exceed the size cap if read to EOF; a path replaced between check and open can invalidate both checks. The 10-second Dart timer cannot run while its isolate is blocked doing synchronous I/O, and the pinned [`SecurityContext.setTrustedCertificates(path)`](https://github.com/dart-lang/sdk/blob/3.13.7/sdk/lib/io/security_context.dart#L96-L117) explicitly reads synchronously. A static FIFO and a silent HTTP peer do not test either gap. Cap bytes during the read, tie file validation to the opened input, and specify an outer Icinga timeout if the command must also be bounded when the isolate cannot run.

2. **The author display cut changes observation identity.** D2 and D11 key non-state events by type, time, and author. D3 (`design.md:127–134`) now feeds the marked prefix into that key. Two distinct authors with the same prefix and command timestamp produce one event; D11's existing same-microsecond coalescence applies to the *same author*, as the spec's scenario confirms. This conflicts with the canonical rule that oversize identity inputs are hashed in full, not truncated. Separate display truncation from author identity evidence, or explicitly change the key contract before publishing the vectors.

3. **The argv change sends notification text to persistent Icinga logs on delivery failure.** D3 documents visibility in process listings and bounds the sender's stderr. Icinga's failure handler also prints the complete command arguments ([`pluginnotificationtask.cpp:82–91`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/methods/pluginnotificationtask.cpp#L82-L91)). A 401 or 503 therefore logs check output, author, and comment independently of the sender's sanitized line. During an outage this adds tens of KiB per failed notification and extends access to sensitive monitoring text. State this in the runbook and test the actual Icinga log boundary rather than treating sender stderr as the whole diagnostic surface.

4. **The timestamp parser can round away evidence inside its advertised range.** D2 (`design.md:83–101`) accepts fractional JSON numbers up to year 10000 and derives key microseconds by multiplication and rounding. If the JSON number is first parsed as a Dart `double`, `8589934592.000001` and `8589934592.000002` round to the same binary value before that multiplication. The decoder then gives two distinct reported microseconds the same source time and, with the other inputs equal, the same native key. The current release captures exercise contemporary timestamps and cannot catch this. Specify exact decimal-to-microsecond conversion over the accepted range or narrow the range and test its precision boundary.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Ensure notification text is valid UTF-8 before it enters the compiled sender's argv. Prove that a real RECOVERY with both literal dollar signs and a multibyte character crossing the byte cut is delivered and resolves the alert.
2. Make the supported launch boundary neutralize Dart runtime environment overrides before AOT startup. Test the compiled binary through Icinga and verify that no runtime option can produce exit 0 without a 202.
3. Enforce file type and byte bounds on the inputs actually read, remove blocking path-based CA loading from the deadline isolate, and prove the time bound at the file-read boundary as well as at the socket.
4. Preserve distinct full-author evidence when only the display prefixes are equal, or revise the non-state identity contract explicitly before freezing it. Test equal-prefix authors at the same microsecond.
5. Document and verify what Icinga logs from argv on failure, including the exposure of notification text and the continued exclusion of credential values.
6. Make timestamp conversion preserve distinct microseconds over the advertised input domain and add exact boundary vectors.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 14 C1 — recursive macro expansion:** Dollar doubling addresses the cited recursive scan. Critical 1 is a separate launcher failure at the same truncation boundary.
- **Round 14 C2 — inherited Correlia settings:** Argv makes command settings authoritative over inherited `CORRELIA_*`, including omitted optionals. Critical 2 is the pinned runtime's separate pre-`main` environment path.
- **Round 14 M1 — oversized author and comment:** Both now have pre-launch bounds. Moderate 2 remains open because the author cut changes key equality.
- **Round 14 M2 — deadline and file bounds:** The silent-peer and static-FIFO scenarios cover their specific cases. Moderate 1 remains open for the actual read and a blocked isolate.
- **Round 14 M3 — state-mapping scenarios:** Resolved in the spec. “Unreachable host” specifies HARD `PROBLEM`; “Soft recovery resolves” specifies `RECOVERY` with SOFT OK.