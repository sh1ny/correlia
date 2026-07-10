# Phase 7: Incident Event Audit Trail - Research

**Researched:** 2026-06-18
**Domain:** Audit-trail persistence, transaction refactor, operator read surface, raw-payload redaction
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Audit Write Timing
- **D-01:** Audit rows are written in the same database transaction as the incident upsert/lifecycle write. This satisfies AUD-02's "every accepted normalized event" crash-safety requirement.
- **D-02:** Transaction commit ownership moves upward from `IncidentManager.apply_problem` and `LifecycleManager.resolve_for_event` to the ingress caller. Managers return their write result and notification intent; the ingress layer inserts the audit row and commits once.
- **D-03:** Notification task submission (`_submit_notifications`) remains post-commit, preserving current envelope behavior. Audit rows record notification **intent** only (`notification_intent = dispatch_planned | no_dispatch` with `no_dispatch_reason`), not actual plugin delivery results.

#### Raw Payload Retention
- **D-04:** The audit table stores a redacted, size-capped snapshot of the accepted source payload object. Exact wire-body retention is not required unless the ingress route is changed to capture bytes.
- **D-05:** Raw payload redaction strips secrets before persistence. A new recursive redactor handles arbitrary JSON paths and string values; the existing `DecisionContext` notes filter is not reused for this purpose.
- **D-06:** Raw payload size cap is configurable via `CORRELIA_AUDIT_RAW_PAYLOAD_MAX_BYTES` in `app.config.settings.Settings`, with a conservative default (e.g., 64 KiB). Capping must be semantic, not arbitrary byte truncation of JSONB.
- **D-07:** Metadata columns accompany the raw snapshot: `original_byte_length`, `stored_byte_length`, `truncated`, `redaction_version`, `redacted_path_count`, and a keyed HMAC of the pre-redaction canonical payload.
- **D-08:** Default audit read responses never expose `raw_payload` or full `normalized_event`. `NormalizedEvent.message` and `tags` are also bounded/redacted on read.

#### Operator Inspection Surface
- **D-09:** The primary canonical read surface is `GET /v1/incident-events`. No incident-scoped alias is added in Phase 7.
- **D-10:** Pagination is cursor-first on the immutable tuple `(accepted_at, id)`. Offset pagination with `total` is diagnostic-only and documented as approximate.
- **D-11:** Filters include `incident_id`, `has_incident` (true/false), `fingerprint`, `source_id`, `event_type`, `incident_effect`, `no_dispatch_reason`, `severity`, `host`, `service`, `accepted_since`/`accepted_until`, and `event_timestamp_since`/`event_timestamp_until`.
- **D-12:** `has_incident=false` maps strictly to `incident_effect = none`. `below_threshold` and `replay` are `no_dispatch_reason` values, not no-incident cases.
- **D-13:** Audit row identifier is a server-generated UUID. `fingerprint` is a correlation field only (repeats for replays).
- **D-14:** Incident correlation uses an `incident_ids` JSONB array. Recovery events may touch multiple incidents; no-op events touch none.
- **D-15:** Read responses project bounded metadata only; raw payload and full normalized event are never selected or serialized by default.
- **D-16:** `/v1/incident-events` is explicitly classified as route class `operator` in `app/middleware/classification.py` so Phase 5 auth and rate-limit inheritance is assertable.

#### Decision Summary Content
- **D-17:** The `decision_summary` column is a bounded Pydantic model named `AuditDecisionSummary`, versioned with `schema_version: Literal[1]`, `strict=True`, `extra="forbid"`, following the existing `DecisionContext` discipline.
- **D-18:** Required fields: `decision_kind` (problem|recovery|noop), `incident_effect` (none|inserted|updated|resolved|affected_set_shrunk), `rule_name` (nullable string), `group_key` (nullable string), `incident_ids` (max 20), `affected_incident_count` (int), `incident_ids_truncated` (bool), `decision_reason` (nullable bounded string, max 256 chars), `no_dispatch_reason` (nullable bounded string, max 128 chars), `notification_intent` (dispatch_planned|no_dispatch), `counted_count` (nullable int), `threshold_count` (nullable int), `threshold_crossed` (nullable bool), `replay` (nullable bool), `first_threshold_transition` (nullable bool), `recovery_resolution` (nullable literal: noop|affected_set_shrunk|resolved), `affected_object_removed` (nullable bool).
- **D-19:** The model deliberately excludes `counted_fingerprints`, `enrichment_diagnostics`, and full `rule_decision`/`threshold_decision` dicts to bound row size, preserve rule-internal privacy, and decouple audit schema from rule-engine evolution.

### Claude's Discretion
- Choose an Alembic migration for the new `incident_events` table and indexes.
- Choose a dedicated `app/persistence/audit.py` module and `app/api/routers/audit.py` router.
- Reuse existing `app.processing.logging.safe_log_extra` for audit-related control logs.
- Keep audit writes synchronous inside the ingress transaction; do not introduce outbox/relay infrastructure in Phase 7.

### Deferred Ideas (OUT OF SCOPE)
- **Phase 9 notification delivery result audit:** Actual plugin delivery outcomes (SMTP exception, retry, final delivery timestamp) belong in a separate notification-result table, not as an update to the append-only `incident_events` row.
- **Phase 10 audit metrics:** Low-cardinality Prometheus metrics for audit writes, read latency, and raw-payload truncation events.
- **Phase 10 audit log safety:** Structured logging for audit write failures and inspection access.
- **Future advanced correlation:** Additional JSONB GIN indexes or full-text search on audit rows beyond the required `incident_ids` containment index, if operator query patterns justify it.
- No incident-scoped alias (`GET /v1/incidents/{id}/events`) in Phase 7.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AUD-01 | Maintainers can migrate the database to include an append-only `incident_events` table with the required traceability columns and indexes. | Database schema section: migration `0003_create_incident_events` with column types, JSONB columns, cursor composite index on `(accepted_at, id)`, GIN index on `incident_ids` for containment, btree indexes on `fingerprint`/`source_id`/`event_type`/`severity`/`host`/`service`/`incident_effect`/`event_timestamp`, and a functional expression index on `decision_summary ->> 'no_dispatch_reason'`. Follows existing `0001`/`0002` migration conventions. |
| AUD-02 | Correlia records one audit row for every accepted normalized event with raw payload, normalized event, decision summary, source ID, fingerprint, severity, host, service, and timestamps. | Implementation approach + ingress transaction refactor: ingress owns one session/transaction for every accepted event, inserts an `incident_events` row covering all accepted paths (problem with incident including below-threshold/replay, recovery with incident, recovery noop, problem no-matching-rule/no-incident). Raw payload redaction + `AuditDecisionSummary` fill the content contract. |
| AUD-03 | Correlia records audit rows without using them to decide incident aggregation, notification thresholds, recovery, or lifecycle transitions. | Implementation approach: managers retain their decision logic unchanged; audit row is inserted after manager returns, read from manager result objects only. Lifecycle expiration sweeps (`expire_stale_batch`) are NOT accepted events and create no audit rows. Read endpoint is read-only and never feeds back into decision state. |
| AUD-04 | Operators can correlate audit rows to incidents when an incident exists and can inspect no-op accepted events when no incident was created or updated. | API surface section: `GET /v1/incident-events` with `incident_id` filter (GIN-indexed JSONB containment on `incident_ids`), `has_incident` filter mapping to `incident_effect`, `incident_effect`/`no_dispatch_reason` filters for no-op inspection. Bounded response projection excludes raw payload. |
</phase_requirements>

## Summary

Phase 7 adds an append-only `incident_events` audit table that records every accepted normalized source event alongside a redacted raw-payload snapshot and a bounded decision summary. The audit trail is purely observational — it records what happened during ingress decisions but never feeds back into incident aggregation, notification thresholds, recovery, or lifecycle transitions. The core implementation challenge is a transaction-ownership refactor: today `IncidentManager.apply_problem` and `LifecycleManager.resolve_for_event` each open their own session and commit internally; Phase 7 moves commit ownership to the ingress `process_payload` caller so that the audit row insertion and the incident/lifecycle write land in a single atomic transaction (D-01, D-02).

