# Review

## Metadata

- **Round:** 24
- **Prior round:** round 23 (omp) REVISE: 1 Critical (qualified vars macros still expand recursively before validation), 3 Moderate (matrix accepts status-only record; D3 burst size infeasible; projection scenario ignores source instance).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, all four spec deltas, four baseline specs, project rules and listed skills, M2 roadmap and named acceptance scenarios, architecture, ADRs 0016/0017/0020/0021/0024/0028/0029, cited Correlia ingest/pipeline/state/identity/schema/runtime/model/protobuf sources, Alertmanager capture precedent, and round 23. Cross-checked Icinga 2 v2.13.0 macro resolution, notification arguments, and check-output handling. Static review only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **D3 feeds a nonexistent output macro into a string-only helper.** The shipped command reads `$service.long_output$` and the host equivalent (`design.md:186–204`). In stock Icinga 2 v2.13.0, [`Service::ResolveMacro`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/service.cpp) and [`Host::ResolveMacro`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/host.cpp) expose `output`, not `long_output`; there is no reflected field of that name either. [`PluginUtility::ParseCheckOutput`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/pluginutility.cpp) already joins the check’s text lines into one output. The nested `macro()` call returns `Empty` for the missing macro, not a string. D3’s `correlia_text` calls `value.len()` before serialization. Applied as written, argument resolution fails before the sender starts, including on a recovery, and Icinga does not retry it. The same absent-value boundary affects `$service.output$` on a CUSTOM notification before the service has a check result.

### Moderate

1. **The matrix checks for missing gate evidence, but does not require rechecking what present evidence proves.** “Listed release missing a capture” now checks the 202 and its canonical event, but “Every capture decodes” (`integration-icinga2/spec.md:503–513`) asserts only kind, status, severity, and fingerprint. A present same-second CRITICAL → OK → CRITICAL capture with both CRITICAL times rounded to the same second can satisfy those assertions while producing only two event IDs. The release gate says that pair must not qualify; the matrix should enforce the gate’s predicates on the committed evidence, not rely on the capture script having checked them earlier.
2. **The projection scenario is fixed, but its governing wording still contradicts the existing cross-source behavior.** The scenario now uses one source instance (`integration-icinga2/spec.md:372–374`). D8 still states that a new observation of unchanged state records no visible change, and the requirement says projected fields come only from object and state. `AlertStateService` projects the event’s source instance (`alert_state_service.dart:22–44`), and `decideTransition` records `displayChanged` when it changes (`transition.dart:115–127`). For a shared namespace, a newer same-state observation from the other instance advances the version and writes activity. The spec should preserve that behavior explicitly, not just avoid it in the scenario.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Use the native multiline `output` macro in the shipped host and service commands. Handle absent output before invoking the text helper. Keep `long_output` optional at the HTTP boundary if desired, but do not read it from a nonexistent Icinga macro. Prove a real multiline recovery reaches ingress and resolves, and a real CUSTOM notification without check output reaches ingress.
2. Require the matrix to evaluate the five release gates against committed evidence. Add a negative case with all artifacts present and decodable but with collapsed same-second state timestamps and event IDs.
3. Scope D8 and the projection requirement to the summary and check-output behavior they change. Explicitly retain the existing source-instance projection, version increment, and activity entry when a newer observation changes that instance.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 23 C1 — recursive setting expansion:** Addressed in the design. Direct reads of global constants remove the `vars` macro expansion step. The real-Icinga scenario tests both rejection of a macro-bearing base URL and literal use of a dollar-bearing file path.
- **Round 23 M1 — status-only architecture evidence:** Addressed. A 202 without a matching canonical event traceable to its raw row now fails the matrix. Moderate 1 concerns a different case: present, decodable evidence that fails a release gate.
- **Round 23 M2 — infeasible burst input:** Addressed. D3 and the scenario both specify 512 KiB outputs and retain the 1 MiB limit on the whole REST request.
- **Round 23 M3 — source-instance precondition:** Addressed in the scenario, not in D8 or the governing projection requirement.