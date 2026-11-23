# Review

## Metadata

- **Round:** 20
- **Prior round:** round 19 (omp) REVISE: 1 Critical (path-token URL reaches argv and Icinga's failure log), 2 Moderate (published fields for author and comment unspecified; arm64 artifact never run by the gate).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, all four spec deltas, four baseline specs, round 19, project rules and relevant skill guidance, M2 roadmap and named acceptance scenarios, architecture and ADRs 0016/0017/0020/0021/0024/0028/0029, cited ingest/pipeline/state/identity/schema/runtime/model/protobuf sources, and the Alertmanager capture precedent. Cross-checked Icinga 2 v2.13.0 argument matching and logging against Boost.Regex. Read-only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **The pre-launch URL filter matches a line, not the whole setting.** D3 (`design.md:157–169`) uses `^…$` with Icinga's DSL `regex()`. [Icinga calls `boost::regex_search` with default flags](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/scriptutils.cpp#L96-L148), and [Boost treats those anchors as line boundaries by default](https://github.com/boostorg/regex/blob/boost-1.74.0/include/boost/regex/v4/perl_matcher_common.hpp#L398-L461). A multiline setting with a valid authority on one line and a credential-bearing URL on another passes the check. `correlia_exact` preserves the whole setting in the JSON argument. The sender correctly rejects the decoded newline, but only after the credential has reached argv and Icinga's failure log. The current real-Icinga cases (`integration-icinga2/spec.md:121–127`) only exercise single-line inputs. Require a whole-input match for both `--base-url` and `--source` before serialization.

### Moderate

1. **The architecture smoke test is specified, but its result is not a required part of the release record.** `integration-icinga2/spec.md:475–505` requires both artifacts in the architecture scenario, but the missing-evidence check and the no-release case still enforce only the five existing gates. A supported-release entry can therefore pass the committed matrix with no ARM64 result. The same scenario requires both architectures for each listed release, while D3 (`design.md:258–260`) allows omitting an architecture without an official image. Define support by release and architecture, and require a recorded 202 from the exact artifact for each advertised pair. Make missing evidence fail qualification.
2. **Successful notifications also expose argv in Icinga logs at Notice level.** D3 (`design.md:239–247`) and the documentation requirement (`integration-icinga2/spec.md:137–146`) describe process-list and failure-log exposure. The [Linux launcher logs the complete command line at Notice level immediately after spawning it](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/process.cpp#L985-L995), irrespective of delivery outcome. An operator enabling Notice logging can persist check output, authors and comments from successful notifications, not just failures. Document that exposure as well.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Enforce whole-input validation of base URL and source in the Icinga DSL before either value enters argv. Add real-Icinga multiline rejection cases with a synthetic credential marker; assert it is absent from the launched arguments and logs, and that no request is made.
2. Make the supported-release statement and evidence check agree on release/architecture pairs. Require evidence of an accepted real notification from the exact artifact for each advertised pair; reject missing evidence and do not advertise an unqualified pair.
3. Document that Icinga's Notice-level process logging can expose notification texts even when delivery succeeds.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 19 C1 — path credential in argv and logs:** The split base URL and source close the reported single-line case. The pre-launch matcher still admits multiline settings; see Critical 1.
- **Round 19 M1 — published author and comment:** Addressed. D11 and the emitted-payload scenario pin `description` and `icinga2.notification_author`, their bounds and omission when empty.
- **Round 19 M2 — ARM64 artifact not exercised:** The real-command smoke test now calls for the exact ARM64 artifact. The supported-release record does not yet require its result; see Moderate 1.