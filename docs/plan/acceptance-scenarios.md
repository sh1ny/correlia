# Acceptance and regression scenarios

Named scenarios every milestone must keep passing. They come from three sources:
- the legacy defects (`docs/research/legacy-audit.md` 6.1);
- the legacy minimum acceptance examples (same file, section 9);
- design flaws common in alert-correlation tools that we chose not to repeat.

Each scenario becomes a named test (tag `db` or `e2e`) in the change that first makes it testable. The
"First in" column is that milestone. A scenario is never deleted; when policy changes, its expected outcome
changes in a spec amendment.

Concurrency scenarios (COR-*, UI-3 and any other interleaving of two writers) run in the `db` tier with
`rollbackDatabase: disabled` and two independent database connections, one per writer, each with its own
transactions. The default rolled-back test transaction runs everything on one connection, so it cannot show
an interleaving. These tests clean up their own rows.

## Ordering and state

| Id | Scenario | Expected | First in |
|---|---|---|---|
| ORD-1 | Problem at t2 is processed, then a delayed recovery with source time t1 < t2 arrives for the same object (legacy B1) | The recovery is recorded as stale; the alert stays firing; the incident stays open | M1 (alert state) |
| ORD-2 | Recovery at t2 is processed, then a stale problem at t1 arrives | The alert stays resolved; no incident is reopened or created | M1 |
| ORD-3 | Problem and recovery with equal source time | Tie broken by observed time, then event id (strategy assumption 5); the outcome is deterministic across replays | M1 |
| ORD-4 | Event with source time in the future beyond the skew limit | Accepted; source time is clamped for operational expiry and the clamp is recorded; correlation windows are not stretched (legacy 6.2) | M2 |
| ORD-5 | The same observation delivered again: (a) a sender retry inside the dedup window; (b) re-batched in another webhook; (c) a retry of a firing observation after a recovery with the same source time, after the transport dedup window expired; (d) a firing observation with source time 1 h in the future, then a recovery, then a retry of the firing after its observation key expired; (e) source time 3 days in the future; (f) generic mapping without a native id: firing with source time 1 h ahead, then a recovery, then a retry of the firing after the transport dedup window | (a) deduplicated at ingest; (b) and (c) `duplicate_observation` that only advances the alert's `last_observed_at`, with no other state, contribution, notification or output effect; the alert stays resolved in (c) and (d) (the retry is `late`); (e) quarantined as `future_dated`, no state effect; (f) same event id (reported source time), `duplicate_observation` (only `last_observed_at` advances), the alert stays resolved | M1 |
| ORD-6 | A firing event older than the lateness horizon arrives after the alert resolved and its events expired | Stored as `late`; the tombstone fence holds; no alert or incident change | M2 |
| ORD-7 | Freshness under any processing order: (a) two observations of one alert, A (source 10:00, observed 10:10) and B (source 10:05, observed 10:06), in both orders; (b) a late observation L (source 8 days ago, observed 10:10) of a new fingerprint and a new firing observation N (observed 10:06), in both orders and in concurrent transactions; (c) a duplicate of L | (a) the alert ends in B's state in both orders (A is stale when it comes second), `last_observed_at` 10:10; (b) N creates the alert, L is `late`, `last_observed_at` 10:06 in every schedule; (c) advances nothing | M2 |

## Identity and bounds

| Id | Scenario | Expected | First in |
|---|---|---|---|
| ID-1 | Two group-by tuples that would collide when joined with delimiters: `(host='a\|service=b', service='c')` vs `(host='a', service='b\|service=c')` (legacy B5) | Two distinct incidents; group keys are structured tuples hashed canonically | M3 |
| ID-2 | Two sources with the same host/service names | Separate alerts by default (per-source-instance namespace); merged only when an operator declared a shared namespace (assumption 3) | M2 |
| ID-3 | Maximum-length legal host (256) grouped and summarized; 4097-character check output (legacy B6) | Accepted; display fields truncated with a marker; identity unaffected; never a 500 | M2 |
| ID-4 | A delimiter-bearing identifier in a fingerprint input | Fingerprints differ; the fingerprint preimage is length-prefixed/structured | M1 |
| ID-5 | Naive datetime in an API filter (legacy B7) | 400/422 with a field error, never 500 | M4 |
| ID-6 | The same alerts re-batched differently or reordered across webhooks | Same event ids (ADR 0019); no extra observations counted | M1 |
| ID-7 | Severity changes: (a) Icinga2 service WARNING → CRITICAL; (b) Alertmanager `warning` and `critical` rules for one condition firing together, then `critical` resolving; (c) a source with `severity` excluded from identity changing the label in place | (a) one alert, severity updated; (b) two alerts, the `warning` one stays firing; (c) one alert, severity updated. Fixtures with severity labels for each | M1 (b, c), M2 (a) |

