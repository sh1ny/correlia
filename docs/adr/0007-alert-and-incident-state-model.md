# 0007. State model: authoritative alert state, relational incidents, one mutation protocol and a lossless change feed

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: none

## Context

The legacy model had several flaws (legacy audit 6-7, lessons P0.2, P0.4, P0.6, P2.3):
- **Hot rows:** it kept active membership and threshold history in one JSONB document per incident row,
  which became a hot row under alert storms.
- **Stale recoveries:** an older recovery could clear a newer problem (B1).
- **Close race:** an insert racing a close returned a 500 (B2).
- **Polling gaps:** incremental polling missed lifecycle changes (B3).
- **Wrong counts:** recovery counts were wrong (B4).
- **Key collisions:** distinct group keys collided (B5).
- **Acknowledgement history:** a re-acknowledgement mixed the first time with the last actor (B10).
- **Blob history:** a mutable `decision_context` blob served as history.

Correlation joins alerts with different fingerprints into one incident. Per-fingerprint ordering (ADR 0005)
therefore does not protect incidents.

## Decision

### Tables
- **events:** immutable canonical events (ADR 0004), time-partitioned and retention-bound. Events are
  evidence, not the source of current state.
- **alerts:** the **authoritative** current state per (tenant, fingerprint). It is not a projection, and it
  is never rebuilt from expired events.
  - Each row stores its ordering fence: the (effective source time, observed time, event id) of the last
    applied event.
  - Status is firing or resolved. Severity updates in place.
  - Acknowledgement, silence and maintenance are separate fields, not statuses.
- **incidents:** status OPEN, RESOLVED or CLOSED. Acknowledgement is orthogonal to status.
  - An open incident's identity is (correlation rule id, structured group key), enforced by a partial
    unique index. The rule version that opened it is recorded.
  - Group keys are structured tuples encoded canonically (ADR 0012), never delimiter-joined strings.
  - The incident shows **current severity** (the max over active members) and **peak severity**
    separately.
- **incident_alerts:** relational membership (incident, alert, joined_at, left_at, active), with no JSON
  membership.
- **threshold_contributions:** rows counted under the rule's explicit counting policy:
  - distinct active alerts (the default);
  - distinct hosts;
  - observations.
- **incident_transitions:** (incident, seq, kind), unique. A threshold crossing, escalation, resolve or
  reopen is recorded exactly once.
- **activity:** an append-only ledger of every state change and operator action. The actor comes from
  authentication, never from a text field.

### Alert ordering, lateness and clock skew
- **Ordering fence:** an event changes an alert only if it is newer than the fence. Newer is compared by
  effective source time, then observed time, then event id. An older event is stored and marked `stale`,
  and changes nothing (B1 in both directions).
- **Effective source time** is the earlier of the source time and observed time + skew allowance (default
  5 minutes). The original is kept. Operational expiry, windows and reminders use observed time.
- **Lateness horizon** (default 7 days): an event whose effective source time is older than the horizon is
  stored, marked `late`, and changes no state.
- **Future limit** (default 24 hours): an event whose source time is further ahead of its observed time is
  quarantined as `future_dated` and changes no state (ADR 0012).
- **Tombstones:** resolved alert rows are kept at least as long as the lateness horizon, so a delayed or
  replayed event always meets its fence.

### One mutation protocol for every incident writer
All writes to `alerts`, `incidents`, `incident_alerts`, `threshold_contributions`, `incident_transitions` and
notification intents go through one `StateMutationService`. Its writers are:
- pipeline correlation;
- operator actions;
- the expiry and reminder jobs;
- merge and split.

No other code writes those tables.

- **Isolation:** READ COMMITTED with explicit locks, so isolation never depends on SERIALIZABLE retries.
- **Lock hierarchy** (always in this order):
  1. **group locks:** `pg_advisory_xact_lock` on a 64-bit hash of (tenant, rule id, group key), in
     ascending order. A hash collision only adds serialization, never wrong results;
  2. alert rows `FOR UPDATE`, in fingerprint order;
  3. incident rows `FOR UPDATE`, in id order.
- **Membership is guarded by group locks.** Any change to an incident's membership, contributions or
  status requires that incident's group lock. Incidents store their (immutable) group key and lock key.
  So membership read under a group lock is stable for the rest of the transaction.
