# Phase 7: Incident Event Audit Trail - Pattern Map

**Mapped:** 2026-06-18
**Files analyzed:** 20 files total — 8 new, 12 modified
**Analogs found:** 19 / 20 (deviations called out per-row; 1 no-analog redactor test)
**Cross-cutting test impact:** `tests/test_settings.py` and `tests/test_size_limit.py` require additions (see entries 19 and 20 below).

**New files (8):** `app/domain/audit.py`, `app/persistence/audit.py`, `app/api/routers/audit.py`, `migrations/versions/0003_create_incident_events.py`, `tests/test_domain_audit.py`, `tests/test_audit_redaction.py`, `tests/test_audit_persistence.py`, `tests/test_audit_api.py`.
**Modified files (12):** `app/persistence/models.py`, `app/processing/ingress.py`, `app/processing/incident_manager.py`, `app/processing/lifecycle.py`, `app/persistence/incidents.py`, `app/middleware/classification.py`, `app/config/settings.py`, `app/main.py`, `tests/conftest.py`, `tests/test_migrations.py`, `tests/test_settings.py`, `tests/test_size_limit.py`.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `app/persistence/models.py` | model (declarative) | append-only row | `app/persistence/models.py:21-57` (Incident) | exact (same file) |
| `app/persistence/audit.py` | persistence/repository | CRUD + cursor | `app/persistence/incidents.py:430-456` (cursor), `:469-549` (list) | role-match, with **deviation** for D-15 projection |
| `app/domain/audit.py` | domain model | bounded DTOs | `app/domain/incidents.py:46-83` (DecisionContext), `:155-216` (List/Detail/Response) | exact |
| `app/api/routers/audit.py` | API router | request-response, read-only | `app/api/routers/incidents.py:30-133` | role-match, with **deviation** for bounded projection + new filters |
| `app/processing/ingress.py` | processing | request-response + transactional write | `app/processing/ingress.py:54-220` (self) | exact (modify-in-place), with **deviation** for single-session transaction |
| `app/processing/incident_manager.py` | processing | transactional write | `app/processing/incident_manager.py:69-167` (self) | exact (modify-in-place), with **deviation** to drop `session.commit()` |
| `app/processing/lifecycle.py` | processing | transactional write | `app/processing/lifecycle.py:58-103` (self) | exact (modify-in-place), with **deviation** to drop `session.commit()` from `resolve_for_event` only |
| `app/persistence/incidents.py` | persistence/repository | CRUD + cursor | `app/persistence/incidents.py:430-549` (self) | exact (pattern source only — likely signature-stable; planner should confirm with downstream consumers) |
| `app/middleware/classification.py` | middleware config | route class | `app/middleware/classification.py:7-16` (self) | exact (one-tuple append) |
| `app/config/settings.py` | config | strict Pydantic settings | `app/config/settings.py:8-83` (self) | exact (additive fields + new validator) |
| `app/main.py` | app factory | wiring | `app/main.py:228-280` (include_router) | exact (one include_router) |
| `migrations/versions/0003_create_incident_events.py` | migration | schema + indexes | `migrations/versions/0001_create_incidents.py` | exact (table + check constraints), with **deviation** for GIN + functional index + comprehensive `downgrade()` |
| `tests/conftest.py` | test fixture | settings env cleanup | `tests/conftest.py:7-43` (self) | exact (additive `_SETTINGS_ENV_KEYS`) |
| `tests/test_domain_audit.py` | test | unit | `tests/test_domain_incidents.py` (whole) | exact (mirror validator + version discipline) |
| `tests/test_audit_redaction.py` | test | unit | new — no existing redactor | no analog (planner uses RESEARCH.md spec) |
| `tests/test_audit_persistence.py` | test | integration | `tests/test_incident_repository.py` | exact (mirror PostgresContainer + async engine pattern) |
| `tests/test_audit_api.py` | test | integration | `tests/test_incidents_api.py:30-200` | exact (mirror `_app` factory + `AsyncClient` + `session_factory`) |
| `tests/test_migrations.py` | test | schema invariant | `tests/test_migrations.py:23-200` (self) | exact (mirror column/constraint/index inspection tests) |
| `tests/test_settings.py` | test | config validation | `tests/test_settings.py:55-126` (Phase 5 token-validation tests) | exact (mirror `test_auth_*` pattern with HMAC-key additions) |
| `tests/test_size_limit.py` | test | route classification | `tests/test_size_limit.py` (`test_classify_path_maps_routes`) | exact (parametrize over the new `/v1/incident-events` path) |

## Pattern Assignments

---

### 1. `app/persistence/models.py` (model, append-only row) — MODIFIED

**Analog:** same file, `Incident` class (lines 21-57).

**Current `Incident` model pattern** (lines 21-57):

```python
class Base(DeclarativeBase):
    pass

class Incident(Base):
    __tablename__ = "incidents"

    id: Mapped[UUID] = mapped_column(PG_UUID(as_uuid=True), primary_key=True)
    rule_name: Mapped[str] = mapped_column(String, nullable=False)
    ...
    decision_context: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default="'{}'::jsonb"
    )
    ...
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default="now()"
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default="now()"
    )
```

**Deviation required by D-13:** Audit row identifier is **server-generated** UUID — use `server_default=sa.func.gen_random_uuid()`. The existing `Incident.id` uses Python `uuid4()` (see `app/persistence/incidents.py:build_open_incident_upsert` at lines 564-624). `IncidentEvent` must diverge to honor the locked decision. The model file is the right home: `migrations/env.py:24` uses `target_metadata = Base.metadata`, and any model defined here is automatically discovered by Alembic.

**New `IncidentEvent` class** to append at the end of `app/persistence/models.py`:

```python
class IncidentEvent(Base):
    __tablename__ = "incident_events"

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=sa.func.gen_random_uuid(),
    )
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
    incident_ids: Mapped[list[str]] = mapped_column(
        JSONB, nullable=False, default=list, server_default=sa.text("'[]'::jsonb")
    )
    incident_effect: Mapped[str] = mapped_column(String, nullable=False)
    decision_summary: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default=sa.text("'{}'::jsonb")
    )
    normalized_event: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default=sa.text("'{}'::jsonb")
    )
    raw_payload: Mapped[dict[str, Any] | None] = mapped_column(JSONB, nullable=True)
    raw_payload_original_byte_length: Mapped[int | None] = mapped_column(Integer, nullable=True)
    raw_payload_stored_byte_length: Mapped[int | None] = mapped_column(Integer, nullable=True)
    raw_payload_truncated: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=sa.text("false")
    )
    redaction_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    redacted_path_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    raw_payload_hmac: Mapped[str | None] = mapped_column(String, nullable=True)
```

**Note on file split:** Declarative model goes here; repository/redactor/HMAC/cursor helpers go in `app/persistence/audit.py` (entry 2 below). The repository imports `IncidentEvent` from this module — see `app/persistence/incidents.py:34` for the existing `from app.persistence.models import Incident` precedent.

---

### 2. `app/persistence/audit.py` (repository, CRUD + cursor) — NEW

**Analog sources:**
- Cursor pattern: `app/persistence/incidents.py:436-456` (`encode_incident_cursor` / `decode_incident_cursor`).
- List/filter pattern: `app/persistence/incidents.py:469-549` (`list_incidents`).
- `LifecycleWriteResult`/`IncidentAggregationWriteResult` shape: `app/persistence/incidents.py:120-160`.

**Cursor pattern to mirror** (`app/persistence/incidents.py:436-456`):

```python
def encode_incident_cursor(cursor: IncidentCursor) -> str:
    payload = {
        "last_update_time": cursor.last_update_time.isoformat(),
        "id": str(cursor.id),
    }
    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode()
    ).decode()
    return encoded.rstrip("=")


def decode_incident_cursor(value: str) -> IncidentCursor:
    try:
        padded = value + ("=" * (-len(value) % 4))
        payload = json.loads(base64.urlsafe_b64decode(padded.encode()).decode())
        last_update_time = datetime.fromisoformat(payload["last_update_time"])
        if last_update_time.tzinfo is None or last_update_time.utcoffset() is None:
            raise ValueError("cursor timestamp must be timezone-aware")
        return IncidentCursor(last_update_time=last_update_time, id=UUID(payload["id"]))
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise ValueError("invalid incident cursor") from exc
```

**Mirror for audit cursor** (key change: tuple is `(accepted_at, id)` per D-10, not `(last_update_time, id)`):

```python
@dataclass(frozen=True, slots=True)
class AuditEventCursor:
    accepted_at: datetime
    id: UUID

def encode_audit_cursor(cursor: AuditEventCursor) -> str:
    payload = {"accepted_at": cursor.accepted_at.isoformat(), "id": str(cursor.id)}
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

**Filter containment pattern to mirror** (`app/persistence/incidents.py:476-477`):

```python
if filters.host is not None:
    stmt = stmt.where(Incident.affected_hosts.contains([filters.host]))
if filters.service is not None:
    stmt = stmt.where(Incident.affected_services.contains([filters.service]))
