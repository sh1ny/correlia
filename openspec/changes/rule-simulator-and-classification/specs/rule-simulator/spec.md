# Spec Delta

## Purpose

Lets an operator see, for one event, every decision the matcher would make and why, against the active
rules or a draft, without changing any state.

## ADDED Requirements

### Requirement: Simulate one event against active or draft rules

The system SHALL offer a read-only simulation on the local console API. Its input is exactly one of: a canonical event as CloudEvent JSON, or a stored event's ID and `observed_at`, with an optional disposition. An optional draft matcher section is also accepted. Without a draft it SHALL use the active snapshot's matcher section. A draft SHALL use only the active outputs and secrets, and SHALL always count as new matcher content.

#### Scenario: Simulate a pasted event against the active rules
- **WHEN** an operator submits a valid CloudEvent JSON event with no draft while a matcher snapshot is active
- **THEN** the result names the active snapshot ID and revision and contains one trace entry per active rule in document order

#### Scenario: Simulate a stored event against a draft
- **WHEN** an operator submits a stored event's ID and `observed_at`, whose kept member the stored fields identify, and a valid draft matcher section
- **THEN** the simulator decodes the event's raw row as the pipeline decoded it, including the admission metadata of a stream row, evaluates the member the pipeline kept, identified from stored fields, against the draft rules, and marks the rule source as `draft`

#### Scenario: Future-dated row and its later ready row
- **WHEN** a non-stream event was stored as `future_dated` and later stored again as `ready` at a later `observed_at`, and the operator simulates each key in turn
- **THEN** each simulation uses its own row's raw row, pin and disposition

#### Scenario: Several rows at one key
- **WHEN** more than one disposition is stored for the given ID and `observed_at` and no disposition is given
- **THEN** the simulator uses the non-`future_dated` row, and a given disposition selects that row

#### Scenario: Same-identity alerts in one raw batch
- **WHEN** a raw batch holds two alerts with the same fingerprint and observation key but different descriptions, and a rule matches only one description
- **THEN** the simulator selects the member whose fields the matcher does not change equal the stored event's, and its decision matches the stored event

#### Scenario: Stored duplicate from before this change
- **WHEN** a raw row stored before this change held two members with one event ID and the pipeline kept the second
- **THEN** the simulator selects the second member, because its description equals the stored event's

#### Scenario: Unknown stored event
- **WHEN** no stored event has the given ID, `observed_at` and disposition
- **THEN** the simulation fails with `event_not_found` and returns no trace

#### Scenario: Raw row no longer retained
- **WHEN** the stored event's raw row has been removed by retention
- **THEN** the simulation fails with `raw_unavailable` and returns no trace

#### Scenario: Both or neither input given
- **WHEN** a request carries both a pasted event and a stored event key, or neither
- **THEN** the simulation fails with `invalid_input` and evaluates nothing

#### Scenario: Partial or orphaned key fields
- **WHEN** a request carries a pasted event with a `disposition` or one stored-key field, only one of the event ID and `observed_at`, or a `disposition` alone
- **THEN** the simulation fails with `invalid_input` naming the field, before any lookup

#### Scenario: Invalid pasted event
- **WHEN** the pasted JSON is not a valid canonical CloudEvent
- **THEN** the simulation fails with the event validation field path and error code and returns no trace

#### Scenario: Oversized pasted event
- **WHEN** the pasted JSON exceeds the event wire bound
- **THEN** the simulation fails with `too_large` on the field `eventJson` and returns no trace

#### Scenario: Invalid draft
- **WHEN** the draft matcher section uses an unknown field, an unsupported language or version, an unknown output or a reserved label write in new content
- **THEN** the simulation fails with the field errors that publication reports for new content, and returns no trace

#### Scenario: A draft equal to earlier content is still new
- **WHEN** a draft's matcher text equals an earlier stored snapshot's that writes `correlia.noise_class` with `set_label`
- **THEN** the simulation rejects the draft with the reserved-key field error, although a guarded publication of the same text succeeds as a restore

#### Scenario: No active matcher configuration
- **WHEN** no snapshot is active, or the active snapshot has no matcher section, and no draft is supplied
- **THEN** the result has an empty trace, states that no rules are active, returns the input event's kind, labels, label origins, links and severity, and adds no routes

#### Scenario: Refused outside the local console policy
- **WHEN** the request does not satisfy the console access policy the mapping preview uses
- **THEN** the simulation is refused with the console access error and evaluates nothing

### Requirement: Stored event keys and members

A stored-key `observed_at` SHALL be a valid RFC 3339 timestamp with an offset, projected to the stored UTC microsecond key before lookup. The simulation SHALL select the member the pipeline kept only when the stored fields identify it, and SHALL otherwise fail with `ambiguous_member`.

