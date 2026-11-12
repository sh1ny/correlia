# Review

## Metadata

- **Round:** 9
- **Prior round:** 8, APPROVE_WITH_CHANGES (CHANGES_APPLIED: no). It required M1, an accepted ADR for the owner-chosen oversized-intent admission policy, and M2, accurate heartbeat/ownership text plus pruning that cannot erase a live host's supervision history.
- **Reviewer:** fresh-context Claude Code (Opus 5.5) reviewer. I did not read the authoring transcript.
- **Reviewed:**
  - **Change artifacts:**
    - `openspec/changes/output-nats-plugin/design.md` (complete), `tasks.md` (complete) and `review.md` (round 8)
    - `specs/plugin-supervision/spec.md` (complete)
    - `specs/output-delivery/spec.md`: the byte-limit admission requirement and the batch requirement
  - **Architecture and ADRs:**
    - `openspec/architecture.md`: ownership rows 103, 106 and 107, the protocol boundary at line 123, and index rows 255–256
    - `docs/adr/0025-…`: D4 and D19
    - `docs/runbooks/output-nats.md:62-66`
  - **Source:**
    - `correlia_server/lib/src/plugin/plugin_status_repository.dart` (complete)
    - `plugin_health_repository.dart` (complete)
    - `plugin_supervisor.dart`: lines 1–260 and 470–512
  - **Tests:** `correlia_server/test/db/plugin_status_persistence_test.dart`, lines 15–179.
- **Tier:** FULL. I re-checked M1 and M2 and checked coherence across the corrected sections and their tasks.
- **Method:** I only read files. I edited nothing and ran no builds or tests. Tasks 1.3 and 6.5 are pending by intent, so their ADR, architecture and code results were not expected to exist yet. I judged the plan, not the outcome.

## Findings

### Critical (blocking)

None.

### Moderate

- **M1: The planned prune rule (owner-local 60 s, cross-host 24 h) removes the only path that deletes a dead host's health rows once that host has pruned its own last status row. Those health rows then stay forever.**
  - **What the plan says:**
    - D19 (`design.md:525-528`) and the spec (`plugin-supervision/spec.md:82`) say another host's health is removed "only after its last status row expires following more than 24 h without a heartbeat".
    - D11 (`design.md:361-363`) and spec `:98` let the owner delete its own `stopped` rows after 60 s, with no condition.
  - **Why health rows can outlive every status row:**
    - The owner's health prune (`plugin_health_repository.dart:85-93`) keeps a health row while its definition has queued work. That includes queued rows that are not yet due, which can wait up to 300 s.
    - The cross-host cascade (`plugin_status_repository.dart:190-197`) fires only when the same batch deletes a status row of that host. It also skips the caller's own host (`h."hostInstanceId"<>@host`).
    - So a host can be left with health rows and zero status rows. When it dies, no status row remains to expire and the cascade can never fire.
  - **A concrete sequence:**
    1. NATS flaps and the plugin crashes, so the health row records failure times and a backoff step.
    2. The plugin recovers. Its remaining rows are in retry delay, so it is idle-released. Idle release persists `stopped` through `policy.stop()` (`plugin_supervisor.dart:479-491`).
    3. After 60 s the owner prunes that `stopped` row. The health row survives because queued work remains.
    4. The worker is redeployed or killed. Each process has a new random `hostInstanceId`, so no host ever matches those health rows again.
  - **Consequence:** `plugin_definition_health` grows by up to the number of failing live definitions on every restart that falls inside such a window. This contradicts the Resource Bounds row (`design.md:679`, "other hosts only after >24 h silence and last status-row removal") and ADR 0025 D19 ("Prune … dead-host rows alongside status pruning").
  - **Why this is new:** today, another worker's 60 s cross-host deletion usually triggered the cascade first. Under the corrected rule, the owner's 60 s self-prune always runs before the 24 h cross-host expiry, so the orphan path becomes the normal one.
  - **Tests:** the new red test `live_host_with_only_stopped_rows_keeps_health` does not cover this, and no other test does.

### Suggestions

