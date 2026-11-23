# Review

## Metadata

- **Round:** 3
- **Prior round:** round 2 (omp) REVISE: 5 Critical (regressing execution end behind the fence; whole-second webhook key; publication race on consumer writes; backlog moved into Icinga 2 and failed rows uncounted; sync chunk rollback), 5 Moderate (CheckResult state type and stop vs database work; gap persistence; bare password digest and CA bound; dotted unknown names; webhook retry claim). Owner chose to fix and run round 3.
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design and all four deltas; main `source-ingress`, `durable-pipeline`, `alert-state` and `canonical-event` specs; project rules, M2 roadmap and the six requested acceptance scenarios; architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029. Checked the cited ingest, pipeline, state, identity, schema and runtime code, `event.proto`, archived Alertmanager D6 and capture script, and relevant Icinga 2 v2.13.0 source. Read-only; no tests or captures run.

## Findings

### Critical (blocking)

1. **D15 creates an ordering cycle; the same raw rows can leave an alert firing or resolved.** Let A be CRITICAL at source time 10:04, observed 10:05; S a sync reporting OK at source time 10:02, subscribed at 10:20; and B a subsequent WARNING at source time 10:03, observed 10:21. These are possible with increasing passive-check starts and nonmonotonic ends, exactly the case D15 addresses. The proposed rules give S > A, A > B, and B > S. `transition.dart:100–119` retains one winning fence, so A→S→B ends WARNING, B→A→S ends resolved, and S→B→A ends CRITICAL. Pairwise determinism is not transitivity. Replace the comparison with a convergent rule grounded in evidence the paths actually carry. Exercise three observations in every processing order, not just separate pairs, and reconcile the unchanged “Ordering fence decides state changes” requirement with the new rule.

2. **A reconnect can know the current state and still be prevented from repairing it.** First sync an OK with `last_state_change=10:04`. Then process a CRITICAL ending at 10:05 and disconnect. Icinga can accept a subsequent OK with a later `execution_start` but the same 10:04 end as the first OK. The new sync has the same D2 event ID as the first. `pipeline.dart:389–421` classifies it as a duplicate before fencing, and `alert_state_service.dart:155–184` gives duplicates only a freshness update. D15 explicitly preserves the wrong firing state and calls it `diverged`. Separate fresh reconciliation evidence from event-publication deduplication, or prove a key that distinguishes these transitions. Assert repair before the original key expires, without republishing an unchanged observation.

3. **Webhook fractions fix rounding, not the race between notification creation and macro evaluation.** Icinga 2 v2.13.0 [`Notification::BeginExecuteNotification`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/notification.cpp) queues an asynchronous callback with the triggering check result; [`Service::ResolveMacro`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/service.cpp) reads `state` and `state_type` from the mutable service. D3 also reads `last_state_change` from that object. If the recovery callback runs after a refire, it can send the refire's state and timestamp under `RECOVERY`, losing the recovery or deduplicating it against the refire. In-order HTTP delivery does not fix this. Before freezing IDs, prove that state, state type and key evidence describe the notification being sent even when the callback is delayed across a transition. A capture that waits for each command before submitting the next result does not prove that.

4. **D7's host query requests a service-only attribute.** The listed attribute projection includes `host_name` for `/v1/objects/hosts`. In v2.13.0, [`service.ti`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/service.ti) declares it and `Host` does not inherit it. [`ObjectQueryHandler::SerializeObjectAttrs`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/remote/objectqueryhandler.cpp) rejects an unknown requested field with HTTP 400. As specified, the first query fails on a deployment with hosts, so the consumer never reaches service sync. Specify the projections separately, including which name supplies the service short name, and capture both actual consumer requests and responses.

5. **An admitted stream batch can drop a valid recovery without triggering reconciliation.** D7 isolates malformed *sync* objects, but D6 still puts up to 100 stream lines in one atomic raw row. The integration spec explicitly requires an unsupported line to fail that row; `pipeline.dart:328–355,529–545` commits no sibling effects on validation failure. A valid recovery beside the offending line is therefore lost after successful admission. D12 counts abnormal connection endings, not downstream batch failures, so an otherwise busy stream can stay `connected` without repairing the alert. Preserve raw-row atomicity, but define either isolation before batching or a durable failure-to-reconciliation path. Test a bad line and a valid recovery in the same flush while the connection remains healthy.

