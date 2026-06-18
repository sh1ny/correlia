# Phase 2: Icinga2 Ingress, Topology, and Rule Decisions - Context

**Gathered:** 2026-06-08
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 2 delivers the deterministic ingestion and decision layer before durable aggregation. Operators can POST real Icinga2 host/service alerts, have them strictly normalized into `NormalizedEvent`, enriched through the static topology plugin, and evaluated against strictly validated YAML rules. The phase must return inspectable decision output: accepted event identity, fingerprint, event type, enrichment tags/provenance, matched/no-op rule result, group key, threshold/window decision, closure count placeholder, and notification count placeholder.

In scope: Icinga2 webhook payload validation, Icinga2 state mapping, replay-tolerant fingerprints, topology enrichment interface plus static YAML hostname/IP implementation, topology diagnostics, rule YAML schema/validation, deterministic rule matching, group key generation, and typed threshold/window decision objects.

Not in scope: durable incident mutation beyond existing Phase 1 incident repository seams, notification dispatch, output plugins, recovery lifecycle resolution, expiration, operator REST incident APIs, built-in frontend, non-Icinga2 inputs, or AI-driven topology enrichment.

</domain>

<decisions>
## Implementation Decisions

### Icinga2 State Semantics
- **D-01:** Process Icinga2 `HARD` states only for v1 ingestion. `SOFT` states should not affect normalized problem/recovery processing; expose them as rejected or non-actionable diagnostics rather than silently aggregating them.
- **D-02:** Map host `UP` and service `OK` to `EventType.RECOVERY` with `Severity.OK`.
- **D-03:** Map host `DOWN`/`UNREACHABLE` and service `WARNING`/`CRITICAL`/`UNKNOWN` to `EventType.PROBLEM` with the corresponding normalized severity.
- **D-04:** Keep all Icinga2-specific state parsing inside the input plugin. Core processing must consume only `NormalizedEvent` fields and normalized tags, never raw Icinga2 state names/numbers.
- **D-05:** Icinga2 fingerprints use source object identity plus normalized state: `source_id`, `host`, optional `service`, `event_type`, and normalized severity/state. Exclude timestamp, attempt/check output, and transient delivery metadata so replayed deliveries collapse while WARNING→CRITICAL remains distinct.
- **D-06:** The Phase 2 webhook response should return a full decision envelope: accepted event id/fingerprint/type, normalized severity, final tags, enrichment diagnostics, matched rule/no-op result, group key when applicable, threshold/window decision, incident-effect placeholders, closure count placeholder, and notification count placeholder.

### Topology Tag Conflicts and Provenance
- **D-07:** Topology enrichment writes reserved `topology.*` tags, such as `topology.site` or `topology.role`, so rules can target topology explicitly without accidental collision with source tags.
- **D-08:** If the source payload already provides a `topology.*` tag that conflicts with static topology enrichment, topology wins. Record the source value and the override in diagnostics.
- **D-09:** Hostname matching has precedence over IP subnet fallback. Once a hostname rule matches, do not apply subnet fallback for that event.
- **D-10:** Enrichment diagnostics should expose the matched topology rule id/name, whether matching came from hostname or subnet, tags added/overridden, and conflict details. Do not emit a full every-rule trace in the normal ingest response.
- **D-11:** Topology enrichment remains a pure plugin-boundary transformation: event in, enriched event plus diagnostics out. It must not own rule evaluation, incident state, or database writes.

### Rule Matching and Group Keys
- **D-12:** Rule evaluation is priority ordered and first-match-wins. One event produces at most one rule decision/group key.
- **D-13:** Duplicate rule priorities are invalid. Strict YAML validation should reject multiple enabled rules with the same priority instead of relying on file order or name tie-breaks.
- **D-14:** Group keys use rule-configured field order and human-readable `key=value` segments, for example `topology.site=dc1|service=cpu`. Avoid opaque hashes as the only operator-facing group key.
- **D-15:** Missing group-by fields required by a matched rule should prevent that rule from producing a valid group key; planners should choose either strict validation against declared fields or an explicit non-match/error decision, but must not silently substitute empty values.
- **D-16:** Accepted normalized events that match no rule return an explicit no-op decision with `matched_rules: []` and no incident effects. Valid ingestion should not fail solely because operator rule config has no match.

### Threshold and Window Decisions
- **D-17:** Threshold/window counting is keyed by `rule_name + group_key`, aligning with Phase 1 incident identity and Phase 3 durable aggregation.
- **D-18:** Within a rule/group/window, the same active fingerprint contributes once. Replayed deliveries with the same fingerprint must not double-count toward thresholds.
- **D-19:** Rule windows use timezone-aware event time from `NormalizedEvent.timestamp`, not processing receipt time.
- **D-20:** Phase 2 returns typed, inspectable threshold/window decision objects suitable for tests and API response diagnostics. Durable threshold/incident mutation waits for Phase 3.
- **D-21:** Threshold decision output should include enough facts for RUL-06 debugging: rule name, group key, window bounds, threshold value, counted unique fingerprints/objects, whether the threshold is crossed, and replay/non-counted reasons where applicable.