The second challenge is coverage. AUD-02 requires "one audit row for **every** accepted normalized event" — not just events that produced an incident upsert. This means the audit write path must handle five distinct decision paths: (1) PROBLEM with incident insert/update (including below-threshold and replay events, which still update the incident row but record `no_dispatch_reason`), (2) RECOVERY that resolves or shrinks one or more incidents, (3) RECOVERY that is a no-op (no matching open incident), (4) PROBLEM with no matching rule (rule engine returns `NoOpDecision`, no incident write), and (5) no rule engine configured at all. The ingress `process_payload` method must own a single session/transaction that wraps all of these paths and inserts the audit row in every case. Operator-mutation paths (acknowledge, manual_close) and background expiration sweeps are NOT accepted source events and must not produce audit rows.

The read surface is a new `GET /v1/incident-events` operator endpoint with cursor pagination on `(accepted_at, id)`, mirroring the existing `list_incidents` pagination contract, plus a rich filter set. Incident correlation uses a JSONB `incident_ids` array with a GIN index for containment lookups. Default responses project bounded metadata only; `raw_payload` and full `normalized_event` are never serialized on the default read path.

**Primary recommendation:** Add the `IncidentEvent` declarative model to `app/persistence/models.py` (following existing convention), create `app/persistence/audit.py` (repository + redactor + HMAC + cursor helpers), `app/domain/audit.py` (`AuditDecisionSummary` + `AuditEventListFilters` + response models), `app/api/routers/audit.py` (read endpoint), migration `0003_create_incident_events`, and refactor `Icinga2DecisionProcessor.process_payload` to own one session per accepted event with a single commit after audit insertion.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Audit row persistence (write) | API / Backend | Database / Storage | Audit rows are written synchronously inside the ingress transaction in the backend processing layer; PostgreSQL stores them durably. |
| Audit row read/query | API / Backend | Database / Storage | Operator read endpoint queries the audit table with filters/pagination; PostgreSQL serves the queries. |
| Raw payload redaction | API / Backend | — | Redaction runs in-process before persistence; no external service. |
| Decision summary construction | API / Backend | — | `AuditDecisionSummary` is built from manager result objects in the processing layer; not derived from audit rows. |
| Incident aggregation decisions | API / Backend | Database / Storage | Unchanged — managers continue to read/write primary incident state. Audit rows never participate. |
| Route classification / auth | API / Backend | — | Middleware classifies `/v1/incident-events` as `operator`; Phase 5 auth/rate-limit inherits. |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SQLAlchemy | 2.0+ (async) | ORM, `AsyncSession`, JSONB columns, GIN indexes | Already the project's persistence layer [VERIFIED: codebase `app/persistence/models.py`, `app/persistence/incidents.py`] |
| Alembic | (pinned in uv.lock) | Database migration for `incident_events` table | Already the project's migration tool [VERIFIED: codebase `migrations/`] |
| Pydantic | v2 (strict) | `AuditDecisionSummary`, filter/response models | Already the project's domain model layer [VERIFIED: codebase `app/domain/incidents.py`] |
| FastAPI | (pinned in uv.lock) | `GET /v1/incident-events` router, query params | Already the project's API layer [VERIFIED: codebase `app/api/routers/`] |
| asyncpg | (pinned in uv.lock) | PostgreSQL async driver | Already the project's DB driver [VERIFIED: `pyproject.toml`] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `hashlib` (stdlib) | Python 3.14 | HMAC-SHA256 of pre-redaction payload | D-07 keyed HMAC [VERIFIED: stdlib] |
| `hmac` (stdlib) | Python 3.14 | HMAC computation with constant-time comparison if needed | D-07 [VERIFIED: stdlib] |
| `base64` / `json` (stdlib) | Python 3.14 | Cursor encoding/decoding | Mirror existing `encode_incident_cursor`/`decode_incident_cursor` [VERIFIED: codebase `app/persistence/incidents.py:436-456`] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| PostgreSQL `gen_random_uuid()` server default for audit row ID | Python `uuid4()` | D-13 locks a **server-generated** audit UUID. `gen_random_uuid()` is built into PG13+ (no extension needed in PG18) and satisfies D-13 directly. The existing `Incident` model uses Python `uuid4()`, but that pattern predates D-13; the audit table must diverge to honor the locked decision. [VERIFIED: PostgreSQL 13+ docs — `gen_random_uuid()` is a built-in SQL function]
| GIN index on `incident_ids` | btree index | btree cannot serve `incident_ids @> ['uuid']` JSONB array containment. GIN is the PostgreSQL-standard index type for JSONB containment queries. [CITED: PostgreSQL docs — JSONB GIN indexes support `@>` operator] |

**Installation:**
```bash
# No new packages required — all dependencies already in pyproject.toml
# SQLAlchemy, Alembic, Pydantic, FastAPI, asyncpg already installed
```

**Version verification:** All recommended libraries are already project dependencies verified in `pyproject.toml`. No new packages are introduced in Phase 7.

## Package Legitimacy Audit

> Phase 7 installs no external packages. All libraries used (SQLAlchemy, Alembic, Pydantic, FastAPI, asyncpg, stdlib `hashlib`/`hmac`/`base64`/`json`/`uuid`) are already project dependencies.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| (none new) | — | — | — | — | — | N/A — no new packages |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

*No new packages are introduced. All libraries are existing project dependencies verified in `pyproject.toml`.*

## Architecture Patterns

### System Architecture Diagram

```
                        HTTP Request
                    POST /v1/icinga2/events
                            │
                            ▼
                ┌───────────────────────┐
                │  Ingress Router        │
                │  (require_ingress_token)│
                └───────────┬───────────┘
                            │
                            ▼
                ┌───────────────────────┐
                │  Icinga2DecisionProcessor│
                │  process_payload()     │
                │                         │
                │  1. Normalize (plugin)  │
                │  2. Enrich (topology)   │
                │  3. Evaluate (rules)    │
                │     │                   │
                │     ├─ PROBLEM ────────┐│
                │     │                  ││
                │     ├─ RECOVERY ──────┐││
                │     │                 │││
                │     └─ NoOpDecision ─┐│││
                │                      ││││
                │  4. Open ONE session  ││││
                │     (all paths)       ││││
                └──────┬───────────────┘│││
                       │                 │││
              ┌────────▼────────┐        │││
              │ IncidentManager │        │││
              │ apply_problem() │        │││
              │ (NO commit)     │        │││
              └────────┬────────┘        │││
                       │                 │││
              ┌────────▼────────┐        │││
              │ LifecycleManager│        │││
              │ resolve_for_event│       │││
              │ (NO commit)     │        │││
              └────────┬────────┘        │││
                       │                 │││
                       ▼◄────────────────┘││
              ┌──────────────────┐        ││
              │ Build             │        ││
              │ AuditDecisionSummary       ││
              │ + redact raw_payload       ││
              │ + HMAC                     ││
              └────────┬─────────┘        ││
                       │                   ││
                       ▼◄──────────────────┘│
              ┌──────────────────┐         │
              │ Insert            │         │
              │ incident_events   │         │
              │ row               │         │
              └────────┬─────────┘         │
                       │                    │
                       ▼◄───────────────────┘
              ┌──────────────────┐
              │ session.commit() │  ← SINGLE commit
              │ (ingress owns)   │
              └────────┬─────────┘
                       │
                       ▼
              ┌──────────────────┐
              │ _submit_         │  ← POST-commit
              │ notifications()  │    (unchanged)
              └──────────────────┘

     READ PATH (separate):

     GET /v1/incident-events
              │
              ▼
     ┌────────────────────┐
     │ Audit Router        │
     │ (require_operator_  │
     │  token)             │
     └────────┬───────────┘
              │
              ▼
     ┌────────────────────┐
     │ list_incident_events│
     │ (filters + cursor)  │
     │ GIN: incident_ids   │
     └────────┬───────────┘
              │
              ▼
     ┌────────────────────┐
     │ Bounded response    │
     │ (no raw_payload,    │
     │  no full normalized)│
     └────────────────────┘
```

A reader can trace the primary write use case: an Icinga2 event enters via the ingress router, the processor normalizes/enriches/evaluates it, opens ONE session, calls the manager (which no longer commits), builds the audit summary + redacted payload + HMAC, inserts the audit row, and commits once. Notifications are submitted post-commit. The read path is a separate operator endpoint with bounded projection.