6. **The 30-second pause timer does not bound sustained upstream queue growth.** Icinga's [`EventsInbox::Push`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/remote/eventqueue.cpp) has no size limit. If each flush takes two seconds and Correlia reads one batch between pauses, no individual pause reaches 30 seconds. If Icinga produces faster than that, its queue grows throughout the connection even while Correlia's durable backlog remains low. Disconnect on sustained saturation, not just one long stall. Exercise repeated short pauses with production above drain rate and assert that the connection closes. The failed-row accounting and one-line batch rule address the other parts of round 2's backlog finding.

7. **The password can still acquire a bare digest through another supported secret use.** D9 screens inbound credentials, but ADR 0028 also preserves bare commitments for outbound webhook signing keys and historical M1 pins. `bootstrap.dart:233–250` accepts a 32-byte signing key and serializes its SHA-256 as the output commitment; `config_repository.dart:186–200` retains the commitment. A 32-byte UTF-8 stream password passes both shape checks, and D9 allows the reuse. Enforce the invariant across all bare-commitment uses, including different references with equal bytes, and in both publication directions. Test adding a bare-commitment use after a stream password was already published.

### Moderate

1. **The publication lock closes the round-2 race, but the shutdown deadline still has no enforcement.** `admission.dart:58–75` and `config_repository.dart:202–249` support D5's source-lock protocol. PostgreSQL's two-second statement and lock timeouts do not bound the whole transaction, pool acquisition, or time spent idle after the locks are taken. D8's own paused-after-locks test can exceed five seconds without executing a timed statement. Specify an end-to-end deadline and cancellation or connection-discard behavior. Test that the transaction releases its locks before shutdown returns, not merely that the caller stops awaiting it.

2. **The takeover heuristic can double-count a recorded gap.** A can close its stream, commit the gap with status `backoff`, and die before opening another connection. B sees a state other than `stopped` and increments again for the same connection. Conversely, a commit with a lost acknowledgement can cause A to retry the increment. Persist enough connection identity to make gap recording idempotent, or explicitly specify an approximate counter instead of the current exactly-once contract. Cover takeover from both `connected` and already-counted `backoff`.

3. **`CheckResult` needs explicit host-state normalization before keying.** Reading `vars_after.state_type` fixes the round-2 field issue. But [`ProcessCheckResult`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/checkable-check.cpp) puts raw `ServiceState` in `vars_after.state` even for hosts, while [`StateChangeHandler`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/apievents.cpp) emits `Host::GetState()`. [`Host::CalculateState`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/host.cpp) maps raw WARNING to UP and raw CRITICAL/UNKNOWN to DOWN. Without normalization before D2 key construction, the same host check can fail decoding, map to the wrong status, or produce two IDs. Include a real host capture with both event types enabled; the service-only `hard_only` scenario cannot catch this.

4. **`last_sync=complete` proves admission, not successful reconciliation.** D7 now isolates decoder-invalid sync objects, but the pipeline can still fail a valid chunk after pre-validation: it enforces a 10-second processing budget, a 16 MiB aggregate fanout limit, and a finite internal retry budget (`pipeline.dart:19–20,443–495,626–667`). A 500-object chunk routed to eight outputs can require thousands of sequential database operations, then exhaust retries while status stays `complete`. Define chunk limits against the pipeline's actual budgets and distinguish completed admission from failed application. Exercise a valid chunk whose application fails after admission.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

Resolve the blocking findings in the design and corresponding specs before implementation review. Keep the source-row publication lock, structural redaction, importer-bound scenario and webhook no-retry documentation. Add the mixed-order, repeated-key, delayed-notification, mixed-batch, sustained-pressure and secret-reuse cases to the acceptance plan.

CHANGES_APPLIED: n/a

## Rebuttals

None.