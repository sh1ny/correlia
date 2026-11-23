# Review

## Metadata

- **Round:** 18
- **Prior round:** round 15 (omp) REVISE: 2 Critical (invalid UTF-8 argv from a byte cut stops the Dart runtime before main; DART_VM_OPTIONS parsed before main), 4 Moderate (file bounds are prechecks and sync CA load blocks the deadline; author cut changes identity; Icinga logs argv on failure; double parsing loses microseconds).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, all four deltas and their relevant baseline specs, round 17, project rules and listed skills, M2 roadmap and named acceptance scenarios, architecture, ADRs 0016/0017/0020/0021/0024/0028/0029, cited ingest/pipeline/state/identity/schema/runtime/model/protobuf sources, and the Alertmanager capture precedent. Cross-checked Icinga 2 v2.13.0 and Dart 3.13.7 source. Read-only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **A NUL in a credential or CA path still selects a different file.** D3 (`design.md:153–161`) preserves U+0000 through `Json.encode` and `Json.decode`, but rejects it only in object names. A file setting containing `/etc/icinga2/correlia-ca.pem` followed by NUL and `-next` satisfies the exact round-trip check and is nonempty. Dart’s [path conversion](https://github.com/dart-lang/sdk/blob/3.13.7/sdk/lib/io/file_system_entity.dart#L673-L687) preserves the interior zero, and its [asynchronous native open](https://github.com/dart-lang/sdk/blob/3.13.7/runtime/bin/file.cc#L823-L839) passes the buffer as `const char*` to [Linux file handling](https://github.com/dart-lang/sdk/blob/3.13.7/runtime/bin/file_linux.cc#L230-L259). The precheck and open can therefore both succeed against the prefix, loading an unintended credential or CA. This requires no file swap and is not mitigated by mode checks. Reject NUL in decoded settings before any file precheck or connection. Extend “Setting not deliverable exactly” to prove that a NUL-bearing path fails even when its prefix names a valid file.

### Moderate

1. **Dollar-heavy output still triggers quadratic work before the command timeout starts.** The raw-output byte walk is gone, but D3 (`design.md:146–152,174–182`) doubles every `$` and then relies on Icinga to undo the doubling. [`InternalResolveMacros`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/macroprocessor.cpp#L217-L307) shrinks the same string once per pair, and [`String::Replace`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/string.cpp#L219-L222) delegates to `std::string::replace`. With an 8 KiB prefix of dollar signs, the replacements alone move roughly 64 MiB of string tails for one field. [`PluginUtility::ExecuteCommand`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/pluginutility.cpp#L24-L82) does this before it starts the timed process. Encode literal dollars in the JSON literal as `\u0024` instead; Dart will recover the same text without Icinga rewriting it. Use dollar-heavy values in the real-command burst test.
2. **The verbose-burst scenario can fail on admission limits without exercising the regression it names.** `integration-icinga2/spec.md:93–95` requires 50 overlapping notifications to receive 202 without defining the receiver, auth mode, or admission budget. Real ingress permits 16 in flight and only two signed requests per source (`ingress.dart:179–188`); the default source burst is 40 (`source_config.dart:43–46`). The same command can pass or fail depending on receiver scheduling. Use a dedicated recording receiver for the preprocessing burst, with explicit capacity for all 50 and assertions on every body; retain the separate real-ingress admission and overload scenarios.
3. **The release gate does not require the downtime evidence it says each listed release has.** `integration-icinga2/spec.md:451–477` makes four clock/state checks explicit listing gates and uses only those four in “No release passes.” The cancellation scenario separately requires a `DOWNTIMECANCELLED` capture from every listed release. “Every capture decodes” can pass on an incomplete fixture set because it only checks files that exist. Require a cancellation capture for every listed release, fail the matrix on missing evidence, and use the same gate list for publication and “No release passes.”
4. **A credential embedded in the configured URL reaches argv and failure logs.** D3 validates the scheme and loopback condition (`design.md:200–208`), but does not rule out URL userinfo or query credentials before placing the URL in argv. Real ingress rejects query strings (`ingress.dart:178`), and [`PluginNotificationTask`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/methods/pluginnotificationtask.cpp#L66-L76) logs the full failed command, including the URL. Reject credential-bearing URL forms before argv construction, not only in the sender, and document the credential-free route shape. The server’s existing URL validator already rejects userinfo, query, and fragment (`bootstrap.dart:516–525`).

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Reject NUL-bearing decoded settings before filesystem and network operations; prove that a valid path prefix is not used.
2. Remove per-dollar macro rewriting and exercise a dollar-heavy burst through the shipped command. Qualify preprocessing independently of production admission caps.
3. Enforce the complete per-release evidence set, including downtime cancellation, in both the fixture matrix and the publication gate.
4. Keep credential-bearing URL forms out of argv and Icinga’s failed-command log; verify with a real-command rejection scenario.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 17 C1 — pre-launch work:** The full-input byte walk is removed. `StringLen` and `StringSubstr` still copy the receiver, so the “one copy” claim is inaccurate, but those are a fixed number of full-input copies. Moderate 1 identifies the remaining repeated rewrite on the bounded prefix.
- **Round 17 M1 — environment scenarios:** Addressed. Direct execution uses an inert variable; hostile runtime and transport variables are set on Icinga and exercised through the shipped command.
- **Round 17 M2 — configured arguments:** The size budget now includes the settings, sender path, terminators, and pointers. Invalid UTF-8 is handled before launch; Critical 1 identifies the remaining exactness failure after decoding.
- **Round 17 M3 — file trust:** Addressed. The documented trust boundary covers resolved symlink targets and file ownership, and the mode checks reject exposed credential files and writable CA files without claiming descriptor-level verification.
- **Round 17 suggestion — credential rotation:** Addressed. The delta removes kind changes from the rotation-during-read scenario and retains credential revocation, disablement, and path-token revocation.