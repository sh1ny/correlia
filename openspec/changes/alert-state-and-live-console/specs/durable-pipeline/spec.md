# Spec Delta

## MODIFIED Requirements

### Requirement: Atomic raw processing outcome

Processing SHALL atomically commit observation keys, canonical events, alert state changes, activity entries, output intents and raw done. Validation/batch-bound errors SHALL commit only failed raw and sanitized failure evidence. Serialization, deadlock, lock-timeout and connection-unavailable errors SHALL retry without spending the internal-error budget. Other internal errors SHALL fail after five attempts as processing_exhausted, retaining pin/raw without partial effects. Counters SHALL reflect committed outcomes.

#### Scenario: DUR-1 outbox failure rolls back event work
- **WHEN** inserting an output intent hits a transient database failure after event insertion and the alert state change, repeatedly beyond five transient retries
- **THEN** no event, observation key, alert state change, activity entry, output intent or done outcome commits, the internal-error budget remains unchanged with the pin intact, and a later successful retry commits one effect set, including exactly one alert state change and its activity entry

#### Scenario: Invalid member after valid member
- **WHEN** one alert in a multi-alert delivery is invalid after an earlier alert normalized successfully
- **THEN** the raw row is failed with raw id, pinned version, error class and field path, and no member's event, observation key, alert state change, activity entry or output intent commits

#### Scenario: Processing budget exhaustion
- **WHEN** a pinned row hits a non-transient internal error on every attempt
- **THEN** after five consumed attempts it is failed with processing_exhausted, its pin and raw bytes remain and no partial effects exist

### Requirement: Durable observation deduplication and quarantine

Before event/output effects, processing SHALL enforce durable event-id uniqueness independent of transport deduplication and keep original ordering evidence. Duplicate observations SHALL not emit events or output intents. A duplicate of an eligible observation SHALL advance only its alert's `last_observed_at`; a duplicate of a late or future-dated observation SHALL change no alert state. Source times beyond the future limit SHALL be stored as future_dated without observation keys, outputs or state; late observations SHALL be stored as late without outputs or state. Classification SHALL use the accepted lateness/skew/future policy, never clamped identity evidence.

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
- **WHEN** effective source time is older than the lateness horizon
- **THEN** processing retains late evidence and creates no output intent and no alert state; it is not counted as a current observation
