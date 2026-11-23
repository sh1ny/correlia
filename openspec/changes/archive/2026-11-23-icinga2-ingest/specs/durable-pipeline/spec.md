# Spec Delta

## ADDED Requirements

### Requirement: Rows decode by their source's kind

The pipeline SHALL decode a raw row with the decoder of its pinned source's kind. A kind with no decoder
SHALL fail the row with a bounded error, never fall back to another decoder.

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

### Requirement: Clamped source time is recorded

When an observation's effective source time is clamped to observed time plus the skew allowance, the stored
event SHALL record the effective time used, the raw outcome SHALL count the clamped observations, and the
event's own `source_time` SHALL stay as reported. The recorded value has microsecond precision and serves
queries; exact ordering SHALL use the canonical evidence. Expiry, windows and reminders SHALL use observed time.

#### Scenario: ORD-4 future source time beyond the skew limit
- **WHEN** an Icinga2 firing observation with source time 3 hours after its observed time (inside the 24 hour future limit) is processed
- **THEN** it is accepted and applied, its stored event records an effective time of observed time plus 5 minutes, the raw outcome counts one clamped observation, and the published event's `source_time` is the reported time

#### Scenario: Events stored before the upgrade
- **WHEN** a database holding an Alertmanager event whose source time was 3 hours after its observed time is upgraded with this change's schema step
- **THEN** the step rewrites no event rows, and that event's effective time read through the step's expression is its observed time plus 5 minutes

#### Scenario: Sub-microsecond evidence
- **WHEN** two observations of one alert have source times t + 800 ns and t + 900 ns, before or after the upgrade
- **THEN** both effective times read through the step's expression are t truncated to the microsecond, and the fence still orders them by their nanosecond times

#### Scenario: Source time within the skew allowance
- **WHEN** an observation's source time is 2 minutes after its observed time
- **THEN** no clamp is recorded and the effective time equals the source time
