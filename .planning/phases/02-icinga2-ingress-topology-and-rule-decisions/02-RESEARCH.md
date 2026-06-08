# Phase 2: Icinga2 Ingress, Topology, and Rule Decisions - Research

**Researched:** 2026-06-08
**Domain:** Python async alert ingestion, topology enrichment, deterministic rule evaluation
**Confidence:** HIGH

## Summary

Phase 2 delivers the deterministic ingestion and decision layer of Correlia. Operators POST real Icinga2 host/service alerts to a FastAPI webhook; the system validates payloads, normalizes them into `NormalizedEvent`, enriches them through a pluggable topology layer (static YAML first), evaluates them against strictly validated YAML rules, and returns an inspectable decision envelope. No durable incident mutation beyond Phase 1's existing upsert seam occurs in this phase — threshold/incident effects are typed decision objects only, waiting for Phase 3 aggregation.

The architectural pattern is a one-way pipeline: HTTP ingress → input plugin normalization → topology enrichment → rule evaluation → decision response. All plugin boundaries are pure transformations: event in, transformed event plus diagnostics out. PostgreSQL is not touched by enrichment or rule evaluation; the incident repository seam from Phase 1 is the only persistence boundary.

**Primary recommendation:** Build strict Pydantic v2 contracts at every boundary (Icinga2 payload, topology config, rule config, decision output), compile matchers at config-load time, and treat no-match as a successful no-op decision rather than an error. This preserves ingestion reliability while making rule coverage gaps visible.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Icinga2 webhook ingress | API / Backend | — | FastAPI route receives raw payload, delegates to input plugin |
| Payload validation & normalization | API / Backend | — | Pydantic models enforce shape before plugin logic runs |
| Topology enrichment | Core Processing | — | Pure function: enriched event + diagnostics from static YAML |
| Rule evaluation | Core Processing | — | Deterministic priority-ordered matching, no DB access |
| Group key generation | Core Processing | — | Derived from matched rule config + enriched event fields |
| Threshold/window decisions | Core Processing | — | Typed decision objects; durable counting deferred to Phase 3 |
| Config loading (rules, topology) | Core Processing | — | Startup-time YAML → Pydantic validation, compiled matchers |
| Response envelope assembly | API / Backend | — | Combines all processing stage outputs into API response |

## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Process Icinga2 `HARD` states only for v1 ingestion. `SOFT` states are rejected or returned as non-actionable diagnostics.
- **D-02:** Host `UP` and service `OK` map to `EventType.RECOVERY` with `Severity.OK`.
- **D-03:** Host `DOWN`/`UNREACHABLE` and service `WARNING`/`CRITICAL`/`UNKNOWN` map to `EventType.PROBLEM` with corresponding normalized severity.
- **D-04:** All Icinga2-specific state parsing stays inside the input plugin. Core processing consumes only `NormalizedEvent`.
- **D-05:** Fingerprints use `source_id`, `host`, optional `service`, `event_type`, and normalized severity/state. Exclude timestamp and transient metadata.
- **D-06:** Phase 2 webhook response returns a full decision envelope with event identity, fingerprint, type, severity, tags, enrichment diagnostics, matched rule/no-op result, group key, threshold/window decision, and placeholders for incident/closure/notification effects.
- **D-07:** Topology enrichment writes reserved `topology.*` tags (e.g., `topology.site`, `topology.role`).
- **D-08:** If source payload provides a conflicting `topology.*` tag, topology wins. Record override in diagnostics.
- **D-09:** Hostname matching has precedence over IP subnet fallback. Once hostname matches, do not apply subnet fallback.
- **D-10:** Enrichment diagnostics expose matched topology rule id/name, matching source (hostname/subnet), tags added/overridden, and conflict details.
- **D-11:** Topology enrichment is a pure plugin-boundary transformation. It does not own rule evaluation, incident state, or DB writes.
- **D-12:** Rule evaluation is priority ordered and first-match-wins. One event produces at most one rule decision/group key.
- **D-13:** Duplicate rule priorities are invalid. Strict YAML validation rejects multiple enabled rules with the same priority.
- **D-14:** Group keys use rule-configured field order and human-readable `key=value` segments (e.g., `topology.site=dc1|service=cpu`). Avoid opaque hashes as the only operator-facing group key.
- **D-15:** Missing group-by fields required by a matched rule prevent that rule from producing a valid group key. Do not silently substitute empty values.
- **D-16:** Accepted normalized events that match no rule return an explicit no-op decision with `matched_rules: []` and no incident effects.
- **D-17:** Threshold/window counting is keyed by `rule_name + group_key`, aligning with Phase 1 incident identity.
- **D-18:** Within a rule/group/window, the same active fingerprint contributes once. Replayed deliveries with the same fingerprint must not double-count.
- **D-19:** Rule windows use timezone-aware event time from `NormalizedEvent.timestamp`, not processing receipt time.
- **D-20:** Phase 2 returns typed, inspectable threshold/window decision objects. Durable threshold/incident mutation waits for Phase 3.
- **D-21:** Threshold decision output includes enough facts for RUL-06 debugging: rule name, group key, window bounds, threshold value, counted unique fingerprints, whether threshold is crossed, and replay/non-counted reasons.

