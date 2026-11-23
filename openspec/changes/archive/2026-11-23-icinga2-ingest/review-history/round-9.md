# Review

## Metadata

- **Round:** 9
- **Prior round:** round 8 (omp) REVISE: 1 Critical (DOWNTIMECANCELLED wire token), 5 Moderate (notification-time gate; step-4 backfill bound; two clocks for windows; weak ordering asserts; pre-parse nesting bound).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, four spec deltas, and round 8; baseline ingress, pipeline, alert-state, and canonical-event specs; project rules, M2 roadmap, named acceptance scenarios, architecture, and ADRs 0016, 0017, 0020, 0021, 0024, 0028, and 0029; cited ingest, pipeline, state, identity, schema, runtime, alert-model, and protobuf sources; ingest startup and schema-step tests; archived Alertmanager D6 and capture script; upstream Icinga 2 notification and macro code and curl transport documentation. Read-only review; no tests or captures run.

## Findings

### Critical (blocking)

1. **The cutover leaves an old writer of source kinds running.** D6 (`design.md:195–210`) and the upgrade requirement stop old `worker` and `all` processes, but a configured `api` also publishes on startup (`ingest_startup.dart:42,70`). The old publisher accepts a higher revision and overwrites `kind` on conflict (`config_repository.dart:145,202–215`). An upgraded API can admit an Icinga2 row at revision N, then an old API can restart with revision N+1 declaring that UUID as `alertmanager`. The unpinned, acknowledged Icinga2 row then pins N+1 and goes to the Alertmanager decoder. D10's check in the new publisher cannot protect against the old publisher. Stop all old configured roles before activation and forbid their restart after activation, or fence old publishers at the database boundary. Verify the cutover includes API startup, not only worker replacement.
2. **A loopback URL does not guarantee a loopback connection.** D3 and the sender transport spec validate the configured URL, but do not constrain curl's inherited transport settings. Curl honors `http_proxy` and `ALL_PROXY`; with a remote proxy and no bypass, an allowed `http://127.0.0.1/...` request sends its bearer header or signed body to the proxy in plaintext. Curl also loads a default config file that can alter TLS verification and diagnostics without the script passing `--insecure`. Disable default curl config loading, require a direct connection for loopback HTTP, and do not follow redirects. Verify with an inherited proxy and curl config, not only a remote HTTP URL.

### Moderate

1. **Catalog-only DDL does not bound the wait for the exclusive lock.** D5 removes the rewrite, but `ALTER TABLE events` still needs an exclusive lock. A transaction holding a read lock on `events` can stall step 4 and every upgraded starter waiting behind its schema advisory lock. The step runner sets no SQL lock timeout (`schema_steps.dart:60–82`), and the `relfilenode` assertion proves only that no rewrite occurred. Specify a bounded lock wait and the operator's retry procedure. Prove that a held read lock causes a clean failure with no step-4 version recorded, and that startup succeeds after release.
2. **The release gate proves sub-second distinction, not microsecond preservation.** All three same-second scenarios pass if a release rounds to milliseconds: samples at `.100` and `.200` still differ after conversion to integer microseconds. That implementation can collapse distinct executions or state changes within one millisecond despite D2/D11's contract. Compare captured values against known microsecond-precision input or independently observed source values for each timestamp path. Also align “No release passes” (`integration-icinga2/spec.md:297–299`) with the three-gate rule: it currently names only host and service, omitting the case where both pass but every release fails `notification_time`.
3. **The late-reminder scenario omits a freshness effect that differs between processing orders.** With the prompt delivery processed first, the reminder is itself beyond the lateness horizon, but `pipeline.dart:407–418` checks only the original key's `ready` disposition and queues the duplicate for state processing. `alert_state_service.dart:171–190` then advances `last_observed_at` to the reminder's receipt time. The new scenario asserts only `duplicate_observation`, while the baseline alert-state spec excludes late evidence from freshness. State whether a late delivery duplicating a ready observation may refresh an alert, align the implementation and specs, and assert `last_observed_at` in the prompt-first case. Otherwise stale-source detection can treat the reminder as fresh without a documented rule.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Extend the cutover to old API configuration publishers and verify that no old process can overwrite an activated source kind.
2. Make sender transport and diagnostics independent of inherited curl configuration; prove loopback HTTP cannot send credentials through a remote proxy.
3. Bound step 4's lock wait and verify clean failure and restart under lock contention.
4. Verify actual microsecond preservation on every timestamp path and express the all-three-gates rule in the no-release scenario.
5. Resolve the freshness semantics for a late duplicate of a ready observation and assert the resulting `last_observed_at`.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 8 C1 — downtime cancellation:** Resolved in design. D3 uses `DOWNTIMECANCELLED`, matching upstream v2.13.0, and each supported release must prove cancellation through output routing without changing the alert fence.
- **Round 8 M1 — notification-time gate:** The whole-second loophole is closed. The remaining precision and negative-gate gaps are Moderate 2.
- **Round 8 M2 — populated upgrade:** The nullable, no-default column removes the rewrite and its disk cost. Lock acquisition and recovery remain open in Moderate 1.
- **Round 8 M3 — operational clocks:** Resolved. D5, the pipeline delta, and ORD-4 use observed time for expiry, windows, and reminders, and reserve effective time for queries and ordering evidence.
- **Round 8 M4 — ordering assertions:** Resolved. The refire must own the final fence, and a same-state observation must advance the fence without changing version or activity.
- **Round 8 M5 — pre-parse nesting bound:** Resolved. The delta requires the Alertmanager depth bound before parsing and asserts `depth_bound` at `body` without an internal retry.