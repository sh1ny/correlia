# Review: source-model-and-secrets, round 4 recheck (M7 only)

- **Scope:** I rechecked only M7 against `tasks.md` group 3 (3.3). M1–M6, M8, N1, N2, S7, D8 and S9–S13 stay closed and are not reopened.
- **Read:** `review.md` (M7 and Required Changes 1) and `tasks.md:1-160`. I relied on the round 3 caller evidence (`relay_subsystem.dart:66-69, 114-117`, `plugin_supervisor.dart:340`) and did not re-read those files.
- Read-only review. No files were edited and no builds or tests were run.

## Recheck

| ID | Finding | Status | Evidence |
|---|---|---|---|
| M7 | Red gate for `historical_outputs_drain_after_a_revision_change` | **Resolved** | `tasks.md:122-127`, option (a) |

### M7: resolved

- **Option (a) is in 3.3.** "Restart without the secret file after importing revision A in both cases" (`tasks.md:124`). The restart comes after A's import and before B. B is then published "while the fileless worker stays running" (`tasks.md:125`), so the worker is already fileless when B lands.
- **The no-restart-after-B assertion is unchanged.** "Then drain revision A's pinned work without another restart" (`tasks.md:125-126`) still holds. Nothing else in 3.3 allows a restart, a reload or a reinjected file map after B. The scenario still proves that A's pinned work drains once B has removed both references.
- **The red run is now real.** Before the reader cutover, both consumers read the startup `bootstrap` map:
  - webhook relay: `relay_subsystem.dart:66-69, 114-117`
  - plugin Configure: `plugin_supervisor.dart:340`

  The worker restarted without the file, so that map does not contain A's references. Two things can happen, and both fail:
  - The worker cannot start without the file.
  - The worker starts but cannot sign the webhook delivery or configure the plugin.

  In both cases the failure comes from the missing store-backed reader, not from a fixture fault. The round 3 objection depended on a worker that still held revision A's file map after B was published. That case can no longer occur.
- **The red gate is still in place.** The red-run command and "confirm both fail" stay before the consumer switch (`tasks.md:126-127, 131`), and the flip-to-green comes after it (`tasks.md:136`).

## Notes (non-blocking)

- **The red signal does not isolate B.** Before the cutover, this test fails for the same reason as `fileless_worker_delivers_both_outputs`: a fileless worker cannot sign or configure. B's removal of the references is only exercised by the green run. That is acceptable for a gate that must be red before the cutover, and option (a) allowed it.
- **Wording clash in 3.3.** `tasks.md:111` makes the secret file optional in `IngestBootstrap.load` before the consumers switch, but `tasks.md:131-132` says "before allowing fileless startup". Either order still produces a real red, but one phrasing would help whoever implements it. Consider settling on one order: either fileless startup is allowed only after the readers move, or it is allowed early and the red is expected to be a signing or Configure failure.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

None remain for M7. The two notes above are optional.

CHANGES_APPLIED: yes