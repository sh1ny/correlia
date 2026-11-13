# Review

## Metadata

- **Round:** 1 re-check
- **Prior round:** APPROVE_WITH_CHANGES; required consistent observed-loss precedence and deterministic classifier regression proof; suggested correcting the testing ADR reference.
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Current `design.md`, `specs/plugin-output-protocol/spec.md`, and `proposal.md` for `plugin-health-timeout-classification`; prior review and author rebuttals; `output_plugin_connection.dart` health, delivery-stream failure, process-exit observation, and `_fail` paths.

This re-check covers Required Changes 1 and 2 and suggestion S1 only. No code was changed or tests run.

## Findings

### Critical (blocking)

None.

### Moderate

**M1. Connection-loss precedence is inconsistent across completion paths and the specification — resolved.**

D1 now checks `_stopped || _failure.isCompleted` before classifying either `TimeoutException` or `GrpcError`. The flowchart, failure table, and Flow & State Gaps agree.

The connection-loss scenario now explicitly uses the host’s observation at call failure. D1 documents the accepted race: an exit not yet observed through `_failure` can yield a timeout for that call.

The planned classifier cases cover both error kinds with an already-recorded connection failure. This addresses the current source’s unconditional `TimeoutException` classification and lack of a post-failure connection-state check.

**M2. D3 does not establish that the regression exercises the repaired path — resolved.**

D3 now identifies pure classifier tests as the deterministic regression proof, explicitly covering non-`deadlineExceeded` gRPC failures both at and past the deadline on a live connection.

The real-process stall test remains integration coverage. Starvation and repeated parallel runs are explicitly supplementary evidence, not proof that the repaired branch executed.

The proposal still calls parallel runs “proof”; read against revised D3, this describes load validation rather than deterministic branch coverage. Updating that wording would improve consistency but is not missing regression design.

### Suggestions

**S1. Correct the in-force testing ADR reference — resolved.**

The design now references ADR 0014, its supersession chain through ADR 0013, and AGENTS.md testing constraints instead of treating ADR 0010 as in force.

## Verdict

VERDICT: APPROVE_WITH_CHANGES
CHANGES_APPLIED: yes

## Required Changes

1. **Applied.** Observed connection-state precedence is consistent across D1, the classification flowchart, failure table, and specification scenario. Both error kinds receive recorded-loss classifier coverage; the unobserved-exit race is documented.
2. **Applied.** Deterministic regression proof is assigned to classifier tests exercising non-`deadlineExceeded` errors at and beyond the deadline. Real-process starvation and parallel runs are supplementary.

## Rebuttals

- **M1 / Required Change 1:** fixed — **accepted by reviewer**.
  - D1 now checks the observed connection state first, for `TimeoutException` and `GrpcError` alike, and states the observation boundary and the accepted unobserved-exit race.
  - The flowchart, the Failure & Visibility row and the Flow & State Gaps entry were updated to match.
  - The spec scenario "Connection lost during a health call" is stated against what the host has observed.
- **M2 / Required Change 2:** fixed — **accepted by reviewer**.
  - D3 makes the fast-tier `classifyHealthFailure` unit test the deterministic regression proof, including a non-`deadlineExceeded` `GrpcError` at and past the deadline on a live connection.
  - The starvation and parallel runs are labelled supplementary stress evidence.
- **S1:** fixed — **accepted by reviewer**. The ADRs section names ADR 0014 and the AGENTS.md testing rules instead of 0010.