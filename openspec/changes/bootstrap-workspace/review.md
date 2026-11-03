# Review

## Metadata

- **Round:** 10
- **Prior round:** Round 9, APPROVE_WITH_CHANGES; C2 critical; CHANGES_APPLIED: no.
- **Reviewer:** Fresh-context, read-only Codex reviewer.
- **Reviewed:** HEAD fix `220adb8`; preceding drift and autonomous-mode commits; planning diff from `77820ff`; proposal, design, both delta specs, tasks, rounds 8 and 9 reviews; AGENTS.md; ADRs 0002 and 0014; Serverpod 4.1.0 ephemeral-database provisioning, embedded resolver, supervisor, transport and environment configuration sources, and Serverpod shutdown; uncommitted `child_server.dart` and `kill_recovery_test.dart`. No files modified or runtime tests executed.

This verdict covers only the contents reviewed. Subsequent planning edits other than applying Required Changes or editing only the proposal’s Release Notes section void it.

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

None.

The replacement resolves C2 within the accepted S8/D4 baseline. `EphemeralTestDatabase` uses Serverpod’s existing shared-cluster provisioning and recovery; the SIGTERM test adds no separate cluster startup, stop handle or PostgreSQL signal mechanism. Fresh start, live reuse, recovery after reboot and startup-failure cleanup remain Serverpod’s shared-cluster lifecycle, including its previously accepted signalling risks.

The child connection is feasible. Environment values override YAML even when the value is empty; the database parser converts an empty `SERVERPOD_DATABASE_DATA_PATH` to `null`, and the embedded resolver returns without starting or attaching PostgreSQL. Explicit host, port, database name and `SERVERPOD_DATABASE_IS_UNIX_SOCKET=true` can connect it to `.serverpod/test/run`. Unix-only transport uses port 5432 as the socket filename suffix; that does not require contacting TCP port 5432 or `/tmp`.

D7, task 8.2 and the test map require the real child to receive SIGTERM, complete subsystem shutdown before pool closure and exit 0. Serverpod’s inspected shutdown sequence supports that proof without the embedded supervisor’s competing signal hook. Implementation and runtime proof remain pending tasks.

D8, State & Ownership, the Mechanism Ledger and task 9.4 agree that the SIGTERM child owns an ephemeral database rather than a cluster root, drops it after child exit, and leaves only the shared cluster eligible to linger. Development-mode exit 143 and potentially interrupted subsystem shutdown are explicitly recorded in D7, the diagrams and Risks; this review carries forward the owner-retained limitation.

## Verdict

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

- **M1–M6:** Previously accepted by reviewer; carried forward.
- **C1/C1a:** Withdrawals accepted by reviewer; carried forward. No replacement shared-cluster shutdown mechanism is approved.
- **C1b:** Withdrawal accepted by reviewer; carried forward. Serverpod’s existing recovery and signalling race remain the accepted S8/D4 baseline.
- **M7:** Withdrawal accepted by reviewer; carried forward.
- **C2:** **Fixed and accepted by reviewer.** HEAD replaces the test-owned detached cluster with an ephemeral database on the shared test cluster, removes `.serverpod/test-external/`, and updates D7, D8, State & Ownership, the Mechanism Ledger and tasks 8.1, 8.2 and 9.4 consistently.