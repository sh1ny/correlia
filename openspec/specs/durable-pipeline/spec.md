# durable-pipeline Specification

## Purpose

Keep accepted raw work and its processing evidence durable across concurrent workers, failures and restarts, and atomically publish canonical events to independent output queues.

## Requirements

### Requirement: Schema readiness on fresh and upgraded databases

Every process role SHALL apply Correlia-owned forward-only schema steps after Serverpod migrations and before ingest or background work becomes ready. Steps SHALL execute once under a database lock and record their version atomically. Fresh and upgraded databases SHALL expose the same application schema. Schema failure SHALL prevent application work without changing unrelated databases.

#### Scenario: Fresh and populated schema paths
- **WHEN** an empty embedded database and a populated database at the preceding schema version start, including two concurrent starters
- **THEN** both reach the same latest schema, each step is recorded once and the populated database retains its existing rows

#### Scenario: Failed schema step
- **WHEN** an injected step fails before its version record commits
- **THEN** that step's changes roll back, ingest and background processing do not become ready and a sanitized startup error names the step

### Requirement: Durable first claim configuration pin

A raw row SHALL durably pin the active immutable configuration version before its first processing attempt. Crashes and automatic retries SHALL reuse that version. Concurrent workers SHALL claim eligible rows without processing-order guarantees and never commit the same raw row's effects twice. Configuration changes SHALL affect unpinned rows, not rewrite old pins.

#### Scenario: Pin survives crash and activation
- **WHEN** a row is pinned to version A, its worker dies before processing commits and version B activates
- **THEN** another worker processes it using A and persists A in its events and failure/delivery provenance

#### Scenario: Concurrent claiming
- **WHEN** two independent workers claim the same pending set
- **THEN** each successfully processed row has one committed effect set, unrelated rows can progress and no ordering by fingerprint or arrival is promised

### Requirement: Atomic raw processing outcome

Processing SHALL atomically commit observation keys, events, alert changes, activity, output intents and raw done, or, for an Icinga2 sync row that stored no event, the row's deletion with its sync counts. Validation/batch-bound errors SHALL commit only failed raw and sanitized evidence. Other errors follow "Processing errors retry within a budget". Counters SHALL reflect committed outcomes.

#### Scenario: DUR-1 outbox failure rolls back event work
- **WHEN** inserting an output intent hits a transient database failure after event insertion and the alert state change, repeatedly beyond five transient retries
- **THEN** no event, observation key, alert state change, activity entry, output intent or done outcome commits, the internal-error budget remains unchanged with the pin intact, and a later successful retry commits one effect set, including exactly one alert state change and its activity entry

#### Scenario: Invalid member after valid member
- **WHEN** one alert in a multi-alert delivery is invalid after an earlier alert normalized successfully
- **THEN** the raw row is failed with raw id, pinned version, error class and field path, and no member's event, observation key, alert state change, activity entry or output intent commits

#### Scenario: Processing budget exhaustion
- **WHEN** a pinned row hits a non-transient internal error on every attempt
- **THEN** after five consumed attempts it is failed with processing_exhausted, its pin and raw bytes remain and no partial effects exist

#### Scenario: Sync row that stored nothing
- **WHEN** an Icinga2 sync row whose items all confirm is processed, and the transaction fails before commit
- **THEN** the row is still pending with its body, its sync counts are unchanged, and a later successful attempt deletes it and adds its counts once

### Requirement: Durable observation deduplication and quarantine

Processing SHALL enforce durable event-id uniqueness with original ordering evidence before effects. Duplicates SHALL emit no events/outputs and advance only eligible alerts' `last_observed_at`, never late/future alerts. Beyond-limit source times SHALL be stored as future_dated without keys/outputs/state; late observations SHALL be stored as late without outputs/state, except Icinga2 items. Classification SHALL use accepted lateness/skew/future policy, never clamped identity evidence.

#### Scenario: ORD-5b rebatching and expired transport window
- **WHEN** equal observations arrive in different bodies concurrently or after transport dedup expiry
- **THEN** only one ordinary event/output effect set commits per observation id and duplicate_observation counts increase without rewriting first-seen/source-time evidence

