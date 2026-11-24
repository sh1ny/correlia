# Review

## Metadata

- **Round:** 5, owner-authorized additional FULL review
- **Prior round:** REVISE. Persist child transitions across reconnects and prove the admission retry without relying on a PostgreSQL diagnostic emitted before the SQL deadline.
- **Reviewer:** Codex, independent review context
- **Reviewed:** `proposal.md`, `.openspec.yaml`, `design.md`, round-4 `review.md`, the review template and schema, the seven named Dart and Serverpod skills, cited tracked source, and in-force ADRs 0014, 0024, and 0030. The change declares `skip_specs: true`. Verification was by source inspection.

## Findings

### Critical (blocking)

None.

### Moderate

1. **D2 and D4 give conflicting deadline instructions for the same retry fixture.** D2 says the retry case’s database deadlines remain armed. D4 disables `statement_timeout` for the blocked admission. The current write wrapper sets the statement and lock timeouts to the same duration on every transaction. Following D2 can therefore produce `57014` and prevent the fixture from obtaining the required lock-timeout evidence. [Design](design.md#L33) · [Write deadlines](../../../correlia_server/lib/src/ingest/icinga2/stream/database.dart#L97)
2. **D1’s “first matching terminal transition” can select a later header attempt.** The unnumbered attempt has no connection ID for the journal to match. The holder can record another terminal error, retry, and then record `timeout` for the same source. Filtering for the expected error before selecting the first terminal transition would let the later attempt satisfy the first-attempt assertion. [Journal design](design.md#L25) · [Reconnect loop](../../../correlia_server/lib/src/ingest/icinga2/stream/stream_holder.dart#L45) · [Terminal state write](../../../correlia_server/lib/src/ingest/icinga2/stream/stream_holder.dart#L356)
3. **The cutoff-ordering citation omits the statement that takes the contested lock.** D2 cites the admission entry and the batch-receipt claim, but the loop delegates the raw write to `_insertRow`. The watcher must identify the data-modifying CTE that inserts into `raw_inbox` and invokes the cutoff trigger. Watching the preceding batch-receipt claim would miss the intended wait. [Cutoff design](design.md#L34) · [Raw insert CTE](../../../correlia_server/lib/src/ingest/icinga2/stream/admission.dart#L280) · [Cutoff trigger](../../../correlia_server/schema/0007_icinga2_reconcile.sql#L38)

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Replace D2’s final sentence under “Waits held until harness release” with: “For D4’s retry case, keep the ordinary PostgreSQL `lock_timeout` on the exact admission statement and disable its competing `statement_timeout` and client watchdog only in that fixture.”
2. In D1’s transition journal, select the fresh source’s first terminal transition after the activation cursor before checking the error class. Require that transition to be `backoff` with `timeout`, and fail on a different first terminal outcome.
3. In D2’s cutoff-ordering paragraph, cite `admission.dart` at `_insertRow` and `0007_icinga2_reconcile.sql:38-54`. Identify the contested statement as the CTE containing `INSERT INTO raw_inbox`.

CHANGES_APPLIED: yes

## Rebuttals

- **Round-4 transition loss fixed.** The trigger journals source, connection and outcome fields in the status transaction before source activation. A reconnect can overwrite the status row while the earlier committed evidence remains available. Required change 2 makes the first unnumbered attempt explicit.
- **Round-4 diagnostic race fixed.** D4 uses the exact statement’s PostgreSQL lock-timeout error under the same held fixture lock for both attempts, with batch and attempt correlation. The reader retries the same batch after its one-second schedule, and the blocked deadline remains relative to blocked entry. Required change 1 aligns D2 with that mechanism. [Retry loop](../../../correlia_server/lib/src/ingest/icinga2/stream/stream_reader.dart#L290) · [Blocked deadline](../../../correlia_server/lib/src/ingest/icinga2/stream/read_timing.dart#L67)
- **Owner option B preserved.** The real child supplies committed outcomes and ordinary lifecycle evidence. The in-process DB and TLS companions prove lock ordering and controlled timeout-to-EOF behavior.