### Recommended Project Structure
```
app/
├── domain/
│   ├── audit.py              # NEW — AuditDecisionSummary, AuditEventListFilters,
│   │                         #         AuditEventResponse, AuditEventListResponse
│   ├── events.py             # unchanged — NormalizedEvent, EventType, Severity
│   ├── incidents.py          # unchanged
│   └── rules.py              # unchanged — IngressDecisionEnvelope
├── persistence/
│   ├── audit.py              # NEW — AuditEventRepository, redactor, HMAC, cursor helpers
│   ├── incidents.py          # MODIFIED — remove commit from managers' callers
│   ├── models.py             # MODIFIED — add IncidentEvent declarative model (follows
│   │                         #             existing convention: all ORM models in models.py)
│   └── database.py           # unchanged
├── processing/
│   ├── ingress.py            # MODIFIED — own session/transaction, insert audit row,
│   │                         #             single commit for all accepted paths
│   ├── incident_manager.py   # MODIFIED — remove session.commit() from apply_problem
│   ├── lifecycle.py          # MODIFIED — remove session.commit() from resolve_for_event
│   └── lifecycle_worker.py   # unchanged — expiration sweeps create no audit rows
├── api/
│   └── routers/
│       ├── audit.py          # NEW — GET /v1/incident-events, filter dependencies
│       └── incidents.py      # unchanged
├── middleware/
│   └── classification.py     # MODIFIED — add /v1/incident-events → operator
├── config/
│   └── settings.py           # MODIFIED — add audit_raw_payload_max_bytes,
│                             #             audit_raw_payload_hmac_key
└── main.py                   # MODIFIED — register audit router

migrations/
└── versions/
    └── 0003_create_incident_events.py  # NEW

tests/
├── test_domain_audit.py      # NEW — AuditDecisionSummary validation tests
├── test_audit_redaction.py   # NEW — redactor unit tests
├── test_audit_persistence.py # NEW — repository + cursor + GIN lookup tests
├── test_audit_api.py         # NEW — endpoint integration tests
├── test_migrations.py        # MODIFIED — add incident_events schema assertions
└── test_incidents_api.py     # possibly MODIFIED — adjust if commit refactor affects
                               #             existing integration test expectations
```

### Pattern 1: Bounded Strict Pydantic JSONB Model
**What:** A versioned, strict, `extra="forbid"` Pydantic model serialized to a JSONB column, following the `DecisionContext` discipline.
**When to use:** Any JSONB column that stores a structured, bounded contract.
**Example:**
```python
# Source: app/domain/incidents.py:57-75 (DecisionContext pattern)
class AuditDecisionSummary(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    decision_kind: Literal["problem", "recovery", "noop"]
    # ... bounded fields only
```

### Pattern 2: Cursor Pagination on Immutable Tuple
**What:** Base64-encoded JSON cursor containing `(sort_column, id)` for deterministic pagination.
**When to use:** Any paginated listing endpoint on an append-only table.
**Example:**
```python
# Source: app/persistence/incidents.py:436-456 (existing cursor pattern to mirror)
# encode: base64(json({"accepted_at": iso, "id": str(uuid)})).rstrip("=")
# decode: reverse, validate timezone-aware, return dataclass
# query: WHERE (accepted_at, id) < (cursor.accepted_at, cursor.id) ORDER BY ... DESC LIMIT N+1
```

### Pattern 3: Route Class Registration
**What:** Explicit prefix-to-class mapping in `ROUTE_CLASS_PREFIXES` so middleware auth/rate-limit inherits.
**When to use:** Any new `/v1` route.
**Example:**
```python
# Source: app/middleware/classification.py:7-16
ROUTE_CLASS_PREFIXES: Final[tuple[tuple[str, RouteClass], ...]] = (
    ("/v1/icinga2/events", "ingress"),
    ("/v1/incidents", "operator"),
    # ... add:
    ("/v1/incident-events", "operator"),
)
```

### Pattern 4: Operator Router with Security Dependency
**What:** APIRouter with `prefix="/v1/..."` and `dependencies=[Security(require_operator_token)]`.
**When to use:** Any operator-facing read/write endpoint.
**Example:**
```python
# Source: app/api/routers/incidents.py:36
router = APIRouter(
    prefix="/v1/incident-events",
    dependencies=[Security(require_operator_token)],
)
```

### Pattern 5: JSONB Containment Filter
**What:** SQLAlchemy `.contains()` operator on a JSONB column for array-membership filtering.
**When to use:** Filtering on a JSONB array column (e.g., `incident_ids @> ['uuid']`).
**Example:**
```python
# Source: app/persistence/incidents.py:476-477 (existing pattern)
# Incident.affected_hosts.contains([filters.host])
# For audit: IncidentEvent.incident_ids.contains([str(filters.incident_id)])
```

### Anti-Patterns to Avoid
- **Deriving incident correlation from `IngressDecisionEnvelope.incident_id`:** That field collapses `LifecycleResult.incident_ids` to the first ID via the `.incident_id` property. Audit correlation must use `IncidentAggregationResult.incident_id` (single) or `LifecycleResult.incident_ids` (tuple, may be multi) directly, so D-14's multi-incident recovery audit is preserved.
- **Using audit rows as decision state:** Audit rows record what happened; they must never be read by `IncidentManager`, `LifecycleManager`, `RuleEngine`, or `expire_stale_batch`. The audit table is write-once-read-many for operators only.
- **Creating audit rows for expiration sweeps:** `expire_stale_batch` / `expire_stale_incidents` are background lifecycle operations, not "accepted normalized source events." They must NOT produce `incident_events` rows. Only ingress-driven problem/recovery decisions do.
- **Committing inside managers after refactor:** D-02 moves commit ownership to ingress. `IncidentManager.apply_problem` and `LifecycleManager.resolve_for_event` must NOT call `session.commit()`. But `acknowledge`, `manual_close`, and `expire_stale_batch` retain their own commits — only the two ingress-called methods change.
- **Reusing `DecisionContext` notes filter for raw payload redaction:** D-05 explicitly requires a new recursive redactor; the `_FORBIDDEN_NOTE_FRAGMENTS` filter is for bounded key-value notes, not arbitrary JSON payload trees.
- **Arbitrary byte truncation of JSONB:** D-06 requires semantic capping — if the redacted payload exceeds the byte limit, drop the largest string values or truncate nested structures semantically, never cut bytes mid-JSON.
- **Using `decision_kind='noop'` for recovery no-ops:** `RuleEngine.evaluate` returns `NoOpDecision` for ALL recovery events, but ingress still runs lifecycle. Use `decision_kind='recovery'` with `incident_effect='none'` and `recovery_resolution='noop'` for recovery no-ops. Reserve `decision_kind='noop'` for the problem-path no-matching-rule / no-processor case.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSONB array containment query | Custom SQL string | SQLAlchemy `.contains()` on JSONB column | Already used in `list_incidents` for `affected_hosts`; generates correct `@>` operator [VERIFIED: codebase `app/persistence/incidents.py:476-477`] |
| Cursor pagination | Custom cursor format | Mirror `encode_incident_cursor`/`decode_incident_cursor` pattern | Existing proven pattern with timezone validation and base64 encoding [VERIFIED: codebase `app/persistence/incidents.py:436-456`] |
| Bounded Pydantic JSONB model | Custom validation | `ConfigDict(strict=True, extra="forbid")` + `Literal` types | Existing `DecisionContext` discipline [VERIFIED: codebase `app/domain/incidents.py:57-75`] |
| HMAC computation | Custom hash | `hmac.new(key, msg, hashlib.sha256).hexdigest()` | stdlib, constant-time, standard [VERIFIED: Python stdlib] |
| Operator auth on audit endpoint | Custom auth middleware | `Security(require_operator_token)` dependency | Phase 5 pattern [VERIFIED: codebase `app/api/security.py:36-48`] |
| Route classification | Manual middleware check | Add to `ROUTE_CLASS_PREFIXES` | Phase 5 pattern [VERIFIED: codebase `app/middleware/classification.py:7-16`] |
| Safe structured logging | Custom log filtering | `safe_log_extra(**fields)` | Existing safe-key allowlist [VERIFIED: codebase `app/processing/logging.py:61-70`] |

**Key insight:** Every infrastructure piece Phase 7 needs — JSONB columns, cursor pagination, strict Pydantic models, operator auth, route classification, safe logging — already has an established pattern in the codebase. The audit feature is primarily about composition and the transaction refactor, not new infrastructure.

## Common Pitfalls

