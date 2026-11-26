# Durable pipeline delta

## MODIFIED Requirements

### Requirement: Rows decode by their source's kind

The pipeline SHALL decode a raw row with the decoder of its pinned source's kind and, for an `icinga2` source in
mode `event_streams`, of the row's stored format. A `generic` row SHALL use its pinned snapshot's mapping on every
automatic retry. Only explicit operator replay of a failed row can change its pin.
A kind or format with no decoder SHALL fail the row with a bounded error, never fall back to another decoder.

#### Scenario: Two kinds in one batch
- **WHEN** pending rows from an `alertmanager` source and an `icinga2` source are processed
- **THEN** each row is decoded by its own kind's decoder and commits its events

#### Scenario: Existing rows after the upgrade
- **WHEN** a database with pending Alertmanager raw rows from before this change is upgraded and the worker starts
- **THEN** those rows are decoded as Alertmanager and processed as before

#### Scenario: Row pinned to a format version 1 snapshot
- **WHEN** a pending row is pinned to a historical format version 1 snapshot whose source has no `kind`
- **THEN** it is decoded as Alertmanager, and the pin is unchanged

#### Scenario: Schema step 4 under lock contention
- **WHEN** a historical fixture at schema step 3 starts against a lock on `events` held by another transaction
- **THEN** step 4 fails within its lock timeout, no step-4 version is recorded, the process exits non-zero with failure class `lock_timeout`, and after the lock is released the next start applies the step

#### Scenario: Schema runner waits behind another starter
- **WHEN** another session holds the schema advisory lock while the schema runner starts against a historical fixture at step 3
- **THEN** the start fails within the lock timeout with failure class `lock_timeout` and no step recorded

#### Scenario: Missing kind in a version 2 snapshot
- **WHEN** a pending row is pinned to a version 2 snapshot whose source has no `kind`
- **THEN** the row fails with `unsupported_kind` and no decoder runs

#### Scenario: Offline upgrade with pending work
- **WHEN** a historical fixture at step 3 has pending Alertmanager rows and starts the worker with the schema step 4 upgrade available
- **THEN** schema step 4 is applied and the pending rows are processed by the upgraded workers

#### Scenario: Body of another kind
- **WHEN** an Alertmanager webhook body is pinned to an `icinga2` source
- **THEN** the row fails with an Icinga2 decoding error and no event commits

#### Scenario: Stream row of a stream source
- **WHEN** a row with format `correlia.icinga2.stream.v1` is pinned to an `icinga2` source in mode `event_streams`
- **THEN** it is decoded by the stream decoder, never the webhook decoder

#### Scenario: Unknown stream format
- **WHEN** a row of a stream source carries a format this build does not know
- **THEN** the row fails with `unsupported_format` and no decoder runs

#### Scenario: Generic mapping changes before the first claim
- **WHEN** a `generic` row is admitted while mapping revision A is active and revision B activates before the row is first claimed
- **THEN** the row is pinned to the snapshot holding B and decoded with B

#### Scenario: Generic mapping changes after the first claim
- **WHEN** a `generic` row is pinned to the snapshot holding mapping revision A, its first attempt fails transiently, and revision B activates before the retry
- **THEN** the retry decodes with A, and the pin is unchanged

#### Scenario: Generic row pinned to a snapshot without its mapping
- **WHEN** a `generic` row's pinned snapshot holds no mapping of the name its source declares
- **THEN** the row fails with `unsupported_mapping` and no decoder runs

## ADDED Requirements

### Requirement: Partitioned storage survives offline upgrade

Correlia SHALL partition raw inbox and canonical events by UTC receipt date and outbox by UTC creation date. Fresh installs and offline upgrades SHALL preserve existing sender data and allow valid writes through the default child when daily attachment cannot finish. Upgrade SHALL NOT require draining unfinished or failed work. Only worker and all roles SHALL perform periodic maintenance.

#### Scenario: Populated upgrade and fresh installation
- **WHEN** a database populated at the immediate predecessor of the partition cutover upgrades offline and an empty database starts on the same version
- **THEN** both have the same partitioned parents, the populated database retains its original bytes, identity tuples, pins and outcomes, and workers can process pre-upgrade work and new work

#### Scenario: Parent-targeted writes retain index and cutoff behavior
- **WHEN** the upgraded database receives an insert across historical and daily raw children with one receipt below the admission cutoff
- **THEN** the parent rejects the entire insert; its expected indexes cover both children, and the effective-time helper reads the new event parent row type