### Claude's Discretion

No area was delegated to Claude. All decisions above are locked.

### Deferred Ideas (OUT OF SCOPE)

- Durable incident mutation beyond existing Phase 1 repository seam
- Notification dispatch, output plugins
- Recovery lifecycle resolution
- Expiration
- Operator REST incident APIs
- Built-in frontend
- Non-Icinga2 inputs
- AI-driven topology enrichment

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ING-01 | Icinga2 can POST host and service alert payloads to a Correlia webhook endpoint. | FastAPI `APIRouter` POST route under `/webhooks/icinga2`; dependency-injected settings, sessionmaker, and processor service |
| ING-02 | Correlia validates Icinga2 webhook payloads before processing. | Pydantic v2 strict request model for Icinga2 payload; explicit validation errors, no coercion |
| ING-03 | Correlia maps Icinga2 host and service states into normalized severity and PROBLEM/RECOVERY event type values. | Icinga2 input plugin owns all state mapping; host UP/service OK → RECOVERY; host DOWN/service WARNING/CRITICAL/UNKNOWN → PROBLEM |
| ING-04 | Correlia derives stable fingerprints for Icinga2 events so repeated deliveries are replay-tolerant. | Fingerprint = hash of source_id + host + service + event_type + severity; excludes timestamp and transient metadata |
| ING-05 | Correlia returns an API response that identifies the accepted event, event type, enrichment tags, matched rules, incident updates, closures, and notification count. | Typed decision envelope Pydantic model combining all processing stage outputs; incident/closure/notification counts are placeholders in Phase 2 |
| TOP-01 | Operator can define hostname pattern enrichment rules in YAML. | Topology YAML schema with `name`, `hostname_pattern` (regex), `tags` dict |
| TOP-02 | Operator can define IP subnet enrichment rules in YAML. | Topology YAML schema with `name`, `subnet` (CIDR), `tags` dict |
| TOP-03 | Correlia enriches events with topology tags using hostname matches before IP subnet fallback. | Deterministic precedence: hostname patterns first, then subnet fallback; compile regexes and parse CIDRs at config load time |
| TOP-04 | Correlia preserves or explicitly resolves conflicts between source-provided tags and enrichment-derived tags. | Reserved `topology.*` namespace; topology wins on conflict; diagnostics record override details |
| TOP-05 | Operator can see enrichment diagnostics sufficient to explain which topology rule affected an event. | Enrichment diagnostics include matched rule id/name, match source (hostname/subnet), tags added/overridden, conflicts |
| TOP-06 | Maintainer can add new topology enricher implementations behind a plugin interface without changing rule evaluation or incident processing. | `TopologyEnricher` Protocol/ABC; static YAML is first concrete implementation; pure transformation boundary |
| RUL-01 | Operator can define aggregation rules in YAML with name, priority, match criteria, window duration, group-by fields, trigger threshold, output summary, and actions. | Rule YAML schema with strict Pydantic v2 validation; `extra="forbid"` on all config models |
| RUL-02 | Correlia validates rule YAML strictly, including references to tags, actions, plugins, window values, and summary placeholders. | Cross-reference validation at load time: compile regexes, validate CIDRs, check placeholder syntax, reject duplicate priorities |
| RUL-03 | Correlia evaluates rules in deterministic priority order. | Sort rules by priority ascending at load time; first-match-wins per D-12 |
| RUL-04 | Correlia matches events by severity, host/service fields, and tag criteria. | Match criteria schema: severity list, host pattern, service pattern, tag equality/wildcard conditions |
| RUL-05 | Correlia generates deterministic, human-readable group keys from configured group-by fields. | Group key = ordered `field=value` segments joined by `\|`; field values extracted from enriched event/tags; fail if required field missing |
| RUL-06 | Correlia calculates threshold/window aggregation decisions in a way that can be inspected during tests and operator debugging. | Typed `ThresholdDecision` model with all debug facts: rule name, group key, window bounds, threshold, counted fingerprints, crossed flag, replay reasons |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Python | 3.14+ | Runtime | Project locked; required by pyproject.toml `requires-python` [VERIFIED: pyproject.toml] |
| FastAPI | 0.136.x | REST API, webhook endpoint | Project locked; async native, OpenAPI generation, Pydantic v2 integration [VERIFIED: pyproject.toml] |
| Pydantic | 2.13.x | Request/response/config validation | Project locked; strict mode, `extra="forbid"`, `model_validate` for YAML → typed objects [VERIFIED: pyproject.toml] |
| pydantic-settings | 2.14.x | App settings with env binding | Project locked; `rules_path`, `topology_path`, `plugins_path` already exposed [VERIFIED: app/config/settings.py] |
| SQLAlchemy | 2.0.x | Async DB access | Project locked; existing persistence layer [VERIFIED: pyproject.toml] |
| asyncpg | 0.31.x | Async PostgreSQL driver | Project locked [VERIFIED: pyproject.toml] |
| PyYAML | 6.0.x | YAML parser for rules/topology | Project locked; use only `yaml.safe_load()` then Pydantic validate [VERIFIED: pyproject.toml] |
| PostgreSQL | 18.x (17.x acceptable) | Durable incident state | Project locked; partial unique indexes, JSONB, `ON CONFLICT` required [VERIFIED: app/persistence/models.py] |
| Alembic | 1.18.x | Schema migrations | Project locked; already configured [VERIFIED: pyproject.toml] |
| uvicorn | 0.49.x | ASGI server | Project locked [VERIFIED: pyproject.toml] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| httpx | 0.28.x | ASGI test client | Already in dev dependencies; use `AsyncClient` + `ASGITransport` for FastAPI webhook tests [VERIFIED: pyproject.toml] |
| pytest | 9.0.x | Test runner | Already in dev dependencies [VERIFIED: pyproject.toml] |
| pytest-asyncio | 1.4.x | Async test support | Already in dev dependencies; `asyncio_mode = "auto"` configured [VERIFIED: pyproject.toml] |
| testcontainers | 4.14.x | PostgreSQL integration tests | Already in dev dependencies; required for DB-specific tests per project convention [VERIFIED: pyproject.toml] |
| Ruff | 0.15.x | Lint/format | Already in dev dependencies; target `py314` [VERIFIED: pyproject.toml] |
| mypy | 2.x | Static typing | Already in dev dependencies; `strict = true` [VERIFIED: pyproject.toml] |

