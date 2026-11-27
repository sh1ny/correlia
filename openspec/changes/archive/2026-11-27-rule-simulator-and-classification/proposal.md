# Proposal

## Why

Change 6 of milestone M2 (Icinga2, Thanos and the ingest track). Matcher rules shipped in change 5, but
an operator cannot see why a rule matched or did not before publishing it. A rule that reads a missing
field quietly does nothing. That gap was a legacy complaint: legacy-audit P1.2 asks for missing-field
and no-fallback behaviour to be visible in a simulator. An event's kind and noise character also need
to be settled before M3 correlation and M5 noise control build on them.

The roadmap's change 6 also held the Prometheus/Thanos query enricher. After five design-review rounds,
nearly every open finding was in query enrichment (the leased processing phase, outbound credentials,
DNS and connection cancellation, publisher-version fencing). The owner split it into its own M2 change,
`query-enrichment`, on 2026-11-25 (S9). After ten rounds the owner also moved the simulated
end-to-end demo to its own M2 change, `enrichment-demo` (S7): its process lifecycle kept raising
blocking findings while the simulator and classification converged. This change keeps the simulator,
its command line, classification and the deterministic duplicate order.

This change advances two M2 exit criteria:
- **Scenarios pass as named tests (agent):** RUL-1 (the documented priority, tag and topology examples
  produce the documented decisions in the simulator) and RUL-2 (a rule that reads a missing field shows
  "no match: field missing", never a silent fallback).
- **The owner checks enriched events from a day of real traffic (user):** the simulator is how the
  owner checks why an event was or was not enriched. That criterion is judged at the milestone close,
  because only the whole ingest track can be run for a day. Before that, the owner runs the fully
  simulated end-to-end demo of the milestone's last change, `enrichment-demo` (S7). Here the owner can trace a
  stored event with the simulator command line (S8) when its raw row still re-decodes and the stored fields
  identify the member the pipeline kept; otherwise the simulator returns `raw_unavailable` or
  `ambiguous_member`.

## What Changes

- **Rule simulator API.** A read-only local console endpoint. It takes a canonical event (CloudEvent
  JSON) or a stored event's ID and `observed_at`, and runs it through the active matcher snapshot or a
  pasted draft matcher section. It returns a trace: each rule in document order, each condition's result
  with a reason (`matched`, `no match: value fails <op>`, `no match: field missing`, `failed: <code>`,
  `not evaluated`), each action's effect or failure, and the final event: its kind, noise class
  hint, labels with their origins, links and severity (a projection of the enriched event, not a
  whole CloudEvent), with its added routes. It writes nothing: no failure counts, no activity
  notices, no deliveries, no pins.
- **Event classification.**
  - Kind stays owned by the decoders. This change specifies each source's kind table (Alertmanager,
    Thanos, Icinga2 webhook and Event Streams, generic webhook) and tests it.
  - A new matcher action, `classify`, sets a noise class hint from a closed vocabulary in one reserved
    label with origin `matcher`. The event contract does not change.
  - Rules still cannot change canonical kind, identity or alert state. Publication rejects any other
    matcher write to the reserved label in new matcher content; an exact restart, a rollback to
    earlier content and pinned snapshots keep working.
- **Deterministic duplicates.** Among alerts with one event ID in one raw batch, the pipeline keeps the
  earliest remaining in input order at the existing same-ID check, after each stream item's own
  time checks (today the choice is unspecified). The simulator selects the member the pipeline kept
  when its stored fields identify it, and otherwise reports `ambiguous_member`.
- **Docs.** `docs/ingest-pipeline.md` gains executable examples for rule priority, labels and topology,
  plus sections on the simulator and classification. The RUL-1 test runs the documented examples.
