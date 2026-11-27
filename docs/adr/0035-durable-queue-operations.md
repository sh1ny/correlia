# 0035: Durable queue operations

- Status: Accepted
- Refines: [0016](0016-durable-staged-pipeline.md), [0030](0030-pull-sources-leased-consumers.md)

## Context

Operators need to inspect and recover failed work without reading payloads from PostgreSQL. Slow consumers and storage pressure must not let the queues grow unchecked. Accepted work must survive both retries and an upgrade from the original heaps.

## Decision

### Operator access and replay

Dead-letter listing, replay and pressure status are typed Serverpod RPCs, disabled by default. A dedicated API credential file contains, at most, eight machine IDs and SHA-256 digests of random 256-bit bearer tokens. The verified machine ID is the ledger actor for each successful replay. Rotate credentials by replacing the file and restarting each API replica. RPC results, status, audit entries and errors do not expose payloads, secrets or raw transport diagnostics. The M2 demo uses the RPCs directly, including the protected status read. The Flutter operator page is deferred to M4 and will reuse these RPCs.

A raw replay takes a pending slot, preserves the original receipt, bytes, Icinga2 origin and canonical generation, and pins the active compatible binding. It does not change the original sync run. The new processing epoch fences a worker's delayed error after replay, even if the pin is unchanged. Refusals leave the original failure unchanged. Queue age alone does not stop recovery.

Delivery replay keeps exact bytes, IDs and pinned destination and signing commitment. Attempts continue numbering from the old history but count against a fresh allowance of twenty. Missing pinned webhook material or a replay that would exceed 64 live/pinned output IDs causes refusal. An accepted replay is a new ledger entry, not a new transport identity.

### Capacity and overflow

The versioned configuration stores nondefault queue policy. Omitted and explicit-default policy resolve to the same immutable snapshot. Authenticated new ingress receives `429` for inbox saturation and `503` for disk pressure or a blocking output, with `Retry-After`. Disk pressure degrades API readiness. Known accepted receipts remain repeatable during pressure. Share reservations and storage signals across roles in PostgreSQL, not in per-process guesses.

An output counts queued, delivering and dead rows plus their exact payload bytes. Default limits are 500,000 intents and 1 GiB per output. A full `discard_new` output drops new intents only; a full `block_ingest` output defers the accepted raw transaction without partial effects or spending its error budget. A configured blocking output must admit a maximum raw row into an empty queue. Limits never increase merely to fit a notice.

Changing a budget does not change the plugin definition digest. A retired output keeps its last
budget while retained work or a pending configuration pin still needs that output.

The first refusal or saturation in an episode produces durable ledger evidence. Route one sanitized Correlia-origin event to other active outputs that have room. A notice does not enter ingest, change alert state, bypass limits or recursively open a new episode. The ledger and status RPC show the episode even when no other output can accept a notice.

Maintain live and pinned counts by output ID and by distinct nonsecret historical commitment. Check publication imports and startup from that metadata, never by scanning payload queues. Missing live webhook signing material still fails startup; missing plugin material remains a per-definition launch failure. Keep event reference counts by full event identity. Failure pages and maintenance select bounded candidates through indexed metadata.

### Retention and upgrade

Defaults: 30 days for terminal raw receipts, 90 days for events and 7 days after delivery completion for delivered intents. Failed raw rows and dead deliveries stay replayable until the configured dead-letter window, then expire with ledger evidence. Never reclaim pending work or an event protected by a queued, delivering or dead intent. Delivery attempts follow their terminal intent through a resumable bounded reclamation queue.

Keep transport keys through their retry window and until no eligible receipt can create a new row with that key. Keep observation keys and Icinga2 silent tombstones while older replayable work can depend on them. A replay of pre-upgrade Icinga2 evidence older than the stored reclaim floor keeps the original receipt and cannot recreate a firing alert.

Stop every old process before cutover. Attach each populated heap through the UTC day containing its highest stored key; do not drain accepted work or copy its payloads to move it. Future work normally goes to daily UTC partitions. The default partitions accept valid timestamps outside prepared ranges. Parent composite identities and the admission cutoff still apply. An event carries exactly one origin: both raw-key parts, or a system activity ID. Either form works in the attached historical child.

The offline partition script has its own client deadline. `CORRELIA_PARTITION_CUTOVER_TIMEOUT_SECONDS` defaults to 3600 and can be increased for a longer maintenance window. It does not change the 30-second SQL lock timeout or the atomic version record.

Each preparation attempt uses a bounded transaction for one empty day. If validation times out, leave default routing in place and record a durable retry. An outcome from an older attempt cannot replace newer success. There is no automatic preparation deadline when defaults remain populated. Offline repair requires stopped writers, range validation and the maintenance lock; do not detach default or move protected rows to make an attach succeed.

## Consequences

Mixed-version deployment and downgrade are unsupported. The cutover consumes offline time to validate existing rows and initialize metadata, but does not require a second copy of retained payloads. Monitoring and inspection use the protected status RPC and ledger in M2; adding Prometheus metrics is separate work.