**Version verification:** All packages already exist in `pyproject.toml` and `uv.lock`. No new external dependencies required for Phase 2.

```bash
# All required packages already installed via uv
# No additional npm/pip/cargo commands needed
```

## Package Legitimacy Audit

No new external packages are introduced in Phase 2. All dependencies are already locked in `uv.lock` and verified through the project's existing dependency resolution.

## Architecture Patterns

### System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  HTTP POST /webhooks/icinga2                                │
│  FastAPI ingress router                                     │
└────────────────────────┬────────────────────────────────────┘
                         │ raw Icinga2 payload
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Icinga2 Input Plugin                                       │
│  • Validate payload shape (Pydantic strict)                 │
│  • Map host/service states → Severity + EventType           │
│  • Reject SOFT states as non-actionable                     │
│  • Compute stable fingerprint                               │
│  • Emit NormalizedEvent                                     │
└────────────────────────┬────────────────────────────────────┘
                         │ NormalizedEvent
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Topology Enricher (static YAML plugin)                     │
│  • Compile regexes / parse CIDRs at load time               │
│  • Match hostname patterns first                            │
│  • Fallback to IP subnet matching                           │
│  • Write topology.* tags; resolve conflicts                 │
│  • Return enriched event + diagnostics                      │
└────────────────────────┬────────────────────────────────────┘
                         │ Enriched NormalizedEvent
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Rule Engine                                                │
│  • Load & validate YAML rules at startup                    │
│  • Sort by priority; reject duplicates                      │
│  • Evaluate first-match-wins                                │
│  • Generate human-readable group key                        │
│  • Produce ThresholdDecision                                │
└────────────────────────┬────────────────────────────────────┘
                         │ RuleDecision + ThresholdDecision
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Response Assembler                                         │
│  • Combine event identity, enrichment, rule match           │
│  • Include placeholders for incident/closure/notification   │
│  • Return inspectable decision envelope                     │
└─────────────────────────────────────────────────────────────┘
```

### Recommended Project Structure

```
app/
├── api/
│   ├── deps.py                     # existing: settings, sessionmaker
│   └── routers/
│       ├── health.py               # existing
│       └── ingress.py              # NEW: POST /webhooks/icinga2
├── domain/
│   ├── events.py                   # existing: NormalizedEvent, Severity, EventType
│   ├── incidents.py                # existing: DecisionContext, IncidentStatus
│   └── rules.py                    # NEW: Rule, MatchCriteria, Window, Action, ThresholdDecision
├── processing/
│   ├── enrichment.py               # NEW: TopologyEnricher interface + static YAML impl
│   └── rule_engine.py              # NEW: RuleEngine, group key generation, match logic
├── plugins/
│   ├── interfaces.py               # NEW: InputPlugin, TopologyEnricher protocols
│   └── inputs/
│       └── icinga2.py              # NEW: Icinga2InputPlugin
├── config/
│   ├── settings.py                 # existing
│   ├── rules.py                    # NEW: YAML rule loader + strict validation
│   └── topology.py                 # NEW: YAML topology loader + strict validation
└── persistence/
    ├── models.py                   # existing
    └── incidents.py                # existing: upsert seam (Phase 2 does not modify)
