# Spec Delta

## ADDED Requirements

### Requirement: The earliest same-ID member of a batch is the candidate

The existing same-ID check SHALL admit, for each event ID in a raw batch, the first item in input order that reaches it. Each stream item SHALL still be classified and counted by its own receipt time before that check, and later same-ID items SHALL count as duplicates as today.

#### Scenario: First input member is the candidate
- **WHEN** a raw batch of more than 32 members, large enough that the previous unstable sort reorders equal IDs, holds two deliverable alerts with the same event ID that differ only in an annotation
- **THEN** the stored and delivered event carries the annotation of the first of the two in input order

#### Scenario: Reversed input order
- **WHEN** the same batch arrives with the two alerts in reverse order, in a database that has not seen their observation key
- **THEN** the stored and delivered event carries the annotation of the alert that is now first

#### Scenario: Stream copies straddle the future limit
- **WHEN** an Icinga2 stream batch holds two copies of one check result, the first received past the future limit and the second within it
- **THEN** the first is counted as future-dated, and the second is stored and delivered

## MODIFIED Requirements

### Requirement: Rows decode by their source's kind

The pipeline SHALL decode a raw row with the decoder of its pinned source's kind and, for an `icinga2` source in
mode `event_streams`, of the row's stored format. A `generic` row SHALL use its pinned snapshot's mapping on every
retry; decoding with a later mapping is operator replay, outside automatic retry and deferred to the M2 change `dead-letters-backpressure-and-retention`.
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
- **WHEN** another transaction holds a lock on `events` while a process of this release starts
- **THEN** step 4 fails within its lock timeout, no step-4 version is recorded, the process exits non-zero with failure class `lock_timeout`, and after the lock is released the next start applies the step

#### Scenario: Schema runner waits behind another starter
- **WHEN** another session holds the schema advisory lock while a process of this release starts
- **THEN** the start fails within the lock timeout with failure class `lock_timeout` and no step recorded, and after the lock is released the next start applies the steps

#### Scenario: Missing kind in a version 2 snapshot
- **WHEN** a pending row is pinned to a version 2 snapshot whose source has no `kind`
- **THEN** the row fails with `unsupported_kind` and no decoder runs

#### Scenario: Offline upgrade with pending work
- **WHEN** every older process stops with pending Alertmanager rows in the inbox, and processes of this release then start
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

