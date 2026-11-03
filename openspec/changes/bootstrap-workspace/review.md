# Review

## Metadata

- **Round:** 8
- **Prior round:** Round 7, APPROVE_WITH_CHANGES; C1a and C1b critical; M7 moderate; CHANGES_APPLIED: no.
- **Reviewer:** Fresh-context, read-only Codex reviewer.
- **Reviewed:** Latest amendment `9e87204` first; four-commit history; change diff since `76c2fc7`; proposal, design, both delta specs, tasks and round-7 review; AGENTS.md; ADRs 0002 and 0014; requested Serverpod 4.1.0 ephemeral-database, embedded startup and supervisor sources; current tier configuration and test command. No files modified or runtime tests executed.

This verdict covers only the contents reviewed. Editing proposal, specs or design afterward, other than applying Required Changes or editing only the proposal’s Release Notes section, voids it.

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

None.

D4, State & Ownership, the Mechanism Ledger and task 9.4 consistently withdraw Correlia’s shared-cluster shutdown. D8, D16, task 7.1 and tasks 8.x require shutdown of child servers and rely on Serverpod to manage their dedicated PostgreSQL clusters; they do not require Correlia to signal PostgreSQL directly.

The specs remain compatible with the lingering shared cluster: ownership is per test package; side-by-side deletion applies to roots used by a single test; the killed-server scenario is concretely assigned to `.serverpod/test-kill/`. Task 9.4 expressly exempts `.serverpod/test/`.

The integration-tag guard is assertable through executable-call-aware source inspection requiring an explicit tier override. D4 and task 3.2 require that guard and the `integration` exclusion. Their absence from the current implementation is pending implementation work, not a design defect.

## Verdict

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

- **M1:** Shutdown sequencing and failure handling. **Previously accepted by reviewer; carried forward.**
- **M2:** Separate cluster roots, identity assertions and isolation. **Previously accepted by reviewer; carried forward.**
- **M3:** Correlia startup indicator and readiness gate. **Previously accepted by reviewer; carried forward.**
- **M4:** Argument-sensitive fast selection and load exclusion. **Previously accepted by reviewer; carried forward.**
- **M5:** Independent temporary generation workspace. **Previously accepted by reviewer; carried forward.**
- **M6:** Stable roots, conditional deletion, stdin-EOF shutdown and child-held ownership handoff. **Previously accepted by reviewer; carried forward.**
- **C1/C1a:** **Withdrawal accepted by reviewer.** The shared-cluster stop mechanism and its child-handle safety claim are removed. No replacement shutdown mechanism is being approved.
- **C1b:** **Withdrawal accepted by reviewer.** Live-cluster refusal and Correlia-owned recovery are removed. Serverpod’s existing stale-lock repair remains the owner-chosen S8 baseline; its signalling race is not fixed by this amendment.
- **M7:** **Withdrawal accepted by reviewer.** The scenarios testing the withdrawn mechanism are removed. Dedicated-root recovery coverage remains, and task 9.4 now permits the shared cluster to remain running.