### Pitfall 1: Audit Rows Not Written for All Accepted Events
**What goes wrong:** Audit rows are only inserted when an incident is upserted, missing recovery-noop and no-matching-rule events (the paths that produce no incident write).
**Why it happens:** The natural implementation inserts the audit row inside `_apply_problem`/`_apply_recovery`, which are only called when a rule matches and a session is opened. No-matching-rule events skip the session entirely.
**How to avoid:** The ingress `process_payload` must own a single session for EVERY accepted event (after normalization succeeds), insert the audit row in all five decision paths, and commit once. The audit insertion happens after the manager call returns (or after the no-op decision is determined), not inside the manager.
**Warning signs:** Integration tests that only verify audit rows for incident-producing events. A test suite must explicitly cover all five paths.

### Pitfall 2: Commit Refactor Breaks Operator Mutation Paths
**What goes wrong:** Removing `session.commit()` from `IncidentManager` or `LifecycleManager` broadly breaks `acknowledge`, `manual_close`, and `expire_stale_batch` which also use those classes.
**Why it happens:** `LifecycleManager` has `acknowledge`, `manual_close`, and `resolve_for_event` methods, all of which call `self._session.commit()`. A blanket removal breaks the operator-mutation and expiration paths.
**How to avoid:** Scope the commit removal narrowly: only `IncidentManager.apply_problem` and `LifecycleManager.resolve_for_event` lose their internal commit. `LifecycleManager.acknowledge`, `LifecycleManager.manual_close`, and `expire_stale_batch` retain their own commits. The refactor is ingress-specific, not class-wide.
**Warning signs:** Existing `test_incidents_api.py` ack/close tests fail after refactor. Run the full incidents API test suite after the refactor.

### Pitfall 3: Incident ID Collapsing on Multi-Incident Recovery
**What goes wrong:** Recovery events that touch multiple incidents (host recovery resolving multiple service incidents) only record the first incident ID in the audit row.
**Why it happens:** `IngressDecisionEnvelope.incident_id` uses `LifecycleResult.incident_id` which returns `incident_ids[0]` — only the first. If audit correlation is built from the envelope, multi-incident recovery is lost.
**How to avoid:** Build `AuditDecisionSummary.incident_ids` from `LifecycleResult.incident_ids` (the full tuple) for recovery, and from `IncidentAggregationResult.incident_id` (wrapped in a single-element tuple) for problem. Never read `IngressDecisionEnvelope.incident_id` for audit correlation.
**Warning signs:** Recovery audit tests that only check a single incident ID. Must test multi-incident recovery (host recovery with multiple open service incidents).

### Pitfall 4: HMAC Key Missing or Reused from Auth Tokens
**What goes wrong:** The D-07 HMAC is either skipped (key is `None`) or computed with an operator/ingress auth token, creating a security dependency between audit integrity and auth.
**Why it happens:** `Settings` has no audit-specific secret today; the implementer reaches for an existing token or makes the key optional.
**How to avoid:** Add a dedicated `audit_raw_payload_hmac_key: SecretStr` to `Settings`. Treat it as required when audit is active — fail fast with a `model_validator` if the key is missing or empty (mirroring the `_require_security_tokens_when_enabled` pattern). Do NOT reuse `operator_api_token` or `ingress_api_token`.
**Warning signs:** Tests that pass with `None` HMAC key. The settings validator must reject empty/missing HMAC keys.

### Pitfall 5: GIN Index Omitted for incident_id Filter
**What goes wrong:** The `incident_id` filter (D-11) does a full table scan on `incident_ids` JSONB array because no GIN index exists.
**Why it happens:** The implementer adds btree indexes on scalar columns but forgets that JSONB array containment (`@>`) needs a GIN index.
**How to avoid:** Create a GIN index on `incident_ids` in the migration: `op.create_index("ix_incident_events_incident_ids_gin", "incident_events", ["incident_ids"], postgresql_using="gin")`. The existing `affected_hosts`/`affected_services` columns have no GIN index, but those are lower-traffic filters; `incident_id` is a first-class correlation filter per D-11.
**Warning signs:** Slow audit listing when filtering by `incident_id` on a large table. Migration test should verify the GIN index exists.

### Pitfall 6: Raw Payload Byte Truncation Corrupts JSONB
**What goes wrong:** The size cap cuts bytes from the middle of a JSON string, producing invalid JSON that fails to insert or read.
**Why it happens:** A naive `payload_bytes[:max_bytes]` approach doesn't respect JSON structure.
**How to avoid:** Semantic capping: serialize the redacted payload to a Python dict, then if the JSON byte length exceeds the cap, progressively drop or truncate the largest string values (or remove non-essential nested keys) and re-serialize until under the limit. Set `truncated=True` and record `original_byte_length` vs `stored_byte_length`.
**Warning signs:** `json.dumps` errors on stored payloads. Test with an oversized payload containing long strings.

