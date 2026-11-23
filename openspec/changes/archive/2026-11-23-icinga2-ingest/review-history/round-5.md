# Review

## Metadata

- **Round:** 5
- **Prior round:** round 4 (omp) REVISE on the narrowed change: 5 Critical (torn macro read wins the fence; regressing or repeating execution end; no SOFT feed from notifications; kind change strands admitted rows; policy change makes dedup winner decide), 4 Moderate (env function binding; notification_time source; HMAC and diagnostics untested; contract precision).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, all four spec deltas and round 4; baseline `source-ingress`, `durable-pipeline`, `alert-state` and `canonical-event` specs; project rules and listed skills; M2 roadmap, named acceptance scenarios, architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029; cited ingest, pipeline, state, identity, schema, runtime and protobuf sources; archived Alertmanager D6 and capture script; relevant Icinga 2 v2.13.0 sources. Read-only; no runtime tests or captures run.

## Findings

### Critical (blocking)

1. **The revised convergence guarantee still fails for coherent deliveries with strictly increasing check end times.** D4 and “Webhook convergence contract” omit the pipeline’s eligibility and effective-time rules. A coherent reminder for a nine-day-old problem at a newly enrolled source is stored as `late` and cannot create the alert, even though the webhook arrived promptly (`pipeline.dart:29–43,421–424`). Separately, take a coherent CRITICAL at source 10:30 received at 10:02, and its newer OK at source 10:31 received at 10:01. Both are eligible, but the five-minute clamp gives CRITICAL effective time 10:07 and OK 10:06; Correlia ends firing in either processing order (`ordering_key.dart:18–51`). Narrow the contract to eligible state-changing observations whose effective fence order preserves source transition order. Test first delivery of an old problem and reversed receipt under clamping. Do not promise repair on the next state change unless its delivery is eligible, has a fresh observation key and outranks the existing fence. The Failure & Visibility table and “Non-atomic macro reads” bullet still promise convergence or repair that D4 itself disclaims.

2. **Repeated end times can make final alert state depend on worker order, not just receipt order.** D4 explicitly allows non-decreasing end times. Admit coherent CRITICAL A at source time `t`, OK B at the same `t`, and a later refire C also at `t`, received in that order. A and C share D2’s event ID; B does not. If A wins the key insert, B’s later receipt wins the fence and C is a duplicate. If C wins the key insert, C’s receipt wins the fence and A is a duplicate. `pipeline.dart:389–422` gives the worker that inserts the key first control of the ordering evidence, and duplicate handling cannot change the fence (`alert_state_service.dart:168–195`). This contradicts both the convergence requirement and the alert-state delta’s unqualified processing-order guarantee. Explicitly exclude repeated or microsecond-colliding transition times from the webhook guarantee and distinguish ordering distinct committed observations from choosing which delivery supplies their evidence. Add a scenario with the same admitted rows processed in both orders, asserting the resulting fence and status.

### Moderate

1. **Kind immutability does not guarantee decoding after a source is disabled or removed.** D10 fixes wrong-decoder selection, but the source-ingress delta overstates the result. `pinOne` takes the active snapshot at first claim, and `pipeline.dart:285–301` fails with `source_not_configured` if the source is absent or disabled there. A delivery can receive 202 before that publication and fail before it reaches its decoder; replay against the same configuration also fails. State explicitly that immutability preserves decoder selection when the pinned source is configured. Add the admission–disable–first-claim outcome alongside the retained-source case.

2. **Enabling `icinga2` also opens a credential-bearing URL unless the existing path-token switch is restricted.** `source_config.dart:216–225,297–305` accepts `path_token_enabled`, and `ingress.dart:233–267,313–317` handles four-segment credential paths without checking for `alertmanager`. D3 says no route change is needed, but the baseline and operator runbook define that exception only for Alertmanager. An Icinga2 source with a copied path-token setting could accept a bearer credential in a URL outside the documented redaction setup. Keep the exception Alertmanager-only and assert that an Icinga2 path-token request returns 401 without inserting a raw row.

3. **D11 specifies one event per execution but has no execution discriminator.** One dedicated recipient prevents fan-out; it does not make the clock unique. Two command executions for the same object, type and author in one microsecond produce the same ID and drop one action, even if their comments differ. Icinga 2 v2.13.0’s `Utility::GetTime()` uses `gettimeofday` on Linux, and the contract rounds to microseconds regardless. Either specify delivery-stable per-execution evidence or document that same-tick executions coalesce. Test equal timestamps explicitly; capturing two comments with different timestamps cannot demonstrate the stated guarantee.

4. **The documented cutover can strand the first Icinga2 deliveries on an old worker.** The upgrade scenario covers old rows on a new worker. It does not cover a new API publishing and accepting Icinga2 work while an old worker still claims from the shared inbox and unconditionally calls `decodeAlertmanager` (`pipeline.dart:328–356`). Those rows fail rather than waiting for a compatible worker. Document that all old workers must be stopped or upgraded before activating the first `icinga2` source. No mixed-version coordination mechanism is needed for that cutover.

5. **The roadmap still assigns the removed SOFT policy to this change.** `openspec/roadmap.md:31–43` lists per-source soft/hard policy under change 2 and omits it from change 3. Move that bullet as S3 requires; otherwise webhook verification has a milestone obligation the proposal explicitly excludes.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

Resolve Critical 1–2 in D2/D4 and the integration and alert-state specs before freezing IDs. Align source activation, route authentication, non-state identity, upgrade instructions and the roadmap with the moderated findings. Keep Event Streams out of this change.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 4 C1–C2:** The torn-after-coherent test and regressing-end example are now present. The convergence conditions still admit counterexamples, and the next-change language still overpromises repair. See Critical 1–2.
- **Round 4 C3 and C5:** Resolved in scope. SOFT non-OK is informational, no SOFT capture is required, and no revision-selectable policy remains in this change.
- **Round 4 C4:** D10 closes the wrong-decoder path for a UUID retained in the pinned snapshot. Disabled or absent sources are a separate case; see Moderate 1.
- **Round 4 M1:** The function-valued macro binding and nonempty release gate address the design gap. Runtime compatibility remains to be proved by real captures.
- **Round 4 M2:** D11 defines the clock and recipient boundary. It does not establish one event per execution; see Moderate 3.
- **Round 4 M3–M4:** Both real-ingress auth modes, rejected-delivery logging, optional check output, the notification annotation and fixed native-key vectors are now specified. Those acceptance checks were not run.