```

**Mirror for `incident_id` filter (D-11, D-14):** `IncidentEvent.incident_ids.contains([str(filters.incident_id)])` — produces `@> '[uuid]'::jsonb`, served by the GIN index defined in migration 0003.

**Pagination pattern to mirror** (`app/persistence/incidents.py:493-549`):

```python
if filters.cursor is not None:
    cursor = decode_incident_cursor(filters.cursor)
    page_stmt = page_stmt.where(
        or_(
            Incident.last_update_time < cursor.last_update_time,
            and_(
                Incident.last_update_time == cursor.last_update_time,
                Incident.id < cursor.id,
            ),
        )
    )
    page_stmt = page_stmt.order_by(
        Incident.last_update_time.desc(), Incident.id.desc()
    ).limit(filters.limit + 1)
    result = await session.execute(page_stmt)
    rows = tuple(result.scalars().all())
    incidents = rows[: filters.limit]
    next_cursor = None
    if len(rows) > filters.limit:
        last = incidents[-1]
        next_cursor = encode_incident_cursor(
            IncidentCursor(last_update_time=last.last_update_time, id=last.id)
        )
```

**Deviation required by D-15 (bounded projection on default read):** Do **NOT** mirror `select(Incident)` wholesale. The `list_incident_events` repository must project an explicit column tuple, omitting `raw_payload` and `normalized_event` from the SELECT (they remain in the table for the future /admin/payload retrieval path but are not selected by the default listing). Use a named tuple / dataclass row result, not the ORM `IncidentEvent` entity:

```python
from sqlalchemy import select, tuple_, and_, or_, func
from sqlalchemy.dialects.postgresql import JSONB

# Explicit projection — never select raw_payload or full normalized_event by default.
_AUDIT_LIST_COLUMNS = (
    IncidentEvent.id,
    IncidentEvent.accepted_at,
    IncidentEvent.event_timestamp,
    IncidentEvent.source_id,
    IncidentEvent.fingerprint,
    IncidentEvent.event_type,
    IncidentEvent.severity,
    IncidentEvent.host,
    IncidentEvent.service,
    IncidentEvent.incident_ids,
    IncidentEvent.incident_effect,
    IncidentEvent.decision_summary,
    IncidentEvent.raw_payload_original_byte_length,
    IncidentEvent.raw_payload_stored_byte_length,
    IncidentEvent.raw_payload_truncated,
    IncidentEvent.redaction_version,
    IncidentEvent.redacted_path_count,
    IncidentEvent.raw_payload_hmac,
    # Bounded JSONB projections (D-08, D-15): pull only the two fields the
    # response DTO needs from normalized_event, not the whole document.
    # Idiom: <jsonb_col>["key"].astext for scalars, <jsonb_col>["key"] for
    # nested objects. The .label() call pins the column to a stable key in
    # result.tuple().all() so the router can read by position.
    IncidentEvent.normalized_event["message"].astext.label("normalized_event_message"),
    IncidentEvent.normalized_event["tags"].label("normalized_event_tags"),
    # explicitly NOT selected:
    #   IncidentEvent.raw_payload
    #   IncidentEvent.normalized_event (whole document)
)

@dataclass(frozen=True, slots=True)
class IncidentEventListPage:
    events: tuple[tuple, ...]   # rows of the projected columns; mapped to DTO in router
    next_cursor: str | None
    total: int
    offset: int

async def list_incident_events(
    session: AsyncSession,
    filters: "AuditEventListFilters",
) -> IncidentEventListPage:
    def apply_filters(stmt):
        if filters.incident_id is not None:
            stmt = stmt.where(IncidentEvent.incident_ids.contains([str(filters.incident_id)]))
        if filters.has_incident is False:
            stmt = stmt.where(IncidentEvent.incident_effect == "none")
        elif filters.has_incident is True:
            stmt = stmt.where(IncidentEvent.incident_effect != "none")
        if filters.fingerprint is not None:
            stmt = stmt.where(IncidentEvent.fingerprint == filters.fingerprint)
        if filters.source_id is not None:
            stmt = stmt.where(IncidentEvent.source_id == filters.source_id)
        if filters.event_type is not None:
            stmt = stmt.where(IncidentEvent.event_type == filters.event_type.value)
        if filters.incident_effect is not None:
            stmt = stmt.where(IncidentEvent.incident_effect == filters.incident_effect)
        if filters.no_dispatch_reason is not None:
            # Functional index on decision_summary->>'no_dispatch_reason' (see migration 0003).
            stmt = stmt.where(
                IncidentEvent.decision_summary["no_dispatch_reason"].astext
                == filters.no_dispatch_reason
            )
        if filters.severity is not None:
            stmt = stmt.where(IncidentEvent.severity == filters.severity.value)
        if filters.host is not None:
            stmt = stmt.where(IncidentEvent.host == filters.host)
        if filters.service is not None:
            stmt = stmt.where(IncidentEvent.service == filters.service)
        if filters.accepted_since is not None:
            stmt = stmt.where(IncidentEvent.accepted_at >= filters.accepted_since)
        if filters.accepted_until is not None:
            stmt = stmt.where(IncidentEvent.accepted_at < filters.accepted_until)
        if filters.event_timestamp_since is not None:
            stmt = stmt.where(IncidentEvent.event_timestamp >= filters.event_timestamp_since)
        if filters.event_timestamp_until is not None:
            stmt = stmt.where(IncidentEvent.event_timestamp < filters.event_timestamp_until)
        return stmt

    base_stmt = apply_filters(select(*_AUDIT_LIST_COLUMNS))
    total = await session.scalar(
        select(func.count()).select_from(base_stmt.subquery())
    ) or 0

    page_stmt = apply_filters(select(*_AUDIT_LIST_COLUMNS))
    order_col = IncidentEvent.accepted_at
    if filters.cursor is not None:
        cursor = decode_audit_cursor(filters.cursor)
        page_stmt = page_stmt.where(
            or_(
                IncidentEvent.accepted_at < cursor.accepted_at,
                and_(
                    IncidentEvent.accepted_at == cursor.accepted_at,
                    IncidentEvent.id < cursor.id,
                ),
            )
        )
        page_stmt = page_stmt.order_by(
            IncidentEvent.accepted_at.desc(), IncidentEvent.id.desc()
        ).limit(filters.limit + 1)
        result = await session.execute(page_stmt)
        rows = tuple(result.tuple().all())
        events = rows[: filters.limit]
        next_cursor = None
        if len(rows) > filters.limit:
            last = events[-1]
            next_cursor = encode_audit_cursor(
                AuditEventCursor(accepted_at=last[1], id=last[0])  # (id, accepted_at) per column order
            )
        offset_value = 0
    elif filters.offset is not None:
        page_stmt = page_stmt.order_by(
            IncidentEvent.accepted_at.desc(), IncidentEvent.id.desc()
        ).offset(filters.offset).limit(filters.limit)
        result = await session.execute(page_stmt)
        events = tuple(result.tuple().all())
        next_cursor = None
        offset_value = filters.offset
    else:
        page_stmt = page_stmt.order_by(
            IncidentEvent.accepted_at.desc(), IncidentEvent.id.desc()
        ).limit(filters.limit + 1)
        result = await session.execute(page_stmt)
        rows = tuple(result.tuple().all())
        events = rows[: filters.limit]
        next_cursor = None
        if len(rows) > filters.limit:
            last = events[-1]
            next_cursor = encode_audit_cursor(
                AuditEventCursor(accepted_at=last[1], id=last[0])
            )
        offset_value = 0

    return IncidentEventListPage(
        events=events,
        next_cursor=next_cursor,
        total=int(total),
        offset=offset_value,
    )
```

The router (`app/api/routers/audit.py`) is responsible for mapping each row tuple into the bounded `AuditEventResponse` DTO — the repository never produces ORM entities on the read path.

**Insert helper (write path):** mirror the simple session-add style of `app/persistence/incidents.py:678-720` (one of the `record_*` functions); no atomic upsert machinery is needed (audit is append-only):

```python
async def insert_incident_event(
    session: AsyncSession,
    *,
    event_timestamp: datetime,
    source_id: str,
    fingerprint: str,
    event_type: str,
    severity: str,
    host: str,
    service: str | None,
    incident_ids: list[str],
    incident_effect: str,
    decision_summary: dict[str, Any],
    normalized_event: dict[str, Any],
    raw_payload: dict[str, Any] | None,
    raw_payload_original_byte_length: int | None,
    raw_payload_stored_byte_length: int | None,
    raw_payload_truncated: bool,
    redaction_version: int | None,
    redacted_path_count: int | None,
    raw_payload_hmac: str | None,
) -> IncidentEvent:
    event = IncidentEvent(
        event_timestamp=event_timestamp,
        source_id=source_id,
        fingerprint=fingerprint,
        event_type=event_type,
        severity=severity,
        host=host,
        service=service,
        incident_ids=incident_ids,
        incident_effect=incident_effect,
        decision_summary=decision_summary,
        normalized_event=normalized_event,
        raw_payload=raw_payload,
        raw_payload_original_byte_length=raw_payload_original_byte_length,
        raw_payload_stored_byte_length=raw_payload_stored_byte_length,
        raw_payload_truncated=raw_payload_truncated,
        redaction_version=redaction_version,
        redacted_path_count=redacted_path_count,
        raw_payload_hmac=raw_payload_hmac,
    )
    session.add(event)
    await session.flush()
    return event
