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

<!-- Current state and constraints the approach needs. Cite existing patterns as file:line. Point to proposal.md instead of restating it. -->

## Decisions

<!-- Repeat per decision. -->

### D1: <!-- decision -->

- **Choice:** <!-- what -->
- **Rejected:** <!-- structurally different alternative --> because <!-- why it lost -->
- **Reversal cost:** <!-- low | medium | high --> <!-- if high on weak evidence: what evidence would settle it -->

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