- **S1: Task 6.5 should say what happens to `pruning_spans_bounded_batches_and_preserves_live_host`.**
  - The test (`plugin_status_persistence_test.dart:133-177`) expects an observer to delete two other hosts' 61 s-old `stopped` rows and to cascade `dead-many`'s health. Under the corrected rule both expectations are wrong.
  - Task 6.5's "verify the status, health and admission database tests pass" will fail unless the test is rewritten. The task does not say how to rewrite it.
  - Rewrite it with `dead-many` rows older than 24 h, so it keeps its coverage of the bounded 256-row batches and the dead-host cascade. Also assert that `alive-many`'s 61 s-old stopped rows survive.
- **S2: D4's metadata line still says `Chosen by: agent.` (`design.md:183`).**
  - The inline text at `:144` and the summary row at `:548` say the oversized-intent policy was chosen by the user.
  - Change the line to "agent; oversized-intent policy: user", matching the summary row, so task 1.3's read-back against D4 gives ADR 0027 the right attribution.
- **S3: The ADR bullet for 0027 (`design.md:755-758`) lists the policy contents but not the rejected alternatives (`:179-180`) or the reversal cost, which round 8 required.**
  - Task 1.3's "read-back against D4" probably picks them up. Naming them in the bullet would make the requirement explicit.

**Checked and found coherent:**

- **Prior M1 is addressed by planning.**
  - Design § ADRs adds ADR 0027, refining 0025 D4 without editing it.
  - Pending task 1.3 writes the ADR and updates architecture row 103 and the in-force index, and is verified by `spec:validate` and read-back.
  - The output-delivery requirement "Plugin intent byte-limit admission" and its four mapped scenarios agree with D4 and with the Failure and Resource Bounds rows.
- **Prior M2(a) is addressed in design, spec and task.**
  - D11 (`:357-363`), D19 (`:522-528`), the State & Ownership rows (`:634`, `:637`), the Resource Bounds rows (`:675`, `:679`) and the spec (`:82`, `:98`) now describe:
    - state-specific heartbeats: ready and waiting rows refresh every 15 s, other states are written on transitions;
    - periodic pruning;
    - owner-local 60 s versus cross-host 24 h.
  - All of this matches `plugin_supervisor.dart:116-161`, `writeWaiting`, and the runbook. Architecture rows 106–107 are still stale, which is correct for now because task 6.5 owns that update.
- **Prior M2(b) is addressed for the live-host erasure.**
  - The new scenario "Live host with only stopped instances" has an assertable THEN.
  - It is mapped to a red db test, and pending task 6.5 is red-first.
  - Under the new rule, a live host's rows cannot reach 24 h stale:
    - ready and waiting rows refresh every 15 s;
    - backoff is capped at 60 s;
    - degraded probes run every 5 min;
    - queued-but-not-due work is due again within 300 s.
  - So the 24 h cross-host expiry is safe for live hosts.
- **The 0025 and 0026 ADRs remain compatible.**
  - The new pruning rule refines ADR 0025 D19 rather than contradicting it, apart from M1.
  - No `Chosen by: user` decision is reversed.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

The planning corrections address round 8's M1 and M2: the ADR is planned, the text now matches the code and runbook, and live-host history erasure is closed by a red-first task. One Moderate gap remains. The corrected prune rule lets a dead host's health rows leak permanently once that host has pruned its own last status row, which breaks the stated bound. The fix touches only D11/D19, which the agent chose, plus pending task 6.5.

## Required Changes

1. **M1: Never let the owner's 60 s stopped-row prune remove a status row whose key still has a health row on that host.**
   - In D11 (`design.md:361-363`) and the State & Ownership and Resource Bounds rows (`:634`, `:675`), qualify the owner-local rule: "prunes its own `stopped` rows older than 60 s whose definition has no health row of this host". The surviving `stopped` row then anchors the 24 h cross-host expiry and cascade if the host dies.
   - Put the same qualification in `specs/plugin-supervision/spec.md:98`, and in D19 (`:525-528`) and spec `:82`.
   - Extend pending task 6.5 and the test map with a mapped db test in `S/db/plugin_status_persistence_test.dart`, for example `dead_host_health_expires_after_self_prune`. Host A holds a `stopped` status row older than 60 s and a health row for a definition with queued work. A runs `prune`, and its status row and health row both survive. Host B then runs `prune` more than 24 h later, and A's status and health rows are both removed.
   - Also have 6.5 rewrite `pruning_spans_bounded_batches_and_preserves_live_host` as S1 describes.

CHANGES_APPLIED: no

## Rebuttals