#### Scenario: Invalid stored key
- **WHEN** a request carries a complete stored key with a malformed event ID or an unknown disposition
- **THEN** the simulation fails with `invalid_input` naming the field, before any database lookup

#### Scenario: Malformed observed_at
- **WHEN** a stored key's `observed_at` has an invalid calendar date, or has no offset
- **THEN** the simulation fails with `invalid_input` naming `observedAt`, before any database lookup

#### Scenario: Kept member cannot be identified
- **WHEN** no decoded member's matcher-invariant fields equal the stored event's, or several differing members do
- **THEN** the simulation fails with `ambiguous_member` and returns no trace

#### Scenario: Members differ only in an excluded label
- **WHEN** a raw batch processed after this change held two alerts with one event ID that differ only in an identity-excluded label, and one of them is simulated by key
- **THEN** the simulation fails with `ambiguous_member`, because the stored fields do not tell them apart

### Requirement: Explain every rule and condition decision

Each trace entry SHALL give the rule ID, a rule outcome (`matched`, `not matched`, `failed: <code>` or `not attempted`) and, unless not attempted, its condition tree. An evaluated leaf SHALL carry `matched`, `no match: value fails <op>` naming its operator, `no match: field missing` or `failed: <code>`; a leaf skipped by short-circuiting SHALL show `not evaluated`. A missing field SHALL make only its leaf false, never fall back to another rule or a default value.

#### Scenario: RUL-2 missing field is visible
- **WHEN** a rule's condition is the single leaf `labels.site` equals `eu1` and the event has no `site` label
- **THEN** the trace shows that leaf as `no match: field missing`, the rule as not matched, no actions applied, and later rules evaluated as usual

#### Scenario: A false leaf names its operator
- **WHEN** one rule's condition is `summary` not_equals the event's summary and another's is `summary` equals a different text
- **THEN** the first leaf shows `no match: value fails not_equals` and the second `no match: value fails equals`

#### Scenario: Missing field under not
- **WHEN** a rule's condition is `not` of a leaf that reads a missing field
- **THEN** the leaf shows `no match: field missing` and the rule matches, because `not` inverts the false leaf

#### Scenario: Explicit null in a pasted event
- **WHEN** a pasted event carries an explicit JSON null in a catalog text field
- **THEN** the simulation fails with the event validation error for that field, as canonical event parsing rejects it, and returns no trace

#### Scenario: Short-circuited leaves are not evaluated
- **WHEN** an `any` condition's first leaf matches and its second leaf is a regex that would exhaust its budget if run
- **THEN** the rule matches, the second leaf shows `not evaluated`, and no regex work or failure is recorded

#### Scenario: Regex leaf times out
- **WHEN** an evaluated regex leaf exhausts its regex budget during simulation, and a later rule has a regex condition and another later rule has none
- **THEN** the leaf and rule show `failed: regex_timeout` and its patch is not applied, the later regex rule shows `failed: regex_budget`, and the rule without a regex is evaluated as usual

#### Scenario: Simulation reaches the optional cutoff
- **WHEN** the simulation's optional time budget runs out during a rule
- **THEN** that rule shows `failed: matcher_cutoff` with no patch applied, and every later rule shows `not attempted`

### Requirement: Simulation results match the pipeline

The simulation SHALL use the pipeline's rule evaluation and patch code. The result SHALL show each action's effect, the final event (kind, noise hint, labels with origins, links, severity; not a whole CloudEvent) and the routes added beyond the source routes, marked hypothetical: delivery eligibility is not applied. A simulation has fresh budgets. A stored event's result SHALL also show its recorded errors. Equal results are promised only for equal inputs and no budget reached in either run.

#### Scenario: RUL-1 documented examples produce the documented decisions
- **WHEN** each priority, label and topology example in `docs/ingest-pipeline.md` is simulated with its documented event and rules
- **THEN** each trace and final event equal the decisions and result documented beside that example

#### Scenario: Later rule wins a shared key
- **WHEN** two matching rules set the same label to different values
- **THEN** the trace shows both patches applied in order, and the final event carries the later rule's value

#### Scenario: A partly overwritten location action
- **WHEN** a rule's `location` action stages `site=eu1` and `environment=prod` and a later action of the same rule sets `site` to `eu2`
- **THEN** the location action is staged and applied, its detail reads `site=eu1 (overwritten later in its rule), environment=prod`, and the final event carries `site=eu2` and `environment=prod`

#### Scenario: A failing action discards only its rule's patch
- **WHEN** one rule's condition matches, it stages a label and then fails an action, and a later rule succeeds
- **THEN** the trace shows the first rule's condition as matched and its rule outcome as `failed` with its code and no applied effects, and the final event carries only the later rule's effects