#### Scenario: Overflow event lands inside the attached historical range
- **WHEN** an upgraded installation records a real overflow notice with a timestamp still inside the attached historical event range
- **THEN** the historical child retains the valid system event, the healthy output receives it, the payload's reference, digest and size match the notice evidence, and existing sender raw keys and bytes are unchanged

#### Scenario: Partition work interrupted
- **WHEN** the partition cutover fails before commit on a populated immediate-predecessor database, or a later partition maintenance batch fails before commit
- **THEN** it leaves no partial relocation or deletion, a failed cutover records no partition-step version, and a subsequent run can retry the failed work

#### Scenario: Default validation failure pauses only daily preparation
- **WHEN** a future day is empty in populated default but its bounded attachment attempt fails, and another candidate day already contains default rows
- **THEN** daily preparation reports the failure and records a retry, valid writes still reach default, the occupied day is skipped without moving its rows, and a later successful attempt attaches the empty range without changing accepted work

#### Scenario: A delayed attachment failure cannot replace success
- **WHEN** one worker rolls back a failed attachment and pauses before recording the retry, and another worker attaches the same day before the first resumes
- **THEN** the day stays covered and the delayed failure adds no degradation, retry or stale last-batch outcome

#### Scenario: Worker stops during maintenance
- **WHEN** shutdown starts while a maintenance batch is open
- **THEN** the active batch finishes or rolls back before its session closes, and no second batch is claimed

### Requirement: Retention preserves unfinished pipeline work

Retention SHALL keep pending and processing raw rows, raw rows with active pipeline failures, and events referenced by live or dead deliveries. It SHALL reclaim only eligible rows older than their configured retention window. The raw and event defaults are 30 and 90 days. It SHALL drop an old time partition only if all its rows and related records can be reclaimed safely; otherwise it SHALL delete eligible rows in bounded transactions.

#### Scenario: DUR-10 a long worker outage
- **WHEN** workers have been down longer than raw retention and an old partition contains pending and failed rows alongside completed rows
- **THEN** maintenance reclaims only eligible completed rows, pending work still processes on restart, and failed work remains replayable until its own failure expiry

#### Scenario: Old event with an unfinished delivery
- **WHEN** an old event partition contains events with delivered and dead or delivering intents
- **THEN** the events with unfinished intents survive, and eligible events with no such references are reclaimed

#### Scenario: Old fully eligible partition
- **WHEN** a partition ends before the retention cutoff and no protected rows or dependent work remain
- **THEN** maintenance drops it without rewriting surviving data in other partitions

#### Scenario: Reclamation advances past protected pages
- **WHEN** more than one batch of old protected events sorts before an old eligible event
- **THEN** successive bounded maintenance batches advance past the protected rows and remove the eligible event while every protected event remains

### Requirement: Atomic dead-letter expiry

A pipeline failure or delivery dead letter SHALL have its own retention window, default 14 days from failure. Expiry SHALL remove the active failure, move the raw row or delivery to `discarded` and record the discarded count in the activity ledger in one transaction. Only then can age-based retention reclaim the discarded row.

#### Scenario: DUR-12 expiration makes old work eligible
- **WHEN** an old failed row and an old dead delivery pass the configured failure expiry without replay
- **THEN** both move to `discarded`, no active failure remains for either, the ledger records the committed count, and retention can reclaim their data

#### Scenario: Expiry rollback
- **WHEN** expiry fails after selecting and updating rows but before committing the ledger entry
- **THEN** the raw and delivery rows remain failed and dead, their active failures remain intact, and no discard is reported

### Requirement: Retention preserves retry and ordering evidence

Maintenance SHALL keep transport keys through their deduplication window, and observation keys through the evidence horizon in ADR 0024. Observation keys and Icinga2 silent tombstones SHALL remain while older accepted or replayable work can still use them. For pre-upgrade Icinga2 failures, replayed evidence older than the previously published reclamation boundary SHALL count as late.

#### Scenario: Evidence still needed by old accepted work
- **WHEN** a key or silent tombstone reaches its age cutoff while an older accepted or replayable row can still use it
- **THEN** maintenance keeps the evidence; after the row is no longer processable and the relevant age bounds pass, maintenance can reclaim it

#### Scenario: Replayed pre-upgrade evidence predates reclaimed fences
- **WHEN** an old pre-upgrade Icinga2 failure replays with evidence older than the published reclamation boundary
- **THEN** that item counts as late, creates no firing state or delivery, and the row's original receipt is unchanged
