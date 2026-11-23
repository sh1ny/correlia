# Spec Delta

## MODIFIED Requirements

### Requirement: State converges in any processing order

The final status, severity, display fields and fence of an alert SHALL NOT depend on the order in which its distinct observations are processed. For Icinga2 stream sources, distinct results with equal starts and copies of one result follow their own requirements, and the displayed source follows "Displayed source in a shared namespace". Deliveries of one observation follow "Duplicate deliveries carry one observation".

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
- **WHEN** an eligible observation has been applied, and a delivery with the same event ID, other than an Icinga2 stream or sync item, arrives after the lateness horizon has passed for it
- **THEN** it is a `duplicate_observation`, and the alert's `last_observed_at`, status, fence and version do not change

#### Scenario: ORD-7c duplicate of a late observation
- **WHEN** the late observation L of ORD-7b is delivered again
- **THEN** it is a `duplicate_observation` and the alert's status, version and `last_observed_at` do not change

### Requirement: Single writer for alert state

Only the state mutation service SHALL write alert state. It SHALL run inside the transaction that commits the observation's event, or, for a reconcile observation that stores no event, inside the transaction that processes its raw row. It SHALL lock the alert rows of one transaction in ascending fingerprint order. It SHALL report the count of applied, stale, late and duplicate observations per transaction. Observations with status `info` SHALL change no alert state.

#### Scenario: Effect counts per raw row
- **WHEN** one raw delivery carries one applied, one stale and one duplicate observation
- **THEN** the raw row's committed outcome reports applied 1, stale 1 and duplicate_observation 1, and each counted observation is classified once

#### Scenario: Opposite fingerprint order in concurrent deliveries
- **WHEN** two concurrent raw rows each carry observations of fingerprints A and B, listed in opposite orders
- **THEN** both commit without exhausting their retry budgets, and each alert's final status, severity and fence equal those of processing the observations one at a time in ordering-key order

#### Scenario: Informational observation
- **WHEN** an eligible observation with status info is processed for a fingerprint
- **THEN** no alert is created or changed and no activity entry is written

#### Scenario: Silent reconcile write
- **WHEN** a reconcile observation advances an alert's fence without storing an event
- **THEN** the fence change commits in the transaction that processes its raw row (which deletes a sync row that stored nothing), and rolls back with it

### Requirement: Resolved alert fences late evidence after its events expire

