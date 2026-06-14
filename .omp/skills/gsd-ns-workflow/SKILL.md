---
name: gsd-ns-workflow
description: "workflow | discuss plan execute verify phase progress"
---


Route to the appropriate phase-pipeline skill based on the user's intent.
Sub-skill names below are post-#2790 consolidated targets — `gsd-phase`
absorbs the former add/insert/remove/edit-phase commands and `gsd-progress`
absorbs the former next/do commands.

| User wants | Read |
|---|---|
| Gather context before planning | Read `skills/discuss-phase/SKILL.md` |
| Clarify what a phase delivers | Read `skills/spec-phase/SKILL.md` |
| Create a PLAN.md | Read `skills/plan-phase/SKILL.md` |
| Execute plans in a phase | Read `skills/execute-phase/SKILL.md` |
| Verify built features through UAT | Read `skills/verify-work/SKILL.md` |
| Add / insert / remove / edit a phase | Read `skills/phase/SKILL.md` |
| Advance to the next logical step | Read `skills/progress/SKILL.md` |
| Offload planning to the ultraplan cloud | Read `skills/ultraplan-phase/SKILL.md` |
| Cross-AI plan review convergence loop | Read `skills/plan-review-convergence/SKILL.md` |
| Generate tests for a completed phase | Read `skills/add-tests/SKILL.md` |
| Design an AI-integration phase | Read `skills/ai-integration-phase/SKILL.md` |
| Run all remaining phases autonomously | Read `skills/autonomous/SKILL.md` |
| Execute a trivial task inline | Read `skills/fast/SKILL.md` |
| Plan a phase as a vertical MVP slice | Read `skills/mvp-phase/SKILL.md` |
| Execute a quick task with GSD guarantees | Read `skills/quick/SKILL.md` |

Read the matched sub-skill's SKILL.md and follow its instructions. The `skills/<name>/SKILL.md` paths in the right column are relative to this skill's own directory.
