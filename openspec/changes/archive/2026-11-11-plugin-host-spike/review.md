# Review

## Metadata

- **Round:** 5
- **Prior round:** Round 4 returned APPROVE_WITH_CHANGES with CHANGES_APPLIED: no. It required three changes (M1–M3) and made suggestions S16–S19. The author's Round-4 responses (`review.md:151-156`) say all of them were addressed in planning.
- **Reviewer:** cross-model CLI (claude route, claude-opus-5-5)
- **Files read:**
  - **Change:** `openspec/changes/plugin-host-spike/{proposal.md, design.md, specs/external-plugin-host/spec.md, tasks.md, review.md}`, plus `evidence/handshake-and-mtls.md` (grep of its criterion, diagnostic and OpenSSL lines)
  - **Architecture and ADRs:** `openspec/architecture.md` (references to ADR 0022 at 125 and 234), `docs/adr/0022` in full, and the 0014/0018/0020/0021 set as cited in prior rounds
  - **Source:**
    - `correlia_server/lib/plugin.dart`
    - `correlia_server/lib/src/plugin/{plugin_host.dart, plugin_rpc_connection.dart}`
    - `correlia_server/lib/src/plugin/bounded_channel.dart` (structure only)
    - `correlia_server/test/plugin/plugin_host_test.dart`
    - `correlia_server/test/plugin/plugin_transport_test.dart` (its imports and its use of the old switches)
    - Go fixture `config.go`/`runtime.go`/`plugin.go` (grep of the TLS and stall modes)
  - **Feasibility inputs only:** `.dart_tool/plugin-openssl-probe/{openssl_engine.dart, result.json}`. The other probe files were judged as in earlier rounds.
- **What was and wasn't run:** No tests, builds, formatters or analysis, and no files edited. Everything here comes from reading the source. No mapped row is counted green. Prototype outputs are feasibility evidence only. The current in-progress API is not judged against the new boundary: native integration, the authenticated-only export and the config migration are still unticked tasks (`tasks.md:43-47`).

## Findings

### Re-check of Round 4 required changes

**M1 (default-mode rejection rules): resolved in planning.**
- D2 now requires the invalid-startup row to include three default-AutoMTLS negatives (`design.md:39`):
  - group/other-write rejection under an explicit permissive launch umask;
  - an empty certificate field;
  - a health stall behind TLS.
- Task 2.2 repeats all three as verification items (`tasks.md:43`). The inherited umask is no longer part of the test setup.
- Each case can be reached with the existing parts:
  - D6's internal harness selects "controlled negative umasks" and "omitted/wrong identities or pins" (`design.md:77`).
  - The fixture already has a `stall-health` startup mode that is independent of TLS mode (`plugin.go:150-153`, `runtime.go:56`).
  - The host already rejects AutoMTLS sockets with group/other write bits (`plugin_host.dart:285`) and empty certificates (`plugin_host.dart:267`).
- D2 still says plaintext diagnostics are selected "only for criteria 3/4" (`design.md:39`). So the remaining invalid-startup cases implicitly move to AutoMTLS as well. S20 below covers a migration side effect of that, not a reason to block.

**M2 (protocol threshold and OpenSSL configuration): resolved in planning.**
- D2 names TLS 1.3 as the required minimum and gives the reason: the authenticated test must exercise the P-521 signature path that failed, not a TLS 1.2 workaround. D2 also requires asserting the actual negotiated protocol and recording the protocol, backend and configuration selection (`design.md:39`). The summary row matches (`design.md:93`).
- D6 now spells out the configuration policy (`design.md:81`):
  - It keeps OpenSSL's default system/`OPENSSL_CONF` configuration.
  - It records the compiled default configuration directory and the `OPENSSL_CONF`, `OPENSSL_CONF_INCLUDE` and `OPENSSL_MODULES` settings.
  - After context construction, it explicitly reapplies the profile: a fresh pin-only trust store, inherited identity material cleared before the caller's identity is installed, and the required protocol.
  - A configuration that blocks the profile "fails visibly; it cannot produce a passing lower-protocol result".
- Task 2.5 records the configuration policy, source and environment (`tasks.md:46`).
- This closes Round 4's scenario where a host capped at 1.2 passes criterion 2. The prototype's `0x0303` minimum (`openssl_engine.dart:119`) is a known gap the implementation must close, not a claim. S21 notes one remaining wording difference.

**M3 (verification ports off the exported surface): resolved in planning.**
- **Export boundary** (`design.md:77`):
  - `plugin.dart` gets an explicit show-list with only authenticated constructors and configuration.
  - The public `secure`, umask opt-out, trust-pin override and separate advertised-certificate controls are removed, with no compatibility shim. Today these are `plugin_host.dart:15-21`, `38-54`.
  - The advertised certificate is derived from the required identity.
  - Diagnostic mode, negative umasks, omitted/wrong identities or pins and resource ports sit behind a private constructor and an internal harness factory. Neither is reachable through `plugin.dart`, a public configuration or an exported class member.
- **Loader control is failure-only** (`design.md:79`):
  - An enum selects an actual OS-load failure at a fixed path, or a missing symbol in the genuine system library.
  - It cannot accept a library object, a successful loader callback or a replacement verifier.
  - The capability profile can only narrow signature support.
  - This removes Round 4's substitute-library contradiction with "no port bypasses checks".
