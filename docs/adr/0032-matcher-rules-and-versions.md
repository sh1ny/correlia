# 0032. Matcher rules and configuration versions

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Supersedes: [0008](0008-rule-language.md)
- Chosen by: user (matcher semantics, provisioning, publication and rollout).

## Context

Operators need to enrich events and add output routes without writing code. They also need to publish rules without changing what workers do with raw rows already pinned to a snapshot. The same condition must mean the same thing on a normalized event in Dart and on equivalent stored values in PostgreSQL.

## Decision

### Conditions and enrichment

Parse rules into one typed condition tree. Conditions use `equals`, `not_equals`, `regex`, `in`, `cidr`, `exists` and `glob`, composed with `all`, `any` and `not`. The field catalog owns field paths, types and allowed operators. Text comparisons are case-sensitive. Missing and null values never satisfy a leaf comparison; `exists` checks presence. Severity comparisons use critical > error > warning > unknown > info. This decision applies to matcher comparisons, not to event wire values, alert state or incident severity.

Compile stored filters from the field catalog and bind every rule key and operand. Filter stored values, which may already include enrichment. Use the same condition corpus for Dart and PostgreSQL. Regex uses a restricted portable syntax with no backreferences, lookaround or inline flags. Run Dart regex work in a killable isolate and bound PostgreSQL reads with a transaction-local statement deadline.

Every rule reads the original normalized event, even if a previous rule changed the same field. A successful rule contributes a whole patch to the retained event. Later writes win per key, links append and output routes form a deduplicated union with the source routes. A rule cannot alter identity, alert-state transitions, reconciliation or delivery eligibility.

Reject invalid rules before activation. At runtime, skip a rule whose patch fails or does not fit the existing batch bound. Count committed failures by snapshot and rule and emit one activity-feed notice for the pair. Runtime failures never publish or disable rules. Only an operator can publish a correction.

### Publication and rollback

The file named by `CORRELIA_INGEST_CONFIG` accepts JSON or YAML. It may include `language: matcher` and `version: 1` in its matcher section. Secret imports stay separate. Validate output references against the candidate registry, including an empty registry.

Publish rules, source mappings and output configuration together in one immutable snapshot. The publisher checks `expected_active_snapshot` under the existing publication lock when matcher content changes, including removal. A rollback is a normal higher-revision publish of earlier matcher content with the current source, credential and output configuration. The exact file can restart against its already-active snapshot. Existing raw pins stay unchanged across all publishes.

The existing 64-output limit counts the candidate output registry, reachable routes from pending pins and live intents. First pins share the active-row lock with the publisher. Stop older workers and their supervisors before cutover. The schema step checks this limit before installing either fence. If it refuses, drain the existing work with the older binary before retrying the upgrade.

## Consequences

Stored events and deliveries can show an enriched severity that differs from the live alert severity. The latter follows original source evidence. A corrected rule affects new pins only; existing retries continue to use the version they pinned.

The format keeps a language discriminator. CEL remains out of scope for 1.0. The rule simulator, additional rule kinds and console authoring are outside this change.