## Correlation and lifecycle

| Id | Scenario | Expected | First in |
|---|---|---|---|
| COR-1 | Two concurrent distinct problems enter one group (legacy acceptance 1) | Exactly one open incident; both memberships persist; exactly one threshold-crossing work item | M3 |
| COR-2 | Insert races a concurrent close of the same incident (legacy B2) | The event opens a new incident or joins the right one; never a 500 | M3 |
| COR-3 | Host-only alert plus two service alerts on the same host; one service recovers; then the host recovers (legacy acceptance 4) | Service recovery removes only that service; host recovery clears that host's objects only; the incident resolves only when membership is empty; members beyond the display cap still count | M3 |
| COR-4 | One recovery resolves N incidents (legacy B4) | The result reports a count per effect (shrunk, resolved) | M3 |
| COR-5 | Correlation window: alerts keep arriving forever (a window that slides on every alert never closes) | A group has a maximum open duration and a quiet period; after either, a new incident starts and the old one links to it | M3 |
| COR-6 | 10,000 alerts for one group in 60 s (hot group) | One incident; no lost membership; no deadlock; serialization retries visible in metrics | M3 (correctness), M10 (latency target) |
| COR-7 | Manual close while alerts are still firing | Policy from open decision D6; tested both ways once chosen | M3 |
| COR-8 | Re-acknowledge by another user (legacy B10) | Ownership transfers; the ledger keeps both actions with their actors and times | M4 |
| COR-9 | Merge, split, expiry or a recovery races a concurrent join of the same alert through another rule, including a join committed between the writer's group-lock membership check and its alert-row lock | The post-alert-lock revalidation finds the new group, rolls back and restarts with it; the recovery leaves no active membership behind; no lost join | M3 |

## Durability and delivery

| Id | Scenario | Expected | First in |
|---|---|---|---|
| DUR-1 | State change succeeds but the outbox insert fails (legacy acceptance 2) | The whole transaction rolls back; the event is retried and succeeds once | M1 |
| DUR-2 | The process dies right after commit (legacy acceptance 3) | Pending outbox work is picked up after restart; attempts are visible | M1 |
| DUR-3 | Output delivered, then the worker crashes before marking it delivered | Delivered again with the same message id; NATS dedupes by `Nats-Msg-Id` within its window; duplicates are documented for other outputs | M1 |
| DUR-4 | Output fails for longer than its retry budget | Dead-lettered with error class; visible in the console; replay succeeds after the fix | M2 |
| DUR-5 | Rules reference an output that is not configured (legacy B8) | Rule activation is rejected with a validation error naming the output | M2 |
| DUR-6 | Notification fails on first threshold crossing (legacy 6.2) | Retried by the outbox; the crossing is not lost; the incident shows the delivery state | M6 |
| DUR-7 | Multiline monitoring text in a summary used as an email subject (legacy B11) | The subject is folded to one line; the notification is sent | M6 |
| DUR-8 | Plugin process crashes mid-stream | The host restarts it with backoff; in-flight batch is redelivered; the plugin shows `degraded` while the crash budget is exceeded | M1 |
| DUR-9 | Raw inbox lag above the bound | Webhooks get 429/503 with `Retry-After`; nothing accepted is lost | M2 |
| DUR-10 | Workers are down longer than raw retention | Pending and failed raw rows survive retention; processed after restart | M2 |
| DUR-11 | One output stays down past its combined pending + dead-letter budget, for hours | Under `discard_new`: new deliveries are counted and ledgered, storage stays within budget, a self-alert fires, ingest and other outputs keep their latency. Under `block_ingest`: ingest backpressure | M2 |
| DUR-12 | A pipeline failure or delivery dead letter expires without replay | Its raw or outbox row moves to `discarded` in the same transaction; ledger entry with a count; the row becomes retention-eligible | M2 |
| DUR-13 | A mapping bug makes raw rows fail to decode; the operator fixes the mapping and replays the failed rows | Each replay runs with the configuration active at replay time and re-pins the row; its events apply with normal ordering and notify normally; automatic retries before the fix used the original pin (ADR 0016, D26) | M2 |

