# Review
## Metadata
- **Round:** 2
- **Prior round:** Round 1 REVISE (4 Critical, 5 Moderate, 2 Suggestions).
- **Reviewer:** cross-model CLI (Codex)
- **Reviewed:** `openspec/strategy.md`, `openspec/architecture.md`, ADRs 0001–0012 in full. Supporting evidence: supplied research, configuration and planning documents; requested Serverpod and Flutter skills. Read-only document review; no runtime verification.

## Findings
### Critical (blocking)

**C1 — Deterministic event ids do not prevent duplicate state mutation. Prior C4 remains open.**

**Files and sections:** ADR 0012, “Transport delivery identity” and “Observation identity”; ADR 0007, “Alert ordering, lateness and clock skew”; ADR 0005, “Processing”.

Transport dedup expires after ten minutes, while the ordering fence compares observed time before event id. Consider a firing observation and a recovery with equal source timestamps, followed by a retry of the firing observation after transport dedup expires. The retry has the same event id but a later observed time. Under the stated comparison, it supersedes the recovery and resurrects the alert.

The documents prescribe no durable observation-id check before state mutation. Deterministic UUIDs and consumer deduplication do not provide that check. Re-batching creates the same problem without waiting ten minutes.

**Required correction:** specify atomic observation deduplication before alert, contribution and notification mutations, including its retention horizon and enforcement across time partitions. A duplicate must preserve the original ordering evidence and produce no additional state effects. Extend ORD-5 with a retry after recovery and after transport-dedup expiry.

**C2 — Alertmanager identity contradicts the promised severity-update semantics. Prior C4 remains open.**

**Files and sections:** ADR 0012, “Alert identity”; ADR 0007, “Tables”; architecture, “Correctness invariants”.

ADR 0012 fingerprints the full Alertmanager label set by default, yet explicitly excludes severity from fingerprints. A payload carrying severity as a label cannot satisfy both rules: changing `labels.severity` changes the fingerprint under the full-label rule.

Consequently, the transition promised by ID-7 can create a second alert instead of updating severity on the existing alert. The old firing member can remain attached until recovery or expiry, corrupting active counts and current severity.

**Required correction:** define the exact precedence between identity labels and normalized semantic fields. Either mandate explicit identity-label selection/exclusions or document label changes as replacement alerts with reconciliation semantics. Align ID-7 with that decision and include severity-label fixtures.

### Moderate

**M1 — Incident-wide operations lack a workable membership-discovery protocol. Prior C2 is substantially improved but remains incomplete.**

ADR 0007, “One mutation protocol for every incident writer”, requires alert locks before group locks, while prohibiting membership reads before the group lock. Merge, split and expiry may need membership to discover which alerts to lock.

An implementation must either reverse the lock order or discover members without protection; concurrent joins can then invalidate its lock set. Define a discovery-and-revalidation protocol with transaction restart when membership changes, or a revised lock hierarchy. Include merge/split versus concurrent join tests.

**M2 — Output budgets still allow an unbounded failed-output storage path. Prior M2 remains open.**

ADR 0005, “Output budget”, bounds pending deliveries but redirects subsequent deliveries into dead letters. Those rows and their referenced events remain stored for fourteen days without a byte/count budget. A failed output can therefore exhaust the shared disk watermark and stop healthy outputs and ingest, despite the stated isolation.

Bound the combined pending and dead-letter footprint, or explicitly qualify isolation and define the policy once the combined budget is exhausted. DUR-11 should exercise sustained overflow.

**M3 — Watermark advancement needs a wake-up or polling contract.**

ADR 0007, “Change feed”, uses streams as wake-ups and excludes transactions above the xmin watermark. A client can receive a commit wake-up, pull while an unrelated transaction holds the watermark back, and receive nothing. When that unrelated transaction ends without activity, no further wake-up is prescribed. The console can remain stale indefinitely despite all transactions being short.

Require periodic cursor pulls or server-side notifications when the safe watermark advances. Extend UI-3 with a watermark-blocking transaction that writes no activity.

**M4 — Expired pipeline failures leave permanently retained raw rows.**

ADR 0005, “Retention never deletes unfinished work”, says failed raw rows never expire, while pipeline failures expire after fourteen days. Expiring the failure does not transition or delete its failed raw row.

Repeated malformed inputs consequently accumulate permanent raw bodies after their replay records disappear. Define an explicit terminal discarded state, entered atomically with the recorded dead-letter expiry, and make its retention eligibility clear.

### Suggestions

None.

## Verdict
VERDICT: REVISE

## Required Changes
Resolve C1 and C2 before accepting the baseline. Address M1–M4 in the affected contracts and acceptance scenarios.

CHANGES_APPLIED: n/a

## Rebuttals

Round-one disposition:

- **C1 retention:** resolved for pending work and partition drops. M4 identifies a separate expiry-state leak.
- **C2 incident concurrency:** substantially addressed by the shared mutation service and group locks; membership discovery remains open as M1.
- **C3 feed cursor:** resolved for late commits by the transaction watermark. M3 identifies a separate feed-liveness gap.
- **C4 identity:** still open as C1 and C2 above.
- **M1 configuration snapshot:** resolved at the baseline level by immutable configuration versions and pinning.
- **M2 output storage:** still open as M2 above; overflow storage bypasses the pending budget.
- **M3 tombstones:** resolved at the baseline level by authoritative alert state and the lateness horizon.
- **M4 security:** resolved at the baseline level by admission, restricted raw access and redaction contracts.
- **M5 defect matrix:** resolved; preventive contracts and named scenarios are now present.
- **S1 plugin spike:** resolved by explicit pass criteria and owner-controlled fallbacks.
- **S2 reversal costs:** resolved in ADRs 0001 and 0008.

The PostgreSQL-only, Relic, future-call and embedded-Postgres choices are consistent with the supplied Serverpod guidance. No additional framework-feasibility blocker was established.
Author responses to round 2 (applied on 2026-11-03 after the round; not yet reviewed):

- **C1 observation dedup:** fixed. ADR 0012 "Durable observation dedup, before any state effect" and "Dedup
  retention" (`observation_keys`, unpartitioned, horizon + skew, insert-on-conflict before any state effect);
  ADR 0007 "Duplicates first"; scenario ORD-5 (a)-(c).
- **C2 Alertmanager severity identity:** fixed. ADR 0012 Alertmanager identity keeps `severity` in the label
  set by default (two-rule warning/critical pattern), with per-source exclusion; "Precedence" rule; ID-7
  (a)-(c) with fixtures.
- **M1 membership discovery:** fixed. ADR 0007 lock hierarchy is now group locks → alert rows → incident rows,
  with "Membership is guarded by group locks" and "Discover, lock, revalidate"; scenario COR-9.
- **M2 output storage:** fixed. ADR 0005 one combined pending + dead-letter budget per output with overflow
  policy `discard_new` (default, ledgered) or `block_ingest`; strategy "No silent loss" updated; DUR-11.
- **M3 feed liveness:** fixed. ADR 0007 "Liveness" (watermark tracking with wake-ups, 10 s safety pull,
  `held_back`); UI-3 (b).
- **M4 discarded state:** fixed. ADR 0005 raw row states and atomic `discarded` transition on dead-letter
  expiry; DUR-12.

Escalation: this is the second consecutive REVISE. Per the roadmap skill, planning stopped here for the
owner's decision (run round 3 on the revised baseline, or USER_OVERRIDE). No roadmap was written and every
ADR stays `Status: proposed`.
