# Review

## Metadata

- **Round:** 8
- **Prior round:** round 7 (omp) REVISE: 3 Critical (version 1 snapshots have no kind; NOT NULL column breaks old workers at step 4; release gate can pass whole-second timestamps), 2 Moderate (effective-time precision and consumers; delayed-notification and recovery scenarios not aligned with the contract).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, four spec deltas, and round 7; baseline ingress, pipeline, alert-state, and canonical-event specs; project rules and listed skills; M2 roadmap and named acceptance scenarios; architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028, and 0029; cited ingest, pipeline, state, identity, schema, runtime, alert-model, and protobuf sources; historical snapshot fixture; archived Alertmanager D6 and capture script; upstream Icinga 2 notification macro source. Read-only review; no tests or captures run.

## Findings

### Critical (blocking)

1. **The shipped command and decoder disagree on downtime cancellation.** D3 (`design.md:124`) lists `DOWNTIMEREMOVED`. Icinga 2 v2.13.0 exposes `$notification.type$` through `NotificationTypeToStringCompat` (`lib/methods/pluginnotificationtask.cpp:34–35,50`), which returns [`DOWNTIMECANCELLED`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/notification.cpp#L634-L646) for `NotificationDowntimeRemoved`. The spelling also appears in v2.14.0 and v2.15.0. D3 specifies no sender translation, so the documented decoder rejects the cancellation as `unsupported_type` after ingress has returned 202. The capture requirement can pass with a downtime start alone. Define the v1 wire token before freezing the key domain, and require a real cancellation capture that commits and routes an informational `downtime` event without changing alert state.

### Moderate

1. **The release gate still permits whole-second `notification_time`.** The same-second host and service scenarios check `last_state_change` only. “Two comments from one author” can pass with comments in different seconds, even if `notification_time` uses a whole-second clock. Two CUSTOM executions for the same object and author in one second would then collapse into one event, rather than only coalescing at the documented microsecond resolution. Require the two captured executions to share an integer Unix second and carry distinct microsecond notification times. Make qualification explicitly per release: every listed release must pass both state-time gates and the notification-time gate, not merely leave the supported list nonempty.
2. **Step 4 has no operating bound for a populated deployment.** D5 rewrites every `events` row and enforces `NOT NULL` in the transaction that holds the startup schema lock (`schema_steps.dart:60–82`). The backlog test and one-row backfill test do not establish a viable cutover: at this milestone, event retention is still ahead, and the rewrite needs space for new row versions and WAL. A disk or statement limit can roll back the entire step and leave upgraded workers unable to start. Specify the lock and disk implications, a preflight and recovery procedure, and a representative populated-upgrade check. If the measured outage or space cost is unacceptable, change how the value is introduced rather than relying on repeated startup attempts.
3. **D5 gives correlation windows two clocks.** It says the SQL column serves correlation windows, then says operational windows use observed time. ADR 0017 uses observed time for windows, while the existing ORD-4 acceptance wording also says the clamp is used for operational expiry. Those clocks are not interchangeable: an observation received at 10:00 with a clamped effective time of 10:05 falls on opposite sides of a 10:03 boundary. Align D5 and ORD-4 with ADR 0017: persist effective time for queries and ordering evidence, and use observed time for operational expiry, windows, and reminders.
4. **Two ordering scenarios can pass without exercising the claimed fence behavior.** “Delayed notifications in any order” asserts only final `firing`; retaining the first CRITICAL and discarding the refire gives the same result. “Same state with different check output” asserts no visible change, which a stale or discarded second event also satisfies. Assert that the final CRITICAL owns the fence in every permutation, and that the same-state update advances the fence without changing the alert version or writing activity.
5. **The new decoder does not specify the pre-parse bound for malformed JSON.** The document is flat, but the worker still has to parse a rejected object or array before checking field types. The 1 MiB ingress limit does not bound nesting. The existing Alertmanager decoder checks depth before `jsonDecode` (`alertmanager_decoder.dart:47,372–395`), and the pipeline's validation path catches `EventValidationError` (`pipeline.dart:354–355`). Require an equivalent pre-parse guard and a bounded validation outcome for deeply nested input, rather than letting it enter the internal retry path.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Align the downtime cancellation wire token with the shipped command and prove the real cancellation path through output routing.
2. Gate each supported release on same-second host and service state-time captures and a same-second non-state notification-time capture.
3. Define and verify an operationally viable step-4 cutover, including lock duration, disk headroom, and recovery after interruption or failure.
4. Align D5 and ORD-4 with ADR 0017 on the clocks used by ordering and operational consumers.
5. Assert fence ownership and fence advancement in the two ordering scenarios.
6. Bound webhook JSON nesting before parsing and verify the bounded failure outcome.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 7 C1 — historical snapshots:** Resolved in the design. D6 and the pipeline delta distinguish a historical v1 source with no kind from a malformed v2 source; the unchanged historical signing-key e2e case remains required.
- **Round 7 C2 — old worker inserts:** Resolved in the design. All old event writers stop before any upgraded role applies step 4, and pending work resumes under upgraded workers. Migration size and failure recovery are separate from mixed-version compatibility.
- **Round 7 C3 — whole-second state timestamps:** Resolved for the stated host and service vectors. Both compare two problem samples in the same integer Unix second and require distinct increasing microsecond evidence. The separate `notification_time` gate remains open.
- **Round 7 M1 — effective-time precision:** Resolved for storage precision. The SQL projection is microsecond-resolution; exact fence comparisons retain nanoseconds. The operational clock wording remains inconsistent.
- **Round 7 M2 — convergence and recovery preconditions:** Resolved. The scenarios now qualify eligibility, clamping, and rank; recovery requires a new eligible event ID that outranks the fence. The remaining gap is what the ordering scenarios assert.