### Claude's Discretion
No selected area was delegated to Claude. Downstream agents should treat the decisions above as locked.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project Scope and Requirements
- `.planning/PROJECT.md` — Product definition, API-first/no-frontend constraint, plugin-boundary decisions, topology-first static YAML requirement, and Phase 1 validated decisions.
- `.planning/REQUIREMENTS.md` — Requirement IDs and traceability for Phase 2: ING-01–ING-05, TOP-01–TOP-06, RUL-01–RUL-06.
- `.planning/ROADMAP.md` — Phase 2 goal, boundaries, dependencies, success criteria, and adjacent Phase 3/4 boundaries.
- `.planning/STATE.md` — Current state and accumulated concerns that Phase 2 must settle: SOFT/HARD handling, source-vs-topology tag conflicts, rule multi-match behavior, and threshold counting semantics.
- `.planning/phases/01-foundations-contracts-and-database-invariant/01-CONTEXT.md` — Locked Phase 1 decisions for `NormalizedEvent`, event tags, incident identity, compact non-secret decision metadata, and PostgreSQL-owned open incident uniqueness.

### Research Grounding
- `.planning/research/ARCHITECTURE.md` — One-way processing pipeline, plugin/core boundaries, recommended `ingress.py`, `rules.py`, `processing/enrichment.py`, and rule-engine responsibilities.
- `.planning/research/FEATURES.md` — Table-stakes guidance for Icinga2 ingress, state mapping, replay tolerance, topology enrichment, YAML rule loading, priority ordering, group keys, and threshold/window aggregation.
- `.planning/research/PITFALLS.md` — Pitfalls to avoid: recovery treated as alert, topology misclassification, plugin boundary leakage, poor grouping semantics, and duplicate open incidents.
- `.planning/research/STACK.md` — Locked stack: Python 3.14+, uv, FastAPI, Pydantic v2 strict validation, SQLAlchemy 2.0, asyncpg, PostgreSQL, Alembic, PyYAML, pytest, Ruff, mypy, Testcontainers.

### Existing Source Contracts
- `app/domain/events.py` — `EventType`, `Severity`, strict `NormalizedEvent`, timezone validation, normalized tag contract, and severity ranking.
- `app/domain/incidents.py` — `IncidentStatus`, acknowledgement-as-metadata, compact non-secret `DecisionContext`, and transition helpers.
- `app/persistence/incidents.py` — Atomic open-incident upsert seam and `IncidentUpsertInput`; Phase 2 should not bypass this with SELECT-then-INSERT behavior.
- `app/persistence/models.py` — Incident columns, JSONB affected hosts/services and decision context, and open-incident unique index constants.
- `app/config/settings.py` — Existing `rules_path`, `topology_path`, and `plugins_path` settings slots for Phase 2 config loading.
- `app/main.py`, `app/api/deps.py`, `app/api/routers/health.py` — FastAPI app factory, dependency pattern, and router style for adding webhook routes.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `NormalizedEvent` in `app/domain/events.py` already enforces strict plugin/core contracts: no extra fields, explicit enums, timezone-aware timestamps, normalized tag keys/values, and optional `ip_address`.
- `DecisionContext` in `app/domain/incidents.py` is the existing compact, non-secret debug envelope. Phase 2 decision objects should mirror this style and avoid raw payload or secret-bearing JSON.
- `Settings` already exposes `rules_path`, `topology_path`, and `plugins_path`; Phase 2 can wire strict YAML loaders to those paths without adding parallel configuration conventions.
- `create_app()` and API dependency helpers provide the route/dependency pattern for the Icinga2 webhook router.

### Established Patterns
- Pydantic v2 strict models at boundaries; malformed source/config data should raise explicit validation errors rather than coerce.
- PostgreSQL-specific behavior is tested with Testcontainers; SQLite is prohibited for database-specific checks.
- Persistence logic stays in `app/persistence`; rule evaluation and topology enrichment should be pure processing/domain code until Phase 3 needs durable incident mutation.
- Existing tests assert behavior/invariants directly and use small helper payload builders; Phase 2 tests should follow the same style.

### Integration Points
- Add an ingress router under `app/api/routers/` and include it from `app/main.py` alongside health routes.
- Add input/topology/rule domain and processing modules without putting alert business rules in route handlers.
- Feed Icinga2 plugin output into `NormalizedEvent`; downstream enrichment/rules consume only normalized fields and tags.
- Use Phase 1 incident identity (`rule_name + group_key`) when shaping rule/threshold decision output, even though durable mutation waits for Phase 3.

</code_context>

<specifics>
## Specific Ideas

- Topology tags should be reserved and explicit (`topology.*`), with topology winning only inside that reserved namespace when source payloads collide.
- Use ordered `key=value` group keys rather than hashes so incidents and responses are understandable without extra lookup.
- Treat no-match as a successful accepted event with a no-op decision; this preserves ingestion reliability while making rule coverage gaps visible.
- Threshold/window decisions are typed products of rule evaluation in Phase 2; planners should not pull durable threshold state or notification dedupe forward from Phase 3.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 2-Icinga2 Ingress, Topology, and Rule Decisions*
*Context gathered: 2026-06-08*
