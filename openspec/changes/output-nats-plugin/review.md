# Review

## Metadata

- **Round:** 8
- **Prior round:** 7, APPROVE_WITH_CHANGES; round-6 M1–M4 were rechecked and resolved (CHANGES_APPLIED: yes).
- **Reviewer:** Claude Code (Opus 5.5) via the reviewer CLI route, in a fresh context. I did not read the authoring transcript.
- **Reviewed:**
  - **Change artifacts:** `proposal.md`, `design.md`, `tasks.md`, `review.md` (round 7), and every spec under `specs/` (`output-delivery`, `plugin-output-protocol`, `plugin-supervision`, `integration-nats`, `workspace-tooling`).
  - **Architecture, ADRs and runbook:** `openspec/architecture.md` (ownership rows 100–107, protocol boundary 123–133, in-force index 246–256), `docs/adr/0025-…`, the 0026 index entry, `docs/adr/0016-…` (dead letters and counters), base `openspec/specs/output-delivery/spec.md`, `docs/runbooks/output-nats.md` and `evidence/check-gate.txt`.
  - **Source:** `correlia_server/lib/src/output/output_relay.dart`, `relay_subsystem.dart`, `plugin/plugin_supervisor.dart`, `plugin_status_repository.dart`, `plugin_health_repository.dart` and `output_plugin_connection.dart`, plus `schema/0003` (by grep).
  - **Tests:** `test/db/plugin_relay_test.dart` (oversized and aggregate cases), `test/db/plugin_status_persistence_test.dart`, and the test-name inventory.
- **Tier:** FULL. Full coherence review, focused on the D4 oversized-intent amendment, the new output-delivery requirement and its test mappings, and the runbook heartbeat clarification.
- **Method:** I only read files. I edited nothing and ran no builds or tests.

## Findings

### Critical (blocking)

None.

### Moderate

- **M1: The owner-chosen oversized-intent admission policy is not recorded in any in-force ADR, but the design still says ADR 0025 covers D4.**
  - **Evidence:**
    - D4 (`design.md:144-149`) adds a lasting rule that users see: an intent goes terminal (`dead`, `payload_too_large`) at claim time, with no attempt record and no automatic replay. D4 is marked "Binds future changes, and is a data-loss risk". The summary row (`design.md:544`) marks this policy as chosen by the user.
    - ADR 0025 D4 (`0025…md:22`) describes plugin claims only as "at most 64 rows / 1 MiB … with one attempt per intent". It has no admission-time dead letter, and neither does architecture row 103.
    - The design's ADR section (`design.md:740-750`) still says ADR 0025 "covers … D4". It names an ADR only for the Configure amendment (0026).
    - Round 7 set the precedent: an amendment to an ADR-covered decision gets its own accepted ADR, because accepted ADRs are immutable (ADR 0023:21).
  - **Consequence:** later work that ADR 0016 assigns will be designed from the in-force ADR set without knowing that a dead letter can exist with zero attempts. That work includes the counters ("attempted … dead-lettered", 0016:141), dead-letter retention and expiry (0016:87-90), and M2 replay. A third-party plugin author reading ADR 0025 would also not learn that the host enforces their advertised byte limit by dead-lettering.

- **M2: The status-heartbeat and pruning text in D11, D19 and architecture contradicts the approved runbook clarification and the code. The code lets one worker erase a live worker's durable supervision history.**
  - **The runbook clarification is accurate:**
    - `docs/runbooks/output-nats.md:62-66` says only ready instances heartbeat every 15 s, and that backoff, degraded and stopped rows can legitimately age while their worker is alive. "A stale row alone does not prove worker death."
    - The code agrees. `plugin_supervisor.dart:134-161` refreshes only instances that hold a slot and are ready. `writeWaiting` refreshes waiting rows every 15 s.
  - **The design and architecture still state the opposite:**
    - D11 (`design.md:357-360`): "writes them on each state change and every 15 s", and "At startup a supervisor deletes rows … stale and in `stopped` … it only touches rows whose writer is dead".
    - Architecture row 106 says "startup pruning is the only cross-host write" and "rewritten on transitions and every 15 s".
  - **The code prunes periodically, not at startup.**
    - `plugin_supervisor.dart:116-121` runs `prune` every minute on every worker.
    - `plugin_status_repository.dart:185` deletes any host's `stopped` rows once they are 60 s stale.
    - It then cascades (`:190-197`): it deletes another host's `plugin_definition_health` rows once none of that host's status rows remain.
  - **How live history gets erased:** an idle-released instance writes `stopped` and never refreshes it again, even though its worker is alive. Example:
    1. Worker W1's definition X crashed, so its health row holds failure times, a backoff step and possibly an open circuit.
    2. X recovers, and is then released because its remaining queued rows are in retry delay. Those rows are queued but not due, so `healthRepository.prune` keeps the health row.
    3. If all of W1's other rows are also `stopped`, worker W2's next prune deletes W1's status rows and W1's health rows.
    4. When X is readmitted on W1, it starts with a fresh backoff step and crash budget.
  - **Consequence:** this breaks ADR 0025 D19 ("Eviction must not reset backoff or crash budget") and the "Durable supervision history" requirement whenever two or more workers run. A flapping plugin whose crashes are separated by idle releases may never open its circuit.
  - **Why tests miss it:** `pruning_spans_bounded_batches_and_preserves_live_host` (`plugin_status_persistence_test.dart:133-177`) keeps the "alive" host only because it also has a fresh `ready` row. No test covers a live host whose rows are all stopped.

