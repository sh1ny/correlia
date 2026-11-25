# Matcher rules and versions

## Why

Operators need to enrich normalized alerts without code and to change or restore rules without changing the meaning of already pinned work. M2 item 5 advances RUL-3, RUL-4, RUL-6, RUL-7, SEC-2 and DUR-5. The owner's day-long real-feed check is judged at M2 close, with the remaining ingest and simulator changes in place.

## What Changes

- Add declarative matcher conditions and enrichment actions for labels/tags, severity mapping, ownership, links, hostname/CIDR lookup and bounded regex extraction.
- Use the same typed condition model for in-memory evaluation and parameterized PostgreSQL filtering of stored events.
- Provision rules from YAML and activate them atomically with the configuration snapshot. Restore earlier matcher behavior by republishing it as a higher revision against the current registry.
- Reject unknown outputs at activation. Skip and count failing rules against the pinned version and raise a self-alert in the activity feed. Only an operator publishes replacement configuration.
- Simulator, query enrichment, classification, correlation policy, and console editing are outside this roadmap item.

## Capabilities

### New Capabilities

- `matcher-rules`: Declarative enrichment, equivalent stored-event matching, rule publication, rollback and failure handling.

### Modified Capabilities

None. Existing source-ingress publication and durable raw-pin guarantees continue to apply.

## Impact

Server-side matcher parsing, event enrichment before routing, stored-event SQL filtering, immutable ingest snapshots, and operator provisioning. No canonical event schema change is proposed.

## Decision Making

DECISION_MAKING: important

Source: setting

### S1: Rollback scope

- Choice: The owner chose “C: cut restore-by-version, roll back by normal publish”. Put earlier rules into the current configuration file, nominate the expected active snapshot and publish at a higher revision using normal startup. Restart from that same file. Existing pins and unchanged credentials remain intact. This supersedes the earlier restore-by-version and resume-only approvals.
- Rejected: Reactivate an earlier full configuration or add separate restore/restart modes; the same bounded input can publish and restart without either mechanism.
- Reversal cost: High; changes the publication and rollback contract.
- Important: yes (persistent contract and operator-visible behavior).
- Chosen by: user.

### S2: Operator-only recovery

- Choice: The owner chose “C: just skip and count it, no auto-recovery”. Skip the failing rule, count it against its pinned snapshot, and raise an activity-feed notice. The operator corrects and publishes a new revision; keep the stale-file startup fence.
- Rejected: Automatically publish a replacement or disablement after an error budget; this adds publication and restart coordination beyond the roadmap brief.
- Reversal cost: Medium; automatic publication would change how configuration revisions are owned.
- Important: yes (operator-visible behavior and publication boundary).
- Chosen by: user.

### S3: Keep matcher effects out of alert state

- Choice: The owner chose “A: cut it, rules don't change alert state”. Keep the existing alert-state and reconciliation transitions on original normalized evidence; apply matcher metadata, severity and routing only to retained event and delivery effects.
- Rejected: Stage and replay state decisions for each candidate matcher effect, expanding the scope and risking state-order changes.
- Reversal cost: High; changing when a matcher affects live state would change the state and reconciliation contract.
- Important: yes (behavior and component boundary).
- Chosen by: user.

## Branch gate

Specwright 0.39.1 reported a clean Git worktree already on `feat/matcher-rules-and-versions`, not local `main`. Using the approved linked-worktree workaround (sh1ny/specwright#258), bootstrapped the pinned binary in this worktree, verified interface 3, verified that the existing branch pointed at fetched `origin/main` (`74a3a74`), and confirmed no archive of this change on local or fetched main. No branch was switched or recreated.
