# Tasks

## Test map

`E` = Declarative matcher enrichment; `F` = Stored and in-memory condition parity; `P` = Atomic matcher publication and restore; `R` = Isolated runtime rule failure. File paths below are relative to `correlia_server/test/`.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| E | Match and enrich a normalized event | unit/matcher/actions_test.dart | enrichment preserves identity | green |
| E | Enrichment cannot alter alert state or reconciliation | db/icinga2_stream_pipeline_test.dart | original severity drives state and sync | green |
| E | Rules do not chain or replace source routes | db/matcher_pipeline_test.dart | ordered patches and additive routes | green |
| E | Matcher routes follow source delivery eligibility | db/icinga2_stream_pipeline_test.dart | stale webhook routes but stale stream does not | green |
| E | Reject invalid operands before activation | db/matcher_publication_test.dart | invalid operands leave active unchanged | green |
| E | Matcher language and version survive publication | db/matcher_publication_test.dart | typed version survives and rejects unknown | green |
| E | Reject nonportable regex syntax | db/matcher_publication_test.dart | reject nonportable regex at publication | green |
| F | RUL-6 condition corpus agrees in both evaluators | db/matcher_filter_test.dart | RUL-6 condition corpus parity; missing and null are false before negation | green |
| F | Historical text with NUL stays distinct | db/matcher_filter_test.dart | historical NUL parity; scan cursor advances across ties and misses | green |
| F | A page with no matches still advances | db/matcher_filter_test.dart | scan cursor advances across ties and misses | green |
| F | SEC-2 SQL-shaped input is only data | db/matcher_filter_test.dart | scan cursor advances across ties and misses | green |
| F | Stored filter budget expiry is not a negative match | db/matcher_filter_test.dart | PostgreSQL cancels a scan when its statement budget expires | green |
| P | RUL-4 workers switch at a version boundary | db/matcher_publication_test.dart | RUL-4 pins activation and rollback | green |
| P | Concurrent publication invalidates a prepared restore | db/matcher_publication_test.dart | stale rollback cannot overwrite rotation | green |
| P | A successful rollback restarts from the exact same file | e2e/matcher_restart_test.dart | guarded YAML rollback restarts identically | green |
| P | DUR-5 unknown output blocks activation | db/matcher_publication_test.dart | DUR-5 unknown output and empty registry | green |
| P | A pending matcher pin retains its output material | db/matcher_publication_test.dart | matcher-only historical secret import | green |
| P | Pending and live routes share the existing output capacity | db/matcher_publication_test.dart | matcher-only historical secret import; stale rollback cannot overwrite rotation | green |
| P | NUL operands do not break existing snapshot readers | db/matcher_publication_test.dart | NUL operand leaves stream admission readable | green |
| R | RUL-3 regex computation exhausts its budget | db/matcher_pipeline_test.dart | RUL-7 one notice no publication | green |
| R | Regex worker exits before readiness or exhausts its regex budget | unit/matcher/regex_worker_test.dart | pre-ready exit and row regex exhaustion | green |
| R | Optional matcher work leaves time to commit the skip | db/matcher_pipeline_test.dart; unit/matcher/actions_test.dart | shared cutoff reserves commit time; non-regex rule crossing shared cutoff discards whole patch | green |
| R | Late action failure discards all staged changes | unit/matcher/actions_test.dart | late action cannot leak patch | green |
| R | Matcher additions exceed the raw batch fanout budget | unit/matcher/actions_test.dart | fanout skips only over-budget patch | green |
| R | A losing quarantine insert does not reserve matcher capacity | db/matcher_pipeline_test.dart | ordered patches and additive routes | green |
| R | A diagnostic does not overflow the event wire bound | unit/matcher/actions_test.dart | near-cap event still commits and counts | green |
| R | RUL-7 repeated timeouts do not publish configuration | db/matcher_pipeline_test.dart | RUL-7 one notice no publication | green |
| R | RUL-7 operator publishes a correction | db/matcher_pipeline_test.dart | RUL-7 one notice no publication | green |

## 1. Decisions and parity proof

- [x] 1.1 Write the superseding rule ADR, update the architecture index and D29, and align the RUL-7 acceptance row with operator-only recovery. Verify against the proposal and `mise run spec:validate`; confirm C1–C12 each appears at its matcher-spec destination, supplementing as needed without changing approved behavior.
- [x] 1.2 Write DB-first RUL-6 and historical-text cases; settle A1 by exercising real PostgreSQL and the Dart semantics on the same cases, including NUL/U+0001, literal escapes, punctuation, Unicode, newlines, repeat limits and null/negation. Prove the D13 complexity boundary, including simple `{255}` and rejection of an over-budget nested repeat in the shared parser. Stop for design drift if the approved representation cannot pass.
- [x] 1.3 Write the remaining F tests first, including deterministic cancellation and keyset ties; implement the typed conditions, field catalog, portable grammar and bounded parameterized stored filter. Verify all F tests and update their rows.

## 2. Rules and publication

- [x] 2.1 Write E validation and P tests first. Use controlled transaction barriers for publication ordering and first-pin races.
- [x] 2.2 Implement bounded JSON/YAML input, typed matcher persistence and registry validation, normal guarded publication and identical restart; vet and scan the existing locked YAML package before making it direct. Verify invalid input, old snapshot identity, literal round trip, activation, rollback and exact-file restart cases.
- [x] 2.3 Implement one inventory read for pending and live outputs, historical matcher secret inventory, and the active-row first-pin lock. Verify both pin race orders, pending-to-intent conversion, and untouched pins. Document provisioning, stale-output errors, rollback, and the offline upgrade procedure.

## 3. Enrich retained work and expose failures

- [x] 3.1 Write remaining E and R tests first. Use deterministic readiness/exit barriers and injected clocks for the regex and non-regex cutoffs, controlled database ordering for duplicate quarantine and concurrent fault aggregation, and exact payload/route assertions rather than elapsed-time assertions.
- [x] 3.2 Implement staged actions and cancellable regex with bounded lifecycle. Integrate after original alert-state/reconciliation decisions; reserve exact retained baseline, count only winning quarantine inserts, preserve source routing eligibility, and reject whole over-budget patches. Verify the action, routing and budget tests, preserving stored/delivered bytes and unchanged state.
- [x] 3.3 Implement bounded per-event diagnostics, transactional failure aggregation and one existing-feed notice per snapshot/rule. Verify rollback cannot consume the first notice, later failures count, no synthetic event/intent appears, and operator correction alone changes active state. Document diagnostics/cutoff and complete the remaining scenario rows.

## 4. Integration gate

- [x] 4.1 Verify focused fast, DB and e2e scenarios against the integrated change; keep generous real-time hang guards only. Run the gaming check before heavy local work; if instructed to use CI, require Linux verification to cover `mise run check` and `mise run test:all` on the exact PR head. Validate specs and review dispositions before the pre-ship gate.
- [x] 4.2 Apply D17: remove the live-upgrade preflight, matcher-specific mixed-version fences, and their fixtures. Verify extraction reads the original label after an earlier patch and reconciliation delivers the same bytes as the stored event.