#### Scenario: ORD-5c retry of firing after a recovery
- **WHEN** a firing observation is applied, a recovery with the same source time and a later observed time resolves the alert, and the firing observation is delivered again after the transport dedup window expired
- **THEN** the retry is a duplicate_observation, the alert stays resolved with its version unchanged, and only `last_observed_at` advances to the retry's observed time

#### Scenario: ORD-5d retry after the observation key expired
- **WHEN** a firing observation with source time 1 hour in the future is applied, a recovery resolves the alert, and the firing observation is delivered again after its observation key expired
- **THEN** the retry is classified late, the alert stays resolved, and neither its version nor its `last_observed_at` changes

#### Scenario: ORD-5f generic retry without a native id
- **WHEN** an Alertmanager observation, which has no native observation id and is identified by its reported times, fires with source time 1 hour ahead, a recovery resolves the alert, and the firing observation is delivered again after the transport dedup window
- **THEN** the retry has the same event id, is a duplicate_observation that advances only `last_observed_at`, and the alert stays resolved

#### Scenario: Duplicate of a late observation
- **WHEN** a late observation is delivered again within its observation key's retention
- **THEN** it is a duplicate_observation and no alert's `last_observed_at`, status or version changes

#### Scenario: Future quarantine does not poison dedup
- **WHEN** source time is three days ahead of observed time, then the same observation is redelivered once it falls within the future limit
- **THEN** the first delivery is visible as future_dated with no key/output/state, and the later eligible delivery can create its first observation key, its alert state effect and ordinary output intents

#### Scenario: Late observation evidence
- **WHEN** effective source time is older than the lateness horizon, for an observation other than an Icinga2 stream or sync item
- **THEN** processing retains late evidence and creates no output intent and no alert state; it is not counted as a current observation

### Requirement: Late and future-dated stream items are counted, not stored

An item of an Icinga2 stream or sync row that is late or future-dated SHALL be counted on its row's outcome and
SHALL NOT be stored: it creates no event, observation key or output intent.

#### Scenario: Late or future stream item
- **WHEN** a sync row holds one reconcile observation older than the lateness horizon and a stream row holds one item beyond the future limit
- **THEN** the rows' outcomes count one `late` and one `future_dated`, and no event, observation key or output intent is stored for either

### Requirement: Role scoped bounded lifecycle

Only api/all SHALL mount ingest routes; only worker/all SHALL process inbox and outbox work. Startup SHALL gate requests on schema/config readiness. Shutdown SHALL stop acquiring work, finish or roll back bounded database operations and stop output calls before closing sessions/database pools. A killed worker SHALL leave accepted work recoverable by a replacement process.

#### Scenario: Split roles and restart
- **WHEN** api accepts deliveries while worker is stopped, then worker starts or restarts after being killed during processing
- **THEN** raw work survives and reaches canonical event/output outcomes without api running a pipeline loop or worker exposing an ingest route

#### Scenario: Shutdown during processing
- **WHEN** shutdown begins while a pipeline transaction or output request is in flight
- **THEN** acquisition stops, the bounded operation completes or cancels without a partial commit, all owned sessions close and uncompleted work remains retryable

### Requirement: Rows decode by their source's kind

The pipeline SHALL decode a raw row with the decoder of its pinned source's kind and, for an `icinga2` source in
mode `event_streams`, of the row's stored format. A kind or format with no decoder SHALL fail the row with a
bounded error, never fall back to another decoder.

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

### Requirement: Clamped source time is recorded

When an observation's effective source time is clamped to observed time plus the skew allowance, a stored
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

#### Scenario: Clamped silent reconcile
- **WHEN** an Icinga2 sync object whose source time is clamped confirms its alert silently
- **THEN** no event is stored, the raw outcome counts one clamped observation, and the fence holds the effective time

### Requirement: Processing errors retry within a budget

Serialization, deadlock, lock-timeout and connection-unavailable errors SHALL retry without spending the internal-error budget. Other internal errors SHALL fail after five attempts as processing_exhausted, retaining pin/raw without partial effects.

#### Scenario: Deadlock retried
- **WHEN** a row's processing transaction hits a deadlock twice and then commits
- **THEN** its effects commit once and its internal-error budget is unchanged

### Requirement: Observation keys are reserved before alert locks