```

**Redactor + HMAC (in this same file, no existing analog):** No analog in the codebase. Per D-05/D-07: a recursive `redact_payload(value, *, max_bytes, hmac_key) -> RedactedPayload` that
- walks dicts/lists/scalars,
- replaces values whose key or scalar text matches the existing `_FORBIDDEN_NOTE_FRAGMENTS` set (`app/domain/incidents.py:33-41`) with the string `"[redacted]"`,
- computes `hmac.new(key, canonical_json, sha256).hexdigest()` of the pre-redaction canonical payload,
- measures `original_byte_length` once, then iteratively drops the largest string values (semantic cap, D-06) until the serialized payload is `<= max_bytes`,
- returns `(redacted_dict, original_byte_length, stored_byte_length, truncated, redacted_path_count, hmac)`.

Configuration is pulled from `Settings.audit_raw_payload_max_bytes` and `Settings.audit_raw_payload_hmac_key` (see entry 10 below). The redactor is a pure function (no I/O), so it is unit-testable in `tests/test_audit_redaction.py` without a Postgres fixture.

---

### 3. `app/domain/audit.py` (domain model, bounded DTOs) — NEW

**Analog sources:**
- `DecisionContext` discipline: `app/domain/incidents.py:46-83` (schema_version, strict, extra="forbid", bounded string types).
- `IncidentListFilters` shape: `app/domain/incidents.py:155-176` (filter DTO with `BoundedString` reuse, `Annotated` constraint aliases).
- `IncidentListResponse`/`IncidentDetailResponse` shape: `app/domain/incidents.py:178-216`.

**Bounded-string reuse pattern** (`app/domain/incidents.py:28-31`):

```python
BoundedString = Annotated[str, Field(min_length=1, max_length=256)]
BoundedStringTuple = Annotated[tuple[BoundedString, ...], Field(max_length=20)]
```

**Strict model pattern** (`app/domain/incidents.py:48`):

```python
class DecisionContext(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    fingerprint: BoundedString | None = None
    ...
```

**Mirror for `AuditDecisionSummary` (D-17, D-18, D-19):**

```python
# Reuse BoundedString, BoundedStringTuple, TagKey, TagValue from app/domain/incidents.py
from app.domain.incidents import BoundedString, BoundedStringTuple
from app.domain.events import TagKey, TagValue

# D-08: dedicated response-only annotation for the audit-list message
# projection. Declared at module scope (Pydantic v2 rejects type aliases
# declared inside a model body) and matches the router's 512-char cap
# plus empty-string fallback. NOT a storage constraint: stored messages
# remain bounded by `NormalizedEvent.message` (max 4096) in
# app/domain/events.py. Reusing BoundedString here would be wrong because
# BoundedString has min_length=1, which rejects the empty-string fallback
# for events whose source payload did not carry a message.
BoundedResponseMessage = Annotated[str, Field(min_length=0, max_length=512)]


class AuditDecisionSummary(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    decision_kind: Literal["problem", "recovery", "noop"]
    incident_effect: Literal["none", "inserted", "updated", "resolved", "affected_set_shrunk"]
    rule_name: BoundedString | None = None
    group_key: BoundedString | None = None
    incident_ids: BoundedStringTuple = ()
    affected_incident_count: int = Field(default=0, ge=0)
    incident_ids_truncated: bool = False
    decision_reason: BoundedString | None = None
    no_dispatch_reason: Annotated[str | None, Field(min_length=1, max_length=128)] = None
    notification_intent: Literal["dispatch_planned", "no_dispatch"]
    counted_count: int | None = Field(default=None, ge=0)
    threshold_count: int | None = Field(default=None, ge=1)
    threshold_crossed: bool | None = None
    replay: bool | None = None
    first_threshold_transition: bool | None = None
    recovery_resolution: Literal["noop", "affected_set_shrunk", "resolved"] | None = None
    affected_object_removed: bool | None = None
```

**Mirror for `AuditEventListFilters` (D-11, D-12) — uses the same filter-DTO discipline as `IncidentListFilters`** (`app/domain/incidents.py:155-176`):

```python
class AuditEventListFilters(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    incident_id: UUID | None = None
    has_incident: bool | None = None
    fingerprint: BoundedString | None = None
    source_id: BoundedString | None = None
    event_type: EventType | None = None
    incident_effect: Literal["none", "inserted", "updated", "resolved", "affected_set_shrunk"] | None = None
    no_dispatch_reason: BoundedString | None = None
    severity: Severity | None = None
    host: BoundedString | None = None
    service: BoundedString | None = None
    accepted_since: datetime | None = None
    accepted_until: datetime | None = None
    event_timestamp_since: datetime | None = None
    event_timestamp_until: datetime | None = None
    limit: int = Field(default=50, ge=1, le=200)
    cursor: Annotated[str, Field(min_length=1, max_length=512)] | None = None
    offset: Annotated[int, Field(ge=0)] | None = None

    @field_validator(
        "accepted_since", "accepted_until",
        "event_timestamp_since", "event_timestamp_until",
        mode="after",
    )
    @classmethod
    def require_timezone(cls, value: datetime | None) -> datetime | None:
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("timestamp must be timezone-aware")
        return value
```

D-12 mapping: `has_incident=False` ⇒ `incident_effect = "none"`. Apply in the repository (entry 2 above), not the filter DTO.

**Mirror for response DTOs (shape: `IncidentDetailResponse` / `IncidentListResponse` at `app/domain/incidents.py:178-216`):**

```python
class AuditEventResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    id: UUID
    accepted_at: datetime
    event_timestamp: datetime
    source_id: BoundedString
    fingerprint: BoundedString
    event_type: EventType
    severity: Severity
    host: BoundedString
    service: BoundedString | None
    incident_ids: BoundedStringTuple
    incident_effect: Literal["none", "inserted", "updated", "resolved", "affected_set_shrunk"]
    decision_summary: AuditDecisionSummary
    # D-08: bounded projection on the read surface only.
    # `BoundedResponseMessage` is declared at module scope above (with
    # min_length=0, max_length=512) and matches the router's truncation
    # and empty-string fallback exactly. Do NOT change it to
    # `BoundedString` (min_length=1) — that would reject the empty-string
    # fallback for events whose source payload did not carry a message.
    # The 512-char cap is a D-08 read-surface bound; the storage
    # constraint is the 4096-char `NormalizedEvent.message` defined in
    # app/domain/events.py.
    normalized_event_message: BoundedResponseMessage
    # tags are bounded by TagKey/TagValue (defined in app/domain/events.py);
    # the read surface does not re-cap them, but the SQL projection
    # preserves the JSONB as-is.
    normalized_event_tags: dict[TagKey, TagValue]
    # raw payload metadata (no raw_payload body, no full normalized_event)
    raw_payload_original_byte_length: int | None
    raw_payload_stored_byte_length: int | None
    raw_payload_truncated: bool
    redaction_version: int | None
    redacted_path_count: int | None
    raw_payload_hmac: str | None


class AuditEventListResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    items: tuple[AuditEventResponse, ...] = Field(max_length=200)
    total: int = Field(default=0, ge=0)
    limit: int = Field(default=50, ge=1, le=200)
    offset: int = Field(default=0, ge=0)
    next_cursor: str | None = None
```

---

### 4. `app/api/routers/audit.py` (router, request-response read-only) — NEW

**Analog:** `app/api/routers/incidents.py:30-133`.

**Router declaration + security dependency pattern** (`app/api/routers/incidents.py:36`):

```python
router = APIRouter(prefix="/v1/incidents", dependencies=[Security(require_operator_token)])
```

**Mirror for audit (D-09, D-16):**

```python
from fastapi import APIRouter, Depends, HTTPException, Query, Security, status
from typing import Annotated
from datetime import datetime
from uuid import UUID

from app.api.security import require_operator_token
from app.api.deps import get_sessionmaker
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.domain.audit import (
    AuditEventListFilters,
    AuditEventListResponse,
    AuditEventResponse,
    AuditDecisionSummary,
)
from app.persistence.audit import (
    list_incident_events,
    decode_audit_cursor,
    AuditEventCursor,
)
from app.persistence.models import IncidentEvent
from app.domain.events import EventType, Severity

router = APIRouter(
    prefix="/v1/incident-events",
    dependencies=[Security(require_operator_token)],
)
```

**Filter dependency pattern** (`app/api/routers/incidents.py:84-105`):

```python
def incident_list_filters(
    status_filter: Annotated[IncidentStatusFilter | None, Query(alias="status")] = None,
    severity: Severity | None = None,
    rule_name: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    host: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    service: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    updated_since: datetime | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    cursor: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
    offset: Annotated[int | None, Query(ge=0)] = None,
) -> IncidentListFilters:
    return IncidentListFilters(...)
```

**Mirror for audit (D-11, D-12 — uses native FastAPI `bool` query parsing with explicit `Query(...)` since `has_incident` defaults are unusual):**

```python
def audit_event_list_filters(
    incident_id: UUID | None = None,
    has_incident: Annotated[bool | None, Query()] = None,
    fingerprint: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    source_id: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    event_type: EventType | None = None,
    incident_effect: Annotated[
        Literal["none", "inserted", "updated", "resolved", "affected_set_shrunk"] | None,
        Query(),
    ] = None,
    no_dispatch_reason: Annotated[str | None, Query(min_length=1, max_length=128)] = None,
    severity: Severity | None = None,
    host: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    service: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    accepted_since: datetime | None = None,
    accepted_until: datetime | None = None,
    event_timestamp_since: datetime | None = None,
    event_timestamp_until: datetime | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    cursor: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
    offset: Annotated[int | None, Query(ge=0)] = None,
) -> AuditEventListFilters:
    return AuditEventListFilters(...)
```

**Endpoint + bounded projection mapping (D-08, D-15) — diverges from `list_incidents_endpoint` at `app/api/routers/incidents.py:107-127`** by mapping the row tuple into a bounded DTO that does NOT carry `raw_payload` or full `normalized_event`:

```python
def _audit_event_response(row: tuple) -> AuditEventResponse:
    (
        id_, accepted_at, event_timestamp, source_id, fingerprint,
        event_type, severity, host, service, incident_ids, incident_effect,
        decision_summary, original_bytes, stored_bytes, truncated,
        redaction_version, redacted_path_count, hmac_,
        normalized_event_message, normalized_event_tags,
    ) = row
    # The repository SELECT explicitly projects `normalized_event['message']`
    # (cast to text) and `normalized_event['tags']` (preserved as JSONB); the
    # full normalized_event document is never fetched. The router does not
    # touch the audit table directly. The DTO field is typed as
    # `BoundedResponseMessage = Annotated[str, Field(min_length=0, max_length=512)]`
    # (declared in app/domain/audit.py alongside AuditEventResponse) so the
    # 512-char cap and empty-string fallback below both type-check. tags
    # pass through the TagKey/TagValue bounds enforced by the DTO.
    # Empty/scalar-NULL message from the SQL projection becomes ""; missing
    # tags become {}. The truncation keeps the first 512 chars.
    message = normalized_event_message or ""
    if len(message) > 512:
        message = message[:512]
    tags = normalized_event_tags or {}
    return AuditEventResponse(
        id=id_,
        accepted_at=accepted_at,
        event_timestamp=event_timestamp,
        source_id=source_id,
        fingerprint=fingerprint,
        event_type=EventType(event_type),
        severity=Severity(severity),
        host=host,
        service=service,
        incident_ids=tuple(incident_ids),
        incident_effect=incident_effect,
        decision_summary=AuditDecisionSummary.model_validate(decision_summary),
        normalized_event_message=message,
        normalized_event_tags=tags,
        raw_payload_original_byte_length=original_bytes,
        raw_payload_stored_byte_length=stored_bytes,
        raw_payload_truncated=truncated,
        redaction_version=redaction_version,
        redacted_path_count=redacted_path_count,
        raw_payload_hmac=hmac_,
    )


@router.get("", response_model=AuditEventListResponse)
async def list_incident_events_endpoint(
    filters: Annotated[AuditEventListFilters, Depends(audit_event_list_filters)],
    sessionmaker: Annotated[async_sessionmaker[AsyncSession], Depends(get_sessionmaker)],
) -> AuditEventListResponse:
    async with sessionmaker() as session:
        try:
            page = await list_incident_events(session, filters)
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="invalid cursor",
            ) from exc
    return AuditEventListResponse(
        items=tuple(_audit_event_response(row) for row in page.events),
        total=page.total,
        limit=filters.limit,
        offset=page.offset,
        next_cursor=page.next_cursor,
    )
```

**Implementation note for the planner:** the D-15 contract is satisfied by the repository-level projection in entry 2 (`_AUDIT_LIST_COLUMNS` includes `IncidentEvent.normalized_event["message"].astext.label("normalized_event_message")` and `IncidentEvent.normalized_event["tags"].label("normalized_event_tags")`). The router consumes those labelled columns positionally and does not select from `normalized_event` directly. The full `normalized_event` JSONB is never fetched on the read path. The SQLAlchemy 2.0 idiom `<jsonb_col>["key"].astext` for scalars mirrors the existing precedent at `app/persistence/incidents.py:1205` (`Incident.window_state["window_seconds"].astext.cast(Integer)`).

---

### 5. `app/processing/ingress.py` (processing, request-response + transactional write) — MODIFIED

**Analog:** same file, `process_payload` at `app/processing/ingress.py:54-220`, plus the helper `_apply_problem` at `:222-240` and `_apply_recovery` at the end of the file.

**Current `_apply_problem` helper** (`app/processing/ingress.py:222-240`):

```python
async def _apply_problem(
    self, event: NormalizedEvent, decision: RuleDecision
) -> IncidentAggregationResult:
    sessionmaker = self._sessionmaker
    if sessionmaker is None:
        raise RuntimeError("sessionmaker is required for problem aggregation")
    async with sessionmaker() as session:
        manager = IncidentManager(
            session,
            task_runner=self._task_runner,
            plugin_registry=self._plugin_registry,
            config_hash=self._config_hash,
        )
        return await manager.apply_problem(event, decision)
```

**Deviation required by D-01, D-02, D-03:** Ingress must own ONE session per accepted event. Managers no longer commit; the session is committed by ingress after the audit row is inserted. The audit row is built from manager return values (`IncidentAggregationResult` for problem, `LifecycleResult` for recovery) plus the event/payload. Notifications remain post-commit (D-03).

**New `process_payload` shape (D-01, D-02, D-03):**

```python
async def process_payload(
    self, payload: Icinga2WebhookPayload
) -> IngressDecisionEnvelope:
    # ... unchanged normalization (lines 55-93) ...
    # ... unchanged enrichment (lines 95-122) ...

    incident_result: IncidentAggregationResult | None = None
    lifecycle_result: LifecycleResult | None = None
    audit_summary: AuditDecisionSummary | None = None
    sessionmaker = self._sessionmaker

    if self._rule_engine is not None:
        decision = await self._rule_engine.evaluate(event)
        # ... unchanged rule-match logging (lines 129-145) ...

        if isinstance(decision, RuleDecision) and event.event_type is EventType.PROBLEM:
            threshold_decision = decision.threshold_decision.model_dump(mode="json")
            if sessionmaker is not None:
                async with sessionmaker() as session:                  # ONE session
                    manager = IncidentManager(                          # no internal commit
                        session,
                        task_runner=self._task_runner,
                        plugin_registry=self._plugin_registry,
                        config_hash=self._config_hash,
                    )
                    incident_result = await manager.apply_problem(event, decision)
                    # Build audit summary from incident_result, redact raw payload,
                    # compute HMAC, insert audit row in the same session.
                    audit_summary = _build_audit_summary_for_problem(
                        event, decision, incident_result, raw_payload
                    )
                    await _insert_audit_row(
                        session, event, decision, audit_summary, redacted_payload, hmac
                    )
                    await session.commit()                              # SINGLE commit
        elif event.event_type is EventType.RECOVERY:
            if sessionmaker is not None:
                async with sessionmaker() as session:                  # ONE session
                    manager = LifecycleManager(session)                 # no internal commit
                    lifecycle_result = await manager.resolve_for_event(event)
                    audit_summary = _build_audit_summary_for_recovery(
                        event, lifecycle_result, raw_payload
                    )
                    await _insert_audit_row(
                        session, event, decision, audit_summary, redacted_payload, hmac
                    )
                    await session.commit()                              # SINGLE commit
        else:
            # NoOpDecision on a PROBLEM (or a recovery with no rule engine).
            if sessionmaker is not None:
                async with sessionmaker() as session:                  # ONE session
                    audit_summary = _build_audit_summary_for_noop(
                        event, decision, raw_payload
                    )
                    await _insert_audit_row(
                        session, event, decision, audit_summary, redacted_payload, hmac
                    )
                    await session.commit()                              # SINGLE commit
    else:
        # No rule engine configured at all.
        if sessionmaker is not None:
            async with sessionmaker() as session:                      # ONE session
                audit_summary = AuditDecisionSummary(
                    decision_kind="noop",
                    incident_effect="none",
                    notification_intent="no_dispatch",
                )
                await _insert_audit_row(
                    session, event, None, audit_summary, redacted_payload, hmac
                )
                await session.commit()                                  # SINGLE commit

    # Post-commit: notifications (D-03).
    if incident_result is not None and self._task_runner is not None:
        # Either re-invoke the manager's submission logic (refactored to live
        # in ingress now) or call a helper here. D-02 splits preflight recording
        # (pre-commit, deterministic) from task submission (post-commit, may fail).
        ...

    # ... unchanged envelope assembly ...
```

**Notification sequencing helper (D-03):** Move the notification preflight and submit logic out of `IncidentManager` into the ingress layer:

```python
# Pre-commit: deterministic preflight failures (recorded in audit via
# decision_summary.no_dispatch_reason and incident_id correlation, not via
# NotificationResult rows; see D-03).
async def _record_preflight_failures(
    session: AsyncSession, write_result, decision: RuleDecision,
    plugin_registry, task_runner: TaskRunner | None,
) -> tuple[NotificationResult, ...]:
    # Mirror the missing_plugin / no-task-runner branches from
    # IncidentManager._submit_notifications (app/processing/incident_manager.py:185-225).
    # Each preflight failure: build a NotificationResult, record metric, persist
    # to the incident row via record_notification_result.
    ...

# Post-commit: actual task submission. Failures are logged via safe_log_extra
# and surfaced in IngressDecisionEnvelope.notification_failed; NOT recorded in
# the audit row (audit records intent only).
async def _submit_notifications(
    task_runner: TaskRunner, write_result, decision: RuleDecision, config_hash: str | None,
) -> tuple[NotificationResult, ...]:
    # Mirror the task_runner.submit branch from IncidentManager._submit_notifications
    # (:235-256). Do NOT touch the session.
    ...
```

---

### 6. `app/processing/incident_manager.py` (processing, transactional write) — MODIFIED

**Analog:** same file, `apply_problem` at lines 69-167 and `_submit_notifications` at lines 184-258.

**Current commit call sites to remove** (D-02, narrow scope):

1. `app/processing/incident_manager.py:136` — `await self._session.commit()` in `apply_problem`.
2. `app/processing/incident_manager.py:257` — `await self._session.commit()` in `_record_notification` (called for preflight failures; must move to ingress).

**Both must be removed.** The commit becomes ingress-owned (entry 5). `apply_problem` continues to call `record_problem_incident` and the `update(Incident).values(decision_context=...)` — those stay. The `_submit_notifications` post-task-runner branch is moved to ingress post-commit (entry 5).

**Pattern source for the post-refactor `apply_problem` shape** (same file, same method, just delete the two `await self._session.commit()` lines):

```python
async def apply_problem(
    self,
    event: NormalizedEvent,
    decision: RuleDecision,
) -> IncidentAggregationResult:
    # ... unchanged logic up through the final_context update ...
    await self._session.execute(
        update(Incident)
        .where(Incident.id == write_result.incident.id)
        .values(decision_context=final_context.model_dump(mode="json"))
    )
    write_result.incident.decision_context = final_context.model_dump(mode="json")
    # await self._session.commit()  <-- DELETED (D-02)
    return IncidentAggregationResult(...)  # no notification_results populated here
```

The post-refactor `apply_problem` no longer calls `_submit_notifications`; ingress owns that (entry 5). The `IncidentAggregationResult` returned should NOT include `notification_results` (or that field becomes the empty tuple, populated post-commit by ingress and reflected in the envelope only).

---

### 7. `app/processing/lifecycle.py` (processing, transactional write) — MODIFIED

**Analog:** same file, `resolve_for_event` at lines 58-91, plus `acknowledge` and `manual_close` for "do not touch" scope clarification.

**Current `resolve_for_event`** (`app/processing/lifecycle.py:58-91`):

```python
async def resolve_for_event(self, event: NormalizedEvent) -> LifecycleResult:
    if event.event_type is not EventType.RECOVERY:
        raise ValueError("LifecycleManager.resolve_for_event only accepts RECOVERY events")
    if event.service is not None:
        write_results = await resolve_service_recovery(...)
    else:
        write_results = await resolve_host_recovery(...)
    await self._session.commit()                                       # <-- DELETE
    for write_result in write_results:
        record_incident_effect(write_result.effect)
    logger.info(...)
    return _result_from_writes(write_results)
```

**Deviation (D-02, narrow scope):** Delete only the `await self._session.commit()` on line 79. The `acknowledge` method (lines 95-110) and `manual_close` method (lines 112-127) keep their internal commits — they are operator-mutation paths and run their own transactions. The `expire_stale_batch` function (line 144+) is also untouched — it is a background sweep, NOT an accepted source event, so it must NOT produce audit rows (per CONTEXT.md "lifecycle expiration sweeps are NOT accepted events and create no audit rows").

**Post-refactor `resolve_for_event`:**

```python
async def resolve_for_event(self, event: NormalizedEvent) -> LifecycleResult:
    if event.event_type is not EventType.RECOVERY:
        raise ValueError("LifecycleManager.resolve_for_event only accepts RECOVERY events")
    if event.service is not None:
        write_results = await resolve_service_recovery(...)
    else:
        write_results = await resolve_host_recovery(...)
    # await self._session.commit()  <-- DELETED (D-02)
    for write_result in write_results:
        record_incident_effect(write_result.effect)
    logger.info(...)
    return _result_from_writes(write_results)
```

**Pattern source for the lifecycle result consumption in audit (D-14):** `LifecycleResult.incident_ids` (a `tuple[UUID, ...]`) is the source of truth for audit correlation — NOT `LifecycleResult.incident_id` which collapses to the first ID (see `app/processing/lifecycle.py:46-48`). Recovery audit must use the full tuple.

---

### 8. `app/persistence/incidents.py` (persistence/repository) — MODIFIED (pattern source; signature change unlikely)

**Analog:** same file (pattern source for the audit repository).

This file is in the file map per RESEARCH.md (marked MODIFIED) and is the source of cursor/JSONB-containment patterns mirrored in `app/persistence/audit.py` (entry 2). The plan should:
- Read `encode_incident_cursor` / `decode_incident_cursor` (lines 436-456) as the template for `encode_audit_cursor` / `decode_audit_cursor`.
- Read `Incident.affected_hosts.contains([filters.host])` (lines 476-477) as the template for `IncidentEvent.incident_ids.contains([str(filters.incident_id)])`.
- Read `list_incidents` cursor + offset branches (lines 469-549) as the template for `list_incident_events`.

**Expected scope:** No signature changes are required IF the audit repository does not share any function with this file. The plan should confirm with downstream consumers (tests) whether the existing `list_incidents` / cursor tests are affected. If they are, the deviation is "add an audit-list variant without disturbing incidents-list"; if not, the file is effectively pattern-source only and can be treated as a one-line comment add (or no change at all beyond importing nothing new).

---

### 9. `app/middleware/classification.py` (middleware config) — MODIFIED

**Analog:** same file, `ROUTE_CLASS_PREFIXES` tuple at lines 7-16.

**Current tuple** (`app/middleware/classification.py:7-16`):

```python
ROUTE_CLASS_PREFIXES: Final[tuple[tuple[str, RouteClass], ...]] = (
    ("/v1/icinga2/events", "ingress"),
    ("/v1/incidents", "operator"),
    ("/v1/rules", "operator"),
    ("/v1/topology", "operator"),
    ("/v1/plugins", "operator"),
    ("/v1/metrics", "metrics"),
    ("/v1/readyz", "readyz"),
    ("/v1/health", "health"),
)
```

**Add one entry (D-16):** insert `("/v1/incident-events", "operator")` between the `"/v1/incidents"` and `"/v1/rules"` lines (or anywhere — order does not affect the prefix-match loop at `app/middleware/classification.py:19-23`):

```python
ROUTE_CLASS_PREFIXES: Final[tuple[tuple[str, RouteClass], ...]] = (
    ("/v1/icinga2/events", "ingress"),
    ("/v1/incidents", "operator"),
    ("/v1/incident-events", "operator"),  # NEW (D-16)
    ("/v1/rules", "operator"),
    ("/v1/topology", "operator"),
    ("/v1/plugins", "operator"),
    ("/v1/metrics", "metrics"),
    ("/v1/readyz", "readyz"),
    ("/v1/health", "health"),
)
```

The `classify_path` function below the tuple (lines 19-23) is unchanged. Phase 5 auth + rate-limit inheritance is automatic because the audit router uses `Security(require_operator_token)` (entry 4) and the middleware consults this tuple.

---

### 10. `app/config/settings.py` (config, strict Pydantic settings) — MODIFIED

**Analog:** same file. Two precedents to mirror:
- Field declaration style: `operator_api_token: SecretStr | None = None` (line 24-25).
- Fail-fast validator style: `_require_security_tokens_when_enabled` (lines 65-92).

**Add new fields (D-06, D-07):**

```python
# Audit-trail settings (Phase 7)
audit_raw_payload_max_bytes: int = Field(default=65_536, ge=1_024, le=1_048_576)
audit_raw_payload_hmac_key: SecretStr
```

**Add validator (D-07 — fail fast when key is missing/empty, mirror `_require_security_tokens_when_enabled` at lines 65-92):**

```python
@model_validator(mode="after")
def _require_audit_hmac_key(self) -> Self:
    if self.audit_raw_payload_hmac_key is None:
        raise ValueError("audit_raw_payload_hmac_key is required")
    raw = self.audit_raw_payload_hmac_key.get_secret_value()
    if raw is None or raw.strip() == "":
        raise ValueError("audit_raw_payload_hmac_key must be non-empty")
    return self
```

Add this validator alongside the existing `_require_security_tokens_when_enabled`. The auditor HMAC key is a separate secret from `operator_api_token` and `ingress_api_token` — it must not be the same string (consider extending the equality check to include the new key, mirroring the `operator_value == ingress_value` check at line 88).

---

### 11. `app/main.py` (app factory) — MODIFIED

**Analog:** `app/main.py:228-280` (the `create_app` body and router includes).

**Router-include pattern** (`app/main.py:266-274`):

```python
app.include_router(health_router)
app.include_router(ingress_router)
app.include_router(plugins_router)
app.include_router(config_status_router)
app.include_router(incidents_router)
app.include_router(metrics_router)
return app
```

**Add import (D-09):** near the existing `from app.api.routers.incidents import router as incidents_router` (line 8), add:

```python
from app.api.routers.audit import router as audit_router
```

**Add include (D-09, D-16):**

```python
app.include_router(audit_router)
```

Place this immediately after `app.include_router(incidents_router)` to keep operator routers adjacent. No other changes to `main.py` are required.

---

### 12. `migrations/versions/0003_create_incident_events.py` (migration) — NEW

**Analog sources:**
- Table + check constraints: `migrations/versions/0001_create_incidents.py` (whole file).
- Add-column pattern: `migrations/versions/0002_add_threshold_state.py` (whole file) — for the optional pattern, not needed here.
- `Base.metadata` discovery: `migrations/env.py:24` (`target_metadata = Base.metadata`).

**Header structure** (mirror `migrations/versions/0001_create_incidents.py:1-26`):

```python
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
```

**`upgrade()` shape** (deviation: JSONB GIN index + functional index on `decision_summary->>'no_dispatch_reason'`, both new patterns relative to `0001`):

```python
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
        sa.Column("incident_ids", postgresql.JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("incident_effect", sa.String(), nullable=False),
        sa.Column("decision_summary", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("normalized_event", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("raw_payload", postgresql.JSONB(), nullable=True),
        sa.Column("raw_payload_original_byte_length", sa.Integer(), nullable=True),
        sa.Column("raw_payload_stored_byte_length", sa.Integer(), nullable=True),
        sa.Column("raw_payload_truncated", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("redaction_version", sa.Integer(), nullable=True),
        sa.Column("redacted_path_count", sa.Integer(), nullable=True),
        sa.Column("raw_payload_hmac", sa.String(), nullable=True),
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
    # Cursor pagination (immutable tuple ordering) — btree on (accepted_at, id)
    op.create_index("ix_incident_events_accepted_at_id", "incident_events", ["accepted_at", "id"])
    # GIN index for incident_id containment (D-11, D-14). Uses postgresql_using="gin".
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
    op.create_index("ix_incident_events_incident_effect", "incident_events", ["incident_effect"])
    op.create_index("ix_incident_events_event_timestamp", "incident_events", ["event_timestamp"])
    # Functional index on the JSONB decision_summary field for the no_dispatch_reason filter (D-11).
    op.create_index(
        "ix_incident_events_no_dispatch_reason",
        "incident_events",
        [sa.text("(decision_summary ->> 'no_dispatch_reason')")],
    )
```

**`downgrade()` shape (deviation: drop EVERY created index in reverse order before dropping the table):**

```python
def downgrade() -> None:
    # Drop every index created in upgrade() in reverse order. Dropping the
    # table alone is not sufficient: each index must be dropped explicitly
    # or the migration may leave dangling artifacts and the downgrade will
    # fail on re-upgrade (PostgreSQL tracks indexes as separate objects).
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

The existing `migrations/versions/0001_create_incidents.py:67-69` (a 2-line downgrade that drops one index + the table) is too sparse for this case. The pattern-of-record here is "drop every created index in reverse order, then drop the table."

---

### 13. `tests/conftest.py` (test fixture) — MODIFIED

**Analog:** same file, `_SETTINGS_ENV_KEYS` tuple at lines 7-43.

**Current shape** (`tests/conftest.py:7-43`):

```python
_SETTINGS_ENV_KEYS = (
    "DATABASE_URL",
    "CORRELIA_DATABASE_URL",
    "CORRELIA_ENVIRONMENT",
    ...
    "CORRELIA_RATE_LIMIT_SWEEP_INTERVAL_SECONDS",
)
```

**Add the audit env keys (D-07):**

```python
_SETTINGS_ENV_KEYS = (
    ...,
    "CORRELIA_AUDIT_RAW_PAYLOAD_MAX_BYTES",
    "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
)
```

Place at the end of the tuple. The `clean_settings_env` autouse fixture (lines 46-50) picks up the new keys automatically — no body change needed.

---

### 14. `tests/test_domain_audit.py` (test, unit) — NEW

**Analog:** `tests/test_domain_incidents.py` (whole file).

**Pattern to mirror** (from `tests/test_domain_incidents.py` — model validator, version discipline, `extra="forbid"` rejection, bounded string enforcement). Each test should be a single-purpose function asserting one property of `AuditDecisionSummary`:
- schema_version defaults to `1`
- `extra="forbid"` rejects unknown fields
- `decision_kind` is one of the three literals
- `incident_effect` is one of the five literals
- `incident_ids` capped at 20 entries
- `affected_incident_count` is `>= 0`
- `no_dispatch_reason` bounded to 128 chars
- `decision_reason` bounded to 256 chars
- `recovery_resolution` is one of three literals or None

Mirror the `pytest.raises` + `pydantic.ValidationError` style used in `tests/test_domain_incidents.py`.

---

### 15. `tests/test_audit_redaction.py` (test, unit) — NEW

**No analog.** The redactor is a new component. The plan should specify the test contract directly from CONTEXT.md D-05/D-06/D-07:
- secret-keyed values (key matches `_FORBIDDEN_NOTE_FRAGMENTS` from `app/domain/incidents.py:33-41`) become `"[redacted]"`
- deeply nested paths are walked
- the HMAC is computed on the pre-redaction canonical payload
- `original_byte_length` reflects the pre-redaction byte length
- `stored_byte_length` is `<= max_bytes` after the semantic cap
- `truncated=True` is set when the semantic cap actually drops content
- `redacted_path_count` reflects the number of leaves rewritten

All tests are pure-Python (no Postgres), so this is the fastest redactor feedback loop.

---

### 16. `tests/test_audit_persistence.py` (test, integration) — NEW

**Analog:** `tests/test_incident_repository.py` (whole file).

**Pattern to mirror** (from `tests/test_incident_repository.py`):
- `PostgresContainer("postgres:18-alpine")` fixture (same as `tests/test_migrations.py:38-44`).
- `create_async_engine` + `async with engine.connect() as conn:` + `conn.run_sync(lambda sync_conn: sa.inspect(sync_conn).get_*)` for schema inspection.
- Async session writes to seed rows, then SELECT them back with the bounded projection to assert columns are not selected.

Tests must cover:
- Insert one row via `insert_incident_event`, then `list_incident_events` with a fresh session — assert `raw_payload` and full `normalized_event` are NOT in the projection (use a row-by-row column name check or assert against the DTO mapping).
- Cursor pagination round-trip on a 5-row seed.
- `incident_id` filter via JSONB containment (seed a row with `incident_ids = ['uuid-1', 'uuid-2']`, filter by `incident_id=uuid-1`, assert the row is returned; filter by `incident_id=uuid-99`, assert not).
- `has_incident=False` filter returns only `incident_effect='none'` rows (seed a no-op and an incident effect, assert only no-op).
- `no_dispatch_reason` filter uses the functional index — assert that filtering by `below_threshold` returns the right row.

---

### 17. `tests/test_audit_api.py` (test, integration) — NEW

**Analog:** `tests/test_incidents_api.py:30-200`.

**Pattern to mirror** (from `tests/test_incidents_api.py`):
- `_run_alembic_upgrade(database_url)` helper (lines 19-31).
- `postgres_url` module-scoped fixture (lines 34-43).
- `session_factory` per-test fixture (lines 46-50).
- `_settings()` factory (lines 60-72).
- `_app(session_factory)` factory (lines 75-95).
- `get_client(app)` AsyncClient context manager (lines 53-58).
- `AsyncClient` with `ASGITransport(app=app)` (per Phase 5 conventions).

Tests must cover (D-09, D-15, D-16):
- Unauthenticated request to `/v1/incident-events` returns 401 (Phase 5 `require_operator_token`).
- Authenticated request with no rows returns `items=[]`, `total=0`.
- Authenticated request returns bounded projection (no `raw_payload` key in the JSON response, no full `normalized_event` key — only `normalized_event_message` and `normalized_event_tags`).
- `has_incident=False` filter returns only no-op rows.
- Cursor pagination on a 5-row seed.
- `incident_id` filter (seed a row with a known incident id, filter by it).
- After ingress, exactly one audit row exists per accepted event (covers all five decision paths: problem-incident, problem-below-threshold, problem-replay, recovery-with-incident, recovery-noop, problem-no-rule).

---

### 18. `tests/test_migrations.py` (test, schema invariant) — MODIFIED

**Analog:** same file, all of the `test_*` functions.

**Pattern to mirror** (from `tests/test_migrations.py:23-200`):
- `PostgresContainer("postgres:18-alpine")` fixture.
- `await _run_alembic_upgrade(postgres_url)`.
- `create_async_engine` + `conn.run_sync(lambda sync_conn: sa.inspect(sync_conn).get_*)` for column, constraint, and index inspection.

Tests must cover (D-01, D-11, D-14):
- `test_migration_creates_incident_events_table` — assert `"incident_events" in tables` (mirror `test_migration_creates_incidents_table` at lines 47-58).
- `test_incident_events_columns_and_types` — assert the expected column set is present, `incident_ids`/`decision_summary`/`normalized_event`/`raw_payload` are JSONB, `accepted_at` is timestamp, `raw_payload_truncated` is boolean, `id` is UUID.
- `test_incident_events_check_constraints` — assert `ck_incident_events_event_type` / `ck_incident_events_severity` / `ck_incident_events_incident_effect` exist and their `sqltext` includes the expected values.
- `test_incident_events_gin_index` — assert `ix_incident_events_incident_ids_gin` exists, `dialect_options.postgresql_using == "gin"`, column is `incident_ids`.
- `test_incident_events_functional_index` — assert `ix_incident_events_no_dispatch_reason` exists with the `decision_summary ->> 'no_dispatch_reason'` expression.
- `test_incident_events_pagination_index` — assert `ix_incident_events_accepted_at_id` exists with `column_names == ["accepted_at", "id"]`.
- `test_audit_id_is_server_generated` — insert with no explicit `id` and assert the row has a non-null UUID (proves `gen_random_uuid()` server default works, D-13).

---

### 19. `tests/test_settings.py` (test, config validation) — MODIFIED

**Analog:** same file, Phase 5 token-validation tests at `tests/test_settings.py:55-126` (`test_auth_enabled_requires_both_tokens`, `test_auth_enabled_requires_non_empty_tokens`, `test_auth_enabled_requires_distinct_operator_and_ingress_tokens`, `test_tokens_stored_as_secret_str`, `test_token_validation_has_no_environment_bypass`).

**Deviation required by D-07 (unconditionally required HMAC key):** The audit HMAC key is **not** gated by `api_auth_enabled` — it is always required. Every existing call to `Settings(database_url=...)` and every `Settings` factory in test helpers (`tests/test_incidents_api.py:_settings`, `tests/test_size_limit.py:_settings`, `tests/test_domain_incidents.py`-style helpers, `tests/test_audit_api.py:_settings` to be added) must pass `audit_raw_payload_hmac_key=SecretStr("test-audit-hmac")` (or a similar non-empty value), otherwise the new `_require_audit_hmac_key` validator (entry 10) raises `ValidationError`.

**New tests to add (mirror the Phase 5 token-validation block):**

```python
# Mirror of test_auth_enabled_requires_both_tokens (tests/test_settings.py:60-...).
def test_audit_hmac_key_is_required() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            database_url=VALID_DATABASE_URL,
            operator_api_token=SecretStr("operator-secret"),
            ingress_api_token=SecretStr("ingress-secret"),
            # audit_raw_payload_hmac_key intentionally omitted
        )
    message = str(exc_info.value)
    assert "audit_raw_payload_hmac_key" in message

# Mirror of test_auth_enabled_requires_non_empty_tokens.
def test_audit_hmac_key_must_be_non_empty() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            database_url=VALID_DATABASE_URL,
            operator_api_token=SecretStr("operator-secret"),
            ingress_api_token=SecretStr("ingress-secret"),
            audit_raw_payload_hmac_key=SecretStr("   "),
        )
    errors = exc_info.value.errors()
    assert any(err["type"] == "value_error" for err in errors)

# Mirror of test_auth_enabled_requires_distinct_operator_and_ingress_tokens.
def test_audit_hmac_key_must_differ_from_auth_tokens() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            database_url=VALID_DATABASE_URL,
            operator_api_token=SecretStr("shared-secret"),
            ingress_api_token=SecretStr("ingress-secret"),
            audit_raw_payload_hmac_key=SecretStr("shared-secret"),
        )
    message = str(exc_info.value)
    assert "audit_raw_payload_hmac_key" in message

# Mirror of test_tokens_stored_as_secret_str.
def test_audit_hmac_key_stored_as_secret_str() -> None:
    from pydantic import SecretStr
    settings = Settings(
        database_url=VALID_DATABASE_URL,
        operator_api_token=SecretStr("operator-secret"),
        ingress_api_token=SecretStr("ingress-secret"),
        audit_raw_payload_hmac_key=SecretStr("audit-secret"),
    )
    assert isinstance(settings.audit_raw_payload_hmac_key, SecretStr)
    assert settings.audit_raw_payload_hmac_key.get_secret_value() == "audit-secret"

# New: default value for audit_raw_payload_max_bytes.
def test_audit_raw_payload_max_bytes_default() -> None:
    from pydantic import SecretStr
    settings = Settings(
        database_url=VALID_DATABASE_URL,
        operator_api_token=SecretStr("operator-secret"),
        ingress_api_token=SecretStr("ingress-secret"),
        audit_raw_payload_hmac_key=SecretStr("audit-secret"),
    )
    assert settings.audit_raw_payload_max_bytes == 65_536
```

**Settings helper impact — REQUIRED across all test files that build a `Settings` instance:**

| File | Helper | Patch |
|------|--------|-------|
| `tests/test_incidents_api.py:60-72` | `_settings()` | Add `audit_raw_payload_hmac_key=SecretStr("test-audit-hmac")` to the `Settings(...)` call. Without this patch, every existing `test_incidents_api.py` test that builds a `Settings` instance starts raising `ValidationError` once entry 10 lands. |
| `tests/test_size_limit.py:_settings` (see `tests/test_size_limit.py:2-50`) | `_settings()` | Same patch. |
| `tests/test_audit_api.py` (to be added) | `_settings()` | New helper, must include the key from the start. |
| `tests/test_migrations.py` | does not construct `Settings`; uses raw `DATABASE_URL` env var | No patch needed. |
| `tests/conftest.py` `_SETTINGS_ENV_KEYS` | (entry 13) | Add the env keys so the `clean_settings_env` fixture clears them between tests. |

The cross-cutting patch is mechanical: every `Settings(...)` call in tests needs the HMAC key. The plan should grep all `Settings(` call sites in `tests/` and patch each one in a single pre-flight commit before the audit-trail work lands.

---

### 20. `tests/test_size_limit.py` (test, route classification) — MODIFIED

**Analog:** same file, the parametrize block at the top of the file that drives `test_classify_path_maps_routes` (the test itself imports `classify_path` from `app.middleware.classification` and asserts prefix→class).

**Add a new parametrize case for `/v1/incident-events` (D-16):** the existing test is a `@pytest.mark.parametrize` over `(path, expected)`. The plan should add the row `("/v1/incident-events", "operator")` so the assertion `classify_path("/v1/incident-events") == "operator"` runs as part of the existing parametrized test, not as a brand-new test function.

**Pattern to mirror** (the parametrize rows in `tests/test_size_limit.py`):

```python
@pytest.mark.parametrize(
    ("path", "expected"),
    [
        ("/v1/icinga2/events", "ingress"),
        ("/v1/incidents", "operator"),
        ("/v1/incident-events", "operator"),  # NEW (D-16) — added alongside the existing operator cases
        ("/v1/rules", "operator"),
        ("/v1/topology", "operator"),
        ("/v1/plugins", "operator"),
        ("/v1/metrics", "metrics"),
        ("/v1/readyz", "readyz"),
        ("/v1/health", "health"),
    ],
)
def test_classify_path_maps_routes(path: str, expected: str) -> None:
    from app.middleware.classification import classify_path
    assert classify_path(path) == expected
```

**No other changes to `tests/test_size_limit.py` are required.** The existing `RequestSizeLimiterMiddleware` tests at the bottom of the file (oversized body, chunked body, under-cap body) are unaffected — they exercise the `default_limit` and `class_limits` paths, not the route-classification prefix table.

The same classification behaviour is also asserted by Phase 5 rate-limit tests (`tests/test_rate_limit.py`) through the middleware stack, so an end-to-end `GET /v1/incident-events` request inside the FastAPI app will exercise the rate-limit + auth inheritance. No separate parametrize change is needed in `tests/test_rate_limit.py` unless the planner wants belt-and-braces coverage; entry 20's parametrize addition is sufficient for the unit-level classification assertion.

---

## Shared Patterns

### Authentication (operator-token on read; ingress-token on write is unchanged)

**Source:** `app/api/security.py:36-48` (`require_operator_token`).

**Apply to:** `app/api/routers/audit.py` (the new read endpoint).

```python
def require_operator_token(
    settings: Annotated[Settings, Depends(get_app_settings)],
    credentials: HTTPAuthorizationCredentials | None = Security(_security),
) -> None:
    if not settings.api_auth_enabled:
        return
    expected = (
        settings.operator_api_token.get_secret_value()
        if settings.operator_api_token is not None
        else None
    )
    if not _token_matches(credentials, expected):
        raise Unauthorized()
```

Apply via `dependencies=[Security(require_operator_token)]` on the `APIRouter(prefix="/v1/incident-events", ...)` (entry 4). The ingress write path uses `require_ingress_token` on the existing `/v1/icinga2/events` router — audit writes happen inside `process_payload` which is reached only after that guard, so no new ingress-token wiring is required.

### Route classification

**Source:** `app/middleware/classification.py:7-16` (`ROUTE_CLASS_PREFIXES`).

**Apply to:** `app/middleware/classification.py` — append `("/v1/incident-events", "operator")` to the tuple (entry 9). This is what makes the Phase 5 auth + rate-limit middleware apply to the new route (D-16).

### Safe structured logging

**Source:** `app/processing/logging.py:22-57` (`safe_log_extra`, `SAFE_LOG_KEYS`).

**Apply to:** any audit-side control log (e.g., `audit_inserted`, `audit_cursor_invalid`, `audit_hmac_key_missing`). Use `safe_log_extra(event="audit_...", incident_id=..., effect=...)` — never log `raw_payload` or full `normalized_event`. The current `SAFE_LOG_KEYS` set does not include `event_id` or `fingerprint` directly, so emit `event="audit_inserted"` plus `incident_id=...` and `effect=...` (both already in the set).

### Settings fail-fast

**Source:** `app/config/settings.py:65-92` (`_require_security_tokens_when_enabled`).

**Apply to:** `app/config/settings.py` — new `_require_audit_hmac_key` validator (entry 10) mirrors the same pattern: read `get_secret_value()`, reject None/empty, raise `ValueError` with a clear message.

### Strict bounded Pydantic models

**Source:** `app/domain/incidents.py:48-83` (`DecisionContext`) and `:178-216` (response DTOs).

**Apply to:** `app/domain/audit.py` — every new model in that file (`AuditDecisionSummary`, `AuditEventListFilters`, `AuditEventResponse`, `AuditEventListResponse`) follows the same discipline: `model_config = ConfigDict(strict=True, extra="forbid")`, `schema_version: Literal[1] = 1`, bounded string types via `Annotated[str, Field(min_length=1, max_length=N)]`, tuples capped via `Field(max_length=N)`. Reuse `BoundedString` / `BoundedStringTuple` from `app/domain/incidents.py:28-29` (do not redeclare).

### SQLAlchemy 2.0 async session patterns

**Source:** `app/persistence/incidents.py:469-549` (async select + or_/and_ tuple pagination) and `:1-50` (imports for `and_`, `or_`, `select`, `func`).

**Apply to:** `app/persistence/audit.py` — every new async function follows the same import style. The `JSONB` import is reused (already imported at `app/persistence/incidents.py:18`). For JSONB-key access, the SQLAlchemy idiom is `IncidentEvent.decision_summary["no_dispatch_reason"].astext` (string-keyed JSONB subscript + cast to text). This is the same idiom the codebase would use for `decision_context` access if it needed it.

### Cursor encoding

**Source:** `app/persistence/incidents.py:436-456`.

**Apply to:** `app/persistence/audit.py` — same base64-urlsafe + JSON-dict + isoformat pattern, key change is the timestamp key (`accepted_at` not `last_update_time`) and the cursor dataclass fields.

### Settings env cleanup in tests

**Source:** `tests/conftest.py:7-43` (`_SETTINGS_ENV_KEYS`) and `:46-50` (`clean_settings_env` autouse fixture).

**Apply to:** `tests/conftest.py` — append the two new `CORRELIA_AUDIT_*` env keys (entry 13). The fixture body is unchanged.

### Testcontainers Postgres fixture

**Source:** `tests/test_migrations.py:38-44` and `tests/test_incidents_api.py:34-43`.

**Apply to:** `tests/test_audit_persistence.py` and `tests/test_audit_api.py` — copy the `PostgresContainer("postgres:18-alpine")` pattern, the URL rewriting `postgresql://` → `postgresql+asyncpg://`, and the module-scoped `postgres_url` fixture.

---

## No Analog Found

Files with no close match in the codebase (planner should use RESEARCH.md spec directly):

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `app/persistence/audit.py` (redactor) | utility | transform | No recursive redactor exists. The existing `DecisionContext.reject_secret_note_content` (`app/domain/incidents.py:71-83`) covers only flat key-value notes — it does not handle arbitrary JSON trees, nested dicts/lists, or semantic size capping. |
| `app/persistence/audit.py` (HMAC) | utility | crypto | No HMAC computation exists in the codebase. Use stdlib `hmac` + `hashlib.sha256` per RESEARCH.md "Don't Hand-Roll" table. |
| `tests/test_audit_redaction.py` | test | unit | No prior redactor test exists; the file is fully new. |

---

## Deviation Summary (recap of "use this pattern, BUT change X")

| File / Section | Pattern Source | Deviation |
|----------------|----------------|-----------|
| `app/persistence/models.py` `IncidentEvent.id` | `app/persistence/models.py:21-57` (Incident.id uses Python uuid4) | **Server-generated** UUID via `server_default=sa.func.gen_random_uuid()` (D-13) |
| `app/persistence/audit.py` `list_incident_events` projection | `app/persistence/incidents.py:469-549` (select(Incident) returns ORM entity) | **Explicit column projection** — no `raw_payload`, no full `normalized_event` selected; rows are mapped to bounded DTOs in the router (D-15) |
| `app/persistence/audit.py` cursor tuple | `(last_update_time, id)` at `app/persistence/incidents.py:436-456` | Tuple is `(accepted_at, id)` per D-10 |
| `app/persistence/audit.py` JSONB filter | `Incident.affected_hosts.contains([host])` at `app/persistence/incidents.py:476-477` | Filter on `IncidentEvent.incident_ids.contains([str(incident_id)])` — served by a GIN index, not the existing btree-less JSONB pattern |
| `app/api/routers/audit.py` filter dependency | `app/api/routers/incidents.py:84-105` | Adds `has_incident: bool \| None`, `no_dispatch_reason`, `event_timestamp_*`, `accepted_*` filters (D-11) |
| `app/api/routers/audit.py` endpoint mapping | `app/api/routers/incidents.py:107-127` | Maps row tuple → bounded `AuditEventResponse` (no raw payload, no full normalized event on the wire, D-15) |
| `app/processing/ingress.py` `process_payload` | self (current shape at `:54-220`) | Owns ONE session per accepted event with a SINGLE commit after audit insertion; covers all five decision paths (D-01, D-02) |
| `app/processing/incident_manager.py` `apply_problem` | self (current `:69-167`) | Remove `await self._session.commit()` at line 136; remove `_submit_notifications` invocation (D-02, D-03) |
| `app/processing/lifecycle.py` `resolve_for_event` | self (current `:58-91`) | Remove only the `await self._session.commit()` at line 79; **do not** touch `acknowledge`, `manual_close`, or `expire_stale_batch` (D-02 narrow scope) |
| `app/middleware/classification.py` tuple | self (`:7-16`) | Add one entry: `("/v1/incident-events", "operator")` (D-16) |
| `app/config/settings.py` fields + validator | self (`:8-92`) | Add `audit_raw_payload_max_bytes` (default 65_536) and `audit_raw_payload_hmac_key: SecretStr`; add `_require_audit_hmac_key` validator (D-06, D-07) |
| `migrations/versions/0003_*.py` `downgrade()` | `migrations/versions/0001_create_incidents.py:67-69` (2-line drop) | Drop EVERY created index in reverse order before dropping the table — the existing 2-line pattern is too sparse for this 9-index migration |
| `migrations/versions/0003_*.py` indexes | `migrations/versions/0001_create_incidents.py` (no GIN, no functional) | GIN index on `incident_ids` (`postgresql_using="gin"`) and functional index on `decision_summary->>'no_dispatch_reason'` (D-11, D-14) |
| `tests/conftest.py` `_SETTINGS_ENV_KEYS` | self (`:7-43`) | Append `CORRELIA_AUDIT_RAW_PAYLOAD_MAX_BYTES` and `CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY` (D-07) |
| `tests/test_migrations.py` | self (`:23-200`) | Add 7 new test functions mirroring the column/constraint/index inspection pattern for the new table and indexes |

---

## Metadata

**Analog search scope:** `app/`, `migrations/`, `tests/`
**Files scanned:** 35 (all files in `app/persistence/`, `app/processing/`, `app/api/`, `app/middleware/`, `app/config/`, `app/domain/`, `migrations/versions/`, plus representative tests in `tests/`)
**Pattern extraction date:** 2026-06-18
**Confidence:** HIGH — every line cited is grounded in the codebase, all deviations are tied to a specific locked decision (D-NN) from CONTEXT.md, and every "no analog" gap is explicitly listed.
