## Metadata

Scope covered D3, D16, the `icinga2-event-streams` delta, and its task map. This was a read-only review. No files changed and no tests ran. Official-image fixtures and full consumer evidence remain pending in tasks 2 and 11.

## Findings

1. **The release gate does not explicitly require the per-grant denial matrix.** The delta’s support requirement gates each release on successful captures and a real-consumer run. Its missing-permission scenario describes one omitted entry, while task 11.4 requires the permission test to pass without specifying a complete release-by-grant matrix. A partial run could satisfy those checks and leave a documented grant untested. [D16](/home/bgshi/Development/dart/correlia/openspec/changes/icinga2-event-streams/design.md:638) · [Delta spec](/home/bgshi/Development/dart/correlia/openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md:945) · [Task 11.4](/home/bgshi/Development/dart/correlia/openspec/changes/icinga2-event-streams/tasks.md:393)

## Verdict

VERDICT: APPROVE_WITH_CHANGES
CHANGES_APPLIED: yes

## Required Changes

Require tasks 2 and 11 to capture and verify one populated-fixture run per documented grant omitted individually for each supported release. Make complete matrix coverage a release criterion. For each case, record the upstream status and assert the corresponding consumer error class, no successful first sync, and no sync started when the subscription itself is refused.

## Rebuttals

D3 and the delta implement the owner’s decision consistently. Subscription 404 backs off before sync. An object-query 404 fails the sync as `http_status`, records a gap, and closes the connection even when the collection is genuinely empty. HTTP 403 is `forbidden`. The task map covers both classifications and the operator warning. The finding concerns matrix completeness while retaining all four candidates. [D3](/home/bgshi/Development/dart/correlia/openspec/changes/icinga2-event-streams/design.md:214) · [Delta spec](/home/bgshi/Development/dart/correlia/openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md:445) · [Task map](/home/bgshi/Development/dart/correlia/openspec/changes/icinga2-event-streams/tasks.md:168)