### Suggestions

- **S1:** No minimum is enforced on the byte limit a plugin advertises. `output_plugin_connection.dart:294-297` rejects only non-positive values.
  - Under the D4 policy, a buggy third-party plugin that advertises a tiny `maxBytesPerBatch` would dead-letter its definition's whole backlog, 64 rows per claim, with no attempt records.
  - The only signal would be outbox `dead_reason`. The status row shows nothing, and the same class is also used for plugin-side rejections.
  - Consider a floor in Configure validation (`plugin_protocol_error`), or a status counter or diagnostic for host-side admission rejections. This does not change the owner's policy.
- **S2:** The oversized tests (`plugin_relay_test.dart:341-454`) seed `attempt_count = 0`. "Retains its prior attempt count" therefore can't be told apart from a reset to zero. Seeding a non-zero prior count, such as a row with earlier retryable attempts, would make that clause assertable.
- **S3:** In the test map, the row `aggregate_limit_defers_fitting_event` (`tasks.md:16`) sits among the plugin-output-protocol rows, away from the other three byte-limit-admission rows (`:69`, `:73-74`). This is cosmetic: the mapping is correct and the test exists.

**Checked and found coherent:**
- The D4 amendment, the new requirement "Plugin intent byte-limit admission" (four failure-bearing scenarios with assertable THENs), and the Failure and Resource Bounds rows all match `output_relay.dart:338-414`:
  - the oversized check comes before the aggregate break;
  - the dead update keeps the payload and `attempt_count` and writes no attempt;
  - an empty plugin claim still reaches `checkClaim` and the permit check, and commits;
  - permit invalidation rolls back through `_RollbackClaim`.
- The byte accounting uses payload-only sums in both the relay (`:338`, `:353`) and the connection (`output_plugin_connection.dart:404-408`). The claim therefore cannot produce a batch that `deliver` refuses.
- All four test mappings point to existing tests whose assertions match their scenarios.
- The protocol spec's "smaller of the host and plugin limits" agrees with `relay_subsystem.dart:130-131`.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

The D4 oversized-intent amendment, its output-delivery requirement and its test mappings agree with each other and with the implementation, and they do not contradict any in-force ADR. The runbook heartbeat clarification correctly describes the implemented behaviour. Two Moderate gaps remain:
- the user-chosen admission policy has no ADR, while the design says ADR 0025 covers D4;
- the heartbeat clarification exposes that the D11, D19 and architecture pruning text is wrong, and that the implemented cross-host pruning can erase a live worker's supervision history, which breaks ADR 0025 D19.

Neither change reverses a `Chosen by: user` decision. M1 records the owner's policy. M2 touches only D11 and D19, which the agent chose.

## Required Changes

1. **M1: Record the oversized-intent admission policy in an accepted ADR.**
   - In `design.md` § ADRs, add an item after the Configure amendment bullet. It should say that a task writes accepted ADR `docs/adr/0027-plugin-intent-byte-limit-admission.md`, which refines ADR 0025 D4 without editing it. The ADR records:
     - admission against the plugin's negotiated batch byte limit before transport;
     - retained `dead` `payload_too_large` with the payload and prior attempt count kept and no attempt record;
     - the same claim transaction, deadline and final permit check, with rollback on readiness loss;
     - that rejections commit without a batch;
     - that aggregate-only overflow defers;
     - `Chosen by: user`, the rejected alternatives from D4 (`design.md:179-180`), and the reversal cost.
   - In `tasks.md`, add a task that writes that ADR and updates architecture row 103 (`outbox`, `delivery_attempts`) and the in-force index with the row "0027 | … | none (refines 0025 D4)". Verify by `mise run spec:validate` and a read-back against D4.
2. **M2: Make the status and health ownership text true, and stop treating a live host's stopped rows as a dead host.**
   - **(a) Fix the text.**
     - In D11 (`design.md:357-360`), replace "writes them on each state change and every 15 s" with the actual rule: rows of instances that hold a slot or are waiting refresh every 15 s; backoff, degraded and stopped rows are written at transitions and may age while their worker lives.
     - Also in D11, replace "At startup … That is the one cross-process write, and it only touches rows whose writer is dead" with the actual periodic (60 s) prune and the deletion rule chosen in (b).
     - Apply the same corrections to D19 (`design.md:522-523`), the State & Ownership row (`design.md:630`), the Resource Bounds "Status rows" row (`design.md:671`), and, through a task, architecture rows 106–107.
   - **(b) Close the erasure.**
     - Another host's `plugin_definition_health` rows must never be deleted while that host is alive.
     - Recommended: a supervisor deletes another host's status rows only when they are more than 24 h stale. It may still delete its own `stopped` rows after 60 s. The existing cascade then removes another host's health only after that host has been silent for 24 h.
     - Add a mapped db test in `test/db/plugin_status_persistence_test.dart`. Host A is alive with only `stopped` status rows older than 60 s, plus a health row (non-zero backoff step, failure times) for a definition with queued rows. Host B runs `prune`. Assert that A's health row survives unchanged.
     - Add the task and test-map row.

CHANGES_APPLIED: no

## Rebuttals