- **Discover, lock, revalidate.** A writer first computes, without locks, the set of groups it needs:
  - pipeline: the groups the correlation rules compute for the event, plus the groups of the alert's current
    active memberships;
  - operator actions, expiry and reminders: the target incidents' stored group keys;
  - merge and split: the groups of every incident involved.

  It takes those group locks in ascending order and reads membership under them. Then it locks the
  affected alert rows (for incident-wide operations: every member alert), and **after** holding the alert
  locks it re-reads each locked alert's active memberships. Every group found there must already be in the
  lock set. If one is not (a join committed between discovery and the alert lock), the transaction rolls
  back and restarts with the larger set, bounded by the retry policy below. A writer never takes a group
  lock while it holds an alert or incident lock. Once validated, no other writer can add a membership to a
  locked alert, because that needs the alert lock too. Incident rows are locked last.
- **Opening an incident:** under the group lock, read the open incident for the key and insert one if
  there is none. The partial unique index is a backstop: a violation is a protocol bug, retried and
  counted (B2).
- **Threshold crossings and notifications:**
  - Crossings are decided under the lock from membership rows and recorded in `incident_transitions`.
  - The notification intent (an outbox row with idempotency key (incident, transition seq, policy)) is
    inserted in the same transaction.
  - So two concurrent contributions give exactly one crossing and one intent.
- **Recovery:** under the group lock, mark the alert's membership inactive. Resolve the incident only if no
  active membership remains, read under that lock.
- **Retries:**
  - Deadlocks, serialization failures and lock timeouts (lock wait timeout default 5 s) retry the whole
    batch with jittered backoff, up to 5 times.
  - After that the batch is split, and single events go to pipeline failures.
- **Results** report counts per effect: opened, joined, shrunk, resolved, unchanged, stale, late,
  duplicate (B4).
- **Duplicates first:** the observation dedup of ADR 0012 runs before any lock is taken for state; a
  duplicate observation takes no group lock and has no effect.
- **Hot groups:** a hot group is serialized by its lock. Throughput is qualified in M3 (scenario COR-6).
  The planned mitigation if it misses the target is group-affine batching.

### Operator semantics
- **Acknowledgement** records an owner, a time and the actor.
  - Acknowledging an already acknowledged incident as another user transfers ownership.
  - Unacknowledge is allowed.
  - The ledger keeps every action (B10).
  - Acknowledgement never changes status or silences.
- **Manual close** follows the policy in the strategy assumptions (open decision D6), applied through the
  mutation service.
- **Entity versions:** every alert and incident has a `version` that increments on each change. Operator
  actions carry the version they saw and get a conflict when it is stale.

### Change feed (console and API)
- **Feed position:** every activity row records `txid xid8 DEFAULT pg_current_xact_id()` and a `bigserial`
  id. The feed position is (txid, id).
- **Safe reads:**
  - A feed read returns rows after the client's cursor with `txid < pg_snapshot_xmin(pg_current_snapshot())`.
  - Every transaction below that watermark has finished, and new transactions always get higher ids.
  - So a transaction that allocated earlier but committed later can never be skipped. The delayed-commit
    interleaving is a named test (UI-3), including a watermark-blocking transaction that writes no
  activity.
- **Snapshot handover:**
  - A view loads its snapshot and the watermark in one REPEATABLE READ transaction, then reads the feed from
    that watermark.
  - Rows already in the snapshot may arrive again. Clients apply changes by entity version, so a repeated
    row is harmless.
- **Streams** only push a wake-up; the client pulls from its cursor. On reconnect it resumes from the cursor.
- **Liveness:** each api instance tracks the safe watermark (polled every 500 ms) and pushes a wake-up
  whenever it advances past activity rows that were held back, even if the transaction that held it back
  wrote no activity. Clients also pull every 10 s as a safety net. A feed pull answers with
  `held_back: true` when rows exist above the watermark, so clients know more is coming.
- **Expired cursors:** a cursor older than feed retention gets `cursor_expired`, and the client takes a new
  snapshot.
- **Bounded stalls:** a long transaction holds the watermark back. Transaction timeouts bound the stall,
  and feed lag is a metric.

Rejected:
- Keeping the legacy JSON-document incident row.
- SERIALIZABLE isolation as the only concurrency control: retries under storms are unbounded and the
  invariants stay implicit.
- A plain `bigserial` cursor: it skips late commits.

Reversal cost: high once production data exists.

## Consequences

- Recovery ordering is decided per alert, and every incident writer shares one lock protocol. This fixes
  the legacy B1, B2, B4, B5 and B10 classes by construction.
- The change feed is lossless under concurrent commits, which fixes the B3 class.
- Threshold semantics become an explicit rule option instead of a side effect of a fingerprint cache.
- `StateMutationService` is the most heavily tested unit. Every interleaving in
  `docs/plan/acceptance-scenarios.md` (COR-*, ORD-*, UI-*) runs against real Postgres.