A resolved alert's row SHALL keep its fence after its events and keys are gone, except for eligible silent
tombstones under reclamation. An observation older than the lateness horizon SHALL change no alert.
When its observation key does not exist (never written, or removed with the alert's events), it SHALL be stored
as `late`; when its key still exists, it SHALL take the duplicate path instead: it is a `duplicate_observation`
and no new event is stored. An item of an Icinga2 stream or sync row is the exception: it is counted `late` and
never stored.

#### Scenario: ORD-6 late firing after resolution and expiry
- **WHEN** an Icinga2 service alert resolves, its event rows and observation keys are removed, and a firing observation of it whose source time is 8 days old arrives
- **THEN** the observation is stored as `late`, the alert stays resolved with its version and fence unchanged, and no output intent is created

#### Scenario: Late firing for a fingerprint with no alert
- **WHEN** a firing observation older than the lateness horizon arrives for a fingerprint that has no alert row
- **THEN** it is stored as `late` and no alert is created

#### Scenario: Late stream item after resolution
- **WHEN** an Icinga2 stream item whose start is 8 days old reports a problem for a resolved alert
- **THEN** it is counted `late`, no event or key is stored, and the alert stays resolved with its fence unchanged

### Requirement: Applied observations update state in place

An applied observation SHALL set the alert's status, severity and display fields to the observation's values and advance its fence. When status, severity or a display field changes, the version SHALL increase by exactly one. An applied observation that changes none of them SHALL advance only the fence and `last_observed_at`. A silent reconcile confirm follows "Reconcile observations confirm or repair" and leaves display fields unchanged.

#### Scenario: ID-7c severity changes in place
- **WHEN** a source excludes severity from identity and a newer firing observation of the same alert changes severity from warning to critical
- **THEN** one alert exists, its severity is critical and its version increased by one

#### Scenario: ID-7b severity-labelled alerts are separate
- **WHEN** warning and critical observations of one condition fire under default identity, and then the critical one resolves
- **THEN** two alerts exist; the critical one is resolved and the warning one stays firing with its version unchanged

#### Scenario: Newer repeat with no visible change
- **WHEN** a newer firing observation arrives with the same status, severity and display fields as the alert
- **THEN** the fence advances, the version is unchanged and no activity entry is written

## ADDED Requirements

### Requirement: Duplicate deliveries carry one observation

Deliveries with the same event ID are one observation, whose evidence comes from the first delivery that keeps a key; only an eligible, state-bearing observation sets the fence, and a duplicate refreshes `last_observed_at` only when itself eligible. Late or future-dated Icinga2 stream and sync items and silent reconcile observations SHALL write no key; such an item is counted late or future even when its key exists.

#### Scenario: Late stream copy after the prompt copy
- **WHEN** an Icinga2 stream copy of an applied result arrives after the lateness horizon
- **THEN** it is counted `late`, not `duplicate_observation`, and the alert's `last_observed_at`, status, fence and version do not change

#### Scenario: Late stream copy is not a first delivery
- **WHEN** an Icinga2 stream copy of a result arrives after the lateness horizon and is processed before a prompt copy of the same result
- **THEN** the late copy writes no key, and the prompt copy is processed as the first delivery

### Requirement: Reconcile observations confirm or repair

A reconcile observation SHALL use the ordinary ordering fence and SHALL create an event only if it
creates a firing alert or changes an existing alert's status or severity. After passing the fence,
an observation that agrees in status and severity SHALL update only the fence and `last_observed_at`;
one that disagrees SHALL apply and be published. A resolved reconcile observation with no alert
SHALL create a resolved tombstone holding its fence, with no event, activity or output intent.

#### Scenario: Sync agrees with the alert
- **WHEN** a firing CRITICAL alert receives a newer reconcile observation reporting CRITICAL
- **THEN** the alert's fence and `last_observed_at` advance, its version is unchanged, and no event row, activity row or output intent is written

#### Scenario: Sync repairs a missed recovery
- **WHEN** a firing alert receives a newer reconcile observation reporting OK
- **THEN** the alert is resolved, its version advances, `resolved` activity is written, and one event is stored and routed

#### Scenario: Recovered object with no alert
- **WHEN** a reconcile observation reports OK for a fingerprint with no alert
- **THEN** a resolved tombstone with the observation's fence is created, and no event, activity or output intent is written

#### Scenario: Older problem after a silent tombstone
- **WHEN** a silent tombstone was created by a sync OK (start 10:02), and a stream CRITICAL with start 10:01 is processed
- **THEN** the CRITICAL is stored as `stale`, no alert fires, and the committed outbox holds no intent for it

#### Scenario: Stale reconcile observation that disagrees
- **WHEN** a reconcile observation older than the fence reports a state different from the alert's
- **THEN** it changes nothing except `last_observed_at`, and it is counted `stale` on the row's outcome and `diverged` on the sync

#### Scenario: Late reconcile observation
- **WHEN** a reconcile observation's effective source time is older than the lateness horizon
- **THEN** it is counted `late`, writes no event and changes no state, and it is counted `diverged` on the sync when it disagrees with the alert

### Requirement: Silent confirms keep no key

A silent reconcile observation SHALL leave no observation key, so a later copy of the same Icinga2
result is a first delivery. Within the clock skew, processing these copies in different orders SHALL
converge on the same alert state and effective fence source time; only the fence receipt time MAY
differ. Beyond the skew, a keyed stale stream copy MAY block its sync copy from repairing the alert;
the documentation SHALL state this.

#### Scenario: Stale stream copy beyond the skew
- **WHEN** a firing alert is fenced at 10:06, and a recovery starting at 10:30 arrives on the stream at 10:00 (clamped to 10:05) and in a sync at 10:02 (clamped to 10:07), in both orders
- **THEN** sync first: the alert is resolved and the stream copy is a `duplicate_observation`; stream first: the stream copy is stored `stale` with its key, the sync copy is a `duplicate_observation`, and the alert stays firing

#### Scenario: Stream copy after a silent confirm
- **WHEN** HARD CRITICAL results A (start 10:00) and B (start 10:01) are processed, with B's sync copy received at 10:02 and its stream copy at 10:03, in the orders B-sync, B-stream, A and A, B-sync, B-stream
- **THEN** in both orders the committed alert is firing CRITICAL with fence source time 10:01, and its fence's observed time is 10:02 in the first order and 10:03 in the second

### Requirement: Displayed source in a shared namespace

In a shared namespace, the same ordering fence SHALL govern writes from every source. The displayed
source is guaranteed to converge only when one source writes the alert: a silent confirmation
preserves the displayed source, so the order in which different sources write MAY affect it. The
documentation SHALL state this.

#### Scenario: Webhook and sync in both orders
- **WHEN** an older HARD CRITICAL from a webhook source and a newer HARD CRITICAL from a stream source's sync, with different starts, are processed for one service in a shared namespace in both orders
- **THEN** both orders end firing CRITICAL with the sync's fence; the displayed source is the webhook source in the first order and the stream source in the second, and the limits documentation names this

### Requirement: Tombstones are reclaimed after the lateness horizon

Only a marked silent tombstone without retained events, activity or keys SHALL be reclaimable. Under
the alert lock, its fence SHALL predate the lateness horizon relative to both the durable admission
cutoff and every pending receipt, including those from other sources. Equality is not eligible.
Queued items SHALL still use their original receipt for lateness.

#### Scenario: Objects deleted upstream
- **WHEN** 100,000 objects are synced OK, deleted in Icinga 2, and 100,000 other objects are synced OK
- **THEN** once the first set's fences are older than the lateness horizon their tombstones are gone, and the second set's remain

#### Scenario: Older problem after reclamation
- **WHEN** a tombstone was reclaimed, and a problem whose start is older than its fence arrives
- **THEN** it is counted `late` and creates no alert, as it would have with the tombstone present

#### Scenario: A promptly received older problem is still pending at reclamation
- **WHEN** a stream CRITICAL is received promptly, a newer sync OK creates a silent tombstone, and a sweep runs after the tombstone's fence becomes old enough while the CRITICAL row is still pending
- **THEN** the sweep retains the tombstone and the CRITICAL is processed as stale with no output intent

#### Scenario: A pending webhook shares the tombstone's namespace
- **WHEN** the old pending problem belongs to a webhook source sharing the sync source's namespace
- **THEN** the sweep also retains the tombstone; processing the webhook row does not make the alert fire

#### Scenario: Older admission is in flight during reclamation
- **WHEN** a transaction inserting an old receipt is concurrent with a sweep that advances the cutoff beyond that receipt
- **THEN** if admission wins the fence, the committed row is visible to the sweep and keeps the tombstone; if the sweep wins the fence, the new raw row and its reservation cannot commit

#### Scenario: Ordinary resolution outlives its history
- **WHEN** a normally resolved alert has no remaining events, activity or observation keys and its fence is older than both reclamation bounds
- **THEN** reclamation retains the resolved alert and its fence

#### Scenario: Fresh problem races deletion after an insert conflict
- **WHEN** an eligible firing observation races a sweep that deletes the silent tombstone after the worker's insert conflicts but before it locks the alert
- **THEN** the worker reacquires the alert row and commits a new alert at version 1, its `created` activity, the event and its output intents together

#### Scenario: Fresh problem precedes a sweep
- **WHEN** the same problem locks and refires the silent tombstone first
- **THEN** it retains the original alert ID, increments its version and records the refire; the sweep does not delete the firing row

#### Scenario: Reclamation is bounded under contention
- **WHEN** a pass encounters locked alert rows or the supervisor is stopped while reclaiming
- **THEN** the pass skips locked candidates, stops by its local deadline or cancellation, and reports deletion only for an acknowledged commit
