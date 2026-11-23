# Review

## Metadata

- **Round:** 2
- **Prior round:** round 1 (omp) REVISE: 4 Critical (missed recovery older than 7 days; contradictory shared observation key; unfenced lease handover and rotation; unbounded backlog and unrecoverable gaps), 3 Moderate (subscription deadline and informational-only types; CA size and password commitments; redacted failure paths)
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design and all four deltas; main `source-ingress`, `durable-pipeline`, `alert-state` and `canonical-event` specs; `AGENTS.md`, M2 roadmap and requested acceptance scenarios; architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029. Checked cited ingest, pipeline, state, identity, schema and runtime code, plus configuration publication and startup; `event.proto`; archived Alertmanager D6 and capture script; upstream Icinga 2 API documentation and source, including v2.13.0. Read-only; no tests or captures run.

## Findings

### Critical (blocking)

1. **C1 — Exempting sync from lateness still leaves a missed recovery permanently behind the fence.** D7 and “Newer live change beats an old sync” assume that Icinga’s accepted check order is execution-end order. [`ProcessCheckResult`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/checkable-check.cpp) rejects older results by `execution_start`, but assigns `last_state_change` from `execution_end`. A passive CRITICAL with start 10:00/end 10:04 can be followed by an accepted OK with start 10:01/end 10:02, submitted later. If Correlia saw the CRITICAL and missed the OK, every reconnect sync reports OK at 10:02. The exemption gets it to the fence, but `ordering_key.dart:43–49` and `transition.dart:100–119` still reject it against 10:04. Subsequent syncs deduplicate it. Define the ordering evidence that makes reconciliation safe, or explicitly bound it to an upstream ordering assumption and make violations visible. Test an accepted recovery with a regressing execution end alongside the existing newer-live case. Apply the resulting exception consistently to the main pipeline and alert-state lateness requirements; the new ORD-6 requirement is currently unqualified and mandates the opposite result for an old firing sync.

2. **C2 — The shipped webhook can deduplicate distinct problems before they reach alert state.** Separate path domains fix the cross-path identity contradiction, but not the precision of the actual sender. [`Service::ResolveMacro`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/service.cpp) casts `last_state_change` to `long`, losing fractional seconds before `jq` sees it. With HARD CRITICAL → OK → HARD CRITICAL in one second and all three notifications delivered in order, D2 gives the two problems the same key. `pipeline.dart:389–418` suppresses the second problem before state mutation, leaving a webhook-only source resolved. Capture that sequence through the shipped command, distinguish the two problems while preserving reminder dedup, and lock the event-id contract only after the capture proves the chosen evidence. Correct proposal S3’s heading, which still says sync shares the stream key.

3. **C3 — The lease lock does not fence configuration publication.** D5’s `FOR SHARE` serializes against takeover, but not against `IngestConfigRepository` publication, which updates `ingest_source` and then `ingest_active_config` (`config_repository.dart:202–249`). A can lock its lease and read revision N; publication can commit N+1; A can then insert and commit an old-endpoint row pinned to N. The existing rotation scenario only covers an unflushed batch, not publication between the check and commit. The status write has the same hole: a generation predicate alone does not serialize against publication or a concurrent takeover. Lock the publication boundary for raw and status writes, define lock order and bounded transaction lifetime, and test with independent connections paused after authorization. Existing webhook admission demonstrates the source-row lock on the publication path (`admission.dart:66–75`).

