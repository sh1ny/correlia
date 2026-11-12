# 0025. Plugin protocol v1 output contract and supervision

- Status: accepted (2026-11-12)
- Date: 2026-11-12
- Supersedes: none
- Chosen by: agent

## Context

The experimental probe proves the transport, not a production delivery contract. Production outputs must preserve pinned definitions and exact event bytes across process death without introducing a second queue. This additive decision implements the output subset of ADR 0020 using the transport accepted in D24.

## Decisions

### D1: Output protocol

`correlia.plugin.v1` defines metadata, Configure with separate config and secret bytes, bounded health calls, and a bidirectional delivery stream. Metadata includes name, version, kinds, config JSON Schema and protocol minor. Configure accepts limits or returns field errors. Batches carry increasing sequences and event ids with exact payloads. Each response covers every event exactly once with acknowledged, retryable or rejected outcomes; failures carry error classes matching `^[a-z][a-z0-9_]{0,63}$`. Malformed answers fail the connection. A stream is one epoch. The cookie is `CORRELIA_PLUGIN=correlia.plugin.v1`, application protocol 1, distinct from the spike.

Rejected: whole-batch acknowledgements, which let one bad event consume the entire batch's retry budget. Reversal cost: medium; external authors may depend on the pre-1.0 contract.

### D4: One durable queue and one batch budget

The outbox remains the only queue. Webhooks claim one row. Plugin claims select the oldest due ready definition and at most 64 rows / 1 MiB of that digest; one delivering set per output remains enforced across workers. A batch shares a claim and 30-second lease, with one attempt per intent. A monotonic 27-second deadline begins before acquisition: claim commits within 5 seconds, delivery gets at most 20 seconds while reserving 5 seconds for completion, and each SQL statement and lock timeout is bounded by the remaining time and 5 seconds.

Completion updates outbox and attempts in one transaction using set-based updates, fenced by claim id, delivering status and `lease_until > clock_timestamp()`. Both exact affected-row counts must match or everything rolls back. Over-budget work writes no completion; lease recovery records interruption and redelivery retains ids and bytes.

Rejected: the spike's in-memory pending queue, per-row batch completion, and independent statement budgets. They create competing ownership or allow completion beyond the lease. Reversal cost: medium.

### D5: Readiness and acquisition boundary

The supervisor publishes its ready `(output, definition digest)` set. Acquisition first takes a launch-generation permit, then claims only that digest. Observed exit, failed health or connection loss invalidates old permits. The last transaction step before COMMIT checks the permit; invalidation rolls back rows and attempts. Loss observed after that check makes unanswered deliveries retryable `plugin_connection_lost`. Voluntary stops wait for outstanding permits. Unavailable definitions spend no attempts and do not block other ready definitions.

Rejected: claiming while down and failing fast, or checking readiness only at discovery. Both burn attempts for local unavailability. Reversal cost: low.

### D6: Supervision policy

An injected-clock state machine owns starting, ready, backoff, degraded and stopped states. Start timeout is 10 seconds; health checks run every 5 seconds with a 2-second deadline, and three consecutive failures count as a crash. Backoff starts at 1 second, doubles to 60 seconds, and resets after 10 minutes continuously ready. More than five crashes or startup failures within 10 minutes opens the circuit. Probes run every 5 minutes; 60 seconds continuously ready closes the circuit. Shutdown grace is 5 seconds. These values are code constants injectable in tests.

Rejected: publishing configuration keys before operators demonstrate a need. Reversal cost: low; expose settings later on evidence.

### D7: Fair slots follow pinned due work

An instance serves one output and definition digest. Only starting or ready instances hold slots: at most 16 per worker and four per output. A keyset cursor over `(output_id, definition_digest)` admits one due, eligible, nonrunning definition at a time, wrapping once. Memory holds only running instances and the cursor, not every live definition. Definition digests hash canonical public configuration, excluding secret values.

Idle instances release after 60 seconds without due work. Waiting-demand lookup ignores both caps. A blocked definition triggers rotation in its blocking scope (worker or its own output), including when other worker slots are free. After 60 seconds held, the longest-held eligible ready instance yields after its current batch. An unfinished circuit probe is protected until failure or 60 seconds of readiness closes its circuit. Handover includes at most one 27-second batch and, where necessary, 10 seconds of probe startup plus 60 seconds of probe readiness. With N runnable definitions waiting, each is admitted within N admissions. Early voluntary probe stops restore the open circuit and retain the next probe time without counting a failure.

Rejected: re-pinning old work, always-warm active definitions, publication bounds bypassed by pinned raw work, and a bounded longest-waiting table that drops candidates. Reversal cost: medium; pinned definitions shape stored work.

### D12: Go modules

Production code lives in module `github.com/sh1ny/correlia/plugins`, generated protocol in `plugins/protocol/correlia/plugin/v1`, and the NATS executable in `plugins/output-nats`. The pinned embedded NATS tool is a separate module, `github.com/sh1ny/correlia/tool/natsdev`. Both record `go.sum` checksums and build through mise into ignored `build/plugins/`. The production plugin uses stock go-plugin Serve with ADR 0018's stdin-EOF exit watcher.

Rejected: production code inside the experimental fixture module, coupling release code to unstable tests. Reversal cost: low.

### D15: Compatibility gate

Buf lint and reproducible Dart/Go generation checks cover the production protocol now. Freeze its breaking-change baseline when declared stable for 1.0; leave the canonical event baseline unchanged.

Rejected: freezing the output-only contract before other plugin kinds exercise it. Reversal cost: low.

### D18: Kind-aware secrets

Publication records immutable commitments for plugin secret references as well as webhook signing references and rejects rebinding across either kind. Startup requires matching loaded material only for live webhook intents. Plugin work never blocks worker startup: missing or mismatched secrets prevent that definition's Configure, expose `plugin_secret_unavailable`, and leave work queued without new attempts while unrelated outputs proceed. Secret values reach plugins only through Configure, never environment, logs or persisted configuration.

Rejected: dummy signing columns on plugin rows, which conceal kind and still couple startup to plugin secrets. Reversal cost: low.

### D19: Durable supervision history

A managed `plugin_definition_health` row per host/output/digest owns at most six failure times, backoff step, next start, circuit state, next probe and last error class. Persist changes before freeing a slot; admission reads this history. Eviction must not reset backoff or crash budget. Prune rows without queued or delivering work and dead-host rows alongside status pruning. Memory retains only the at-most-16 running instances.

Rejected: unbounded evicted state in memory, discarding history, or treating mirrored instance status as authority. Reversal cost: low; the table has no other authoritative readers.

## Consequences

Plugin delivery is at least once; JetStream deduplicates within its configured window and consumers retain event-id deduplication responsibility beyond it. Old definitions drain without redirecting pending work. Plugin status is inspectable through persisted heartbeat rows and degraded/recovered activity, not a new console page. Failed plugins can accumulate live definition history on disk, never an unbounded host-side work queue. This ADR records the contract and policy; implementation and runtime evidence are tracked by `output-nats-plugin`.
