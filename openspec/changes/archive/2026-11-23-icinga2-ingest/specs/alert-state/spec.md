# Spec Delta

## MODIFIED Requirements

### Requirement: State converges in any processing order

The final status, severity, display fields and fence of an alert SHALL NOT depend on the order in which its distinct observations are processed. Deliveries with the same event ID (same namespace, source, fingerprint, generation and observation key) are one observation, whose evidence comes from the delivery processed first; only an eligible, state-bearing observation sets the fence, and a duplicate delivery refreshes `last_observed_at` only when it is itself eligible.

#### Scenario: ORD-3 equal source times are ordered deterministically
- **WHEN** a firing and a resolved observation of one fingerprint have equal source times and are processed in each of the two orders, on fresh state each time
- **THEN** both orders end in the same status, severity and fence, chosen by observed time and then by event id, and in each order the version equals the number of visible changes that order committed

#### Scenario: ORD-7a two observations in both orders
- **WHEN** observations A (source 10:00, observed 10:10) and B (source 10:05, observed 10:06) of one alert are processed in each order, on fresh state each time
- **THEN** both orders end in B's state, A is classified stale when it comes second, and `last_observed_at` is 10:10

#### Scenario: ORD-7b late and new observations in any schedule
- **WHEN** a late observation L (source 8 days before 10:10, observed 10:10) and a new firing observation N (observed 10:06) of the same new fingerprint are processed in each order and in two concurrent transactions
- **THEN** in every schedule N creates the alert, L is stored as `late`, and `last_observed_at` is 10:06

#### Scenario: Duplicate deliveries carry one observation
- **WHEN** two eligible, state-bearing deliveries produce the same event ID but differ in observed time, and are processed in each order
- **THEN** the observation's fence uses the observed time of the delivery processed first, and the second is a `duplicate_observation`

#### Scenario: Same observation key from two sources
- **WHEN** two sources in one namespace report the same object with the same observation key
- **THEN** their event IDs differ and each is processed as its own observation

#### Scenario: Late duplicate of a ready observation
- **WHEN** an eligible observation has been applied, and a delivery with the same event ID arrives after the lateness horizon has passed for it
- **THEN** it is a `duplicate_observation`, and the alert's `last_observed_at`, status, fence and version do not change

#### Scenario: ORD-7c duplicate of a late observation
- **WHEN** the late observation L of ORD-7b is delivered again
- **THEN** it is a `duplicate_observation` and the alert's status, version and `last_observed_at` do not change

## ADDED Requirements

### Requirement: Ordering keys compare at full precision

Ordering-key times SHALL compare at the canonical timestamp's full nanosecond precision, also after the fence is stored and reloaded.

#### Scenario: Source times less than a microsecond apart
- **WHEN** a firing observation with source time t + 900 ns commits, and a resolved observation of the same fingerprint with source time t + 800 ns and a later observed time is processed in a later transaction
- **THEN** the recovery is classified stale and the alert stays firing with its fence's source time at t + 900 ns

### Requirement: Resolved alert fences late evidence after its events expire

A resolved alert's row SHALL keep its fence after the alert's events and observation keys are gone. A firing
observation older than the lateness horizon SHALL change no alert, whether or not its event or key still exists.
When its observation key does not exist (never written, or removed with the alert's events), it SHALL be stored
as `late`; when its key still exists, it SHALL take the duplicate path instead: it is a `duplicate_observation`
and no new event is stored.

#### Scenario: ORD-6 late firing after resolution and expiry
- **WHEN** an Icinga2 service alert resolves, its event rows and observation keys are removed, and a firing observation of it whose source time is 8 days old arrives
- **THEN** the observation is stored as `late`, the alert stays resolved with its version and fence unchanged, and no output intent is created

#### Scenario: Late firing for a fingerprint with no alert
- **WHEN** a firing observation older than the lateness horizon arrives for a fingerprint that has no alert row
- **THEN** it is stored as `late` and no alert is created