```

### Pattern 1: Strict Pydantic v2 at Every Boundary

**What:** Every config, request, and response model uses `ConfigDict(strict=True, extra="forbid")`. YAML is parsed with `yaml.safe_load()` then fed into `model_validate()`.

**When to use:** All YAML config loading, webhook request validation, and API response models.

**Why:** Prevents silent coercion (`"5"` → `5`), rejects unknown fields, and surfaces operator errors with clear paths.

**Example:**
```python
# Source: project conventions from Phase 1
class Icinga2WebhookPayload(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    host: Annotated[str, Field(min_length=1)]
    service: Annotated[str, Field(min_length=1)] | None = None
    state: Literal["UP", "DOWN", "UNREACHABLE", "OK", "WARNING", "CRITICAL", "UNKNOWN"]
    state_type: Literal["HARD", "SOFT"]
    # ... other fields
```

### Pattern 2: Plugin Protocol with Pure Transformation Semantics

**What:** Define small `Protocol` classes for input and topology plugins. Concrete implementations are loaded and cached at startup.

**When to use:** Input normalization and topology enrichment boundaries.

**Why:** Keeps core processing source-agnostic; future inputs (Alertmanager) and enrichers (AI-driven) plug in without changing rule engine or incident logic.

**Example:**
```python
# Source: ARCHITECTURE.md Pattern 1
class InputPlugin(Protocol):
    async def process_payload(self, payload: Mapping[str, Any]) -> NormalizedEvent: ...

class TopologyEnricher(Protocol):
    async def enrich(self, event: NormalizedEvent) -> EnrichmentResult: ...
```

### Pattern 3: Compiled Config at Load Time

**What:** Compile regexes, parse CIDRs, sort rules by priority, and build lookup structures when YAML is loaded — not per event.

**When to use:** Topology YAML loading and rule YAML loading.

**Why:** Alert bursts are the normal case; per-event compilation causes CPU spikes and latency growth.

**Example:**
```python
# Source: PITFALLS.md Performance Traps
class StaticTopologyEnricher:
    def __init__(self, config: TopologyConfig) -> None:
        self._hostname_rules = [
            (re.compile(r.name), r.tags) for r in config.hostname_rules
        ]
        self._subnet_rules = [
            (ipaddress.ip_network(r.subnet), r.tags) for r in config.subnet_rules
        ]
```

### Pattern 4: First-Match-Wins with Explicit No-Op

**What:** Rules evaluate in strict priority order. The first matching rule produces a decision. If no rule matches, return an explicit no-op decision with empty `matched_rules`.

**When to use:** All enriched PROBLEM events. RECOVERY events bypass rule evaluation entirely.

**Why:** Prevents surprise multi-match behavior; no-match is a valid ingestion outcome that makes coverage gaps visible.

**Example:**
```python
# Source: CONTEXT.md D-12, D-16
decisions = []
for rule in self._rules:  # already sorted by priority ascending
    if rule.matches(enriched_event):
        group_key = self._build_group_key(rule, enriched_event)
        threshold = self._evaluate_threshold(rule, group_key, enriched_event)
        decisions.append(RuleDecision(...))
        break  # first-match-wins

if not decisions:
    return NoOpDecision(event_id=event.fingerprint, reason="no matching rule")
```

### Anti-Patterns to Avoid

- **Raw Icinga2 fields in core processing:** Core must branch on `EventType` and `Severity`, never on `check_result`, `state_type`, or numeric Icinga states. [CITED: PITFALLS.md Pitfall 5]
- **SELECT-then-INSERT for incident creation:** Already solved in Phase 1; Phase 2 must not introduce any new persistence patterns that bypass the atomic upsert. [CITED: PITFALLS.md Pitfall 1]
- **Opaque hash-only group keys:** Operators cannot debug `a1b2c3d4`. Use `key=value|key=value` format. [CITED: CONTEXT.md D-14]
- **Silent SOFT state processing:** SOFT states must be explicitly rejected or returned as diagnostics, not silently treated as problems. [CITED: CONTEXT.md D-01]
- **Per-event regex/CIDR compilation:** Compile at config load time. [CITED: PITFALLS.md Performance Traps]
- **YAML as programming language:** No expressions, no Jinja, no arbitrary code. Declarative match criteria only. [CITED: STACK.md]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| YAML parsing | Custom parser | `yaml.safe_load()` + Pydantic `model_validate()` | PyYAML handles syntax; Pydantic handles semantics and strictness |
| Regex compilation safety | Custom regex engine | Python `re.compile()` with validated patterns | Standard library proven, well-tested, handles edge cases |
| CIDR matching | Custom subnet logic | `ipaddress.ip_network()` + `overlaps()` / `contains` | Python stdlib handles IPv4/IPv6, edge cases, overlapping nets |
| Fingerprint hashing | Custom hash | `hashlib.sha256()` or `blake2b` | Cryptographic hashes prevent collision; deterministic output |
| Config validation cross-references | Ad-hoc checks | Pydantic `@model_validator(mode='after')` | Reuses existing validation framework; produces consistent errors |
| Webhook payload validation | Manual dict inspection | Pydantic v2 strict request model | Automatic error messages, type coercion prevention, OpenAPI docs |

**Key insight:** The "don't hand-roll" list for Phase 2 is short because the domain is largely config-driven business logic, not infrastructure. The main risk is building a custom rule expression language instead of keeping match criteria declarative and simple.

## Common Pitfalls

### Pitfall 1: Icinga2 SOFT States Creating Noise

**What goes wrong:** SOFT states (transient check failures before `max_check_attempts`) are treated as real problems, creating premature incidents and false pages.

**Why it happens:** Icinga2 sends notifications for both SOFT and HARD states depending on notification object configuration. If Correlia does not filter, it pages on every transient retry.

**How to avoid:** Reject SOFT states at the input plugin boundary. Return them in the decision envelope as `state_accepted: false` with a diagnostic reason, preserving the 200 response for valid webhook deliveries.

**Warning signs:** Incident count spikes correlate with Icinga2 check retry intervals; incidents auto-resolve quickly; operators report "flapping" incidents.

### Pitfall 2: Group Key Collisions from Missing Fields

**What goes wrong:** A rule's `group_by` references a tag that does not exist on an event. The group key generator silently substitutes an empty string, causing unrelated events to collapse into the same group.

**Why it happens:** Enrichment may not set every expected tag for every host. Without explicit handling, `topology.datacenter=None` and `topology.datacenter=None` collide across all unmapped hosts.

**How to avoid:** If a required group-by field is missing, the rule must either fail to match or produce an explicit error decision. Do not generate a group key with empty segments. [CITED: CONTEXT.md D-15]

**Warning signs:** One incident accumulates hosts from many unrelated services; group key contains `datacenter=` with no value.

### Pitfall 3: Topology Regex Precedence Ambiguity

**What goes wrong:** Overlapping hostname regexes or CIDRs produce different tags depending on evaluation order. A host matches both `.*-lon-.*` and `.*-web-.*`, getting different `topology.role` values.

**Why it happens:** Regex-based matching is inherently order-dependent. Without deterministic precedence and conflict rules, enrichment becomes non-reproducible.

**How to avoid:** Use configured file order for hostname rules (first match wins). Document this explicitly. Validate topology config for overlapping CIDRs that assign different tags. [CITED: CONTEXT.md D-09, D-10]

**Warning signs:** Same host gets different topology tags on different events; group keys change for the same incident over time.

### Pitfall 4: Fingerprint Instability

**What goes wrong:** Fingerprints include timestamps, check output, or attempt counts. Replayed deliveries create new fingerprints, defeating deduplication.

**Why it happens:** Naive fingerprinting hashes the entire payload. Icinga2 resends notifications, and Correlia must collapse replays.

**How to avoid:** Fingerprint = stable identity only: `source_id`, `host`, `service`, `event_type`, `severity`. Exclude timestamp, message, check output, and transient metadata. [CITED: CONTEXT.md D-05]

**Warning signs:** Same alert storm produces many fingerprints with identical host/service/state; event count in incidents does not match expected unique sources.

### Pitfall 5: Duplicate Rule Priorities

**What goes wrong:** Two rules share the same priority. Evaluation order becomes undefined or file-order-dependent, surprising operators.

**Why it happens:** YAML file order is not a reliable semantic ordering; operators may not realize files are concatenated.

**How to avoid:** Validate at load time: reject the config if two enabled rules share the same priority. Emit a clear error with rule names and offending priority value. [CITED: CONTEXT.md D-13]

**Warning signs:** Same event matches different rules on different deployments; rule evaluation tests pass locally but fail in CI.

### Pitfall 6: Threshold Double-Counting on Replay

**What goes wrong:** A replayed delivery with the same fingerprint increments the threshold counter, causing premature threshold crossing.

**Why it happens:** Threshold counting naively increments on every event without tracking which fingerprints have already contributed.

**How to avoid:** Track seen fingerprints per `(rule_name, group_key, window)`. A fingerprint contributes at most once per window. Replays return the threshold decision with `counted: false` and a replay reason. [CITED: CONTEXT.md D-18]

**Warning signs:** Threshold crosses on 2 events when configured for 5; replayed deliveries change `threshold_crossed` from false to true.

## Code Examples

### Icinga2 State Mapping

```python
# Source: CONTEXT.md D-01 through D-04
_ICINGA_HOST_STATES = {
    "UP": (Severity.OK, EventType.RECOVERY),
    "DOWN": (Severity.CRITICAL, EventType.PROBLEM),
    "UNREACHABLE": (Severity.UNKNOWN, EventType.PROBLEM),
}

_ICINGA_SERVICE_STATES = {
    "OK": (Severity.OK, EventType.RECOVERY),
    "WARNING": (Severity.WARNING, EventType.PROBLEM),
    "CRITICAL": (Severity.CRITICAL, EventType.PROBLEM),
    "UNKNOWN": (Severity.UNKNOWN, EventType.PROBLEM),
}

def map_icinga_state(state: str, is_host: bool) -> tuple[Severity, EventType]:
    mapping = _ICINGA_HOST_STATES if is_host else _ICINGA_SERVICE_STATES
    if state not in mapping:
        raise ValueError(f"Unknown Icinga2 state: {state}")
    return mapping[state]
```

### Stable Fingerprint Generation

```python
# Source: CONTEXT.md D-05
import hashlib

def fingerprint_icinga_event(
    source_id: str,
    host: str,
    service: str | None,
    event_type: EventType,
    severity: Severity,
) -> str:
    parts = [source_id, host, event_type.value, severity.value]
    if service is not None:
        parts.append(service)
    raw = "|".join(parts)
    return hashlib.sha256(raw.encode()).hexdigest()[:32]
```

### Topology Enrichment with Conflict Handling

```python
# Source: CONTEXT.md D-07 through D-11
from dataclasses import dataclass

@dataclass(frozen=True)
class EnrichmentDiagnostic:
    rule_name: str
    match_source: Literal["hostname", "subnet"]
    tags_added: dict[str, str]
    tags_overridden: dict[str, tuple[str, str]]  # key -> (old, new)

@dataclass(frozen=True)
class EnrichmentResult:
    event: NormalizedEvent
    diagnostics: list[EnrichmentDiagnostic]

class StaticTopologyEnricher:
    def __init__(self, config: TopologyConfig) -> None:
        self._hostname_rules = [
            (re.compile(r.hostname_pattern), r.tags) for r in config.hostname_rules
        ]
        self._subnet_rules = [
            (ipaddress.ip_network(r.subnet), r.tags) for r in config.subnet_rules
        ]

    async def enrich(self, event: NormalizedEvent) -> EnrichmentResult:
        new_tags = dict(event.tags)
        diagnostics: list[EnrichmentDiagnostic] = []

        # Hostname matching first
        for pattern, rule_tags in self._hostname_rules:
            if pattern.search(event.host):
                added, overridden = self._apply_tags(new_tags, rule_tags, "topology.")
                diagnostics.append(EnrichmentDiagnostic(...))
                break  # hostname precedence; no subnet fallback

        # IP subnet fallback only if no hostname match
        if not diagnostics and event.ip_address is not None:
            addr = ipaddress.ip_address(event.ip_address)
            for network, rule_tags in self._subnet_rules:
                if addr in network:
                    added, overridden = self._apply_tags(new_tags, rule_tags, "topology.")
                    diagnostics.append(EnrichmentDiagnostic(...))
                    break

        enriched = event.model_copy(update={"tags": new_tags})
        return EnrichmentResult(event=enriched, diagnostics=diagnostics)
```

### Rule Evaluation with First-Match-Wins

```python
# Source: CONTEXT.md D-12, D-13, D-14
class RuleEngine:
    def __init__(self, rules: list[Rule]) -> None:
        priorities = [r.priority for r in rules]
        if len(priorities) != len(set(priorities)):
            raise ValueError("Duplicate rule priorities detected")
        self._rules = sorted(rules, key=lambda r: r.priority)

    def evaluate(self, event: NormalizedEvent) -> RuleDecision | NoOpDecision:
        for rule in self._rules:
            if self._matches(rule, event):
                group_key = self._build_group_key(rule, event)
                if group_key is None:
                    return NoOpDecision(
                        reason=f"matched rule '{rule.name}' but missing required group-by fields"
                    )
                return RuleDecision(
                    rule_name=rule.name,
                    group_key=group_key,
                    threshold=ThresholdDecision(...),
                )
        return NoOpDecision(reason="no matching rule")

    def _build_group_key(self, rule: Rule, event: NormalizedEvent) -> str | None:
        segments: list[str] = []
        for field in rule.group_by:
            value = self._resolve_field(field, event)
            if value is None or value == "":
                return None
            segments.append(f"{field}={value}")
        return "|".join(segments)
```

### Decision Envelope Response Model

```python
# Source: CONTEXT.md D-06
class IngressDecisionEnvelope(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    event_id: str
    fingerprint: str
    event_type: EventType
    severity: Severity
    enriched_tags: dict[str, str]
    enrichment_diagnostics: list[EnrichmentDiagnostic]
    matched_rule: str | None = None
    group_key: str | None = None
    threshold_decision: ThresholdDecision | None = None
    incident_effects: IncidentEffectPlaceholder
    closure_count: int = 0
    notification_count: int = 0
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Raw payload dicts throughout | `NormalizedEvent` strict Pydantic model | Phase 1 | Type safety, explicit contracts, no source leakage |
| SQLite for tests | PostgreSQL via Testcontainers | Phase 1 | Real concurrency behavior, partial indexes, JSONB |
| ACKNOWLEDGED as status enum | Acknowledgement as metadata on OPEN | Phase 1 | Preserves partial unique index invariant |
| Ad-hoc config loading | YAML → Pydantic strict validation | Phase 2 (this phase) | Fail-fast config, clear errors, compiled matchers |
| Host-only grouping | Topology-aware enrichment before grouping | Phase 2 (this phase) | Datacenter/role-based incidents instead of host piles |

**Deprecated/outdated:**
- Pydantic v1 `.dict()` / `.parse_obj()`: Use v2 `model_dump()` / `model_validate()` [CITED: STACK.md]
- `yaml.load()`: Use `yaml.safe_load()` only [CITED: PITFALLS.md]
- FastAPI `BackgroundTasks`: Use explicit `TaskRunner` abstraction [CITED: STACK.md]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Icinga2 webhook payloads contain `host`, optional `service`, `state`, `state_type` fields at minimum | Icinga2 Ingress | If actual payloads differ significantly, request model and mapping logic must change |
| A2 | Python `ipaddress` module handles all CIDR formats operators will use | Topology Enrichment | If exotic formats needed, may need `netaddr` dependency |
| A3 | First-match-wins rule semantics are sufficient for v1; multi-match can be added later via `stop_processing` flag | Rule Engine | If operators need multi-match from day one, architecture needs adjustment |
| A4 | Threshold counting state can be kept in-memory for Phase 2 decision objects; durable counting waits for Phase 3 | Threshold Decisions | If Phase 3 needs different counting semantics, Phase 2 tests may need updates |
| A5 | `topology.*` reserved namespace is sufficient to prevent all meaningful source/topology tag collisions | Topology Enrichment | If operators use `topology.*` in source payloads intentionally, override behavior may surprise them |

## Open Questions

1. **Icinga2 webhook payload exact shape**
   - What we know: Icinga2 notification commands pass host/service state, check output, and custom variables via environment variables or stdin. A common webhook integration sends a JSON payload with these fields.
   - What's unclear: The exact field names and nesting of the JSON payload Icinga2 will POST.
   - Recommendation: Define a conservative payload model with required `host`, `state`, `state_type` and optional `service`, `check_output`, `custom_variables`. Document that operators may need to adjust their NotificationCommand template if fields differ.

2. **Rule match criteria expressiveness**
   - What we know: Match by severity list, host pattern, service pattern, and tag equality/wildcard.
   - What's unclear: Whether operators need negation (`not_tag`), range matching, or regex on tag values in v1.
   - Recommendation: Start with equality and wildcard (`*`) only. Negation and regex matching can be added in v1.x without breaking existing rules.

3. **Summary template syntax**
   - What we know: Rules should declare an `output_summary` that may reference event fields and tags.
   - What's unclear: Whether to use Python f-string style, Jinja2-style, or a custom minimal template syntax.
   - Recommendation: Use Python `string.Template` with `$field` substitution for v1. It is safe (no code execution), simple, and sufficient for `\${host} - \${topology.site}` style summaries.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Python 3.14+ | Runtime | ✓ | 3.14 | — |
| uv | Package management | ✓ | 0.11.x | — |
| PostgreSQL | Incident persistence (Phase 1 seam) | ✓ | 18.x (or 17.x) | — |
| Docker | Testcontainers for PostgreSQL tests | ✓ | — | — |
| PyYAML | Rule/topology config parsing | ✓ | 6.0.x | — |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** None.

## Security Domain

> `security_enforcement` is enabled (ASVS Level 1).

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | Webhook ingress has no auth in v1; document that endpoint should be network-restricted |
| V3 Session Management | No | Stateless API; no sessions |
| V4 Access Control | No | No role-based access in v1 |
| V5 Input Validation | Yes | Pydantic v2 strict models for all ingress payloads and YAML config; `extra="forbid"` |
| V6 Cryptography | No | No cryptographic operations in this phase |
| V7 Error Handling | Yes | Explicit validation errors; no raw exception leakage in API responses |
| V8 Data Protection | Yes | DecisionContext rejects secret-bearing notes; raw payloads stay in optional debug only |
| V10 Malicious Code | Yes | `yaml.safe_load()` only; no arbitrary code execution from config |
| V12 File Upload | No | No file uploads |
| V13 API | Yes | FastAPI automatic OpenAPI; strict request/response models |

### Known Threat Patterns for Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Unsafe YAML loading → RCE | Tampering/Elevation | `yaml.safe_load()` + Pydantic validation [CITED: PITFALLS.md] |
| Unauthenticated webhook ingress | Spoofing | Network-restrict endpoint; document auth as v1.x hardening |
| Secret leakage in incident metadata | Info Disclosure | `DecisionContext` rejects `raw_payload`, `credential`, `password`, `token`, `secret`, `plugin_config` in notes [VERIFIED: app/domain/incidents.py] |
| Broad wildcard rules causing mega-incidents | Denial of Service | Require explicit `group_by`, threshold, and window; validate rules at load time |
| Plugin import from untrusted config | Elevation | Restrict to allowlisted module paths; validate plugin names against registry |

## Sources

### Primary (HIGH confidence)
- `.planning/phases/02-icinga2-ingress-topology-and-rule-decisions/02-CONTEXT.md` — Locked implementation decisions D-01 through D-21
- `.planning/REQUIREMENTS.md` — Requirement IDs ING-01 through RUL-06 with traceability
- `.planning/research/ARCHITECTURE.md` — Component boundaries, data flow, build order, plugin patterns
- `.planning/research/FEATURES.md` — Feature landscape, table stakes, prioritization
- `.planning/research/PITFALLS.md` — Critical pitfalls, performance traps, security mistakes, integration gotchas
- `.planning/research/STACK.md` — Locked technology versions and compatibility matrix
- `app/domain/events.py` — `NormalizedEvent`, `EventType`, `Severity`, `TagKey`, `TagValue` contracts
- `app/domain/incidents.py` — `DecisionContext`, `IncidentStatus`, transition helpers, secret rejection in notes
- `app/persistence/incidents.py` — `IncidentUpsertInput`, atomic upsert seam for Phase 3 integration
- `app/config/settings.py` — `rules_path`, `topology_path`, `plugins_path` settings slots
- `app/main.py` — FastAPI app factory and router wiring pattern
- Icinga2 Monitoring Basics — host/service states, hard/soft states: https://icinga.com/docs/icinga-2/latest/doc/03-monitoring-basics/
- Icinga2 Object Types — notifications, notification commands, state/type filters: https://icinga.com/docs/icinga-2/latest/doc/09-object-types/
- PostgreSQL Partial Indexes — https://www.postgresql.org/docs/current/indexes-partial.html
- SQLAlchemy 2.0 PostgreSQL Upsert — `on_conflict_do_update(index_where=...)`: https://docs.sqlalchemy.org/en/20/dialects/postgresql.html#insert-on-conflict-upsert

### Secondary (MEDIUM confidence)
- Prometheus Alertmanager documentation — grouping, routing, resend behavior (informs replay tolerance design)
- PagerDuty Event Orchestration — routing rules, suppression, threshold conditions (informs rule action design)
- Grafana OnCall integrations — grouping ID templates, escalation (informs group key readability)

### Tertiary (LOW confidence)
- None — all claims in this research are verified against project documents or official documentation.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all packages already locked in `uv.lock` with verified versions
- Architecture: HIGH — derived from existing project research (ARCHITECTURE.md, FEATURES.md, PITFALLS.md) and locked CONTEXT.md decisions
- Pitfalls: HIGH — based on documented anti-patterns from Alertmanager, PagerDuty, and Icinga2 operational experience

**Research date:** 2026-06-08
**Valid until:** 2026-07-08 (30 days for stable stack; revisit if FastAPI or Pydantic release major versions)
