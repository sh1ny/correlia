# Spec Delta

## Purpose

Keep accepted raw work and its processing evidence durable across concurrent workers, failures and restarts, and atomically publish canonical events to independent output queues.

## ADDED Requirements

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

Processing SHALL atomically commit observation keys, canonical events, output intents and raw done. Validation/batch-bound errors SHALL commit only failed raw and sanitized failure evidence. Serialization, deadlock, lock-timeout and connection-unavailable errors SHALL retry without spending the internal-error budget. Other internal errors SHALL fail after five attempts as processing_exhausted, retaining pin/raw without partial effects. Counters SHALL reflect committed outcomes.

#### Scenario: DUR-1 outbox failure rolls back event work
- **WHEN** inserting an output intent hits a transient database failure after event insertion, repeatedly beyond five transient retries
- **THEN** no event, observation key, output intent or done outcome commits, the internal-error budget remains unchanged with the pin intact, and a later successful retry commits one effect set

#### Scenario: Invalid member after valid member
- **WHEN** one alert in a multi-alert delivery is invalid after an earlier alert normalized successfully
- **THEN** the raw row is failed with raw id, pinned version, error class and field path, and no member's event, observation key or output intent commits

#### Scenario: Processing budget exhaustion
- **WHEN** a pinned row hits a non-transient internal error on every attempt
- **THEN** after five consumed attempts it is failed with processing_exhausted, its pin and raw bytes remain and no partial effects exist

### Requirement: Durable observation deduplication and quarantine

Before event/output effects, processing SHALL enforce durable event-id uniqueness independent of transport deduplication and keep original ordering evidence. Duplicate observations SHALL not emit events or output intents. Source times beyond the future limit SHALL be stored as future_dated without observation keys or outputs; late observations SHALL be stored as late without outputs. Classification SHALL use the accepted lateness/skew/future policy, never clamped identity evidence.

#### Scenario: ORD-5b rebatching and expired transport window
- **WHEN** equal observations arrive in different bodies concurrently or after transport dedup expiry
- **THEN** only one ordinary event/output effect set commits per observation id and duplicate_observation counts increase without rewriting first-seen/source-time evidence

#### Scenario: Future quarantine does not poison dedup
- **WHEN** source time is three days ahead of observed time, then the same observation is redelivered once it falls within the future limit
- **THEN** the first delivery is visible as future_dated with no key/output, and the later eligible delivery can create its first observation key and ordinary output intents

#### Scenario: Late observation evidence
- **WHEN** effective source time is older than the lateness horizon
- **THEN** processing retains late evidence and creates no output intent; it is not counted as a current observation

### Requirement: Role scoped bounded lifecycle

Only api/all SHALL mount ingest routes; only worker/all SHALL process inbox and outbox work. Startup SHALL gate requests on schema/config readiness. Shutdown SHALL stop acquiring work, finish or roll back bounded database operations and stop output calls before closing sessions/database pools. A killed worker SHALL leave accepted work recoverable by a replacement process.

#### Scenario: Split roles and restart
- **WHEN** api accepts deliveries while worker is stopped, then worker starts or restarts after being killed during processing
- **THEN** raw work survives and reaches canonical event/output outcomes without api running a pipeline loop or worker exposing an ingest route

#### Scenario: Shutdown during processing
- **WHEN** shutdown begins while a pipeline transaction or output request is in flight
- **THEN** acquisition stops, the bounded operation completes or cancels without a partial commit, all owned sessions close and uncompleted work remains retryable
