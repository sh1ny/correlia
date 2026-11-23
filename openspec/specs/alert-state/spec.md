# alert-state Specification

## Purpose

Keep one authoritative current state per alert (tenant and fingerprint) that only fenced, newer observations can change, so that delayed, retried or reordered input never corrupts it.

## Requirements

### Requirement: Authoritative alert state per fingerprint

The system SHALL keep exactly one alert state per (tenant, fingerprint). It holds:
- status (firing or resolved);
- current severity;
- display fields;
- an ordering fence;
- `last_observed_at`;
- an entity version.

The first eligible observation of a fingerprint SHALL create the state with its status. Alert state is authoritative: the system SHALL NOT rebuild it from events. A resolved alert SHALL be kept, as a tombstone, at least as long as the lateness horizon.

#### Scenario: First firing observation creates a firing alert
- **WHEN** an eligible firing observation arrives for a fingerprint with no alert state
- **THEN** one alert exists for that fingerprint with status firing, the observation's severity, version 1 and a fence equal to that observation's ordering key

#### Scenario: First observation is a recovery
- **WHEN** the first eligible observation of a fingerprint is resolved
- **THEN** one alert exists with status resolved and version 1, and a later firing observation with an older ordering key leaves it resolved

#### Scenario: Concurrent first observations of one fingerprint
- **WHEN** two workers concurrently process different raw rows that each carry the first observation of the same new fingerprint
- **THEN** exactly one alert exists for that fingerprint, both observations are classified (one applied and one either applied or stale, by fence order), and neither raw row fails

### Requirement: Ordering fence decides state changes

An observation SHALL change an alert only when its ordering key is greater than the alert's fence. The key compares effective source time, then observed time, then event id. Effective source time is the earlier of the source time and the observed time plus the skew allowance (default 5 minutes). An observation that does not pass the fence SHALL be classified `stale` and change no status, severity, display field, fence or version.

#### Scenario: ORD-1 delayed recovery does not clear a newer problem
- **WHEN** a firing observation with source time t2 is processed, then a resolved observation of the same fingerprint with source time t1 < t2 is processed
- **THEN** the recovery is classified stale, the alert stays firing with the t2 fence and its version is unchanged

#### Scenario: ORD-2 stale problem does not resurrect a resolved alert
- **WHEN** a resolved observation with source time t2 is processed, then a firing observation with source time t1 < t2 is processed
- **THEN** the firing observation is classified stale and the alert stays resolved with its version unchanged

#### Scenario: Source clock ahead within the future limit
- **WHEN** an observation's source time is 2 hours after its observed time (inside the 24 hour future limit)
- **THEN** its effective source time is its observed time plus 5 minutes, it is compared by that time, and its original source time is preserved in its event

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

### Requirement: Ordering keys compare at full precision

Ordering-key times SHALL compare at the canonical timestamp's full nanosecond precision, also after the fence is stored and reloaded.

#### Scenario: Source times less than a microsecond apart
- **WHEN** a firing observation with source time t + 900 ns commits, and a resolved observation of the same fingerprint with source time t + 800 ns and a later observed time is processed in a later transaction
- **THEN** the recovery is classified stale and the alert stays firing with its fence's source time at t + 900 ns

### Requirement: Applied observations update state in place

An applied observation SHALL set the alert's status, severity and display fields to the observation's values and advance its fence. When status, severity or a display field changes, the version SHALL increase by exactly one. An applied observation that changes none of them SHALL advance only the fence and `last_observed_at`.

#### Scenario: ID-7c severity changes in place
- **WHEN** a source excludes severity from identity and a newer firing observation of the same alert changes severity from warning to critical
- **THEN** one alert exists, its severity is critical and its version increased by one

#### Scenario: ID-7b severity-labelled alerts are separate
- **WHEN** warning and critical observations of one condition fire under default identity, and then the critical one resolves
- **THEN** two alerts exist; the critical one is resolved and the warning one stays firing with its version unchanged

#### Scenario: Newer repeat with no visible change
- **WHEN** a newer firing observation arrives with the same status, severity and display fields as the alert
- **THEN** the fence advances, the version is unchanged and no activity entry is written

### Requirement: Last observed time advances monotonically

`last_observed_at` SHALL advance to the greatest observed time of the alert's applied and stale observations and of duplicates of those. It SHALL never move backwards. It SHALL NOT be advanced by late or future-dated observations or by their duplicates. Changing it SHALL NOT change the version or write activity.

#### Scenario: Stale observation with a later observed time
- **WHEN** a stale observation arrives whose observed time is later than the alert's `last_observed_at`
- **THEN** `last_observed_at` equals that observed time and status, fence and version are unchanged

#### Scenario: Older observed time never moves it backwards
- **WHEN** an applied or stale observation arrives whose observed time is earlier than the alert's `last_observed_at`
- **THEN** `last_observed_at` is unchanged

#### Scenario: Late observation advances nothing
- **WHEN** an observation whose effective source time is older than the lateness horizon arrives for an existing alert
- **THEN** the alert's `last_observed_at`, status, fence and version are unchanged and no alert is created for an unknown fingerprint

### Requirement: Single writer for alert state

Only the state mutation service SHALL write alert state. It SHALL run inside the transaction that commits the observation's event. It SHALL lock the alert rows of one transaction in ascending fingerprint order. It SHALL report the count of applied, stale, late and duplicate observations per transaction. Observations with status `info` SHALL change no alert state.

#### Scenario: Effect counts per raw row
- **WHEN** one raw delivery carries one applied, one stale and one duplicate observation
- **THEN** the raw row's committed outcome reports applied 1, stale 1 and duplicate_observation 1, and each counted observation is classified once

#### Scenario: Opposite fingerprint order in concurrent deliveries
- **WHEN** two concurrent raw rows each carry observations of fingerprints A and B, listed in opposite orders
- **THEN** both commit without exhausting their retry budgets, and each alert's final status, severity and fence equal those of processing the observations one at a time in ordering-key order

#### Scenario: Informational observation
- **WHEN** an eligible observation with status info is processed for a fingerprint
- **THEN** no alert is created or changed and no activity entry is written

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
