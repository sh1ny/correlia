# Review

## Metadata

- **Round:** <!-- 1, 2, ... after 2 consecutive REVISE rounds, escalate to the user -->
- **Prior round:** <!-- none | one-line summary -->
- **Reviewer:** <!-- cross-model CLI (which) | fresh-context subagent (which harness) | user (USER_OVERRIDE) | n/a for SKIPPED_LIGHT | none (DEFERRED by the user) | none (WAIVED by the user) -->
- **Reviewed:** <!-- artifacts and source files read -->
<!-- DEFERRED only: add the line `- **Deferred to:** <changes or milestones>`. WAIVED only: add the line `- **User decision:** "<the user's words>"` and the line `No design review ran.` -->
<!-- - **Deferred to:** <changes or milestones> -->
<!-- - **User decision:** "<the user's words>" -->

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

### Critical (blocking)

### Moderate

### Suggestions

## Verdict

<!-- Exactly one of: APPROVE | APPROVE_WITH_CHANGES | REVISE | SKIPPED_LIGHT | USER_OVERRIDE | DEFERRED | WAIVED. Any open Critical forbids APPROVE. USER_OVERRIDE only on the user's explicit decision after 2 consecutive REVISE rounds were escalated: quote it and list the open findings. DEFERRED only when the user declared a FULL-tier change a parking change that is never applied: add the Deferred to line. WAIVED only on the user's explicit decision to apply with no design review: add the User decision line (their quoted words) and `No design review ran.`; the pre-ship review still runs. A deferral or waiver is never USER_OVERRIDE, and the agent never offers either. Both use CHANGES_APPLIED: n/a. -->
VERDICT: <VALUE>

## Required Changes

<!-- APPROVE_WITH_CHANGES only: numbered exact edits. -->

<!-- yes (applied, and re-checked by the reviewer - only the reviewer sets it) | no (outstanding) | n/a (any other verdict) -->
CHANGES_APPLIED: <VALUE>

## Rebuttals

<!-- Author: fixed (cite) or rebutted (reason) per finding. A Critical/Moderate rebuttal counts only once marked "accepted by reviewer". -->
