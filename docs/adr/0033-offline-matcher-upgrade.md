# 0033. Offline matcher upgrade

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Supersedes: the rollout procedure in [0032](0032-matcher-rules-and-versions.md). Its matcher and publication decisions remain in force.
- Chosen by: user.

## Decision

Do not support live upgrades or mixed-version operation for the matcher release. No existing installation needs an in-place upgrade. Stop admission and manually drain pending inbox work and the outbox on the old release. Stop all old processes and their supervisors before starting the new release.

The matcher schema step installs retained-output inventory functions without an upgrade capacity preflight or additional version fences. Configuration publication still counts candidate outputs, pending routes and live intents against the same 64-output limit. Existing pins remain unchanged.
