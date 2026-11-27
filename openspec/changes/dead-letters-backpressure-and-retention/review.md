# Review

## Metadata

- **Round:** 4, required-change recheck of the FULL design review for `dead-letters-backpressure-and-retention`.
- **Prior round:** Round 3 returned `REVISE`. Round 4 returned approval with one required change covering delayed partition attachment failures.
- **Reviewer:** Codex, read-only.
- **Reviewed:** The previous verdict, the design's State & Ownership and Migration and reclamation sections, and the durable-pipeline scenario for delayed attachment failure. The recheck used document inspection only.

## Prior round reconciliation

| Round 3 finding | Disposition |
|---|---|
| Critical 1. An overflow notice can fail to insert into the attached historical event heap. | Resolved. The parent and historical heap enforce the same exclusive-origin constraint. The populated upgrade scenario sends a real notice into the historical range and checks its reference, digest and size against ledger evidence while preserving existing sender keys and bytes. |
| Moderate 1. Historical secret checks scan the payload backlog under the publication lock. | Resolved in the design. Indexed pinned and live counts are read in one statement for the supplied references, and processing moves references from pin to intent atomically. Worker startup checks distinct live webhook commitments in a consistent view. Plugin secret availability remains a per-definition launch check. |
| Moderate 2. Bounded attachment can time out on an empty range in a populated default child. | The owner’s chosen policy is preserved. Occupied days are skipped, empty ranges get a bounded attempt, valid writes can still reach default, and cleanup and offline repair remain available. This recheck resolves the remaining outcome-ordering gap. |
| Suggestion. Restore the source and replay the original occurrence. | Addressed. The scenario restores the same UUID and mode before expiry and replays the original occurrence under the restored snapshot while preserving the admission-time stream or reconcile policy. |

## Findings

### Critical (blocking)

None.

### Moderate

1. **Resolved. A delayed attachment failure cannot overwrite a newer success.** Maintenance reserves a monotonic attempt ID for `(parent, day)` under the DDL lock and rechecks the ID and catalog before running DDL. If worker A rolls back and pauses, worker B can reserve a newer attempt, attach the same day and clear its retry in the attachment transaction. When A resumes, it reacquires the same lock. Its ID is no longer current and the catalog already covers the range. Either check is sufficient to reject the write. Current partition degradation comes only from outstanding, uncovered retries, and A's rejected result is excluded from the last-batch outcome. [State & Ownership](design.md#state--ownership-full) and [Migration and reclamation](design.md#migration-and-reclamation).
2. **The regression scenario covers that interleaving.** It pauses A after rollback and before retry recording, lets B attach the same day, then resumes A. It checks that the day stays covered and that A adds no degradation, retry or stale last-batch outcome. Carry barriers and injected time into the task map, with elapsed time used only as a hang guard. [Delayed attachment failure scenario](specs/durable-pipeline/spec.md#scenario-a-delayed-attachment-failure-cannot-replace-success).

### Suggestions

- Exercise historical import across the actual pin-to-intent commit. Give the last pending pin a historical reference absent from the candidate configuration, commit its conversion to a live intent at a barrier, and run publication with matching and mismatched imports on both sides of the commit. This catches separate snapshots for the pinned and live lookups. The startup scenario separately checks `historical_key_unavailable` for a live webhook intent.
- Exercise maintenance through the runtime registry in API, worker and all roles. Start shutdown at a barrier inside a failing batch and verify that rollback and any outcome recording finish before session close, with no second batch claimed.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Applied and rechecked. The attempt ID and catalog checks fence failure recording after rollback. Successful attachment clears retry state atomically, and rejected failures cannot affect reported status. The scenario covers the required two-worker ordering.

CHANGES_APPLIED: yes

## Rebuttals

- **Accepted by reviewer in round 4.** Supported publication rejects kind or mode changes for an existing source UUID and preserves both fields on removal. A same-UUID stream-to-webhook fixture falls outside the supported contract. Missing, disabled and restored bindings are reachable and covered by replay scenarios.

## Round 5: Cutoff amendment and offline deadline

Codex accepted the source-ingress amendment. The cutoff still fences every new raw insert. Only an authorized replay of an eligible retained failure can requeue the existing row below the cutoff; it keeps the raw ID and receipt without inserting a transport reservation. This implements the behavior the owner approved in D2 and D7.

The reviewer required D14's scenario in the durable-pipeline delta and evidence from PostgreSQL for a nondefault timeout. The recheck accepted both. The default fixture observes the one-hour client deadline. The rollback-and-retry fixture observes the two-hour override and reads `lock_timeout` as `30s` in the cutover transaction. It finds no version record after failure and the expected version after retry.

## Round 6: Active maintenance failures

Codex approved D15 after requiring a fence for late failure reports. Each batch gets an attempt number before doing work. The status write compares that number with the stored outcome for the same job, so a failure delayed past a newer success cannot reopen the job's failure. Partition retry records keep their own fence.

The review accepted the regression that parks an expiry failure after rollback, commits a newer expiry sweep and releases the old report. The successful outcome stays visible and the failure does not reappear. The maintenance loop test separately checks that an unrelated success does not hide the active failure.

## Round 7: Drained outbox partitions

Codex accepted D16 after requiring a fresh count snapshot after the partition locks, transactional resets for parent and child truncation, and proof that unrelated outputs can write and reclaim rows while one count is busy. The rechecks confirmed the `READ COMMITTED` guard, both reset scopes and their rollback, and the test-map entries for those cases.

Pre-ship review 41 found that resetting only the count on direct child truncation left queue metadata behind. The guard now refuses direct truncation of nonempty children and requires `READ COMMITTED`. Truncation through the parent still resets queue metadata and counts in one transaction.

## Round 8: Overflow fanout under contention

Codex approved D17. Notice routing skips locked destination capacity rows, not shared relation, registry or signing commitment locks. The same transaction writes at most one canonical event, its fitting intents and the handled marker. A rollback leaves the occurrence pending. Normal pipeline processing and replay keep strict capacity locking.

The regression holds one capacity row through another destination's notice commit, releases the lock and checks that a second worker cannot send the same occurrence to the skipped destination. The ledger and status retain the overflow evidence.

## Round 9: Legacy delivery windows at cutover

Codex approved D18 after two required test changes. The fixture excludes raw failures so that the expiry batch measures only delivery failures. The regression writes matching terminal attempts with a non-UTC PostgreSQL session, then checks both windows from the cutover timestamp without changing the attempt history.

The recheck confirmed that replay clears the legacy metadata. A normal permanent completion opens a distinct failure occurrence at the controlled transition time and keeps the old attempts. That occurrence remains replayable until its own expiry boundary.