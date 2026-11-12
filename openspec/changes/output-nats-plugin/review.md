# Review

## Metadata

- **Round:** 5
- **Prior round:** Round 4 returned REVISE for hidden per-output waiting demand and rotation interrupting circuit probes. The owner authorized both fixes and another review.
- **Reviewer:** Fresh-context OMP reviewer.
- **Reviewed:** Proposal, design, previous review, all five specification deltas, requested existing specifications, architecture, M1 roadmap, DUR-3/DUR-8, in-force ADRs, D24, and cited source.
- **Tier:** FULL.
- **Method:** Read-only artifact and source inspection. No files changed; no builds or tests run.

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

None.

## Verdict

VERDICT: APPROVE

The revised scheduling policy addresses both round 4 findings. No remaining design-level issue was found that blocks correct implementation.

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

- **R4-C1 — Fixed; accepted by reviewer.** D7 now detects waiting demand independently of admission eligibility, ignoring both caps. Per-output contention triggers handover within that output even when worker capacity remains available. The Resource Bounds row agrees, and **Five busy definitions of one output** explicitly exercises the previously stranded fifth definition with twelve worker slots free.
- **R4-M1 — Fixed; accepted by reviewer.** D7 protects probing instances until circuit closure after sixty seconds of readiness or failure, includes the protection interval in the handover bound, and defines early voluntary stops as returning the circuit to `open` without counting a failure. **Probe under slot contention** covers nonzero startup time, circuit closure, exactly one recovery entry, and subsequent fair admission.
- **Previously closed findings:** No findings reopened. The durable supervision history, generation-checked acquisition boundary, end-to-end completion budget, kind-aware secret handling, and separate encoded secrets-file bound remain addressed.