## Change feed and console

| Id | Scenario | Expected | First in |
|---|---|---|---|
| UI-1 | Ack, partial recovery, close, expiry and delivery update happen with no new problem event (legacy B3, acceptance 8) | The console sees each through the change feed (monotonic record version), without a refresh | M4 (M1 for the alert list) |
| UI-2 | Two operators act on the same incident at the same time | Both actions are recorded; the second sees a conflict when its view was stale (optimistic version check) | M4 |
| UI-3 | (a) Transaction A allocates activity id 100 and commits after transaction B commits 101; (b) an unrelated transaction that writes no activity holds the watermark while B commits | (a) a feed reader never skips A's row; a snapshot-then-feed handover misses nothing; (b) the client receives B's row within one watermark poll after the blocker ends, without a new activity write | M1 |
| UI-4 | An open console shows an alert; the source repeats it every minute (duplicates) and a stale observation with a later observed time arrives; a slow freshness response from before the repeats returns last | The displayed last seen advances to the latest observed time without a reload, within one safety pull, and never moves backwards; no activity row and no version change is written for it | M4 |

## Rules and configuration

| Id | Scenario | Expected | First in |
|---|---|---|---|
| RUL-1 | Rule priority, tag and topology examples from the docs (legacy acceptance 9) | Executable examples: the simulator produces the documented decisions | M2 |
| RUL-2 | A rule references a field missing from the event | Visible in the simulator as "no match: field missing"; never a silent fallback | M2 |
| RUL-3 | A regex rule with catastrophic backtracking | Timed out; skipped and counted; the event continues | M2 |
| RUL-6 | The same rule corpus evaluated in memory and as SQL over stored events (missing fields, nulls, case, severity order, wildcards in values) | Identical results in both evaluators | M2 |
| RUL-7 | A rule that times out on every event: (a) its fallback is valid; (b) its fallback is a previous rule version that references an output removed from the current registry | Skipped and counted against the pinned version, with a self-alert; ingestion continues. (a) A new configuration version disabling or replacing the rule is validated and activated atomically on all workers. (b) The fallback is rejected by validation and does not activate. In both, existing raw-row pins are unchanged | M2 |
| RUL-8 | A generic mapping with neither an observation id nor a source time field | Activation fails with a validation error | M2 |
| RUL-4 | Activating a new rule set version | Atomic: every worker switches at a version boundary; rollback restores the previous version | M2 |
| RUL-5 | A provisioned (YAML) rule edited in the UI | Refused: provisioned rules are read-only in the UI | M4 |

## Security

| Id | Scenario | Expected | First in |
|---|---|---|---|
| SEC-1 | A webhook with another source's token | 401; counted per source | M1 |
| SEC-2 | Rule filter input containing SQL fragments (filter-to-SQL injection class) | Treated as a literal; rules compile to parameterized queries only | M2 |
| SEC-3 | A plugin config secret | Never returned by the API, never logged; encrypted at rest | M2 |
| SEC-4 | A viewer calls an operator action | 403 | M4 |
| SEC-5 | Ingest token in the URL path; request logged | Token redacted in every log | M1 |
| SEC-6 | Sign-in with an email that was not invited | Refused; first admin only through the one-time bootstrap token | M4 |

## Upgrade and recovery

| Id | Scenario | Expected | First in |
|---|---|---|---|
| UPG-1 | Upgrade with retained data (legacy acceptance 10) | Migrations run forward without loss on a populated database; background jobs start after migration | M10 |
| UPG-2 | Restore from backup | Restore drill documented and tested; no background mutation before verification | M10 |
| UPG-3 | Canonical event v1.x minor change | `buf breaking` passes; older consumers still parse | M1 |