### Pitfall 7: Recovery No-Op vs Problem No-Op Confused in decision_kind
**What goes wrong:** Recovery events that resolve nothing are labeled `decision_kind='noop'` instead of `'recovery'`, conflating them with problem-path no-matching-rule events.
**Why it happens:** `RuleEngine.evaluate` returns `NoOpDecision` for all RECOVERY events (recovery events don't match problem rules). The implementer maps `NoOpDecision` → `decision_kind='noop'` without checking event type.
**How to avoid:** `decision_kind` is derived from the decision path, not from `event.event_type` alone: a PROBLEM event that matched a rule and produced an incident write is `"problem"`; a RECOVERY event (which always gets `NoOpDecision` from the rule engine but still runs lifecycle) is `"recovery"` with `recovery_resolution` set; a PROBLEM or RECOVERY event where the rule engine returns `NoOpDecision` AND no lifecycle runs is `"noop"`. Specifically: no-matching-rule PROBLEM → `decision_kind='noop'` with `incident_effect='none'`; recovery-noop (lifecycle ran, resolved nothing) → `decision_kind='recovery'` with `recovery_resolution='noop'`; no-rule-engine at all (`self._rule_engine is None`) → `decision_kind='noop'`. The field-derivation table below is the authoritative mapping.
**Warning signs:** Audit rows for recovery events showing `decision_kind='noop'`. Test both recovery-noop and problem-no-rule paths.

## Code Examples

### AuditDecisionSummary Model (D-17, D-18, D-19)
```python
# Source: pattern from app/domain/incidents.py:57-75 (DecisionContext)
# Source: field requirements from CONTEXT.md D-18

from __future__ import annotations
from typing import Annotated, Literal
from uuid import UUID
from pydantic import BaseModel, ConfigDict, Field

_BoundedStr256 = Annotated[str, Field(min_length=1, max_length=256)]
_BoundedStr128 = Annotated[str, Field(min_length=1, max_length=128)]
_IncidentIdsTuple = Annotated[tuple[str, ...], Field(max_length=20)]

class AuditDecisionSummary(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    decision_kind: Literal["problem", "recovery", "noop"]
    incident_effect: Literal["none", "inserted", "updated", "resolved", "affected_set_shrunk"]
    rule_name: _BoundedStr256 | None = None
    group_key: _BoundedStr256 | None = None
    incident_ids: _IncidentIdsTuple = ()
    affected_incident_count: int = Field(default=0, ge=0)
    incident_ids_truncated: bool = False
    decision_reason: _BoundedStr256 | None = None
    no_dispatch_reason: _BoundedStr128 | None = None
    notification_intent: Literal["dispatch_planned", "no_dispatch"]
    counted_count: int | None = Field(default=None, ge=0)
    threshold_count: int | None = Field(default=None, ge=1)
    threshold_crossed: bool | None = None
    replay: bool | None = None
    first_threshold_transition: bool | None = None
    recovery_resolution: Literal["noop", "affected_set_shrunk", "resolved"] | None = None
    affected_object_removed: bool | None = None
```

**Field derivation map** (from manager result objects, NOT from `IngressDecisionEnvelope`):

| Field | PROBLEM path | RECOVERY path | NoOp/no-rule path |
|-------|-------------|---------------|-------------------|
| `decision_kind` | `"problem"` | `"recovery"` | `"noop"` |
| `incident_effect` | `IncidentAggregationResult.effect` (`"inserted"`/`"updated"`) — below-threshold/replay events still update the incident, so effect is always `inserted`/`updated`, never `"none"` | `LifecycleResult.effect` mapped: `"resolved"`/`"affected_set_shrunk"` or `"none"` if noop | `"none"` |
| `incident_ids` | `(str(IncidentAggregationResult.incident_id),)` or `()` | `tuple(str(id) for id in LifecycleResult.incident_ids)` or `()` | `()` |
| `rule_name` | `RuleDecision.rule_name` | `None` (recovery has no rule) | `None` |
| `group_key` | `RuleDecision.group_key` | `None` | `None` |
| `no_dispatch_reason` | `IncidentAggregationResult.no_dispatch_reason` | `None` | `None` |
| `notification_intent` | `"dispatch_planned"` if `first_threshold_transition` else `"no_dispatch"` | `"no_dispatch"` | `"no_dispatch"` |
| `recovery_resolution` | `None` | `LifecycleResult.effect` if in `("noop","affected_set_shrunk","resolved")` else `None` | `None` |
| `counted_count` | `IncidentAggregationResult.counted_count` | `None` | `None` |
| `threshold_count` | from `RuleDecision.threshold_decision.threshold` | `None` | `None` |
| `threshold_crossed` | `IncidentAggregationResult.threshold_crossed` | `None` | `None` |
| `replay` | `IncidentAggregationResult.replay` | `None` | `None` |
| `first_threshold_transition` | `IncidentAggregationResult.first_threshold_transition` | `None` | `None` |
| `affected_object_removed` | `None` | `LifecycleResult.affected_object_removed` | `None` |

**Note on `incident_ids_truncated`:** Set to `True` when `len(incident_ids)` would exceed 20 but is capped. For problem events this is always `False` (single incident). For recovery events with >20 resolved incidents, truncate to 20 and set `True`. `affected_incident_count` records the uncapped count.

### IncidentEvent SQLAlchemy Model
```python
# Source: pattern from app/persistence/models.py:21-57 (Incident model)
from __future__ import annotations
from datetime import datetime
from typing import Any
from uuid import UUID
import sqlalchemy as sa
from sqlalchemy import DateTime, Integer, String, Text, Boolean, func
from sqlalchemy.dialects.postgresql import JSONB, UUID as PG_UUID
from sqlalchemy.orm import Mapped, mapped_column
from app.persistence.models import Base

class IncidentEvent(Base):
    __tablename__ = "incident_events"

    id: Mapped[UUID] = mapped_column(PG_UUID(as_uuid=True), primary_key=True, server_default=sa.func.gen_random_uuid())
    accepted_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=sa.func.now()
    )
    event_timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    source_id: Mapped[str] = mapped_column(String, nullable=False)
    fingerprint: Mapped[str] = mapped_column(String, nullable=False)
    event_type: Mapped[str] = mapped_column(String, nullable=False)
    severity: Mapped[str] = mapped_column(String, nullable=False)
    host: Mapped[str] = mapped_column(String, nullable=False)
    service: Mapped[str | None] = mapped_column(String, nullable=True)
    incident_ids: Mapped[list[str]] = mapped_column(JSONB, nullable=False)
    incident_effect: Mapped[str] = mapped_column(String, nullable=False)
    decision_summary: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    normalized_event: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    raw_payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    raw_payload_original_byte_length: Mapped[int] = mapped_column(Integer, nullable=False)
    raw_payload_stored_byte_length: Mapped[int] = mapped_column(Integer, nullable=False)
    raw_payload_truncated: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    redaction_version: Mapped[int] = mapped_column(
        Integer, nullable=False, default=1, server_default="1"
    )
    redacted_path_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    raw_payload_hmac: Mapped[str] = mapped_column(String, nullable=False)
```

### Alembic Migration (0003)
```python
# Source: pattern from migrations/versions/0001_create_incidents.py
"""create incident_events

Revision ID: 0003_create_incident_events
Revises: 0002_add_threshold_state
Create Date: 2026-06-18 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0003_create_incident_events"
down_revision: Union[str, Sequence[str], None] = "0002_add_threshold_state"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "incident_events",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("event_timestamp", sa.DateTime(timezone=True), nullable=False),
        sa.Column("source_id", sa.String(), nullable=False),
        sa.Column("fingerprint", sa.String(), nullable=False),
        sa.Column("event_type", sa.String(), nullable=False),
        sa.Column("severity", sa.String(), nullable=False),
        sa.Column("host", sa.String(), nullable=False),
        sa.Column("service", sa.String(), nullable=True),
        sa.Column("incident_ids", postgresql.JSONB(), nullable=False),
        sa.Column("incident_effect", sa.String(), nullable=False),
        sa.Column("decision_summary", postgresql.JSONB(), nullable=False),
        sa.Column("normalized_event", postgresql.JSONB(), nullable=False),
        sa.Column("raw_payload", postgresql.JSONB(), nullable=False),
        sa.Column("raw_payload_original_byte_length", sa.Integer(), nullable=False),
        sa.Column("raw_payload_stored_byte_length", sa.Integer(), nullable=False),
        sa.Column("raw_payload_truncated", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("redaction_version", sa.Integer(), nullable=False, server_default=sa.text("1")),
        sa.Column("redacted_path_count", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("raw_payload_hmac", sa.String(), nullable=False),
        sa.CheckConstraint(
            "event_type IN ('PROBLEM', 'RECOVERY')",
            name="ck_incident_events_event_type",
        ),
        sa.CheckConstraint(
            "severity IN ('OK', 'WARNING', 'UNKNOWN', 'CRITICAL')",
            name="ck_incident_events_severity",
        ),
        sa.CheckConstraint(
            "incident_effect IN ('none', 'inserted', 'updated', 'resolved', 'affected_set_shrunk')",
            name="ck_incident_events_incident_effect",
        ),
    )
    # Cursor pagination index (immutable tuple ordering)
    op.create_index(
        "ix_incident_events_accepted_at_id",
        "incident_events",
        ["accepted_at", "id"],
    )
    # GIN index for incident_id containment filter (D-11, D-14)
    op.create_index(
        "ix_incident_events_incident_ids_gin",
        "incident_events",
        ["incident_ids"],
        postgresql_using="gin",
    )
    # Btree indexes for high-cardinality scalar filters
    op.create_index("ix_incident_events_fingerprint", "incident_events", ["fingerprint"])
    op.create_index("ix_incident_events_source_id", "incident_events", ["source_id"])
    op.create_index("ix_incident_events_event_type", "incident_events", ["event_type"])
    op.create_index("ix_incident_events_severity", "incident_events", ["severity"])
    op.create_index("ix_incident_events_host", "incident_events", ["host"])
    op.create_index("ix_incident_events_service", "incident_events", ["service"])
    # incident_effect covers the has_incident filter (D-11/D-12)
    op.create_index("ix_incident_events_incident_effect", "incident_events", ["incident_effect"])
    # event_timestamp range filters (D-11: event_timestamp_since/until)
    op.create_index("ix_incident_events_event_timestamp", "incident_events", ["event_timestamp"])
    # no_dispatch_reason filter: expression index on the JSONB decision_summary field.
    # no_dispatch_reason lives inside decision_summary JSONB, not as a top-level column,
    # so a functional index on the extracted value is needed for D-11's filter.
    op.create_index(
        "ix_incident_events_no_dispatch_reason",
        "incident_events",
        [sa.text("(decision_summary ->> 'no_dispatch_reason')")],
    )


def downgrade() -> None:
    op.drop_index("ix_incident_events_no_dispatch_reason", table_name="incident_events")
    op.drop_index("ix_incident_events_event_timestamp", table_name="incident_events")
    op.drop_index("ix_incident_events_incident_effect", table_name="incident_events")
    op.drop_index("ix_incident_events_service", table_name="incident_events")
    op.drop_index("ix_incident_events_host", table_name="incident_events")
    op.drop_index("ix_incident_events_severity", table_name="incident_events")
    op.drop_index("ix_incident_events_event_type", table_name="incident_events")
    op.drop_index("ix_incident_events_source_id", table_name="incident_events")
    op.drop_index("ix_incident_events_fingerprint", table_name="incident_events")
    op.drop_index("ix_incident_events_incident_ids_gin", table_name="incident_events")
    op.drop_index("ix_incident_events_accepted_at_id", table_name="incident_events")
    op.drop_table("incident_events")
```

### Cursor Helpers (mirroring existing pattern)
```python
# Source: app/persistence/incidents.py:436-456
import base64, json
from dataclasses import dataclass
from datetime import datetime
from uuid import UUID

@dataclass(frozen=True, slots=True)
class AuditEventCursor:
    accepted_at: datetime
    id: UUID

def encode_audit_cursor(cursor: AuditEventCursor) -> str:
    payload = {
        "accepted_at": cursor.accepted_at.isoformat(),
        "id": str(cursor.id),
    }
    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode()
    ).decode()
    return encoded.rstrip("=")

def decode_audit_cursor(value: str) -> AuditEventCursor:
    try:
        padded = value + ("=" * (-len(value) % 4))
        payload = json.loads(base64.urlsafe_b64decode(padded.encode()).decode())
        accepted_at = datetime.fromisoformat(payload["accepted_at"])
        if accepted_at.tzinfo is None or accepted_at.utcoffset() is None:
            raise ValueError("cursor timestamp must be timezone-aware")
        return AuditEventCursor(accepted_at=accepted_at, id=UUID(payload["id"]))
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise ValueError("invalid audit event cursor") from exc
```

### Ingress Transaction Refactor (process_payload)
```python
# Source: app/processing/ingress.py:54-207 (current process_payload)
# Key change: open ONE session for every accepted event, call managers
# without commit, insert audit row, commit once.

async def process_payload(self, payload):
    # ... normalization, enrichment, rule evaluation (unchanged) ...

    incident_result = None
    lifecycle_result = None
    sessionmaker = self._sessionmaker

    if self._rule_engine is not None:
        decision = await self._rule_engine.evaluate(event)
        # ... rule matching, metrics (unchanged) ...
        if isinstance(decision, RuleDecision) and event.event_type is EventType.PROBLEM:
            if sessionmaker is not None:
                # CHANGED: pass session to manager, no internal commit
                async with sessionmaker() as session:
                    manager = IncidentManager(session, ...)
                    incident_result = await manager.apply_problem(event, decision)
                    # insert audit row here
                    await session.commit()
        elif event.event_type is EventType.RECOVERY and sessionmaker is not None:
            async with sessionmaker() as session:
                manager = LifecycleManager(session)
                lifecycle_result = await manager.resolve_for_event(event)
                # insert audit row here
                await session.commit()
        else:
            # NoOpDecision or no sessionmaker — still need audit row
            if sessionmaker is not None:
                async with sessionmaker() as session:
                    # insert audit row (no incident write)
                    await session.commit()

    # Post-commit: submit notifications (unchanged)
    if incident_result is not None:
        await self._submit_notifications(incident_result, decision)
    # ... build and return envelope (unchanged) ...
```

**Critical:** The `async with sessionmaker() as session` block must wrap ALL accepted paths — problem, recovery, and no-op. The audit row is inserted inside the session in every case. The `_submit_notifications` call happens AFTER `session.commit()` (post-commit, D-03). This means `_submit_notifications` must move out of `IncidentManager.apply_problem` into the ingress layer, OR `apply_problem` must return its notification intent without submitting, and ingress submits post-commit. The cleaner approach: `apply_problem` returns `IncidentAggregationResult` (including `first_threshold_transition` and `no_dispatch_reason`) without calling `_submit_notifications`; ingress calls `_submit_notifications` after commit.

**Note on `_record_notification`:** Currently `_submit_notifications` calls `_record_notification` which calls `session.commit()` internally. After the refactor, notification sequencing splits into two phases: (1) **pre-commit** — record only deterministic preflight failures (missing plugin, no task runner configured) in the ingress session, since these are known before the commit; (2) **post-commit** — submit the actual `task_runner.submit` job. If `task_runner.submit` raises post-commit, that failure is NOT recorded in the audit row — D-03 locks audit to notification **intent** only (`notification_intent = dispatch_planned | no_dispatch`), not actual plugin delivery results. A post-commit submit exception is logged via `safe_log_extra` and surfaced in the `IngressDecisionEnvelope`, but it does not update the audit row or the incident's notification-result records. This preserves atomicity of preflight records while keeping task submission non-blocking and the audit row immutable after commit.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Managers commit their own sessions | Ingress owns the transaction and commits once | Phase 7 (D-02) | Audit row and incident write are atomic; crash-safety for AUD-02 |
| No audit trail | Append-only `incident_events` table | Phase 7 | Every accepted event is traceable without being decision state |
| Raw payload not retained | Redacted, size-capped payload snapshot | Phase 7 | Operator traceability without secret leakage or unbounded storage |

**Deprecated/outdated:**
- `IncidentManager.apply_problem` calling `self._session.commit()` — superseded by ingress commit ownership.
- `LifecycleManager.resolve_for_event` calling `self._session.commit()` — superseded by ingress commit ownership.
- (These are NOT deprecated for `acknowledge`/`manual_close`/`expire_stale_batch` — only for the ingress-called methods.)

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `gen_random_uuid()` is built into PostgreSQL 13+ without an extension | Database schema | Low — project uses PG18 (testcontainers `postgres:18-alpine`). D-13 locks a server-generated UUID, so the audit table uses `server_default=sa.func.gen_random_uuid()` in the model and `server_default=sa.text("gen_random_uuid()")` in the migration. This diverges from the existing `Incident.id` Python-`uuid4()` pattern, which is intentional per D-13. [VERIFIED: PostgreSQL 13+ release notes] |
| A2 | GIN index on JSONB array supports `@>` containment operator efficiently | Database schema | Low — this is well-established PostgreSQL behavior. The codebase already uses JSONB containment in `list_incidents` (just without a GIN index on those columns). |
| A3 | `_submit_notifications` can be split into a pre-commit preflight phase (missing plugin, no runner) and a post-commit submit phase without breaking the notification result recording pattern | Ingress transaction refactor | Medium — the current `_record_notification` calls `session.commit()` internally. After refactor, only deterministic preflight failures are recorded pre-commit in the ingress session; post-commit `task_runner.submit` failures are logged and surfaced in the envelope but NOT recorded in the audit row per D-03 (audit records intent only). Requires careful sequencing. |
| A4 | The `Icinga2WebhookPayload` Pydantic model (the accepted source payload) can be serialized to a dict for redaction and JSONB storage | Raw payload redaction | Low — Pydantic v2 models have `model_dump(mode="json")`. The payload is already parsed by the input plugin. |
| A5 | `CORRELIA_AUDIT_RAW_PAYLOAD_MAX_BYTES` default of 64 KiB is sufficient for Icinga2 webhook payloads | Raw payload redaction | Low — Icinga2 payloads are typically small JSON. The cap is configurable. |

**If this table is empty:** All claims in this research were verified or cited — no user confirmation needed.

## Open Questions

1. **HMAC key provisioning in production**
   - What we know: D-07 requires a keyed HMAC. `Settings` has no audit-specific secret. We recommend a new `audit_raw_payload_hmac_key: SecretStr` that is required (fail-fast).
   - What's unclear: Whether the operator wants the key to be required unconditionally or only when audit writes are active (there's no "audit enabled" toggle in the current decisions — audit is always on for accepted events). Given D-01/D-02, audit is always active, so the key should be unconditionally required.
   - Recommendation: Add `audit_raw_payload_hmac_key: SecretStr` as a required field with a `model_validator` that rejects empty/missing values (same pattern as `_require_security_tokens_when_enabled`). Add `CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY` to `_SETTINGS_ENV_KEYS` in `tests/conftest.py`.