#### Scenario: Pipeline and simulator agree for a deliverable event
- **WHEN** a ready, deliverable webhook event, alone in its raw row, is processed by the pipeline and simulated against the same snapshot and evaluation time, with a regex condition on one rule, and neither run reaches a budget, cutoff or fanout bound
- **THEN** the stored enriched event and the simulated final event have equal labels, labels origin, links and severity, and the simulated routes added beyond the source routes equal the routes the pipeline added

#### Scenario: The pipeline's cutoff left rules unattempted
- **WHEN** a stored event's later rules were left unattempted at the pipeline's cutoff, with no diagnostic stored, and the event is simulated
- **THEN** the simulation evaluates every rule within its own budgets, and the result states that the pipeline's row-shared budgets may have stopped rules without a recorded error

#### Scenario: Stored event processed under other rules
- **WHEN** a stored event was processed under a snapshot whose matcher wrote `correlia.noise_class` with `set_label`, and the active rules differ
- **THEN** the result names the stored event's snapshot and the simulated one, lists the stored labels separately, and reports a hint only from a simulated `classify` action

#### Scenario: The pipeline's regex budget ran out
- **WHEN** earlier events in a raw row exhausted the row's regex budget, so a later event's regex rule failed in the pipeline with `regex_budget`, and that later event is simulated
- **THEN** the simulation applies the rule within its own fresh budget, and the result shows the stored event's recorded `regex_budget` error for that rule beside the successful simulated decision

#### Scenario: The pipeline's regex call overran its budget
- **WHEN** a stored event's regex call started with budget left and overran it, so the rule failed in the pipeline with `regex_timeout`, and the event is simulated
- **THEN** the result shows the stored `regex_timeout` error for that rule beside the simulated decision

#### Scenario: Routes for an ineligible event are hypothetical
- **WHEN** a stale Icinga stream event matching an additive route is simulated
- **THEN** the trace lists the route as hypothetical and states that delivery eligibility is not evaluated

### Requirement: Simulated fanout bound

The fanout bound of a simulation SHALL be the whole 16 MiB limit for the one event, its baseline routes included. When the baseline alone exceeds it, every rule SHALL be `not attempted` and the result SHALL say so.

#### Scenario: Simulated effect beyond the fanout bound
- **WHEN** a simulated rule's patch would take the event past the fanout limit
- **THEN** that rule shows `failed: batch_bound` and its patch is not applied

#### Scenario: Baseline already over the fanout bound
- **WHEN** a pasted event's baseline routes alone exceed the fanout limit
- **THEN** every rule shows `not attempted` and the result states that the baseline exceeds the bound

### Requirement: Hints come only from simulated classify

The result SHALL report a noise class hint only when a simulated `classify` action set it. A `correlia.noise_class` label from the source, from a stored event or from another action SHALL be listed as a label, never as a hint.

#### Scenario: Stored label is not a hint
- **WHEN** a stored event carries `correlia.noise_class` with origin `matcher`, written by `set_label` under its pinned snapshot, and no active rule classifies it
- **THEN** the result lists the label among the stored labels and reports no hint

### Requirement: Route baseline comes from the active snapshot

The source routes a simulation adds to SHALL be those of the event's source in the active snapshot, for pasted and stored events and for drafts alike. When that source is absent, the baseline SHALL be empty and the result SHALL say so.

#### Scenario: A route moved from source configuration to a rule
- **WHEN** a stored event's source listed a route when it was processed, the active snapshot's source no longer lists it, and an active rule adds it
- **THEN** the result shows the route as added by that rule

#### Scenario: Source absent from the active snapshot
- **WHEN** a stored event's source is not in the active snapshot
- **THEN** the route baseline is empty, the result states that the source is absent, and every route a rule adds is shown as added

### Requirement: Simulation has no side effects

A simulation SHALL NOT write events, raw rows, pins, deliveries, rule failure counts, activity notices or session logs, and SHALL NOT change any snapshot.

#### Scenario: Failing rule in simulation is not counted
- **WHEN** a simulated rule fails with a timeout
- **THEN** the matcher failure counts and the activity feed are unchanged after the simulation

#### Scenario: The endpoint writes no session log
- **WHEN** a simulation is called through the real RPC endpoint in a configuration that persists session logs
- **THEN** no session log row is written for the call

#### Scenario: Simulation leaves stored state unchanged
- **WHEN** an operator simulates a stored event with a draft that adds a route and a label
- **THEN** the stored event, its deliveries, the outbox and the active snapshot are unchanged afterwards
