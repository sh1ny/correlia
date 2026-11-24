# Review

## Metadata

- **Round:** 3
- **Prior round:** Round 2 approved the design with all five required changes applied.
- **Reviewer:** Codex
- **Reviewed:** Correlia #77 amendments to D3 and C1 and the owner-approved `icinga2-event-streams` evidence delta, checked against the shutdown and database source, the amended stop tests, the TLS fixture, ADR 0014, and the existing specs. No files were written and no tests were run.

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

None.

## Verdict

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

- **D3 lock and cancellation evidence verified.** The observer keeps its transaction open until test cleanup. The transaction advisory lock and absence of staged rows witness rollback, while the dedicated connection’s session-level advisory lock survives rollback and independently witnesses backend session end. For running SQL, the backend releases the entry lock from inside the statement before entering the repeated `pg_sleep(30)` loop. Repeating the interruptible sleep keeps the statement in flight through slow staging. [D3](openspec/changes/correlia-fix-flaky-stream-tests/design.md#d3-prove-shutdown-ordering-against-database-work-still-blocked) · [Stop tests](correlia_server/test/db/icinga2_stream_stop_test.dart#L185)
- **D3 timer evidence and spec delta verified.** The holder arms a four-second admission abort, and the supervisor arms one ten-second deadline around the combined stop futures. The test-only Zone checks the timer durations and counts, fires the admission aborts explicitly, and verifies that stop disarms the shared deadline without firing it while admission gates remain held. The delta adds two verification notes and preserves every existing requirement and scenario, including the five-second PostgreSQL outcomes. The approved evidence checks the one-second disconnect setting and observes actual backend cleanup. It leaves elapsed backend latency unmeasured. [Holder shutdown](correlia_server/lib/src/ingest/icinga2/stream/stream_holder.dart#L152) · [Supervisor shutdown](correlia_server/lib/src/ingest/icinga2/stream/supervisor.dart#L283) · [Spec delta](openspec/changes/correlia-fix-flaky-stream-tests/specs/icinga2-event-streams/spec.md)
- **C1 verified.** The fixture’s class doc comment identifies the local TLS boundary, and the implementation uses `HttpServer.bindSecure` on IPv4 loopback. Accepted ADR 0014 and the workspace-tooling spec continue to require the worktree’s own embedded PostgreSQL. [TLS fixture](correlia_server/test/support/icinga2_consumer_loopback.dart#L5) · [ADR 0014](docs/adr/0014-linux-first-platform.md#decision) · [Workspace tooling spec](openspec/specs/workspace-tooling/spec.md#requirement-tests-use-only-their-own-postgresql)