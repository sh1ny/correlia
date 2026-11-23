# Review

## Metadata

- **Round:** 23
- **Prior round:** round 22 (omp) REVISE: 1 Critical (unqualified macro lookup lets a same-named service variable bypass the helpers), 2 Moderate (capture path cannot deliver 1 MiB or invalid bytes; 202 alone qualifies an architecture).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, all four spec deltas and their baseline specs; project rules, M2 roadmap, named acceptance scenarios, architecture, and ADRs 0016/0017/0020/0021/0024/0028/0029; cited Correlia ingest, pipeline, state, identity, schema, runtime, model and protobuf sources; Alertmanager capture precedent; round 22; upstream Icinga 2 macro resolution, notification dispatch and check-result inputs. Static review only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **Qualified settings still undergo macro expansion before validation.** D3 (`design.md:186–200`) fixes which object supplies each setting, but reads it through `$notification.vars.correlia_*$`. Icinga 2 marks any resolved path beginning with `vars` as recursive, even when qualified, and expands the returned string before `macro()` returns ([`macroprocessor.cpp:149–159,260–279`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/macroprocessor.cpp#L149-L159)). Thus a configured value such as `https://$host.name$` can become a valid authority *before* Correlia checks it. The sender can then post to an object-derived destination with the configured bearer token. TLS authenticates that destination; it does not enforce the literal destination contract. Credential and CA paths can likewise be rewritten before `correlia_exact` sees them. Escaping dollars in the helper’s **output** does not protect its **input**.

### Moderate

1. **The version-matrix test still permits a status-only architecture record.** The support requirement and smoke scenario now require both a 202 and the canonical event decoded from that row. But “Listed release missing a capture” (`integration-icinga2/spec.md:503–505`) only asks the matrix test to reject missing release captures or an absent 202 record. “Every capture decodes” cannot detect a missing artifact. A listed pair can therefore retain its 202, lose its canonical-event evidence, and still pass the specified matrix checks.
2. **D3 still prescribes the infeasible 1 MiB REST burst.** The scenario now uses 512 KiB of output per request (`integration-icinga2/spec.md:93–95`), but D3 Proof (`design.md:268–275`) still calls for 50 outputs of 1 MiB each while requiring each REST request to fit in 1 MiB. The JSON envelope alone makes the design’s version impossible on the default API limit.
3. **The no-visible-change projection scenario omits the source-instance precondition.** D8 and “Same state with different check output” (`integration-icinga2/spec.md:372–374`) promise no version or activity change. Two Icinga2 sources sharing a declared namespace can produce those observations for one fingerprint. `AlertStateService` projects each event’s `sourceInstance`, and `decideTransition` treats a source-instance change as `displayChanged` (`alert_state_service.dart:22–44`; `transition.dart:115–127`). A newer same-state observation from the other source advances the version and writes activity, contrary to the unqualified scenario.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Read operator settings and their presence directly from the bound `Notification` object, without macro expansion. Add a real-Icinga scenario proving a macro-bearing base URL is rejected without a request and a permitted dollar-bearing file path is used literally.
2. Require the version-matrix test to reject a listed pair when its canonical-event evidence is absent, mismatched, or not traceable to the raw row represented by that pair’s 202 record. Add the negative case with a 202 present and the event missing.
3. Align D3 Proof with the 512 KiB REST burst scenario and retain the full encoded request limit.
4. Scope the unchanged-projection assertion to observations from the same source instance. Preserve the existing version and activity behavior when a newer observation changes the projected source instance in a shared namespace.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 22 Critical 1 — helper shadowing:** Addressed. Direct argument functions and qualified inputs remove the reported same-name lookup. Finding C1 is a separate expansion step: the correctly selected setting can still be rewritten.
- **Round 22 Moderate 1 — capture input path:** The spec’s 512 KiB burst fits the REST limit, and the active-check path avoids REST JSON repair before the helper. D3 retains the conflicting burst size.
- **Round 22 Moderate 2 — 202-only qualification:** Addressed in the support requirement and capture scenario. The missing-evidence matrix scenario still does not enforce the new condition.