2. **`_submit_notifications` relocation and notification result recording**
   - What we know: Currently `_submit_notifications` lives in `IncidentManager` and is called after `session.commit()`. It records notification results via `_record_notification` which commits again.
   - What's unclear: After the refactor, how are notification results recorded when `task_runner.submit` happens post-commit?
   - Recommendation: Split into two phases. **Pre-commit** (in the ingress session, before the single commit): record only deterministic preflight failures — missing plugin (`category="missing_plugin"`), no task runner configured (`category="dispatch_failed"` with message "notification task runner is unavailable"). These are known before commit. **Post-commit**: submit the actual `task_runner.submit` job. If the submit call raises post-commit, that exception is NOT recorded in the audit row (D-03 locks audit to intent only) — it is logged via `safe_log_extra` and surfaced in `IngressDecisionEnvelope.notification_failed`. The `_submit_notifications` method moves to ingress: a pre-commit portion that takes a session and records preflight results, and a post-commit portion that submits to the task runner without committing.

3. **Audit row for events when `sessionmaker is None`**
   - What we know: `process_payload` has paths where `self._sessionmaker is None` (e.g., test/non-DB mode). In these cases, no incident write happens and no session is available for audit insertion.
   - What's unclear: Should audit rows be skipped when there's no sessionmaker, or should the processor require a sessionmaker for audit?
   - Recommendation: If `sessionmaker is None`, skip audit insertion (no DB available). This is consistent with the current behavior where no incident persistence happens without a sessionmaker. Document this in the implementation. The `IngressDecisionEnvelope` already handles the no-DB case.

