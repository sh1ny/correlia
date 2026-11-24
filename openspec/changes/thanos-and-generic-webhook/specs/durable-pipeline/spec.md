# Spec Delta

## MODIFIED Requirements

### Requirement: Rows decode by their source's kind

The pipeline SHALL decode a raw row with the decoder of its pinned source's kind and, for an `icinga2` source in
mode `event_streams`, of the row's stored format. A `generic` row SHALL use its pinned snapshot's mapping on every
retry; decoding with a later mapping is operator replay, outside automatic retry and deferred to M2 change 7.
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

## ADDED Requirements

### Requirement: Generic decode failures name paths, never values

A failed `generic` row SHALL record a bounded code and no events. Its path is a canonical field, absent, or an
RFC 6901 pointer retaining only tokens the pinned mapping names at that prefix and traversed array indexes,
with other tokens `*`. Cut pointers at a segment boundary within 256 bytes; store `/*` if no segment fits,
or the empty pointer for a root failure. Failure records, logs and metrics SHALL NOT include keys or values
taken from the sender's body.

#### Scenario: Invalid JSON body
- **WHEN** a `generic` row's body is not valid JSON
- **THEN** the row fails with `invalid_json`, the error holds no part of the body, and no event commits

#### Scenario: Canonical failure while decoding
- **WHEN** a generic alert maps but its event fails construction with `event_too_large`
- **THEN** the row fails with `event_too_large` and the stored path is `event`, never a sender pointer

#### Scenario: Budget failure while committing
- **WHEN** a generic row's events and fan-out exceed the per-row budget
- **THEN** the row fails with `batch_bound` and no stored path

#### Scenario: Numeric object key
- **WHEN** a mapping reads `/check/name` and a failing alert carries an object key `0042` under `/check`
- **THEN** the stored path names `/check/*`, because `0042` is an object key, not an array index

#### Scenario: Failure in the second of three alerts
- **WHEN** the second alert of a three-alert delivery has a severity value its table does not list and no default
- **THEN** the whole row fails with an error naming `/items/1` and the severity pointer, without the value, and none of the three events commits

#### Scenario: First segment longer than the path bound
- **WHEN** a mapping reads a field under a 300-byte key and that field has the wrong type
- **THEN** the stored path is `/*`, distinct from the empty pointer stored for a body that is not an object

#### Scenario: Multibyte segment at the path bound
- **WHEN** a failing path's next mapping-named segment holds multibyte or `~1`-escaped characters that would cross 256 bytes
- **THEN** the stored path ends before that segment, and no character or escape is split
