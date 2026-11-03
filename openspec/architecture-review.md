# Review

## Metadata

- **Round:** 11
- **Prior round:** Round 10, REVISE (M1: late observation before alert creation).
- **Reviewer:** cross-model CLI (Codex)
- **Reviewed:** Proposed ADRs 0016–0020 against unchanged predecessors 0005, 0007, 0011, 0012 and 0015; amendment `9af6e43..17941a5` and working-tree fixes; architecture, strategy, roadmap and changed planning documents; accepted ADRs 0001–0004, 0008, 0009 and 0014; AGENTS.md; plugin-architecture research; legacy-audit section 6 and question 14; saved rounds 9–10 and current architecture review; applicable Serverpod skills and supplied Serverpod 4.1.0 migration, configuration and server sources. Read-only; no runtime verification.

## Findings

### Critical (blocking)

None.

### Moderate

None open. Round 10 M1 and round 9 C1, M1 and M2 are resolved.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Applied and re-checked — unmanaged schema bootstrap:** `openspec/architecture.md` specifies ordered, forward-only Correlia SQL scripts, a versions table, an advisory lock, execution after Serverpod migrations and before role work, and coverage of fresh installations, upgrades and test databases. Managed tables cannot reference exception tables by foreign key. ADRs 0016–0017 and M1 reflect this procedure.

2. **Applied and re-checked — freshness independent of applied-versus-stale processing order:** ADR 0017 counts both applied and stale observations using locked `GREATEST` updates. ORD-7(a) asserts the same final freshness in both processing orders.

3. **Applied and re-checked — late observations before alert creation:** ADR 0017 excludes late and future-dated observations, and duplicates of those outcomes, from freshness updates. Dedup records retain the original outcome. ORD-7(b–c) covers late-before-creation permutations, concurrent transactions and a late duplicate. ADR 0019’s context and D25 reflect the owner’s revised policy.

4. **Applied and re-checked — console freshness synchronization:** ADR 0017 specifies page-bounded freshness pulls on safety pulls and reconnect, with monotonic timestamp merging. UI-4 covers repeated observations, stale observations and delayed responses.

5. **Applied and re-checked — replay and source-claim corrections:** ADR 0016 explicitly scopes its replay re-pinning exception relative to ADR 0008. ADR 0018 names the available ordering fields and discloses the clamp difference. The architecture identifies the verified 4.1.0 future-call configuration and leaves webhook body-limit behavior as an explicit implementation proof obligation.

6. **Applied and re-checked — release scope:** D16 and D27 explicitly record that plugin SDKs are not 1.0 blockers, consistent with the strategy, roadmap and release definition.

CHANGES_APPLIED: yes

## Rebuttals

- **Round-9 C1 — accepted by reviewer as resolved.** The schema step addresses Serverpod’s fresh-install use of `definition.sql`, which excludes unmanaged tables.
- **Round-9 M1 — accepted by reviewer as resolved.** The separate freshness pull makes unversioned updates observable by an open console.
- **Round-9 M2 and round-10 M1 — accepted by reviewer as resolved.** Applied/stale observations count regardless of their processing order; late observations count in neither missing-row nor existing-row schedules.
- The superseding ADRs preserve their predecessors’ substantive contracts apart from the documented amendments. The five predecessor files remain unchanged. No additional concrete regression requiring a change was identified.