4. **`incident_effect` for problem events that are below-threshold but still update the incident row**
   - What we know: `IncidentAggregationResult.effect` is `"inserted"` or `"updated"` — even below-threshold events update the incident (increment event count, update window state). So `incident_effect` for a below-threshold event is `"updated"`, not `"none"`.
   - What's unclear: Does D-12's `has_incident=false` → `incident_effect='none'` correctly exclude below-threshold events? Yes — below-threshold events DO update the incident, so `incident_effect` is `"updated"` and `has_incident` is `true`. The `no_dispatch_reason` field distinguishes them.
   - Recommendation: `incident_effect` comes directly from `IncidentAggregationResult.effect`. `has_incident` is `true` when `incident_effect != "none"`. No special-casing needed.

5. **Append-only enforcement**
   - What we know: AUD-01 says "append-only." PostgreSQL doesn't have a native append-only constraint.
   - What's unclear: Should we add a trigger to prevent UPDATE/DELETE on `incident_events`, or rely on application discipline?
   - Recommendation: Application discipline for Phase 7 (the repository only has an `insert` method, no update/delete). A DB-level trigger can be deferred to a future hardening phase. Note this as a risk.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| PostgreSQL 18 | Audit table, JSONB, GIN indexes | ✓ | 18-alpine (testcontainers) | — |
| Alembic | Migration `0003` | ✓ | pinned in uv.lock | — |
| SQLAlchemy 2.0+ | ORM, JSONB, GIN | ✓ | pinned in uv.lock | — |
| Python 3.14+ | stdlib `hmac`, `hashlib`, `uuid` | ✓ | 3.14 (pyproject) | — |

**Missing dependencies with no fallback:** none
**Missing dependencies with fallback:** none

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | `require_operator_token` on `/v1/incident-events` (Phase 5, reused) |
| V3 Session Management | no | Stateless API, no sessions |
| V4 Access Control | yes | Route class `operator` classification; operator token required for read; ingress token for write path (unchanged) |
| V5 Input Validation | yes | Pydantic v2 strict models (`AuditDecisionSummary`, `AuditEventListFilters`); query param bounds (`Annotated[int, Query(ge=1, le=200)]`) |
| V6 Cryptography | yes | HMAC-SHA256 with dedicated `SecretStr` key (D-07); stdlib `hmac` module — never hand-roll |

### Known Threat Patterns for Audit Trail

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Secret leakage via raw payload | Information Disclosure | Recursive redactor strips secrets before persistence (D-05); HMAC computed on pre-redaction payload only (not stored with secrets); default read never exposes `raw_payload` (D-08, D-15) |
| Audit row tampering | Tampering | Append-only table enforced by insert-only repository API (no update/delete methods); DB-level UPDATE/DELETE prevention trigger deferred to future hardening. The pre-redaction HMAC (D-07) does NOT self-detect changes to the stored redacted payload — it supports later verification/correlation against a candidate original payload held externally, since only the redacted/capped snapshot is stored |
| HMAC key reuse from auth tokens | Spoofing / Info Disclosure | Dedicated `audit_raw_payload_hmac_key: SecretStr` distinct from `operator_api_token`/`ingress_api_token`; fail-fast validator |
| Unbounded payload storage | Denial of Service | Configurable size cap (D-06, default 64 KiB); semantic truncation, not byte truncation |
| Unauthorized audit read | Information Disclosure | `require_operator_token` security dependency; route class `operator` classification (D-16) |
| Audit row influences decisions | Elevation of Privilege | Audit rows never read by managers, rule engine, or lifecycle workers; read endpoint is operator-only and returns bounded projection |

## Sources

### Primary (HIGH confidence)
- `app/persistence/incidents.py:436-542` — cursor pagination implementation (`encode_incident_cursor`, `decode_incident_cursor`, `list_incidents` with filter/cursor/offset logic) [VERIFIED: codebase]
- `app/persistence/incidents.py:476-477` — JSONB containment filter pattern (`affected_hosts.contains([host])`) [VERIFIED: codebase]
- `app/domain/incidents.py:57-75` — `DecisionContext` bounded Pydantic model pattern [VERIFIED: codebase]
- `app/processing/ingress.py:54-207` — `process_payload` full flow with all five decision paths [VERIFIED: codebase]
- `app/processing/incident_manager.py:69-167` — `apply_problem` with internal `session.commit()` at line 136 [VERIFIED: codebase]
- `app/processing/lifecycle.py:58-91` — `resolve_for_event` with internal `session.commit()` at line 79 [VERIFIED: codebase]
- `app/processing/lifecycle.py:93-140` — `acknowledge`/`manual_close` with their own commits (must NOT change) [VERIFIED: codebase]
- `app/persistence/models.py:21-57` — `Incident` SQLAlchemy model conventions [VERIFIED: codebase]
- `migrations/versions/0001_create_incidents.py` — Alembic migration conventions (table, columns, check constraints, indexes) [VERIFIED: codebase]
- `migrations/versions/0002_add_threshold_state.py` — Alembic add-column migration conventions [VERIFIED: codebase]
- `app/middleware/classification.py:7-16` — route class registration pattern [VERIFIED: codebase]
- `app/api/routers/incidents.py:36,84-105` — operator router with security dependency + filter dependency pattern [VERIFIED: codebase]
- `app/api/security.py:36-48` — `require_operator_token` pattern [VERIFIED: codebase]
- `app/config/settings.py:8-83` — strict Pydantic settings with `model_validator` fail-fast pattern [VERIFIED: codebase]
- `app/processing/lifecycle.py:34-51` — `LifecycleResult` with `incident_ids` tuple and `incident_id` property (collapses to first) [VERIFIED: codebase]
- `app/processing/incident_manager.py:38-53` — `IncidentAggregationResult` dataclass with `incident_id` (single) [VERIFIED: codebase]
- `app/domain/rules.py:87-92,118-149` — `NoOpDecision` and `IngressDecisionEnvelope` [VERIFIED: codebase]
- `app/processing/logging.py:7-70` — `safe_log_extra` and `SAFE_LOG_KEYS` [VERIFIED: codebase]
- `app/main.py:116-267` — app factory, lifespan, router registration [VERIFIED: codebase]
- `.planning/phases/07-incident-event-audit-trail/07-CONTEXT.md` — all locked decisions D-01 through D-19 [VERIFIED: context doc]
- `.planning/REQUIREMENTS.md:30-33` — AUD-01 through AUD-04 [VERIFIED: requirements doc]

### Secondary (MEDIUM confidence)
- PostgreSQL JSONB GIN index for `@>` containment — well-established PostgreSQL behavior [CITED: PostgreSQL documentation — GIN indexes on `jsonb` support containment operators]

### Tertiary (LOW confidence)
- None — all findings are grounded in the codebase or established PostgreSQL behavior.

## Required Sections

The assignment required 10 explicit sections. Each is addressed below with a concise summary and a cross-reference to the detailed treatment elsewhere in this document.

### 1. Phase scope summary
- **In scope:** Append-only `incident_events` audit table recording every accepted normalized source event; transaction-ownership refactor (ingress commits once); redacted raw-payload snapshot with HMAC metadata; `GET /v1/incident-events` operator read endpoint with filters and cursor pagination; route classification as `operator`.
- **Out of scope (Deferred Ideas):** Notification delivery result audit (Phase 9), audit metrics (Phase 10), audit log safety (Phase 10), additional JSONB GIN/full-text indexes beyond required `incident_ids` containment, incident-scoped alias endpoint.
- **Detailed coverage:** `## Summary` + `<user_constraints>` Deferred Ideas.

### 2. Implementation approach
- **Write path:** Ingress `process_payload` opens one session per accepted event, calls managers (no internal commit), builds `AuditDecisionSummary` + redacted payload + HMAC, inserts audit row, commits once. Notifications submitted post-commit.
- **Read path:** Separate `GET /v1/incident-events` operator endpoint with cursor pagination, JSONB containment on `incident_ids`, bounded response projection.
- **Raw-payload redaction:** Recursive redactor strips secrets; semantic size capping; HMAC on pre-redaction canonical payload.
- **Detailed coverage:** `## Architectural Responsibility Map` + `### System Architecture Diagram` + `### Ingress Transaction Refactor` code example.

