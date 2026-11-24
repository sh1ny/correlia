# Review

## Metadata

- **Round:** 4
- **Prior round:** round 3 REVISE (7 Critical, 8 Moderate), all answered in the revised artifacts
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-event-streams` proposal, FULL design, six spec deltas and rounds 1–3; corresponding main specs and `integration-icinga2`; archived `icinga2-ingest` rounds 1–3 and round 4 Critical 5; ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029; architecture, roadmap, project rules and relevant Dart/Serverpod skills. Source: cited ingest admission, ingress, configuration, bootstrap, Icinga2 parser/mapper/decoder/facts, commitments, pipeline, alert state, worker registry, relay and console code; also `ingest_startup.dart`, raw-inbox schema, production database configuration and capture tooling. Read-only review; no tests or captures run.

## Findings

### Critical (blocking)

1. **Equal-start convergence still depends on whether the sync happens to repair or write silently.** Use the three rows in the new scenario: stream OK received at 10:01, stream CRITICAL at 10:02, and a sync copy of the OK at 10:03, all with the same projected start. The two specified schedules end firing. But CRITICAL → sync OK → stream OK ends resolved: the sync differs, so D2 gives it a normal repair fence using 10:03 and keeps its key; the stream OK is then a duplicate. This follows the comparator in `ordering_key.dart:43–51` and the key-before-effects behavior in `pipeline.dart:445–495`. D2 also allows a fence to move backwards: a distinct, agreeing sync result at the same start can pass with its real receipt time, then overwrite a higher receipt-time fence with the minimum. Define the incoming rank and persisted fence together, including repairs and copies; test all six schedules and an agreeing equal-start sync against an existing ordinary fence. The current two-schedule test excludes the schedule that resolves the alert.

2. **An older publisher can expose a bare digest after a password is accepted.** D8 catches snapshots an older process publishes *before* the password publication. It cannot stop that process publishing afterward. `ingest_startup.dart` runs publication in every role, including `api`; `config_repository.dart:119–246` serializes publications but has no reuse check in the older binary. The prospective cutover rule upgrades only workers. An older API process with a higher revision can still install a credential or signing commitment matching an already-published password, including one since removed. Catch-up at the next new publication cannot undo disclosure. Make the activation boundary exclude **all** incompatible publishers, including restarts or rollback, before the first password can be accepted. The existing offline upgrade rule in `integration-icinga2` already names every role.

3. **A connection can end mid-sync without closing that sync's durable read phase.** D12 finalizes when reading ends, when rows finish, and on the holder's check; its only explicit interrupted-read recovery is takeover of a `reading` sync. A stream can disconnect or hit lag/backpressure while the same holder is still enumerating, then reconnect without a generation change. Cancelling the sync reader does not itself set `readEndAt` or `readProblem`. If the holder starts another sync, the previous record can stay `reading` forever: its rows cannot complete it and the stalled check and prune both need a timestamp it never received. Define a fenced, idempotent close or recovery step before replacing any connection's sync, keyed to whether reading actually ended, not to `phase` alone—a row failure can set `failed` while enumeration is still open. Test a same-generation reconnect and takeover after a row failed but before reading ended.

4. **The stop mechanism still cannot guarantee the stated backend lock-release times.** D13 bounds local socket closure, not when a backend reaches an interrupt check and completes abort. TCP keepalives and `tcp_user_timeout` detect certain peer or network failures; they do not bound cleanup, and a TCP-terminating intermediary can keep the database-side session alive after losing the worker side. The planned “test TCP proxy” does not establish a direct transport blackhole unless it actually drops packets on the database connection rather than terminating it. Keep the enforceable 10-second local deadline separate from the conditions for observing backend lock release. Specify the supported topology and cancellation behavior, and measure release with an independent connection under applicable faults rather than promising a universal 5/15-second bound.

5. **The lag rule does not bound Icinga's queue under the burst that needs the bound most.** D7 measures lag on lines that have already reached Correlia, using the first observed lag as the baseline if nothing earlier was read. An initially busy subscription can build a large queue before the first usable sample; a burst can also accumulate arbitrarily many bytes before the 60-second threshold plus 120-second observation window, with no single 30-second pause. The capture assumption itself says the upstream inbox has no limit. A disconnect limits how long some overload patterns persist; it does not bound upstream memory at 10× or 100× volume. Either define an enforceable upstream operating limit or state the residual overload risk explicitly in the contract and setup, rather than calling the queue bounded. Exercise initial backlog as well as repeated short pauses.

### Moderate

1. **The phase, cap and retention estimates omit triggered syncs and retired sources.** D12's 8,640 progress rows per source in 30 days counts only periodic syncs at the minimum interval. Failed stream rows, oversize lines and reconnects can start additional syncs. The holder is also the only pruner; after source retirement no holder is required to return, so otherwise eligible records can remain indefinitely. State what limits triggered sync creation and who reclaims retired-source history. Separately, D7's partial index addresses unrelated-source scans, but the evidence map only checks a cap count; it would pass on a plan that repeatedly scans another source's backlog. Retain the quiet-source-beside-backlog case.

2. **The backfill's catch-up path reintroduces unbounded work under the publication lock.** D8 batches the initial scan, but the first password publication must add *every* snapshot newer than the mark while serialized with publication. The mark is described as permanent and no bounded resume or advance rule is specified. An inventory built long before Event Streams activation can therefore turn activation into a historical scan that serializes unrelated publications. Define a stable scan boundary, monotonic completion marking, and a bounded catch-up path. Test a stale mark against a populated history, not just one newer snapshot. This is distinct from the old-publisher cutover defect.

3. **Field-path redaction does not sanitize bad-object names in diagnostics.** D3/D20 log every rejected object's name and retain the first 20 names and codes, even though invalid objects have not passed validation and an oversize skipped object might never yield a usable name. A malformed response can put control characters or arbitrary text into production logs and status, and the sample's count limit alone does not bound its serialized bytes. Use bounded diagnostic identifiers that are safe to emit, with a fixed fallback when no valid identifier was read. Test malformed and oversized samples at the stored status and log surfaces.

4. **Several merged requirements still disagree on what commits.** `alert-state` “Silent reconcile write” says a confirmation marks its raw row done, while D19 and `durable-pipeline` delete an eventless sync row in that transaction. `durable-pipeline` “Late observation evidence” is still unqualified, and the unchanged “Clamped source time is recorded” requires a stored event even for a clamped silent reconcile. The main `integration-icinga2` document requirement also names the webhook route without the new mode restriction. Scope these contracts and their scenarios explicitly. Include the stale-reconcile storage exception in ADR 0030: ADR 0017 currently says stale events are stored, while the delta forbids storing them for reconcile.

5. **The acceptance map puts some assertions below the layer that can prove them.** The fast parser/scanner/batcher group cannot prove that invalid bytes are admitted unchanged or that the persisted diagnostic path is `check_result.vars_after.state`; current `pipeline.dart:94–145` applies a separate storage-path transform. Map those cases to a committed raw/failure-row check. Map the hostile TLS/proxy environment and hostname cases to the actual HTTPS client path, not just the positive consumer e2e run. In the fanout scenario, specify a fixture that demonstrably hits the ×9 cut rather than the 256 KiB encoded cut first; a test that only sees small emitted batches can pass with the fanout check removed.

6. **The identity-time contract has two definitions of the same bytes.** D17 prescribes `double.toString()` while the spec says the shortest decimal text that round-trips. For an integral double, `1.0` and the shorter `1` both round-trip to the same double, but produce different native keys. Specify the exact string contract, including integer-valued times. Also add a floor-boundary vector such as `4294967296.000001`: the parsed double is about 0.954 µs greater than the whole second, so its exact microsecond floor is the whole second, even though floating-point multiplication by one million can round onto the next integer. The current vectors do not catch that implementation.

7. **The carried-constraint ledger still has a wrong destination and missing lifecycle constraints.** C5 points to “Event Streams setup documentation,” but the gap-loss contract is in “Event Streams limits documentation.” No carried entry preserves D20's no-row/no-trigger behavior for malformed sync objects, D12's rule that a failed sync row cannot request another sync, or the rule that a predecessor's gap must be recorded before numbering the next connection. Removing any of these can restore the failure loop or silently lose a gap. Name one durable destination per constraint and update C10 to preserve the publisher boundary as well as the worker decoder boundary.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

CHANGES_APPLIED: n/a

## Rebuttals

Round 3 C2's key-before-alert lock order, C4's bad-object isolation, C5's owner-approved retention exception and C7's acquisition deadline are present. C1 and C6 remain open; C3 now covers normal finalization but not interrupted reads on reconnect. D19's per-row deletion and D20's count-without-admission decision should stand.

Round 3 M1's eligibility and shared-writer limits, M3's framing distinction and M4's structural path redaction are present. M2 now has the partial index but lacks the contention evidence and still understates sync-history growth. M5–M8 are partial as noted above. The earlier source/lease fencing, per-item receipt evidence, default-mode snapshot stability and late/policy-skipped key exclusions remain intact. The late-copy and policy fixes do not solve equal-start repair ordering.
No finding is rebutted; each is fixed in round 5 (design.md, "This change's review round 4"). The owner chose
(2026-11-23) "Revise, narrow claims", "Outside guarantee" for C1 (D22), "All roles upgraded" for C2 (D23) and
"State residual risk" for C5 (D24). For D23, the agent enforces the owner's rule with a database trigger rather
than the process registry the option described, because an older binary cannot register; this is recorded in D23.
