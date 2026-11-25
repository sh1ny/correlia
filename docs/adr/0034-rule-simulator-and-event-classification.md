# 0034. Rule simulator and event classification

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Supersedes: none (extends [0032](0032-matcher-rules-and-versions.md))
- Chosen by: user (simulator input and API, stored-event lookup, kind ownership, the reserved noise label and its digest table); agent (the shared decode, the simulation engine, the duplicate order).

## Context

Matcher rules (ADR 0032) give an operator no way to see why a rule matched or did not before publishing it. A rule that reads a missing field silently does not match, a gap the legacy audit lists as P1.2. Correlation (M3) and noise control (M5) also need each event's kind and noise character settled before they build on them.

## Decision

### Read-only simulator over re-decoded stored events

The console API gets one read-only method, `RuleSimulatorEndpoint.simulate`. It takes either a pasted canonical event (CloudEvent JSON) or a stored event's key, plus an optional draft matcher section. The result uses typed Serverpod models (`RuleSimulationResult`, `RuleTrace`, `ConditionTrace`, `ActionTrace`, `SimulationError`). Rejected: one JSON string result, which the console could not type-check.

A stored event is named by `event_id` and `observed_at`, with an optional disposition. `observed_at` must be an RFC 3339 timestamp with an offset, checked as ADR 0021 checks canonical timestamps, and is projected to the stored UTC microsecond key before lookup. The simulator reads the row's raw key and pin in one read-only transaction, decodes the raw row again through the pipeline's own decode, and picks the member whose matcher-invariant fields (the event apart from labels, labels origin, links, severity, enrichment errors, processing time and observation generation) equal the stored payload's. When none or several differing members match, it returns `ambiguous_member`. Rejected: a lookup by event ID alone with a new index on `events(event_id)`, which adds write cost to the busiest table; a lookup by event ID alone with a bounded partition scan, which cannot find old events; stripping matcher effects from the stored payload, because a mapped severity cannot be undone.

The simulator runs the pipeline's own `applyMatcherRule` rule by rule over the one event, with fresh regex and time budgets and the whole 16 MiB fanout limit, and records each condition and action. Condition evaluation keeps the pipeline's short-circuit flow; skipped children show `not evaluated` and run no regex work. Routes are those added beyond the source routes of the active snapshot, marked hypothetical because delivery eligibility is not applied. A simulation writes nothing: no failure counts, activity notices, deliveries, pins, events or session logs. Rejected: running `MatcherBatch.enrich` inside a rolled-back transaction, which would take pipeline locks and could send notices before the rollback; an evaluator that visits every leaf, which would run regex work the pipeline skips and could drift from it.

Every decode of a raw row, in the pipeline and in the simulator, goes through one shared decode: `readDecodeInputs` reads the pin's source settings and, for an Icinga2 Event Streams row, its admission metadata; `decodeRow` is pure. Rejected: decoding from the processing pin alone in the simulator, which cannot rebuild stream events.

A command line, `correlia_server/tool/simulate.dart`, calls the endpoint through the generated client and prints the trace readably or as JSON.

### Decoder-owned event kind

Each source's decoder alone sets canonical `kind`, following a kind table that the event-classification spec states and tests for each source. Rules cannot change it; a label named `kind` is an ordinary label. Rejected: rules that reclassify kind on the retained event, which would give an event two kinds for M3 correlation to reconcile.

### Reserved noise label, checked against new content only

A new matcher action, `classify`, writes one value from the closed set `heartbeat`, `informational`, `test`, `flapping` and `maintenance` to the reserved label `correlia.noise_class` with origin `matcher`. The event contract does not change. Publication and startup reject a `set_label` or `extract` write to that key only when the candidate matcher content differs from the matcher content of every stored snapshot. An exact restart, a rollback to earlier content and pinned snapshots keep working as ADR 0032 requires. A simulator draft always counts as new content. Rejected: a typed field in `correlia.event.v1` 1.1, which changes what NATS consumers see on weak evidence of what M5 needs; accepting such writes and giving `classify` its own label origin, which adds an origin value; rejecting restarts and rollbacks too, which breaks ADR 0032.

### Matcher content digest tables

Schema step `0015` creates two SQL-owned tables outside Serverpod's managed models and repairs:

- `matcher_content_digest(digest bytea PRIMARY KEY, first_snapshot_id text)`: the `sha256Digest` of each published matcher section, the digest the publication guard already computes. Publication inserts it in the snapshot's transaction, so the new-content check is one primary-key probe however long the history grows.
- `matcher_content_digest_fill`: a one-row table holding the completion marker of the upgrade fill.

On upgrade the new binary fills the digests of existing snapshots once, in Dart, so PostgreSQL never parses snapshot JSON and a plugin configuration holding U+0000 cannot block it. The fill is one transaction under the publication advisory lock, taken with a 60 s timeout; it reads snapshots in keyset pages of 100 by table ID, inserts with `ON CONFLICT DO NOTHING`, and writes the completion row last. Startup runs it right after the schema steps and before the configuration file is parsed; a starter that times out exits non-zero with failure class `lock_timeout`. Rejected: scanning every snapshot under the publication lock, which grows with history forever; a `jsonb` index, which can fail on old snapshots holding NUL escapes.

### One deterministic retained member per event ID

The pipeline orders prepared events by event ID and then by input position, a stable order, and keeps each stream item's own receipt-time gates before the same-ID check. Among same-ID items in one raw batch, the first remaining in input order is kept. Rejected: keeping the unstable sort and storing the retained input position in the event row, a schema change for a choice a stable order already makes deterministic.

## Consequences

Upgrade stays offline (ADR 0033). After a publication that uses `classify`, a previous binary cannot read the active snapshot, so going back to it is not supported. Repairs must not drop or alter `matcher_content_digest` or `matcher_content_digest_fill`.

Rows stored before this change keep whichever member the unstable sort kept; the simulator finds it from stored fields when they tell the members apart. Members that differ only in fields the projection leaves out, such as an identity-excluded label, stay `ambiguous_member` even after this change.

Simulated results equal the pipeline's only for equal inputs and when neither run reaches a budget, cutoff or fanout bound. For a stored event the result also shows the stored labels and enrichment errors and names both snapshots.

Console UI for the simulator (M4), simulators for other rule kinds and query enrichment are outside this decision.
