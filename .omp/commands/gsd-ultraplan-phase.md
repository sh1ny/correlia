---
name: gsd-ultraplan-phase
description: "[BETA] Offload plan phase to OMP's ultraplan cloud; review in browser and import back."
argument-hint: "[phase-number]"
---


<objective>
Offload GSD's plan phase to OMP's ultraplan cloud infrastructure.

Ultraplan drafts the plan in a remote cloud session while your terminal stays free.
Review and comment on the plan in your browser, then import it back via /gsd-import --from.

⚠ BETA: ultraplan is in research preview. Use /gsd-plan-phase for stable local planning.
Requirements: OMP v2.1.91+, claude.ai account, GitHub repository.
</objective>

<execution_context>
@.omp/gsd-core/workflows/ultraplan-phase.md
@.omp/gsd-core/references/ui-brand.md
</execution_context>

<context>
{{GSD_ARGS}}
</context>

<process>
Execute the ultraplan-phase workflow end-to-end.
</process>