Eligible state observations, including reconcile observations, SHALL reserve keys in event-ID order
before any alert locks are acquired. All alert locks SHALL then be acquired in fingerprint order.
A reconcile reservation SHALL either key a stored event or be deleted in that same transaction,
including when the observation confirms, creates a silent tombstone, or is stale.

#### Scenario: Stream and sync copies of one result at once
- **WHEN** a stream row and a sync row carrying the same result of one service are processed concurrently on independent connections, the sync copy repairing the alert
- **THEN** both commit without a deadlock or lock timeout, exactly one event is stored and routed, and the copy that reserved the key second is a `duplicate_observation`

#### Scenario: Silent reconcile leaves no key
- **WHEN** a sync object confirms its alert
- **THEN** after commit no observation key exists for its event id

#### Scenario: Stale sync item before an eligible stream copy
- **WHEN** a sync copy received at 10:00 with start 10:30 is clamped to 10:05 and is stale against a 10:06 fence, and the stream copy of the same result received at 10:02, clamped to 10:07, is processed next
- **THEN** after the sync row commits no key exists for the result, and the stream copy applies with its event, state change and output intents committed

### Requirement: Consumer admission into the raw inbox

A pull consumer SHALL insert raw rows only through fenced admission, checking lease generation, configuration
revision and source mode in the insert transaction. Source lookup, identity namespace and routing SHALL use the
first-claim snapshot, as for webhook rows; the same claim, retry and failure rules apply. Stream and sync state
policy SHALL use the admission snapshot in `icinga2_raw_origin`. Use stored format and each item's own receipt time.

#### Scenario: Stream row processed
- **WHEN** a consumer admits a row of 100 valid `StateChange` items
- **THEN** the pipeline pins it at first claim, decodes it as an Icinga2 stream row and commits its effects in one transaction

#### Scenario: Items received at different times
- **WHEN** a row holds two items received 800 ms apart
- **THEN** each observation's observed time is its own item's receipt time

#### Scenario: Stream row under a snapshot without the source
- **WHEN** a stream row is admitted, and a revision removing its source is active at first claim
- **THEN** the row fails with `source_not_configured` and no decoder runs

### Requirement: Reconcile observations are stored only when they change state

The pipeline SHALL store and route an event for a reconcile observation only when it creates a firing alert or
changes an alert. A confirming, stale, late, future-dated or tombstone-creating reconcile observation SHALL
write no event, observation key or output intent, and SHALL be counted on the raw row's outcome.

#### Scenario: Hourly sync of a steady installation
- **WHEN** a sync of 10,000 objects whose alerts already match is processed
- **THEN** no event, observation key or output intent is written, and the sync's counts hold 10,000 confirmations or tombstones

#### Scenario: Sync with one repair
- **WHEN** a sync row holds 99 confirming objects and one that resolves a firing alert
- **THEN** exactly one event is stored and routed to the source's outputs

### Requirement: Raw row outcomes count stream results

The raw outcome of a stream or sync row SHALL count, beside the existing counters, `confirmed`, `repaired`,
`tombstoned` and `soft_info`. Each item SHALL be counted in exactly one counter. `diverged` is a count of the
sync, not of a row, and overlaps the row counters.

#### Scenario: Mixed sync row
- **WHEN** a sync row holds confirming, repairing, tombstoning and stale objects
- **THEN** its outcome JSON holds each count, and the counts sum to the row's item count

#### Scenario: Webhook rows unchanged
- **WHEN** a webhook row is processed
- **THEN** its outcome JSON holds the new counters at zero or omits them, and every existing counter is unchanged

### Requirement: Stale stream observations are stored, not routed

A stale observation from an Icinga2 stream row SHALL be stored with the `stale` outcome and SHALL
never be routed. This keeps outputs from seeing a stale problem the alert did not take. Stale
observations of webhook rows SHALL still be stored and routed.

#### Scenario: Older stream problem after a tombstone
- **WHEN** a sync OK leaves a silent tombstone, and a stream CRITICAL with an older start is then processed
- **THEN** the CRITICAL's event is stored as `stale`, and the committed outbox holds no intent for it

#### Scenario: Stale webhook observation
- **WHEN** a stale observation of an Icinga2 webhook row is processed
- **THEN** it is stored and routed exactly as before this change
