# Review

## Metadata

- **Round:** 10
- **Prior round:** Round 9 gave APPROVE_WITH_CHANGES (CHANGES_APPLIED: no). Its M1 required the owner's 60 s stopped-row prune to keep a status row while its key has a health row, so that a host's leftover health history cannot escape the 24 h cross-host expiry. It also made three suggestions: S1 (rewrite the existing pruning tests), S2 (D4's attribution) and S3 (ADR 0027's alternatives and reversal cost).
- **Reviewer:** fresh-context Claude Code (Opus 5.5) reviewer. I did not read the authoring transcript.
- **Reviewed:**
  - **Change artifacts:**
    - `openspec/changes/output-nats-plugin/design.md` (complete), `tasks.md` (complete) and `review.md` (round 9)
    - `specs/plugin-supervision/spec.md` (complete)
    - `specs/output-delivery/spec.md`: the requirement index and the byte-limit admission requirement
    - `proposal.md`: decision mode
  - **Architecture and ADRs:**
    - `openspec/architecture.md`: rows 79, 106 and 107, the protocol boundary at line 123, and index rows 255–256
    - `docs/adr/0025-…`: D4 and D19
    - `docs/runbooks/output-nats.md:55-74`
  - **Source:**
    - `correlia_server/lib/src/plugin/plugin_status_repository.dart` (complete)
    - `plugin_health_repository.dart` (complete)
    - `plugin_supervisor.dart:105-164`, plus every call site of health `save`, status `prune`, `writeWaiting` and `markStopped`
  - **Tests:** `correlia_server/test/db/plugin_status_persistence_test.dart` (complete)
- **Tier:** FULL. I re-checked round 9's M1 and its suggestions, then checked coherence across design, spec, tasks, ADRs and code on my own.
- **Method:** I only read files. I edited nothing and ran no builds or tests. Tasks 1.3 and 6.5 are pending on purpose, so I did not expect ADR 0027, the architecture updates or the pruning fix to exist yet. I judged the plan, not the result.

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

- **S1: Tell operators in the runbook how long status rows are kept.**
  - Under the new rule, a dead worker's `stopped` rows stay for 24 h. A live host's `stopped` rows also stay while their key has a health row.
  - `docs/runbooks/output-nats.md:60-66` explains that stale rows are not proof of a dead worker, but says nothing about how long rows are kept.
  - Task 6.5 already aligns the architecture rows. Adding one sentence to the runbook in the same task would answer the obvious question of why a dead worker's rows are still there. This is optional, and nothing in the runbook currently contradicts the design.

**Checked and found coherent:**

- **Round 9's M1 is addressed in design, spec and tasks.**
  - D11 (`design.md:361-364`) adds the exception: the owner prunes its own stopped rows older than 60 s only when the key has no health row. Another host's rows expire only after 24 h, whatever their state.
  - D19 (`:526-530`) states the anchor rule and says a live host's stopped rows older than 60 s do not allow another host to delete them.
  - The same rule appears in the State & Ownership rows (`:636`, `:639`), the Resource Bounds rows (`:677`, `:681`) and the spec (`:82`, `:84`, `:106`).
  - The new scenario "Dead host after owner-local pruning" (`spec.md:94-96`) has a THEN that can be asserted. Its test map row (`tasks.md:38`) is `red` in `S/db/plugin_status_persistence_test.dart`, and pending task 6.5 confirms it fails first.
- **The anchor closes the leak, judged against the code.**
  - Every health write goes through `PluginStatusRepository.write` (`plugin_status_repository.dart:98-101`), which upserts the status row in the same transaction. So whenever a health row exists, a status row for the same key exists too.
  - With the fix, the owner's prune can no longer remove that status row first. It goes only after `PluginHealthRepository.prune` (`plugin_health_repository.dart:85-93`) has removed the health row. The sweep order (`plugin_supervisor.dart:118-119`) means this happens on the next 60 s tick.
  - A dead host therefore always keeps a status row while it has health rows. Its last heartbeat dates every one of those rows, so after 24 h they all expire. The cascade at `:190-197` then fires in the batch that removes the host's last row, even when the 256-row limit splits the rows across batches.
- **Live hosts are safe from the 24 h expiry.**
  - A kept anchor means the definition still has queued or delivering work. On a live host that work leads to admission within one of these windows:
    - a waiting row, refreshed every 15 s;
    - a start after backoff, capped at 60 s;
    - a degraded probe, every 5 min;
    - work that becomes due, within 300 s.
  - Each of these rewrites the row, so its heartbeat never gets near 24 h.
- **Both new failing tests should fail on today's code.**
  - `live_host_with_only_stopped_rows_keeps_health`: today another host deletes stopped rows older than 60 s and the cascade removes the health rows with them.
  - `dead_host_health_expires_after_self_prune`: today the owner's prune deletes its own anchor row.
- **Round 9's suggestions are taken up.**
  - **S1:** task 6.5 now names the existing-test updates: dead hosts at 25 h, live stopped rows at 61 s, and the owner's status-then-health sweep.
    - This is needed. Under the fix, the owner's `terminal` row in `stale_dead_hosts_and_nonlive_health_are_pruned` (`:48-54`, `:85-92`) survives the first status prune because it has health.
    - `pruning_spans_bounded_batches_and_preserves_live_host` (`:133-177`) uses 61 s rows for both hosts.
  - **S2:** D4's line now reads `agent; oversized-intent policy: user` (`design.md:183`), matching the summary row at `:550`.
  - **S3:** the ADR 0027 bullet (`:757-761`) now names D4's rejected alternatives and the medium reversal cost. Task 1.3 checks it by reading it back against D4.
- **The ADRs remain compatible.**
  - ADR 0025 D19 says "Prune rows without queued or delivering work and dead-host rows alongside status pruning". The new rule refines this and does not contradict it.
  - ADR 0027 is planned to refine 0025 D4 without editing the accepted ADR.
  - ADR 0026 is untouched.
  - No `Chosen by: user` decision is reversed. D11 and D19 are agent decisions, and the proposal sets `DECISION_MAKING: autonomous`.
- **Pending work is not claimed as done.**
  - Architecture rows 106–107 still describe the old pruning, and index row 255 has no 0027 entry. Tasks 1.3 and 6.5 own those updates, and both are unticked.
  - The two failing tests are mapped `red`. No artifact claims they are implemented or verified.

## Verdict

VERDICT: APPROVE

The planning corrections fully address round 9's Required Change and its three suggestions. The kept status row closes the health-row leak, live hosts never reach the 24 h expiry, and the two new scenarios can be asserted and are set to fail first. Design, spec, tasks and the in-force ADRs 0025 and 0026 agree. The work still to do is correctly assigned to pending tasks 1.3 and 6.5.

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals