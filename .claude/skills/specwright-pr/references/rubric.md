# Judging review feedback

Judge every item before changing code. Read the code the comment points at (for outdated threads, look up `line`, then the original line, then search the same file for the quoted code).

**Default to fixing**, nitpicks included. A fix is cheap; an argument is not. Unease is not a reason to decline - "I read the callers and this breaks X" is.

Verdicts:
- **fix** - the finding holds. Fix it, and fix every other site with the same root cause.
- **not-addressing** - the finding does not hold (wrong reading of the code, code already moved). Cite the evidence (file:line).
- **declined** - the fix would make the code worse. Name the specific harm.
- **replied** - a question, or a suggestion that buys nothing real. Answer it.
- **needs-human** - a product or design decision, a trade-off the user should own, or a request to reverse a deliberate decision.

Rules:
- Reversing deliberate design needs both positive evidence it was intentional (a comment, test, ADR, design.md decision or commit message) and a real disagreement. Without both, just fix it. With both, it is needs-human.
- "Already bounded elsewhere" is a valid not-addressing reason only with evidence, and never for security, auth, money, data loss, migrations or irreversible effects.
- Cluster by root assumption. A source (often a bot) that is wrong in one place is suspect in its sibling comments - verify each, do not batch-accept or batch-reject.
- Prompts, skills and docs: if the existing text already decides the case, it is not a fix. On a second round against the same block, stop patching and rewrite the block around its goal.
- A spec, scenario or ADR conflict is spec drift: amend the artifact (and re-review if the design tier is FULL), do not code around it.

Replies (quote the point briefly, then one of):
- `Addressed: <what changed, commit sha>`
- `Addressed differently: <what and why>`
- `Not addressing: <reason with evidence>`
- `Declined: <the specific harm>`
- needs-human: a plain reply saying it is waiting on the owner. Do not resolve the thread. In the summary to the user give: the quoted feedback, what you found, the options with trade-offs, and your recommendation.