### 3. Database schema
- **Table:** `incident_events` with UUID PK (server-generated `gen_random_uuid()`), `accepted_at`, `event_timestamp`, scalar correlation columns, JSONB `incident_ids`/`decision_summary`/`normalized_event`/`raw_payload`, NOT NULL on all required columns, server defaults only for fixed fields (`redaction_version=1`, `redacted_path_count=0`, `raw_payload_truncated=false`).
- **Indexes:** Cursor composite on `(accepted_at, id)`; GIN on `incident_ids`; btree on `fingerprint`/`source_id`/`event_type`/`severity`/`host`/`service`/`incident_effect`/`event_timestamp`; functional expression index on `decision_summary ->> 'no_dispatch_reason'`.
- **Migration:** `0003_create_incident_events` following `0001`/`0002` conventions with matching upgrade/downgrade.
- **Detailed coverage:** `### IncidentEvent SQLAlchemy Model` + `### Alembic Migration (0003)` + `### Alternatives Considered`.

### 4. Decision summary model
- **Model:** `AuditDecisionSummary` with `ConfigDict(strict=True, extra="forbid")`, `schema_version: Literal[1]`, all D-18 required fields, D-19 exclusions (`counted_fingerprints`, `enrichment_diagnostics`, full `rule_decision`/`threshold_decision` dicts).
- **Derivation:** Field-by-field map from `IncidentAggregationResult` (problem) and `LifecycleResult` (recovery) — never from `IngressDecisionEnvelope.incident_id`.
- **Detailed coverage:** `### AuditDecisionSummary Model (D-17, D-18, D-19)` including full model sketch and derivation table.

### 5. Code changes
- **NEW files:** `app/domain/audit.py` (domain models), `app/persistence/audit.py` (repository/redactor/HMAC/cursors), `app/api/routers/audit.py` (read endpoint), `migrations/versions/0003_create_incident_events.py`, test files (`test_domain_audit.py`, `test_audit_redaction.py`, `test_audit_persistence.py`, `test_audit_api.py`).
- **MODIFIED files:** `app/persistence/models.py` (add `IncidentEvent`), `app/processing/ingress.py` (own session/commit), `app/processing/incident_manager.py` (remove commit from `apply_problem`), `app/processing/lifecycle.py` (remove commit from `resolve_for_event`), `app/middleware/classification.py` (add route class), `app/config/settings.py` (add audit settings), `app/main.py` (register router), `tests/test_migrations.py` (schema assertions).
- **Detailed coverage:** `### Recommended Project Structure` + `**Primary recommendation**`.

### 6. API surface
- **Endpoint:** `GET /v1/incident-events` with `require_operator_token` security dependency, route class `operator`.
- **Filters:** `incident_id` (GIN containment), `has_incident`, `fingerprint`, `source_id`, `event_type`, `incident_effect`, `no_dispatch_reason`, `severity`, `host`, `service`, `accepted_since`/`accepted_until`, `event_timestamp_since`/`event_timestamp_until`.
- **Pagination:** Cursor-first on `(accepted_at, id)`, mirroring `list_incidents` contract; offset/`total` diagnostic-only.
- **Response:** Bounded projection — `raw_payload` and full `normalized_event` never serialized on default read.
- **Detailed coverage:** `### Pattern 2` through `### Pattern 5` + `### Cursor Helpers` + `<phase_requirements>` AUD-04 + `<user_constraints>` D-09 through D-16.

### 7. Ingress transaction refactor
- **Commit ownership moves** from `IncidentManager.apply_problem` (line 136) and `LifecycleManager.resolve_for_event` (line 79) to ingress `process_payload`. Only these two methods lose their internal commit.
- **Narrow scope:** `acknowledge`, `manual_close`, and `expire_stale_batch` retain their own commits — the refactor is ingress-specific.
- **Notification sequencing:** Pre-commit records only deterministic preflight failures (missing plugin, no runner); post-commit `task_runner.submit` failures logged but not in audit row per D-03.
- **Detailed coverage:** `### Ingress Transaction Refactor (process_payload)` + `### Pitfall 2` + `## State of the Art`.

### 8. Raw payload redaction
- **Secrets removal:** New recursive redactor handles arbitrary JSON paths and string values (D-05); `DecisionContext` notes filter is NOT reused.
- **Size capping:** `CORRELIA_AUDIT_RAW_PAYLOAD_MAX_BYTES` (default 64 KiB); semantic truncation (progressive string/key dropping), never byte truncation (D-06, Pitfall 6).
- **Metadata:** `original_byte_length`, `stored_byte_length`, `truncated`, `redaction_version`, `redacted_path_count`, keyed HMAC of pre-redaction canonical payload (D-07). Dedicated `audit_raw_payload_hmac_key: SecretStr` required setting.
- **HMAC limitation:** Pre-redaction HMAC supports later verification against a candidate original payload held externally; it does NOT self-detect changes to the stored redacted payload.
- **Detailed coverage:** `### Pitfall 6` + `<user_constraints>` D-04 through D-08 + `## Security Domain` + `## Open Questions` #1.

### 9. Testing strategy
- **Migration tests:** `test_migrations.py` — assert `incident_events` table columns, NOT NULL constraints, check constraints, all indexes (GIN, btree, expression), upgrade/downgrade round-trip.
- **Unit tests:** `test_domain_audit.py` — `AuditDecisionSummary` validation (strict, extra-forbid, field bounds, all `decision_kind`/`incident_effect` literals); `test_audit_redaction.py` — redactor strips secrets, semantic capping under byte limit, HMAC computation, oversized payload handling.
- **Integration tests:** `test_audit_persistence.py` — repository insert, cursor encode/decode/round-trip, GIN containment lookup by `incident_id`, filter combinations; `test_audit_api.py` — endpoint with auth, all filters, cursor pagination, bounded response (no `raw_payload`), offset/total diagnostic.
- **Edge cases:** All five decision paths (Pitfall 1), multi-incident recovery (Pitfall 3), recovery-noop vs problem-noop `decision_kind` (Pitfall 7), below-threshold events still produce `incident_effect=inserted/updated` (not `none`), oversized payload truncation (Pitfall 6), missing HMAC key rejected by settings validator, `sessionmaker=None` skips audit.
- **Infrastructure:** PostgreSQL 18 testcontainers required (no SQLite for JSONB/GIN/migration behavior); `NoopLifecycleWorker` pattern from `test_incidents_api.py`; `CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY` added to `conftest.py` `_SETTINGS_ENV_KEYS`.
- **Detailed coverage:** `### Recommended Project Structure` test files + `### Pitfall 1/3/6/7` warning signs + `## Environment Availability`.

### 10. Risks / open questions
- **Open Questions:** (1) HMAC key provisioning — required unconditionally or toggle-gated? (2) `_submit_notifications` relocation — pre-commit preflight + post-commit submit split. (3) Audit row when `sessionmaker=None` — skip insertion. (4) `incident_effect` for below-threshold — always `inserted`/`updated`. (5) Append-only enforcement — application discipline vs DB trigger.
- **Assumptions:** A1 (gen_random_uuid in PG13+), A2 (GIN supports `@>`), A3 (notification split feasible), A4 (payload serializable to dict), A5 (64 KiB default sufficient).
- **Pitfalls:** Seven catalogued with warning signs — missing audit rows for non-upsert paths, commit refactor breaking operator paths, incident ID collapsing, HMAC key reuse, missing GIN index, JSONB byte truncation, decision_kind confusion.
- **Detailed coverage:** `## Open Questions` + `## Assumptions Log` + `## Common Pitfalls` + `## Security Domain`.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all libraries are existing project dependencies, verified in `pyproject.toml`
- Architecture: HIGH — all patterns (cursor pagination, JSONB containment, strict Pydantic, operator router, route classification) are verified in the codebase
- Pitfalls: HIGH — derived from concrete code analysis of `process_payload`, `apply_problem`, `resolve_for_event`, and `list_incidents` bodies
- Schema: HIGH — migration conventions verified from `0001`/`0002`; column types follow `Incident` model
- Transaction refactor: HIGH — commit sites verified at `incident_manager.py:136` and `lifecycle.py:79`; unchanged commit sites verified at `lifecycle.py:95,125` and `lifecycle.py:151`

**Research date:** 2026-06-18
**Valid until:** 2026-07-18 (30 days — stable internal codebase, no external API dependencies)
