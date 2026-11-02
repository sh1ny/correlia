# 0008. Declarative matcher language for rules now, CEL as the future syntax

- Status: accepted (2026-11-03)
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
- **One rule tree, two evaluators.** Rules parse into one typed condition tree. It is evaluated in memory
  (Dart) in the pipeline, and compiled to SQL for console search, filters and simulator queries over stored
  data. One conformance suite runs every case through both evaluators and requires identical results, so
  the console never shows something the pipeline would decide differently. The browser never evaluates
  rules itself; it asks the server.
- **Field catalog.** Every addressable field is declared once: where it lives (column or JSON path), its
  type, its ordering (severity is ordered, not compared as text), case sensitivity, and how a missing field
  or null behaves (`exists` is the only operator that matches a missing field). Rules may only use catalog
  fields; label and annotation keys are validated against a strict key pattern.
- **SQL only from the catalog and bind parameters.** Field paths come from the catalog, never from rule
  text; every value is a bind parameter; `LIKE`/glob wildcards in values are escaped. No string-built SQL.
- **A broken rule never stops ingestion.** Validation failures block activation. A rule that fails at
  runtime (timeout, type error) is skipped for that event and counted against the pinned configuration
  version, and a self-alert fires. After a configurable error budget the rule is disabled or replaced only
  through the normal publication path:
  - disabling or replacing the rule publishes a **new immutable configuration version**;
  - the complete resulting configuration is validated against its own registry, exactly like any other
    activation, and activated atomically at batch boundaries on every worker;
  - a fallback that fails validation (for example, a previous rule version that references an output the
    current registry no longer has) does **not** activate; the per-event skip-and-count behaviour and the
    self-alert continue until an operator acts;
  - existing raw-row pins stay unchanged: work already pinned to the failing version records its rule
    failures and skips against that version, and running it under the replacement configuration requires
    an explicit reprocess (ADR 0005).
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
