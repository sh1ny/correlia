# Review

## Metadata

- **Round:** 6
- **Prior round:** Round 5 APPROVE_WITH_CHANGES (CHANGES_APPLIED: no; 3 required edits to ADR 0008 and RUL-7). Author applied them, listed under Rebuttals.
- **Reviewer:** cross-model CLI (Codex)
- **Reviewed:** `openspec/strategy.md`, `openspec/architecture.md`, ADRs 0001–0012, and round 5’s `openspec/architecture-review.md`. Supporting evidence: requested research, planning and configuration documents, and eight named project skills. Read-only review; no runtime verification. Official Serverpod 4.1 documentation confirms [embedded PostgreSQL](https://docs.serverpod.dev/concepts/data-and-the-database/database/embedded-postgres), [custom HTTP routes](https://docs.serverpod.dev/concepts/web-server/routing), and [durable, at-least-once scheduling](https://docs.serverpod.dev/concepts/scheduling/overview).

## Findings

### Critical (blocking)

None.

### Moderate

None open. Round 5 M1 is resolved.

### Suggestions

None.

## Verdict

VERDICT: APPROVE

The revised baseline adequately covers T1–T6 and the legacy correctness hazards for starting the walking skeleton. ADRs identify concrete rejected alternatives and reversal costs. Plugin interoperability remains subject to an explicit, measurable spike gate.

## Required Changes

None outstanding. All three round 5 edits were verified:

1. ADR 0008 requires a new immutable configuration version, complete registry validation and atomic activation at worker batch boundaries. Invalid fallback cannot activate; skip-and-count and self-alerting continue.
2. Existing raw-row pins remain unchanged. Failures are recorded against the pinned version; replacement requires explicit reprocessing.
3. RUL-7 covers valid fallback and a previous rule referencing a removed output, requiring rejection of the invalid fallback, consistent worker activation and preservation of existing pins.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 5 M1 — resolved.** Automatic fallback now follows the configuration publication and validation contract without changing pinned work.
- **Round 4 C1 — remains resolved.** Fallback observation identity uses reported source time, independently of arrival-dependent clamping. Generic mappings must supply delivery-independent identity evidence.
- **Round 3 C1 — remains resolved.** Stable dedup retention, lateness rejection and far-future quarantine prevent the reported retry resurrection.
- **Round 3 M1 — remains resolved.** Membership is revalidated after acquiring alert locks; newly discovered groups require rollback and restart in the prescribed lock order.
- **ADR 0008 evaluator revision — remains adequate.** The typed condition tree, field catalog, bound SQL parameters and conformance suite provide sufficient baseline contracts. No new finding with a concrete correctness, safety or first-milestone consequence was identified.