- **Spec and tasks agree:**
  - The spec requirement says the exported API "SHALL require AutoMTLS and exclude internal test/diagnostic controls; failure controls SHALL NOT supply a substitute verification implementation" (`spec.md:36`).
  - Task 2.4 lists every control to keep off the export, the removal without shims, and a public-import compile smoke as the check (`tasks.md:45`).
  - The ADR 0022 rule that diagnostic mode is test-only (`0022:120-122`) now holds by construction, not by convention.
- **No contradictions found:**
  - Tests already import `src/` directly (`plugin_transport_test.dart:8-9`), so moving the ticked tests to an internal harness is mechanically straightforward.
  - A library-private constructor plus a top-level internal factory hidden by the show-list is valid Dart.

**S16–S19:**
- **S16 (eager symbol resolution): resolved.** All required symbols resolve eagerly before any raw connection or per-connection allocation (`design.md:79`). This replaces the prototype's lazy `late final` lookups (`openssl_engine.dart:18-60`).
- **S17 (inbound bound): resolved.** There is a new scenario (`spec.md:42-44`) and a mapped row (`tasks.md:21`). Task 2.6's count of "nine" matches rows 13–21.
- **S18 (allocation-accounting isolation): resolved.** Allocation accounting runs in a separately spawned process and also tracks real Dart-side staging allocations (`design.md:83`, `tasks.md:47`).
- **S19 (evidence labels and release notes): partly resolved.** Task 2.5 now requires labelling historical diagnostic results as diagnostic-only (`tasks.md:46`). The Release Notes (`proposal.md:59-70`) still omit the OpenSSL 3 runtime dependency and the superseding ADR. The author defers this to the "verified group commit", but no task records that deferral (see S22).

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

- **S20. Say how the remaining diagnostic invalid-startup cases migrate.**
  - Today, 11 cases in the ticked criterion-1 row run with `secure: false` (`plugin_host_test.dart:138`, `164`, `175`, `199`, `212`). D2 limits plaintext to criteria 3/4.
  - **Script cases:** the two scripted cases print an empty certificate field (`plugin_host_test.dart:186`, `190`). If they move to AutoMTLS as written, the empty-certificate check (`plugin_host.dart:267`) rejects them before the path-escape and non-socket checks (`plugin_host.dart:273`, `283-287`). Those checks then lose their test. The cases need to advertise a certificate.
  - **Exact-0600 rule:** the diagnostic exact-0600 rule (`design.md:207`, `plugin_host.dart:286`) is currently tested only by `plugin_host_test.dart:150-161`. If that case moves, give the rule a home in a criteria-3/4 or gate row.
- **S21. Make task 2.3 and the spec assert TLS 1.3, not just record it.**
  - D2 says to assert the negotiated protocol (`design.md:39`). Task 2.3 says "record negotiated TLS/backend version" (`tasks.md:44`), and the spec says "recorded" (`spec.md:29`).
  - Stock Go negotiates TLS 1.3 by default (`result.json:9`), so a carried-over `0x0303` minimum would pass every mapped row on a default host.
  - The "fails visibly" configuration rule (`design.md:81`) has no mapped check.
  - Optional related point: say whether the "fresh pin-only store" covers the verify store a configuration can set as well as the context's own trust store. The exact DER pin check after the handshake (`openssl_engine.dart:283-294`) means this cannot admit a wrong peer.
- **S22. Track the Release Notes update in a task.**
  - Add "update Release Notes for the OpenSSL 3 runtime dependency and the ADR that supersedes 0022" to task 2.3 or 2.4.
  - Without it, the deferred S19 item depends on someone remembering. Line 67 of the Release Notes still describes ADR 0022 as in force (`proposal.md:67-68`).

## Verdict

All three Round-4 required changes check out against the current proposal, design, spec and tasks:
- **M1:** the default-AutoMTLS negatives are named in D2 and task 2.2.
- **M2:** D2 sets a TLS 1.3 minimum, and D6 sets a recorded configuration policy that explicitly reapplies the trust, identity and protocol profile.
- **M3:** D6 and task 2.4 define an authenticated-only curated export, remove the public switches without shims, move controls to a private or internal harness, and make the native fault selector failure-only.

S16–S18 are incorporated, and S19 is partly incorporated. The plan specifies the API migration and its verification (compile smoke, mapped rows, regressions shown red first) without requiring implementation before the design gate. I found no concrete contradictions between the revised requirements. The three remaining items are wording and coverage suggestions (S20–S22).

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

None remain. I independently re-checked Round-4 M1–M3 above against `design.md:39`, `77`, `79`, `81`, `83`, `93`, `97`; `spec.md:36`, `42-44`; and `tasks.md:21`, `43-47`.

CHANGES_APPLIED: yes

## Rebuttals

- **Round-4 M1:** accepted as addressed in planning. S20 records a migration side effect, not a blocking gap.
- **Round-4 M2:** accepted. The TLS 1.3 minimum and the configuration selection/recording are explicit. S21 asks only to align the task and spec wording to "assert".
- **Round-4 M3:** accepted. The authenticated-only show-list, removal without shims, private constructor/internal factory and failure-only loader enum resolve the Round-4 contradiction.
- **S16–S18:** accepted as resolved.
- **S19:** labelling is accepted as resolved. Deferring the release notes is acceptable, but it should be recorded in a task (S22).
- **Feasibility inputs** (`result.json`, allocation probe, historical evidence): accepted as feasibility only. None of them satisfies a mapped row, the revised API or profile, or the backpressure commitments, and no such claim was made.