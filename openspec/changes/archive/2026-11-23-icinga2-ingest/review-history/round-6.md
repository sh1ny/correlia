# Review

## Metadata

- **Round:** 6
- **Prior round:** round 5 (omp) REVISE: 2 Critical (convergence guarantee ignores eligibility and the skew clamp; equal end times make the outcome depend on worker order), 5 Moderate (kind immutability vs disabled source; path tokens on icinga2; same-microsecond non-state executions; old workers at cutover; roadmap SOFT policy bullet).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, all four spec deltas, and round 5; baseline `source-ingress`, `durable-pipeline`, `alert-state`, and `canonical-event` specs; project rules and listed skills; M2 roadmap and named acceptance scenarios; architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028, and 0029; cited ingest, pipeline, state, identity, schema, runtime, alert model, and protobuf sources; archived Alertmanager D6 and capture script. Read-only source review; no tests or captures run.

## Findings

### Critical (blocking)

1. **D4 still promises convergence when the latest state never reaches the fence.** The integration spec requires that every *state-changing delivery* be coherent, eligible, and unclamped. It does not require a delivery representing the latest state. An eligible HARD CRITICAL at `t1` followed by an undelivered OK at `t2 > t1` satisfies the stated delivery conditions; the alert stays firing. A delivered SOFT non-OK sample also cannot establish the object's latest state: `transition.dart:95` ignores `info`.

   Even a promptly admitted, eligible delivery of the latest HARD state can fail to reach the fence. Pause processing, admit CRITICAL promptly, then admit a reminder of the same problem more than seven days later. If the late reminder wins the key insert, `pipeline.dart:389–424` records `late` and suppresses the earlier eligible delivery as a duplicate. With the opposite commit order the alert fires. The reminder is not a new state change, and no transition times collide. Define convergence over **committed, eligible, state-bearing observations**, after deduplication, and require the latest projected state to be represented and to outrank any competing evidence. Add the lost-recovery and ready-versus-late duplicate cases. No fence or Event Streams change is needed.

### Moderate

1. **The alert-state delta describes deduplication at the wrong scope.** “Deliveries that share an observation key are one observation” is false across source instances, fingerprints, and generations. Two sources sharing a namespace can report the same object with the same D2 native key and still produce distinct events. `identity.dart:468–486` includes all three inputs in the event UUID, and `pipeline.dart:393–395` deduplicates by UUID. Say “same event ID,” and qualify the fence scenario to eligible, state-bearing observations; a late or informational winner does not install a fence.

2. **Schema step 4 makes `NULL` ambiguous for data the pipeline already writes.** D5 defines `NULL` as “not clamped,” but existing Alertmanager events could have been clamped in `AlertStateService` while `pipeline.dart:445–458` persisted only the reported time. The additive migration leaves those rows null. A later reader following the spec can use the wrong effective time for retained events. Specify the legacy-row read semantics or a backfill, and prove them with a previously clamped Alertmanager event on upgrade. Compute new rows’ clamp evidence from the same policy used for the fence.

3. **The release gate can pass without ever running the shipped host command.** D3 ships separate host and service definitions, but the real-ingress auth case, sub-second gate, and captured transition sequence exercise only services. A broken host macro binding can therefore ship on a release listed as supported; a synthetic host decoder case would not detect it. Require a real host DOWN → UP capture through the shipped host command for every listed release, with decoded identity, status, and time assertions.

4. **The dotted-field regression vector does not match the failure it claims to prove.** D9 adds documented Icinga2 field names to `_safePath`; neither the existing allowlist nor the webhook document defines `type`. The current `state.type` fixture therefore does not exercise the case where *both* dotted segments would survive the old sanitizer. Use `state.state_type` and assert a persisted single `*`; the old split-and-allowlist path would preserve both names.

5. **Retry safety is stated at the wrong boundary for non-state notifications.** The failure table says retry is safe via deduplication, while D11 assigns a fresh `notification_time` to each command execution. If the inbox commits but the response is lost, rerunning the command can publish a second acknowledgement, downtime, or comment. Limit the claim to resending the same serialized document, with fresh HMAC request metadata if needed. Document that rerunning the command is a new execution, not a delivery retry.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Replace the unconditional latest-object-state promise with the committed-evidence contract in Critical 1, align D4, the proposal, and the operator-facing scenarios, and cover both counterexamples.
2. Correct the deduplication scope and fence scenario, define clamp semantics for upgraded rows, require real host captures, fix the dotted-path vector, and distinguish resending a delivery from rerunning the command.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 5 C1:** The old-problem and reversed-clamp counterexamples are now covered. The revised wording still does not require the latest state to reach the fence; see Critical 1.
- **Round 5 C2:** The equal-time A/B/C case is now explicitly outside the convergence contract and exercises different processing orders. The general dedup statement needs the event-ID scope in Moderate 1.
- **Round 5 M1:** D6 and the source-ingress delta now qualify kind preservation on a configured pinned source and specify `source_not_configured` on disable-before-claim. The proposal’s “always decodes” wording should carry the same qualifier.
- **Round 5 M2–M5:** The path-token restriction, same-microsecond coalescing, worker cutover order, and move of per-source SOFT policy to roadmap change 3 are addressed in the design and specs.