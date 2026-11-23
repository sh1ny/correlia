# Review

## Metadata

- **Round:** 1
- **Prior round:** none
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, and all four delta specs; main `source-ingress`, `durable-pipeline`, `alert-state`, and `canonical-event` specs; `AGENTS.md`; M2 roadmap and requested acceptance scenarios; architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028, and 0029.
- **Source evidence:** `source_config.dart`, `ingress.dart`, `admission.dart`, `alertmanager_decoder.dart`, `bootstrap.dart`, `config_repository.dart`, `pipeline.dart`, `ordering_key.dart`, `transition.dart`, `alert_state_service.dart`, `identity.dart`, `0001_ingest.sql`, `schema_steps.dart`, `registry.dart`, `ingest_workers.dart`, and `event.proto`; archived Alertmanager design D6 and `tool/alertmanager_capture.sh`; upstream Icinga 2 API reference and check-result processing source. Read-only review; no tests run.

## Findings

### Critical (blocking)

1. **Reconnect cannot repair a missed recovery older than seven days.** D7 and the “Recovery missed while disconnected” scenario use the object's `last_state_change` and promise to resolve the alert. If a service recovers on day 1 of a nine-day disconnect and stays OK, `pipeline.dart:29–43,424–428` classifies the sync observation as `late` and never sends it to `AlertStateService`. Every subsequent sync sees the same old timestamp; the alert can stay firing indefinitely while the consumer reports `connected`. ADR 0017 and ORD-6 prohibit letting ordinary late evidence mutate state. Define how a current-state read reconciles after that horizon without admitting a delayed webhook or overwriting a newer live change, or explicitly narrow the recovery guarantee. Add a long-disconnect case with a concurrent newer stream observation.

2. **The shared observation key has contradictory inputs, and first-writer dedup makes the choice observable.** Proposal S3 and ADR 0024 name check execution end; D2/D7 and the delta use `last_state_change` except for `CheckResult`. These are not interchangeable. [Upstream check processing](https://github.com/Icinga/icinga2/blob/master/lib/icinga/checkable-check.cpp) updates `last_state_change` when the state value changes and separately records a HARD transition; a CRITICAL first seen SOFT at `t1` can become HARD at `t2` without moving `last_state_change`. The [documented `StateChange` payload](https://icinga.com/docs/icinga-2/latest/doc/12-icinga2-api/#event-stream-type-statechange) carries an event timestamp and check result, not the object's last state change. D11 also preserves distinct state names (`UNREACHABLE` and `DOWN`) that D2 puts in the key. Divergent keys can publish the same logical change twice; equal keys with different summaries can make the stored alert display depend on whether the state-only sync or the live event wins the insert (`pipeline.dart:382–420`; `alert_state_service.dart:22–44`). Before freezing IDs, capture **webhook, stream, and sync for the same transition**, including SOFT→HARD without a state-value change and opt-in `CheckResult`. Specify each path's evidence, which observations are intentionally distinct, and what alert projection must agree for events that deduplicate. Amending only the unchanged-reconnect scenario does not settle those contracts.

3. **Lease handover and configuration rotation are not fenced at the write boundary.** D5 declares a generation, but the mechanism ledger explicitly omits fencing on raw writes and D12 defines no generation guard on status. If A stalls past expiry, B can take the lease and sync while A's blocked flush is still in flight. A can then commit evidence from a replaced endpoint under the same source UUID; `pinOne` selects the *current* snapshot (`pipeline.dart:207–236`), and observation dedup cannot reject a distinct, newer observation from the old endpoint. A late status write can also overwrite B's state. Existing `IngestAdmission.admit` cannot implement this as written: it requires a webhook `SourceCredential` and rechecks that credential's row (`admission.dart:38–103`), not consumer ownership or the connection configuration. Define consumer authorization on the shared insert path: atomically check holder generation, database-clock expiry, and the active connection configuration before raw/transport or status writes. Preserve the intended first-claim pin for work already admitted. Prove a paused old holder cannot write after takeover or endpoint rotation.

4. **The batch limits do not bound the backlog, and sync cannot recover everything lost before admission.** D6 bounds one assembling batch, not what happens while its database insert is blocked. If reads continue, queued batches can grow; if reads pause or the connection closes, unread events can be lost. The resource table explicitly leaves durable raw growth unchecked until change 6, despite ADR 0016's ingest budget and pause policy. At sustained input above drain rate, retained raw rows can exhaust the database used by webhook ingest too. Reconnect sync only reads current host/service state: it cannot recover a lost acknowledgement, downtime, flapping transition, per-check event, or a problem that recovered during the gap. Define a bounded read-to-commit policy and a durable admission limit for the configuration shipped by this change, or make the consumer depend on the budget change. Specify what happens on a failed flush, how operators see a possible gap, and which evidence is best-effort before commit. Exercise a blocked insert and a stream interruption with valid uncommitted lines.

### Moderate

1. **A healthy subscription can omit all state updates, or a stalled subscription can hold the lease indefinitely.** `event_stream.types` can be an informational-only selection. Continuous informational traffic then prevents the idle timeout, and a missed state change is never reconciled despite `connected`. Separately, D8 bounds socket connect, sync response, and stream idle, but not the wait for subscription response headers before a stream exists. Require a state-bearing subscription for the continuous-state guarantee, or document a separate informational-only mode. Give subscription establishment a deadline and specify cancellation of connecting, syncing, and reading on shutdown or lease loss, before `IngestWorkers` tears down its dependencies.

2. **D9's CA and password contract needs explicit changes to secret import.** The advertised 64 KiB CA bundle cannot enter through the existing importer: `bootstrap.dart:432–447` caps each decoded secret at 16 KiB. `config_repository.dart:286–300` enumerates inbound credentials and output secrets, not consumer credentials. Reusing the inbound credential commitment scheme would also expose a bare hash for a potentially low-entropy API password, contrary to ADR 0028's rationale for keyed commitments. Pick an importable CA limit, or explicitly extend and test the byte budget. Define keyed password commitments, shared-reference behavior, and publication-time validation from both file and stored records.

3. **The delta promises diagnostic paths the current pipeline deliberately redacts.** The webhook spec requires an unknown field's path and exact paths such as `format` and `last_state_change`. The pipeline persists `_safePath(error.path)` (`pipeline.dart:65–87,354–355`), using a fixed allowlist. Without updating it, known Icinga2 fields become `*`; reflecting arbitrary field names would undo the credential-safe rule established by the Alertmanager precedent. Specify structural paths for known fields and a redacted segment for sender-controlled unknown names. Assert the persisted failure diagnostic, not only the parser exception.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

Address the four blocking findings in the design and corresponding delta specs before implementation review.

CHANGES_APPLIED: n/a

## Rebuttals

None.