4. **C4 — The backlog limit can protect neither Icinga nor shared storage under sustained pressure.** D6 pauses the socket indefinitely if the in-flight flush stalls. [`EventsInbox::Push`](https://github.com/Icinga/icinga2/blob/master/lib/remote/eventqueue.cpp) queues events without a size limit while the [stream handler](https://github.com/Icinga/icinga2/blob/master/lib/remote/eventshandler.cpp) waits on the HTTP write. TCP backpressure can move memory growth to Icinga rather than stopping it. On the Correlia side, pending-only admission does not count failed rows: `_fail` changes their status to `failed` without removing the body (`pipeline.dart:598–622`), so a repeating format mismatch can fill storage without reaching 10,000 pending rows. Bound time spent paused and bytes admitted, including retained failures, or make the consumer depend on the ADR 0016 storage watermark. Reconcile the 1 MiB line limit with the claimed 256 KiB batch cap; a valid line between those limits otherwise has no defined disposition.

5. **Sync can report `connected` after discarding the recovery it was meant to reconcile.** D7 batches up to 500 objects per raw row, and the state diagram enters `connected` when the raw inserts commit. The pipeline rolls back an entire raw row on one invalid member (`pipeline.dart:328–355,529–545`; durable-pipeline “Atomic raw processing outcome”). A recovery and an unrelated object that fails decoding in the same chunk therefore yield no recovery, even with a healthy stream and successful sync inserts. Reconnect can reproduce the same failure. Keep raw-row atomicity, but define how a failed sync chunk is surfaced and how valid objects get reconciled. Add a scenario that places the recovery and an invalid member in the same sync chunk and asserts both the alert outcome and reported sync health.

### Moderate

1. **M1 — The HTTP gaps are addressed; the stop guarantee is not.** D8 adds the 10-second header deadline and D10 requires a state-bearing type. For `CheckResult`-only mode, specify `check_result.vars_after.state_type`: [the emitter](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/apievents.cpp) does not send top-level `state_type` for `CheckResult`, but upstream check processing supplies it in `vars_after`. Test that mode independently under `hard_only`. Also, force-closing `HttpClient` does not cancel a PostgreSQL commit or lease renewal. Specify how stop cancels or drains database work before closing dependencies, and test shutdown during admission, not only during an HTTP read.

2. **Gap persistence is required precisely when the writer cannot persist it.** “Consumer gap visibility” requires a durable increment for every refusal or failed flush. `lease_lost` and `config_changed` prohibit the old holder’s status write, and the database-outage scenario makes the status store unavailable. Define when the surviving holder retries the update, what the next holder records after takeover, and how overlapping flush failure and disconnect signals count as one gap. Assert the status after database recovery and after takeover.

3. **M2 — The CA byte cap and keyed scheme are specified, but shared references can still expose an unkeyed password digest.** D9 permits an identical secret to be shared with another use. A 32-byte, low-entropy password can also pass the inbound credential check, which stores a bare SHA-256 digest (`source_config.dart:243–253`; ADR 0029). Keying the stream commitment does not remove that digest. Disallow password references that have a bare commitment, including historical commitments, or narrow the security guarantee explicitly. Also align the oversize-CA failure scenario with the importer: a file value above 16 KiB fails at `secrets.value` before `ca_ref` validation (`bootstrap.dart:432–447`).

4. **M3 — Redact unknown names before rendering paths.** The revised scenarios correctly assert persisted diagnostics. D14 only extends `_safePath`’s allowlist, though, and the current implementation splits rendered strings on `.` (`pipeline.dart:65–98`). If a parser interpolates an unknown key such as `state.type` first, allowlisted segments can survive instead of becoming one `*`. Require parsers to emit a structural wildcard at the unknown-key boundary and test a dotted unknown name made of allowlisted segments.

5. **The webhook-only failure table promises a retry Icinga does not guarantee.** D3 makes the script exit nonzero, which is useful for logging. [Icinga’s notification scheduler](https://github.com/Icinga/icinga2/blob/master/lib/icinga/notification.cpp) schedules periodic problem reminders independently of command success; it does not schedule a retry of a failed recovery. A webhook-only install can retain a firing alert after a 503 on its recovery. Remove the retry claim and document webhook-only loss, or provide a bounded sender retry contract and test it.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

Resolve the five blocking findings in the design and corresponding specs before implementation review. Capture the real sender’s ordering and identity evidence before freezing event IDs; exercise the publication race, resource limits and failed sync chunk at the layer that enforces each contract.

CHANGES_APPLIED: n/a

## Rebuttals

None.