- **Simulator command line.** `tool/simulate.dart` prints a trace for a pasted or stored event.
- **Roadmap.** M2 gains change 7, `query-enrichment`, and change 9, `enrichment-demo`, each with the
  decisions already taken and the open review findings handed over (design, "Handed to
  enrichment-demo" and "Handed to query-enrichment"); `dead-letters-backpressure-and-retention`
  becomes change 8. The demo comes last so that it tests all of M2.

## Capabilities

### New Capabilities

- `rule-simulator`: a read-only explanation of the matcher's decisions for one event: the trace of each
  rule and condition, missing-field reasons, the result, and the guarantee that a simulation has no side
  effects.
- `event-classification`: the decoder-owned kind table for each source, and the noise class hint
  vocabulary with its reserved label.

### Modified Capabilities

- `workspace-tooling`: the simulator command line.
- `matcher-rules`: the action set gains `classify`, validation covers the reserved label, and condition
  evaluation keeps short-circuiting with an explaining variant.
- `durable-pipeline`: the decode requirement names the dead-letters change instead of "change 7",
  since change 7 is now `query-enrichment`.

## Impact

- Code: `correlia_server/lib/src/matcher/` (an explaining condition evaluator, the `classify` action,
  the reserved-label check), `lib/src/pipeline/` (a shared row decode and a deterministic duplicate
  order), and a new simulator endpoint under `lib/src/endpoints/`.
- API: a new console endpoint and its Serverpod models, regenerated in `correlia_client`.
- Configuration: the ingest file gains one matcher action. Existing files stay valid. New matcher
  content that writes the reserved `correlia.noise_class` label with `set_label` or `extract` is
  rejected; an exact restart or a rollback to earlier content still works.
- Database: schema step `0015` adds two SQL-owned tables: `matcher_content_digest`, the digests of
  published matcher content, and `matcher_content_digest_fill`, the fill's one row. Step `0016` adds
  `filled_through` to that row, the last snapshot table ID the fill read. Step `0017` adds a foreign key
  from each digest to the snapshot it names, so a digest never outlives that snapshot. Publication records each new
  digest; the first start fills the digests of every stored snapshot, and each later start and publication
  fills those after the watermark, such as a snapshot the previous binary published during an offline
  downgrade. Upgrade is offline (ADR 0033); a previous binary cannot read a snapshot whose matcher uses
  `classify`.
- Event contract: unchanged (`correlia.event.v1` 1.0).
- Tests: fast tests for the trace and classification; `db` tests for the simulator over stored events
  and the reserved-label lookup.
- Tooling: a simulator command line under `correlia_server/tool/`.
- Docs: `docs/ingest-pipeline.md` and `openspec/roadmap.md`.

## Decision Making

DECISION_MAKING: important
- **Source:** setting

### S1: Simulator input

- **Choice:** a canonical event (CloudEvent JSON) or a stored event, against the active snapshot or a
  pasted draft matcher section; a read-only local console endpoint. A stored event is named by its ID
  and `observed_at`, which the owner chose after review round 1 (design D9).
- **Rejected:** decoding raw source payloads first (adds decoder paths to the simulator; the mapping
  preview already covers generic samples); a search over stored events for each rule (more scope, and it
  pays off with the M4 console).
- **Reversal cost:** low (adding input kinds later is additive).
- **Important:** yes, it changes an API that users see.
- **Chosen by:** user

### S3: Noise class hint location

- **Choice:** a `classify` matcher action that writes a closed-vocabulary value into one reserved label
  with origin `matcher`; no event contract change.
- **Rejected:** a typed optional field in `correlia.event.v1` 1.1 (changes the schema NATS consumers see,
  chosen on weak evidence of what M5 needs); deferring hints to M5.
- **Reversal cost:** low (a label can later move into a typed field).
- **Important:** yes, it binds a label key and value set that later changes read.
- **Chosen by:** user

### S4: Event kind ownership

- **Choice:** decoders own kind; this change specifies and tests each source's kind table, and the
  simulator shows it. Rules cannot change kind.
- **Rejected:** rules reclassifying kind on the retained event (two kinds per event would confuse M3
  correlation).
- **Reversal cost:** low (an override can be added later).
- **Important:** yes, it binds M3 and M5.
- **Chosen by:** user

### S5: Simulation has no side effects

- **Choice:** a simulation writes no failure counts, activity notices, deliveries, pins or events.
- **Rejected:** a simulation inside a rolled-back transaction (it would take pipeline locks).
- **Reversal cost:** low.
- **Important:** no, it follows from the read-only preview pattern already used for mappings.
- **Chosen by:** agent

### S6: Out of scope

- **Choice:** console UI for the simulator (M4), simulators for other rule kinds (M3 correlation, M5
  silences), query enrichment (S9), and changing the kind of an event.
- **Rejected:** none (scope boundary).
- **Reversal cost:** low.
- **Important:** no, each item follows from the roadmap's milestone split.
- **Chosen by:** agent

### S7: Fully simulated end-to-end demo moves to its own change

- **Choice:** the reusable `mise run demo:enrichment` task the owner asked for (a fully simulated test
  with expected results) becomes `enrichment-demo`, the last M2 change (change 9), so that it tests
  all of M2's functionality, query enrichment and dead letters included. Its settled decisions and the
  open findings of review round 10 are in design.md ("Handed to enrichment-demo").
- **Rejected:** fixing round 10's demo findings here and running round 11 (rounds 6 to 10 each found
  new process-lifecycle edges in the demo); a demo without cleanup or parent-death handling.
- **Reversal cost:** low (planning only).
- **Important:** yes, it changes the roadmap and what the owner can run after this change.
- **Chosen by:** user (asked for the demo on 2026-11-25; moved it after review round 10, 2026-11-25;
  moved it to the end of M2 during apply, 2026-11-25)

### S8: Where results are observed

- **Choice:** the console for live alert state (original severity, by design), the NATS subscriber
  for enriched events, and a simulator CLI for traces. No console change in this change. This change
  ships the simulator CLI; the demo change prints the console URL and the NATS replay command.
- **Rejected:** a console event-detail panel showing labels and traces (pulls M4 console work forward).
- **Reversal cost:** low.
- **Important:** yes, it changes what users see.
- **Chosen by:** user

### S9: Query enrichment moves to its own change

- **Choice:** the Prometheus/Thanos query enricher becomes its own M2 change, `query-enrichment` (now
  change 7, right after this change). Its settled decisions and the open findings listed in design.md ("Handed to
  query-enrichment") are handed over.
- **Rejected:** fixing round 5's findings here and running a sixth round (each round found new edges in
  the leased processing path); overriding the review.
- **Reversal cost:** low (planning only).
- **Important:** yes, it changes the roadmap.
- **Chosen by:** user (2026-11-25, after review round 5)
