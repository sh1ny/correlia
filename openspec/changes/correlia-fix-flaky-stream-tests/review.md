# Review

## Metadata

- **Round:** 2
- **Prior round:** 1
- **Reviewer:** Codex
- **Scope:** Correlia #77. Rechecked only the five round-one Required Changes against the revised design and tracked source. Files were unchanged. No builds or tests were run.

## Findings

All five required design changes are applied. There are no remaining edits within the re-check scope.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Amend D1 and the sequence diagram to define test-controlled spacing that remains ineligible for all intervening attempts regardless of runner latency. Keep the existing direct spacing test. At each twelfth reconnect, require a committed completed read and `connected` status tied to that connection before closing it. Preserve the final assertions for 120 subscriptions, 119 gaps, and 10 syncs. Specify a committed `LISTEN` registration on a dedicated connection to the test group’s embedded database, fresh predicate reads, and teardown of the listener and test-owned triggers and functions.

   **Result — Applied.** D1 parks the ended attempt before changing spacing and uses a future timestamp beyond the whole-test guard to keep intervening reconnects ineligible. The diagram shows the spacing fence for intervening attempts and a fresh read of the committed successful sync and `connected` status for the same connection ID and sequence before closing each twelfth reconnect. D1 keeps the direct spacing test and all three totals. It also specifies committing `LISTEN` on the dedicated group database connection before writers start, reading fresh predicates after notifications, and removing the listener, triggers, and function after the workers stop. [D1](openspec/changes/correlia-fix-flaky-stream-tests/design.md#d1-test-waits-observe-committed-changes-and-lifecycle-events) · [Sequence diagram](openspec/changes/correlia-fix-flaky-stream-tests/design.md#diagrams-full) · [Tracked spacing gate](correlia_server/lib/src/ingest/icinga2/stream/sync_progress.dart#L131)

2. Amend D2 to name the completion signal for each supervisor’s first acquisition pass over the expanded target set. Require both signals before checking cumulative consumer opens and active sessions by worker and source against the 64 real lease rows. Preserve the simultaneous stop.

   **Result — Applied.** D2 signals successful acquisition-scan completion after each supervisor scans the expanded set. The test-only launch hook records the source ID and open future immediately, covering opens that are still pending when the scan ends. After both scans complete, the test awaits the recorded futures and checks cumulative opens and live sessions against all 64 lease rows by `(holder, sourceId)`, with one of each per leased pair and zero per nonholder pair. Both workers then stop concurrently. [D2](openspec/changes/correlia-fix-flaky-stream-tests/design.md#d2-stop-workers-after-there-is-no-upstream-response-left-to-write) · [Acquisition scan and worker launch](correlia_server/lib/src/ingest/icinga2/stream/supervisor.dart#L162) · [Asynchronous consumer open](correlia_server/lib/src/ingest/icinga2/stream/stream_holder.dart#L30)

3. Amend D2 and Failure & Visibility to require successful current-attempt sync outcomes and completion of the corresponding fixture object responses before stop. Define how unexpected request, listener, header-flush, and detached-socket errors reach the test. Scope any expected peer-close handling to the specific socket and deliberately staged disconnect.

   **Result — Applied.** D2 waits for the 64 initial `connected` rows joined to their successful completed reads and for successful fixture closes on both object routes. Failure & Visibility sends request-handler failures, HTTP listener errors, header-flush failures, detached-socket input errors, and `socket.done` failures to one first-error future. The test races that future against readiness and checks it through teardown. The exception applies only to the expected peer-close errno on the specific established event socket marked for deliberate shutdown. [D2](openspec/changes/correlia-fix-flaky-stream-tests/design.md#d2-stop-workers-after-there-is-no-upstream-response-left-to-write) · [Failure & Visibility](openspec/changes/correlia-fix-flaky-stream-tests/design.md#failure--visibility-full) · [Tracked fixture handlers](correlia_server/test/support/icinga2_consumer_loopback.dart#L43)

4. Amend D3 to require a backend-side statement-entry signal and an independently observed transaction-lock release while the deliberate blocker remains held. Check client closure, rolled-back writes, and survival of unrelated work before releasing the blocker. Keep production shutdown settings and use the whole-test hang guard for missing signals.

   **Result — Applied.** In the running-SQL scenario, one backend statement releases the session entry lock and then attempts the observer-held blocker. The test lifts both statement and lock timeouts so the statement stays in flight until shutdown interrupts it. In both scenarios, D3 requires observing dedicated client closure, independently acquiring the transaction’s advisory lock, verifying the staged writes are absent, and checking that unrelated transaction work survives before releasing the Dart gate or SQL blocker. D3 retains the production shutdown settings and bounds the waits with the whole-test guard. [D3](openspec/changes/correlia-fix-flaky-stream-tests/design.md#d3-prove-shutdown-ordering-against-database-work-still-blocked) · [Tracked shutdown tests](correlia_server/test/db/icinga2_stream_stop_test.dart#L103) · [Shutdown scenarios](openspec/specs/icinga2-event-streams/spec.md#scenario-stop-during-a-stalled-insert)

5. Qualify the `Broken pipe` attribution in Context and record the unconfirmed emitter in Assumptions. Add carried-constraint entries with one destination each. Use ADR 0014 for the embedded database boundary and test or fixture doc comments for the synchronization and socket-error rules.

   **Result — Applied.** Context describes a possible TLS close/write ordering. A1 records that the historical emitter is unconfirmed and that the CI log lacked an application stack. C1–C3 each name one destination. The embedded database boundary goes to ADR 0014, synchronization goes to the `IcingaTestDbChanges` doc comment, and socket-error handling goes to the `IcingaConsumerLoopback` doc comment. [Context](openspec/changes/correlia-fix-flaky-stream-tests/design.md#context) · [Assumptions and carried constraints](openspec/changes/correlia-fix-flaky-stream-tests/design.md#assumptions) · [ADR 0014](docs/adr/0014-linux-first-platform.md#L34)

CHANGES_APPLIED: yes

## Rebuttals

None.