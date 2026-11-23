# Design

## Triage

<!-- Check each trigger against the code. When unsure, it applies. -->

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | | |
| T2 State (persistent state, caches, 3+ state machine) | | |
| T3 Concurrency (background work, workers/isolates, async, retries) | | |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | | |
| T5 Volume (grows without a fixed bound) | | |
| T6 Risk (security, money, data loss, unrecoverable user data) | | |

<!-- Replace <VALUE> with LIGHT or FULL. -->
TIER: <VALUE>

## Context

<!-- Current state and constraints the approach needs. Cite each claim about existing behaviour as `path:line`, the narrowest range that shows it. Point to proposal.md instead of restating it. -->

## Decisions

<!-- Repeat per decision (D1, D2...), each before the Decision summary. -->

### D1: <!-- decision -->

- **Choice:** <!-- what -->
- **Rejected:** <!-- structurally different alternative --> because <!-- why it lost -->
- **Reversal cost:** <!-- low | medium | high --> <!-- if high on weak evidence: what evidence would settle it -->
- **Important:** <!-- yes | no --> <!-- if yes: the criterion met (high reversal cost | binds future changes | changes what users see | weak evidence) -->
- **Chosen by:** <!-- agent | user (user when the user chose or stated it, in any mode) -->

### Decision summary

<!-- Goes after the last decision. One row per scope decision (S1...) from proposal.md and per design decision (D1...). Update in the same edit as any entry. -->

| # | Decision | Choice | Rejected | Reversal cost | Important | Chosen by |
|---|---|---|---|---|---|---|

## Assumptions

<!-- Both tiers. One entry per claim not checked against the code, or `None` when every claim is cited. -->

- **A1:** <!-- the claim --> Not checked because <!-- why -->. Depends on it: <!-- decisions or tasks, or none -->

## Carried constraints

<!-- Both tiers. One entry per fact a future change must respect, or `None` when nothing outlives the change. Exactly one destination: `doc comment: <path> <symbol>`, `spec: specs/<capability>/spec.md → Requirement: <name>`, or `ADR NNNN`. -->

- **C1:** <!-- the fact --> Kind: <!-- invariant | deliberate gap | rejected alternative -->. Destination: <!-- doc comment: <path> <symbol> -->

<!-- ===== LIGHT tier ends here. Delete everything below for LIGHT. ===== -->

## Diagrams (FULL)

<!-- One mermaid diagram per applying trigger among T1-T4. -->

## State & Ownership (FULL)

| State | Owner (sole writer) | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|

## Failure & Visibility (FULL)

| Component | Fails / dies mid-operation → | Recovery | Retry safe? | Who finds out |
|---|---|---|---|---|

## Resource Bounds (FULL)

| Queue / buffer / cache / transfer | Bound | At the bound | Timeout | At 10x / 100x |
|---|---|---|---|---|

## Flow & State Gaps (FULL)

<!-- Partial completion, concurrency, stale data, out-of-order events, restart mid-operation: behavior, or default assumption if undecided. -->

## Mechanism Ledger (FULL)

| Mechanism | Built? | Why (harm nobody catches / expensive later) | Evidence that would change the call |
|---|---|---|---|

## Risks / Trade-offs

<!-- [Risk] → Mitigation -->

## ADRs

- **In force, constraining this change:** <!-- ADR ids, or none -->
- **To record during apply:** <!-- new or superseding ADRs, or none -->

## Open Questions

<!-- Only unknowns answerable later without changing specs, approach or tasks. Omit if none. -->
