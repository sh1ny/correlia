# Spec Delta

## Purpose

Fixes which kind each source's events carry, and gives rules a closed set of noise class hints that
later correlation and noise control can read, without changing the event contract.

## ADDED Requirements

### Requirement: Decoder-owned event kind

Each event's canonical `kind` SHALL be set only by its source's decoder, per the kind table in the scenarios. No source produces `heartbeat` today. Matcher rules SHALL NOT change canonical `kind`; a label whose key is `kind` is an ordinary label and leaves canonical `kind` unchanged.

#### Scenario: Alertmanager-protocol and generic kinds
- **WHEN** golden Alertmanager fixtures, Thanos Ruler fixtures (sent to an Alertmanager-protocol source) and generic webhook fixtures are normalized
- **THEN** every event has kind `alert`

#### Scenario: Icinga2 webhook kinds
- **WHEN** golden Icinga2 webhook fixtures are normalized
- **THEN** hard problems and recoveries are `alert`, soft problems and flapping changes are `state`, acknowledgements are `ack`, downtimes are `downtime` and comments are `comment`

#### Scenario: Icinga2 Event Streams kinds under each state policy
- **WHEN** golden Event Streams fixtures are normalized under `hard_only` and under `soft_and_hard`
- **THEN** state changes are `alert`, except that a SOFT state other than `OK` or `UP` under `hard_only` produces no event; acknowledgements are `ack`, downtimes `downtime` and flapping changes `state`; and an Event Streams comment type is rejected as `unsupported_type`

#### Scenario: A label named kind does not change kind
- **WHEN** a rule sets the label `kind` to `heartbeat` on an Alertmanager event
- **THEN** the event carries that label and its canonical kind stays `alert`

### Requirement: Noise class hints

A `classify` action SHALL set the reserved label `correlia.noise_class` with origin `matcher` to one of `heartbeat`, `informational`, `test`, `flapping` or `maintenance`. Publication and startup SHALL reject any other matcher write to that key in new matcher content, equal to no stored snapshot's; stored content and pinned snapshots MAY still write it. A hint SHALL change neither kind, identity, alert state nor delivery eligibility.

#### Scenario: Classify a watchdog alert
- **WHEN** a rule matching `labels.alertname` equal to `Watchdog` has `classify: heartbeat`
- **THEN** the enriched event carries `correlia.noise_class` = `heartbeat` with origin `matcher`, its kind stays `alert`, and its fingerprint and live alert state are unchanged

#### Scenario: Later classify wins
- **WHEN** two matching rules classify the same event as `test` and then `informational`
- **THEN** the event carries `informational`

#### Scenario: Value outside the vocabulary
- **WHEN** a `classify` action uses a value outside the closed set
- **THEN** activation fails with a field error listing the allowed values and the active snapshot is unchanged

#### Scenario: Other actions cannot write the reserved key
- **WHEN** a `set_label` or `extract` action in new matcher content, equal to no stored snapshot's, targets `correlia.noise_class`
- **THEN** activation fails with a field error naming the reserved key and the active snapshot is unchanged

#### Scenario: A snapshot pinned before the change keeps running
- **WHEN** a raw row pinned to a snapshot published before this change has a `set_label` write to `correlia.noise_class`
- **THEN** the worker applies that snapshot unchanged, and a simulation of the stored event lists the label among the stored labels, never as a hint from a simulated action

#### Scenario: Source label with the reserved key
- **WHEN** a source event already carries a `correlia.noise_class` label, no rule classifies it, and no matcher action (such as a grandfathered `set_label` or `extract`) overwrites that key
- **THEN** the label keeps origin `source`, the simulator reports no hint, and identity is unchanged
