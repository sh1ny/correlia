# 0008. Declarative matcher language for rules now, CEL as the future syntax

- Status: proposed
- Date: 2026-11-03
- Supersedes: none

## Context

Enrichment, routing, correlation, silencing and notification policies all need conditions over event
fields. CEL is the common choice for such filters. The Dart CEL port (`cel` 0.6.1) is simplified and has no timestamps, durations or
type conversions. The legacy rules used first-match regex/literal predicates that operators found
understandable.

## Decision

- **One shared condition model** for every rule kind:
  - Matchers: `equals`, `not_equals`, `regex` (an RE2-safe subset, with a timeout), `in`, `cidr`,
    `exists`, `glob`.
  - Combined with `all` / `any` / `not`.
  - Applied to dotted field paths such as `labels.site`, `resource.host.name` and `severity`.
- **Storage:** rules are versioned documents in Postgres, edited in the console, and importable/exportable
  as YAML.
- **One configuration version:** rules of every kind, source mappings, routing and plugin configuration are
  published together as one immutable, validated **configuration version**, activated atomically. Workers
  switch at a batch boundary; rollback re-activates an earlier version. Raw rows pin the version they were
  first processed with (ADR 0005).
- **Validation before activation:** every reference (outputs, plugins, notification targets, rule ids) is
  checked against the explicit registry of that version. An empty registry is a registry: a reference to a
  missing output fails activation (legacy B8). There is no "unknown context, skip validation" mode.
- **Simulator:** every rule kind has one. It runs the rule against stored events and shows what would match.
- **CEL later:** CEL is the documented future syntax. The stored rule format has a `language` field, so CEL
  rules can be added without a migration.

Rejected: CEL from day one. The Dart implementation is immature, and running cel-go in a plugin adds a
process hop to every rule evaluation.

Reversal cost: storage is cheap to extend (the `language` field), but behaviour is not. Adding CEL means a
second evaluator whose semantics (missing fields, type coercion, regex dialect) must match the matcher's
for equivalent rules, and the simulator must explain both. Converting existing rules is optional and
tooling-assisted. Medium overall.

## Consequences

- Operator regexes are bounded in length and run time, so a bad pattern cannot stall the pipeline
  (legacy 7.4).
- Rules are versioned: an incident records the rule version that created it.
