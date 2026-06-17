# Phase 6: Canonical Incident API Operation Parity - Pattern Map

**Mapped:** 2026-06-17
**Files analyzed:** 4 (3 modified source, 1 modified test)
**Analogs found:** 4 / 4 (all in-repo; patterns are within the same four files Phase 6 will touch — the existing cursor/filters/ack/close paths in this codebase are themselves the analogs)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `app/domain/incidents.py` | model (Pydantic schemas + StrEnum) | request-response | `app/domain/incidents.py` itself (`IncidentListFilters`, `IncidentListResponse`) | exact — same file, add fields to existing models |
| `app/persistence/incidents.py` | repository (async SQLAlchemy) | CRUD + cursor pagination | `app/persistence/incidents.py` itself (`list_incidents` cursor branch, `ack_open_incident`, `close_open_incident`) | exact — same file, extend `list_incidents` and reuse existing lifecycle functions |
| `app/api/routers/incidents.py` | controller (FastAPI router) | request-response | `app/api/routers/incidents.py` itself (`incident_list_filters` dep, `acknowledge_incident`, `close_incident_endpoint`) | exact — same file, add `offset` query param and PATCH/DELETE handlers beside existing POST ones |
| `tests/test_incidents_api.py` | test (pytest + httpx.ASGITransport) | request-response | `tests/test_incidents_api.py` itself (`test_list_incidents_filters_and_cursor_pagination`, `test_ack_is_idempotent_and_keeps_incident_open`, `test_manual_close_is_idempotent_and_frees_open_slot`) | exact — same file, add new tests beside existing ones using identical fixtures |

No external-package analogs apply — Phase 6 is pure code work within the existing FastAPI / Pydantic v2 / SQLAlchemy 2.0 async stack. All patterns are in the four target files.

## Pattern Assignments

### `app/domain/incidents.py` (model, request-response)

**Analog:** `app/domain/incidents.py` itself (the same file holds every model Phase 6 extends).

**Import block / StrEnum precedent** (`app/domain/incidents.py:1-15`) — this is the model the new `IncidentStatusFilter` StrEnum must follow; it is the canonical StrEnum that `IncidentStatus` defines today, and Phase 6 adds a sibling StrEnum *in this same file* rather than mutating the canonical enum:

```python
from __future__ import annotations
...
from app.domain.events import Severity, TagKey, TagValue


class IncidentStatus(StrEnum):
    OPEN = "OPEN"
    RESOLVED = "RESOLVED"
    CLOSED = "CLOSED"


BoundedString = Annotated[str, Field(min_length=1, max_length=256)]
```

The new `IncidentStatusFilter` MUST live beside `IncidentStatus` (StrEnum, query-filter-only). It must NOT inherit from or extend `IncidentStatus` — the canonical `IncidentStatus` is consumed by the DB CHECK constraint and by `IncidentDetailResponse.status` (typed `status: IncidentStatus` at `app/domain/incidents.py:170`) and must remain `OPEN | RESOLVED | CLOSED`.

**`IncidentStatusFilter` required member set** (D-08): the new enum MUST declare exactly four members, in this order, so existing Correlia `?status=...` callers keep working AND `ACKNOWLEDGED` is accepted on the wire:

```python
class IncidentStatusFilter(StrEnum):
    OPEN = "OPEN"
    ACKNOWLEDGED = "ACKNOWLEDGED"
    RESOLVED = "RESOLVED"
    CLOSED = "CLOSED"
```

Critical: `RESOLVED` MUST be present. The compatibility surface focuses on `OPEN`/`ACKNOWLEDGED`/`CLOSED` (D-08), but `RESOLVED` remains available for canonical use and dropping it would silently break `?status=RESOLVED` callers — Phase 6 must preserve all existing Correlia status values plus the new `ACKNOWLEDGED` alias. Do not add an `int` value, do not add a method, do not extend `IncidentStatus`.

**`StrEnum` config note (do NOT do this):** a `StrEnum` is not a `BaseModel` subclass; Pydantic v2 will reject a `model_config = ConfigDict(...)` line on it. The new `IncidentStatusFilter` must be a plain StrEnum with member declarations only — no `model_config`, no `model_config_json_schema_extra`, no `field_validator`. FastAPI's `Query` binding validates the wire value against the enum members at request time; that is sufficient.

**`IncidentListFilters` shape** (`app/domain/incidents.py:149-171`) — current model. Two changes are required on this class:

1. `status: IncidentStatus | None` → `status: IncidentStatusFilter | None`. The dependency (`app/api/routers/incidents.py:64-79`) widens `status` to `IncidentStatusFilter` to accept `ACKNOWLEDGED` on the wire; if the model field stays `IncidentStatus | None`, Pydantic will reject the assignment at request-binding time, and `?status=ACKNOWLEDGED` will 422 with the global list-shaped error rather than reaching the SQL translation. The persistence layer must then translate `filters.status == IncidentStatusFilter.ACKNOWLEDGED` to a compound WHERE on `OPEN + acknowledged_at IS NOT NULL + acknowledged_by IS NOT NULL` (D-05). The non-pagination `if filters.status is not None` block in `list_incidents` must be replaced with the ACKNOWLEDGED-aware `if/elif` chain (see "Status-filter dispatch" below).
2. Add `offset: int | None = None` (default `None`, bounded by `Field(ge=0)`). **`None` is the explicit discriminator** between "caller did not supply `offset`" (the existing cursor-first-page path with `next_cursor`) and "caller supplied `offset`" (the new offset branch). A `default=0` would collapse both cases and silently change the no-param endpoint behavior, breaking D-01's "both cursor and offset" contract. The default-`0` value lives on the response/page (`IncidentListResponse.offset`, `IncidentListPage.offset`), not on the filter. On the Pydantic model, either `offset: Annotated[int, Field(ge=0)] | None = None` or `offset: Annotated[int | None, Field(ge=0)] = None` is acceptable — the file's existing `cursor: Annotated[str, Field(min_length=1, max_length=512)] | None = None` precedent favors the first form.

Required new shape (in the same file, replacing lines 149-171):

```python
class IncidentListFilters(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    status: IncidentStatusFilter | None = None
    severity: Severity | None = None
    rule_name: BoundedString | None = None
    host: BoundedString | None = None
    service: BoundedString | None = None
    updated_since: datetime | None = None
    limit: int = Field(default=50, ge=1, le=200)
    cursor: Annotated[str, Field(min_length=1, max_length=512)] | None = None
    offset: Annotated[int, Field(ge=0)] | None = None

    @field_validator("updated_since", mode="after")
    @classmethod
    def require_updated_since_timezone(cls, value: datetime | None) -> datetime | None:
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("updated_since must be timezone-aware")
        return value
```

Pattern notes:
- The `Field(default=50, ge=1, le=200)` and `Annotated[str, Field(min_length=1, max_length=512)]` idioms are how bounded fields are declared in this file; the new `offset` follows the bounded-int idiom without an upper bound (Pydantic `Optional` + `Field(ge=0)`).
- The `status` retype touches every site that constructs `IncidentListFilters` — currently only the router dependency at `app/api/routers/incidents.py:64-79`. The persistence filter clause must compare against `IncidentStatusFilter.ACKNOWLEDGED` (a member of the new enum, not the canonical `IncidentStatus`); `IncidentStatusFilter` MUST be added to the `from app.domain.incidents import (...)` block at `app/persistence/incidents.py:14-21` — current imports cover only `DecisionContext, IncidentListFilters, IncidentStatus, IncidentWindowState, validate_incident_transition`, so the new comparison would otherwise be undefined.

**`IncidentListResponse` shape** (`app/domain/incidents.py:188-193`) — currently:

```python
class IncidentListResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    items: tuple[IncidentDetailResponse, ...] = Field(max_length=200)
    next_cursor: str | None = None
```

D-02 requires the new `total` / `limit` / `offset` fields to be **always-present non-null ints** on the response envelope (Vigilo clients read them without null checks). Do NOT default them to `None`; do NOT use `Optional[]`. The required shape is non-null `int` with `Field(default=..., ge=..., le=...)` bounds, mirroring the existing `limit` style at `app/domain/incidents.py:159`:

```python
class IncidentListResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    items: tuple[IncidentDetailResponse, ...] = Field(max_length=200)
    total: int = Field(default=0, ge=0)
    limit: int = Field(default=50, ge=1, le=200)
    offset: int = Field(default=0, ge=0)
    next_cursor: str | None = None
```

Notes:
- `total: int = Field(default=0, ge=0)` — always present; `0` is the legitimate "no rows" answer, not a sentinel.
- `limit: int = Field(default=50, ge=1, le=200)` — mirrors the `limit` bound on `IncidentListFilters`; Pydantic will reject the `IncidentListResponse(...)` construction call in the router if the router forwards an out-of-range value.
- `offset: int = Field(default=0, ge=0)` — always present; `0` is the legitimate "first page" answer for cursor paths (persistence passes `0` on the cursor path and `filters.offset` on the offset path).
- `next_cursor` stays `str | None = None` (cursor trailing to preserve the field that cursor-only consumers read; the rest of the envelope is non-null ints).
- Field ordering: `items, total, limit, offset, next_cursor` — stable for Vigilo clients; cursor trails the new non-null metadata.

**`IncidentAckRequest` / `IncidentCloseRequest` validation pattern** (`app/domain/incidents.py:195-218`) — these exist as the reference for any Pydantic body model with a `hide_input_in_errors` flag, but Phase 6 does NOT add a Pydantic body model for PATCH (see "Manual PATCH body parsing" below). The relevant pattern is the *config* line:

```python
class IncidentAckRequest(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", hide_input_in_errors=True)
    ...
```

`hide_input_in_errors=True` is the project pattern for hiding the offending value from the global 422 detail; useful as a reference if any auxiliary model is added.

---

### `app/persistence/incidents.py` (repository, CRUD + cursor pagination)

**Analog:** `app/persistence/incidents.py` itself — the cursor branch of `list_incidents` is the exact pattern to mirror for the new offset branch.

**Imports** (`app/persistence/incidents.py:1-22`) — Phase 6 needs to add `IncidentStatusFilter` to the `from app.domain.incidents import (...)` block at lines 14-21 (current imports cover only `DecisionContext, IncidentListFilters, IncidentStatus, IncidentWindowState, validate_incident_transition` — the new ACKNOWLEDGED comparison in `list_incidents` would otherwise be undefined). No new external imports; `func` is already imported at line 10, so `func.count` is available for the new `COUNT(*)` subquery.

```python
from sqlalchemy import Integer, and_, case, func, literal, or_, select, text, update
```

**`IncidentListPage` dataclass** (`app/persistence/incidents.py:225-228`) — currently a 2-field frozen dataclass. Phase 6 adds `total: int` and `offset: int` here so the router endpoint can pass them through to the response model. Persistence populates `offset` as `0` for the cursor path and `filters.offset` for the offset path — the response field is always present (D-02), only the *filter* field is `None`-discriminated.

```python
@dataclass(frozen=True, slots=True)
class IncidentListPage:
    incidents: tuple[Incident, ...]
    next_cursor: str | None
```

Required new shape (after Phase 6 edit, in the same file, replacing lines 225-228):

```python
@dataclass(frozen=True, slots=True)
class IncidentListPage:
    incidents: tuple[Incident, ...]
    next_cursor: str | None
    total: int
    offset: int
```

This is a frozen dataclass — callers must update both construction sites. The router at `app/api/routers/incidents.py:101-115` only consumes `.incidents` and `.next_cursor`; both must be updated to forward `.total` and `.offset`.

**`list_incidents` cursor branch** (`app/persistence/incidents.py:458-497`) — the precise structural layout that Phase 6 must respect when inserting the offset branch, the COUNT subquery, and the ACKNOWLEDGED status filter. The body of `list_incidents` is divided into three non-overlapping regions:

- **Non-pagination filter clauses** (the `if filters.X is not None: stmt = stmt.where(...)` block for `status`, `severity`, `rule_name`, `host`, `service`, `updated_since`). **The cursor predicate is NOT in this region** — see below. These clauses are the matching predicate set; `total` is derived from a `stmt` that carries only these clauses.
- **Cursor predicate** (`if filters.cursor is not None: cursor = decode_incident_cursor(filters.cursor); stmt = stmt.where(or_(...))`). This is **pagination**, not a filter — it is NOT part of the matching-count set. It lives AFTER the non-pagination filters and BEFORE the ORDER BY.
- **ORDER BY + LIMIT** (`stmt = stmt.order_by(Incident.last_update_time.desc(), Incident.id.desc()).limit(filters.limit + 1)`), then **execute / slice / next_cursor encode / return**.

The shared base filter build (non-pagination predicates only) is the source of truth for both the count and the page query. The cursor predicate is **pagination**, not a filter — it is NOT part of the matching-count set. Required query construction order:

1. Build a `base_stmt = select(Incident)` and apply only the non-pagination filter clauses (`status`, `severity`, `rule_name`, `host`, `service`, `updated_since`). At this point `base_stmt` represents the matching predicate set.
2. Compute `total = await session.scalar(select(func.count()).select_from(base_stmt.subquery())) or 0`. The count uses the base stmt before any cursor/offset/ordering.
3. Build a separate `page_stmt = select(Incident)` and apply the same non-pagination filters, then branch on `page_stmt`:
   - If `filters.cursor is not None`: decode the cursor and apply the cursor predicate to `page_stmt`. The branch for cursor wins over offset (D-03). Then apply the shared ORDER BY + `LIMIT filters.limit + 1` (the `+1` lets the existing `next_cursor` detection work — see step 4).
   - Else if `filters.offset is not None`: skip the cursor predicate; `page_stmt` carries only the base filters. Then apply the shared ORDER BY + `.offset(filters.offset).limit(filters.limit)` (NO `+1` — offset pages are bounded to exactly `limit` rows, `next_cursor` is `None` for the offset path per D-02).
   - Else: skip both cursor and offset; this is the existing no-param default path. Apply the shared ORDER BY + `LIMIT filters.limit + 1` (the `+1` preserves cursor first-page behavior for pre-Phase-6 callers, who expect `next_cursor` to be populated when more rows exist).
4. The shared `ORDER BY last_update_time DESC, id DESC` is identical across all three branches; the limit operation differs:
   - Cursor branch: `page_stmt.limit(filters.limit + 1)`.
   - No-param branch: `page_stmt.limit(filters.limit + 1)` (same as cursor — preserves existing behavior).
   - Offset branch: `page_stmt.offset(filters.offset).limit(filters.limit)` (the only branch that calls `.offset(...)` and the only branch without the `+1`).
   The `(last_update_time desc, id desc)` ordering MUST be preserved by the new offset branch (D-01 ordering invariant).
5. Execute `page_stmt`; for the cursor and no-param branches use the existing `limit + 1` / `rows[:limit]` / `next_cursor` pattern (the `if len(rows) > filters.limit: ... next_cursor = encode_incident_cursor(...)`) to detect more pages and emit `next_cursor`. For the offset branch, `incidents = rows` (no `+1` slicing, no `next_cursor` — `next_cursor` stays `None` per D-02).

The existing code:

```python
async def list_incidents(
    session: AsyncSession,
    filters: IncidentListFilters,
) -> IncidentListPage:
    stmt = select(Incident)
    if filters.status is not None:
        stmt = stmt.where(Incident.status == filters.status.value)
    if filters.severity is not None:
        stmt = stmt.where(Incident.severity == filters.severity.value)
    if filters.rule_name is not None:
        stmt = stmt.where(Incident.rule_name == filters.rule_name)
    if filters.host is not None:
        stmt = stmt.where(Incident.affected_hosts.contains([filters.host]))
    if filters.service is not None:
        stmt = stmt.where(Incident.affected_services.contains([filters.service]))
    if filters.updated_since is not None:
        stmt = stmt.where(Incident.last_update_time >= filters.updated_since)
    if filters.cursor is not None:
        cursor = decode_incident_cursor(filters.cursor)
        stmt = stmt.where(
            or_(
                Incident.last_update_time < cursor.last_update_time,
                and_(
                    Incident.last_update_time == cursor.last_update_time,
                    Incident.id < cursor.id,
                ),
            )
        )
    stmt = stmt.order_by(Incident.last_update_time.desc(), Incident.id.desc()).limit(
        filters.limit + 1
    )
    result = await session.execute(stmt)
    rows = tuple(result.scalars().all())
    incidents = rows[: filters.limit]
    next_cursor = None
    if len(rows) > filters.limit:
        last = incidents[-1]
        next_cursor = encode_incident_cursor(
            IncidentCursor(last_update_time=last.last_update_time, id=last.id)
        )
    return IncidentListPage(incidents=incidents, next_cursor=next_cursor)
```

Patterns to follow exactly:
- **Two-statement construction** is required: `base_stmt` (non-pagination filters only, used for `total`) and `page_stmt` (base filters + cursor/offset branch + ORDER BY + LIMIT, used for the page). Do NOT reuse the same `stmt` for both — the cursor predicate must NOT contaminate `total`.
- The `limit + 1` / `rows[:limit]` / `next_cursor` pattern is the cursor convention. It also applies to the no-param default path (preserves pre-Phase-6 behavior). The offset branch does NOT use the `+1` trick; offset pages are exactly `limit` rows and `next_cursor` is `None` (D-02).
- The dependency injection pattern — `async def list_incidents(session: AsyncSession, filters: IncidentListFilters) -> IncidentListPage` — must not change. The router dependency wires the session.
- Branch order on `page_stmt`: (a) cursor wins if `filters.cursor is not None` (D-03); (b) else offset branch if `filters.offset is not None`; (c) else the existing no-param cursor-first-page behavior — this MUST stay as it is today so that pre-Phase-6 callers that hit `GET /v1/incidents` with no params still get the cursor first page. Persistence decides the branch; router just consumes `page.total` / `page.offset`.
- For D-05 ACKNOWLEDGED SQL translation: **REPLACE** the existing `if filters.status is not None: stmt = stmt.where(Incident.status == filters.status.value)` block (the first non-pagination filter clause in the body) with an `if/elif` chain that handles `ACKNOWLEDGED` first. The canonical `IncidentStatus` enum covers only `OPEN`/`RESOLVED`/`CLOSED`, so the existing `Incident.status == filters.status.value` line would translate `status="ACKNOWLEDGED"` to a column equality that never matches (no row has `status='ACKNOWLEDGED'` in the DB; the DB CHECK constraint forbids it per `migrations/versions/0001_create_incidents.py:67-70`). The required shape is:

  ```python
  if filters.status == IncidentStatusFilter.ACKNOWLEDGED:
      stmt = stmt.where(
          Incident.status == IncidentStatus.OPEN.value,
          Incident.acknowledged_at.is_not(None),
          Incident.acknowledged_by.is_not(None),
      )
  elif filters.status is not None:
      stmt = stmt.where(Incident.status == filters.status.value)
  ```

  This `if/elif` is a non-pagination filter and MUST be applied to **both** `base_stmt` (for `total`) and `page_stmt` (for the page) so the count and the page agree on what "matches the filters" means. The `is_not(None)` predicate is a standard SQLAlchemy Column operator; it is the required new code, not a reference to an existing pattern in this file. The `where(Incident.status == IncidentStatus.OPEN.value)` style is the existing precedent (used at the top of `ack_open_incident` and `close_open_incident` for the OPEN-state row lock).

**`ack_open_incident` signature** (`app/persistence/incidents.py:1040-1106`) — Phase 6 PATCH/DELETE handlers call this verbatim:

```python
async def ack_open_incident(
    ...
) -> LifecycleWriteResult | None:
    selected = await session.execute(
        select(Incident)
        .where(Incident.id == incident_id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .with_for_update()
    )
    incident = selected.scalar_one_or_none()
    if incident is None:
        current = await session.execute(select(Incident).where(Incident.id == incident_id))
        row = current.scalar_one_or_none()
        if row is None:
            return None
        return LifecycleWriteResult(
            incident=row,
            effect="noop",
            ...
        )
    ...
    result = await session.execute(
        update(Incident)
        .where(Incident.id == incident_id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .values(
            acknowledged_at=func.coalesce(Incident.acknowledged_at, func.now()),
            acknowledged_by=operator,
            decision_context=decision_context,
            updated_at=func.now(),
        )
        .returning(*Incident.__table__.columns)
    )
```

Patterns:
- Function is idempotent in the D-14 sense (returns 200 with the current incident state on repeat calls) but it is NOT a noop on repeat ACK: an acknowledged incident is still `status == OPEN` (D-05), so the `where(Incident.status == IncidentStatus.OPEN.value)` predicate at the top of the function still matches, the row falls through to the UPDATE block, and the write re-runs. The UPDATE uses `acknowledged_at=func.coalesce(Incident.acknowledged_at, func.now())` so the original acknowledgement timestamp is preserved; `acknowledged_by` is OVERWRITTEN with the new operator; `updated_at` is bumped. The noop branch (`if incident is None: ...`) is reached only when the row does not exist at all (`return None`) or when the row is in a non-OPEN terminal state (`RESOLVED`/`CLOSED`, returning `effect="noop"`). PATCH `ACKNOWLEDGED` calls do NOT hit the noop branch on a healthy lifecycle — they re-run the UPDATE.
- Signature: `async def ack_open_incident(session, incident_id, *, operator)` (keyword-only operator). PATCH/DELETE callers pass `operator="vigilo-compat"`.
- Returns `LifecycleWriteResult | None` — `None` means the incident_id does not exist at all; router maps that to 404.
- **Idempotency caveat for tests:** because repeat ACK re-runs the UPDATE rather than hitting the noop branch, `updated_at` differs between the first and second PATCH `ACKNOWLEDGED` calls (the second call bumps it via `func.now()`). `acknowledged_at` is preserved by `coalesce` so the second call's `acknowledged_at` equals the first call's; `acknowledged_by` is overwritten to `"vigilo-compat"` on both calls (same value, so still equal); `status` remains `OPEN` for both. Stable semantic fields for D-14 assertions: `["status"]` and `["acknowledgement"]["acknowledged_by"]`. Tests must NOT assert full body equality (because `updated_at` changes) and must NOT assert `acknowledged_at` equality across calls (it is preserved, but the safe assertion is the semantic fields, not the timestamp).

**`close_open_incident` signature** (`app/persistence/incidents.py:1108-1180`) — PATCH and DELETE handlers both call this:

```python
async def close_open_incident(
    session: AsyncSession,
    incident_id: UUID,
    *,
    operator: str,
    reason: str,
) -> LifecycleWriteResult | None:
    selected = await session.execute(
        select(Incident)
        .where(Incident.id == incident_id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .with_for_update()
    )
    ...
    target = validate_incident_transition(IncidentStatus.OPEN, IncidentStatus.CLOSED)
    result = await session.execute(
        update(Incident)
        .where(Incident.id == incident_id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .values(
            status=target.value,
            decision_context=decision_context,
            closed_at=func.now(),
            updated_at=func.now(),
        )
        .returning(*Incident.__table__.columns)
    )
```

Patterns:
- Signature: `async def close_open_incident(session, incident_id, *, operator, reason)`. PATCH/DELETE callers pass `operator="vigilo-compat", reason="vigilo-compat"`.
- Idempotency in the D-14 sense is achieved differently than ACK: the first successful close moves the row out of `OPEN` (status becomes `CLOSED`). On a repeat close, the `where(Incident.status == IncidentStatus.OPEN.value)` predicate at the top of the function no longer matches, `selected.scalar_one_or_none()` returns `None`, and the noop branch returns the existing row with `effect="noop"`. The row is NOT updated, so `closed_at`, `updated_at`, and `status` are all unchanged from the first call.
- The noop branch is also reached when the row is `RESOLVED` (already non-OPEN), and `return None` is reached when the incident_id does not exist.
- `validate_incident_transition(IncidentStatus.OPEN, IncidentStatus.CLOSED)` is invoked inside the function — domain-layer validation, raises `ValueError` on illegal transitions.
- **Idempotency caveat for tests:** repeat PATCH/DELETE `CLOSED` returns the existing closed row from the noop branch with no UPDATE applied. The first call's body and the second call's body are byte-identical: `status == "CLOSED"`, `closed_at` unchanged, `updated_at` unchanged. Stable semantic fields for D-14 assertions: `["status"]`. The existing test in this file does not test PATCH/DELETE; new tests follow the existing POST-endpoint shape but assert semantic fields, not whole-body equality (the ACK case differs from the CLOSE case — see the contrast above; tests for each case must assert the right fields).

**`LifecycleWriteResult` consumers** — both lifecycle functions return objects with `.incident` (the persisted row) and `.effect` (one of `"noop"`, `"acknowledged"`, `"closed"`). The router reads `.incident` to build the response.

---

### `app/api/routers/incidents.py` (controller, request-response)

**Analog:** the same file — the existing `incident_list_filters` dependency, `acknowledge_incident` endpoint, and `close_incident_endpoint` are the exact patterns the new `offset` query parameter and PATCH/DELETE handlers must follow.

**Imports** (`app/api/routers/incidents.py:1-23`) — already cover every symbol Phase 6 needs (`APIRouter`, `Body`, `Depends`, `HTTPException`, `Query`, `Security`, `Request` already covered by `fastapi`, `async_sessionmaker`, `AsyncSession`, `safe_log_extra`):

```python
from fastapi import APIRouter, Body, Depends, HTTPException, Query, Security, status

from app.api.security import require_operator_token
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import get_sessionmaker
from app.domain.events import Severity
from app.domain.incidents import (
    Acknowledgement,
    DecisionContext,
    IncidentAckRequest,
    IncidentCloseRequest,
    IncidentDetailResponse,
    IncidentListFilters,
    IncidentListResponse,
    IncidentStatus,
)
from app.persistence.incidents import (
    ack_open_incident,
    close_open_incident,
    get_incident_by_id,
    list_incidents,
)
from app.processing.logging import safe_log_extra
from app.persistence.models import Incident
```

Phase 6 must add: `Request` to the FastAPI import line (for PATCH manual body parsing), and `IncidentStatusFilter` to the `from app.domain.incidents import (...)` block.

**Router-level auth** (`app/api/routers/incidents.py:24`) — applies to every endpoint on this router, including the new PATCH/DELETE:

```python
router = APIRouter(prefix="/v1/incidents", dependencies=[Security(require_operator_token)])
```

No new auth wiring. PATCH and DELETE inherit `require_operator_token` automatically.

**`incident_list_filters` dependency** (`app/api/routers/incidents.py:64-79`) — pattern for adding the new `offset` parameter and retargeting `status` to `IncidentStatusFilter`:

```python
def incident_list_filters(
    status_filter: Annotated[IncidentStatus | None, Query(alias="status")] = None,
    severity: Severity | None = None,
    rule_name: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    host: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    service: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    updated_since: datetime | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    cursor: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
) -> IncidentListFilters:
    return IncidentListFilters(
        status=status_filter,
        severity=severity,
        rule_name=rule_name,
        host=host,
        service=service,
        updated_since=updated_since,
        limit=limit,
        cursor=cursor,
    )
```

Patterns:
- Each query parameter is `Annotated[T | None, Query(...)] = None` (or a default for `limit`).
- `alias="status"` is the existing pattern for the `status_filter` parameter; the new `offset` parameter does NOT need an alias (the Python name matches the query string).
- Add `offset: Annotated[int | None, Query(ge=0)] = None` to the signature. **The `Query` metadata MUST wrap the entire `int | None` annotation** (not just the `int` part) so FastAPI reliably preserves the `ge=0` constraint on the wire; `Annotated[int, Query(ge=0)] | None` can drop the constraint at binding time. **`None` is mandatory** — the persistence layer uses `is None` to discriminate the cursor-first-page path from the offset branch (D-01/D-03). A `default=0` would silently change pre-Phase-6 caller behavior and break D-01.
- Retarget the `status_filter` annotation from `IncidentStatus | None` to `IncidentStatusFilter | None` so `ACKNOWLEDGED` is accepted on the wire (D-08). The model field in `IncidentListFilters` is also `IncidentStatusFilter | None` (see "IncidentListFilters shape" above), so the assignment at `return IncidentListFilters(status=status_filter, ...)` is type-compatible end-to-end. The persistence layer translates `IncidentStatusFilter.ACKNOWLEDGED` to a WHERE clause on `OPEN + acknowledged_at/acknowledged_by IS NOT NULL` (D-05). Do NOT use `IncidentStatusFilter` for PATCH dispatch (D-10 — see PATCH guidance below).

**`list_incidents_endpoint`** (`app/api/routers/incidents.py:81-99`) — pattern for forwarding the new `total`/`limit`/`offset` fields to the response:

```python
@router.get("", response_model=IncidentListResponse)
async def list_incidents_endpoint(
    filters: Annotated[IncidentListFilters, Depends(incident_list_filters)],
    sessionmaker: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_sessionmaker)
    ],
) -> IncidentListResponse:
    async with sessionmaker() as session:
        try:
            page = await list_incidents(session, filters)
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="invalid cursor",
            ) from exc
    return IncidentListResponse(
        items=tuple(_incident_response(incident) for incident in page.incidents),
        next_cursor=page.next_cursor,
    )
```

Patterns:
- The 400 on `ValueError` from `decode_incident_cursor` is the cursor-decode failure mapping. Phase 6 must preserve this exactly.
- The `page.next_cursor` mapping is the precedent for forwarding new page fields. Add `total=page.total, limit=filters.limit, offset=page.offset` to the response construction. D-02 says these are always present — `offset=0` for the cursor path, `offset=filters.offset` for the offset path (persistence decides; router just passes through).
- No 422 logic belongs in this handler — invalid query params are caught by FastAPI's query validation and go through the global handler (see "Manual PATCH body parsing" below for the body-handler contrast).

**`acknowledge_incident` endpoint** (`app/api/routers/incidents.py:131-158`) — full pattern for the PATCH/DELETE handlers (idempotency check, logger emit, response shape):

```python
@router.post("/{incident_id}/ack", response_model=IncidentDetailResponse)
async def acknowledge_incident(
    incident_id: UUID,
    sessionmaker: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_sessionmaker)
    ],
    body: IncidentAckRequest = Body(...),
) -> IncidentDetailResponse:
    async with sessionmaker() as session:
        result = await ack_open_incident(session, incident_id, operator=body.operator)
        if result is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="incident not found")
        await session.commit()
        logger.info(
            "incident acknowledged",
            extra=safe_log_extra(
                event="operator_mutation",
                incident_id=str(result.incident.id),
                status=result.incident.status,
                effect=result.effect,
                reason="acknowledged",
                operator=body.operator,
            ),
        )
    return _incident_response(result.incident)
```

Patterns:
- `response_model=IncidentDetailResponse` is mandatory for all router endpoints (Phase 5 requirement; new PATCH/DELETE handlers must follow).
- `if result is None: raise HTTPException(404, "incident not found")` is the canonical not-found mapping for the lifecycle functions.
- `await session.commit()` after the lifecycle call (the lifecycle functions don't commit themselves).
- `logger.info(..., extra=safe_log_extra(event="operator_mutation", ...))` is the audit-log idiom. New PATCH/DELETE handlers must emit a `safe_log_extra(event="operator_mutation", ...)` with `reason="acknowledged"` (PATCH status=ACKNOWLEDGED) or `reason="manual_close"` (PATCH/DELETE status=CLOSED), `operator="vigilo-compat"`, and `effect` from `result.effect`. See `app/processing/logging.py:38-54` for `safe_log_extra` signature.
- `body: IncidentAckRequest = Body(...)` is the existing Pydantic-body precedent. The PATCH endpoint does NOT use this pattern (see below) because D-15/D-16/D-17 require compact-string 422 details that bypass the global handler.

**`close_incident_endpoint`** (`app/api/routers/incidents.py:160-189`) — same shape as `acknowledge_incident` but with `close_open_incident(session, incident_id, operator=body.operator, reason=body.reason)`. Phase 6 PATCH/DELETE handlers reuse this entire scaffold, substituting `operator="vigilo-compat"` (and `reason="vigilo-compat"` for the close case) and emitting the same `safe_log_extra` audit log.

**Manual PATCH body parsing — required for D-15/D-16/D-17** — the project has a global `RequestValidationError` handler at `app/main.py:48-58` that produces `{"detail": [...]}` (list, not string):

```python
async def request_validation_exception_handler(
    _request: Request,
    exc: Exception,
) -> JSONResponse:
    if not isinstance(exc, RequestValidationError):
        raise exc
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        content={"detail": _safe_validation_errors(exc)},
    )
```

`app/main.py` registers it via `app.add_exception_handler(RequestValidationError, request_validation_exception_handler)`. Any Pydantic-body endpoint that fails validation produces the list shape, not the compact string D-16/D-17 require. Therefore the new PATCH handler must:
- Take `request: Request` (not a Pydantic model).
- Call `await request.json()` inside a `try/except` — any decode error → `HTTPException(422, "status is required")` (D-17).
- Check `isinstance(body, dict)` — non-dict (list, scalar, null) → `HTTPException(422, "status is required")` (D-17).
- Check `any(k != "status" for k in body)` — extra key (e.g. `"summary"`) → `HTTPException(422, "summary mutation is not supported")` (D-15/D-16). This must run before the `status` value check so that `{"summary": "x"}` and `{"status":"ACKNOWLEDGED","summary":"x"}` both return the summary-mutation message.
- Check `body.get("status")` against raw string literals `"ACKNOWLEDGED"` / `"CLOSED"` ONLY (D-10; do NOT use `IncidentStatusFilter` here because it includes `OPEN`/`RESOLVED` which are not valid PATCH targets). `{}`, missing key, `None`, `"OPEN"`, `"RESOLVED"`, unknown strings, non-string values → `HTTPException(422, "status is required")` (D-17).
- Dispatch: `"ACKNOWLEDGED"` → `ack_open_incident(session, incident_id, operator="vigilo-compat")`; `"CLOSED"` → `close_open_incident(session, incident_id, operator="vigilo-compat", reason="vigilo-compat")`.

The DELETE handler takes no body. It maps directly to `close_open_incident(session, incident_id, operator="vigilo-compat", reason="vigilo-compat")` using the `close_incident_endpoint` scaffold minus the `body` parameter and `IncidentCloseRequest`.

---

### `tests/test_incidents_api.py` (test, request-response)

**Analog:** the same file — `_app`, `get_client`, `_seed_incident`, and the existing `test_list_incidents_filters_and_cursor_pagination` / `test_ack_is_idempotent_and_keeps_incident_open` / `test_manual_close_is_idempotent_and_frees_open_slot` are the exact patterns new tests must follow.

**Test imports and fixtures** (`tests/test_incidents_api.py:1-25`) — already cover every symbol Phase 6 tests need (httpx, ASGITransport, pytest-anyio, Session, async_sessionmaker, PostgresContainer, Settings, IncidentStatus, create_app, Incident):

```python
from __future__ import annotations

import logging
import os
import subprocess
from collections.abc import AsyncIterator
from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.config.settings import Settings
from app.domain.events import Severity
from app.domain.incidents import DecisionContext, IncidentStatus
from app.main import create_app
from app.persistence.models import Incident

pytestmark = pytest.mark.anyio
```

**Postgres container fixture** (`tests/test_incidents_api.py:27-54`) — runs Alembic migrations against a `postgres:18-alpine` container once per module. New tests inherit this fixture and the `session_factory` fixture (line 57-66) and require NO new infrastructure.

**`get_client` / `_app` / `_settings` / `_event_time` helpers** (`tests/test_incidents_api.py:74-103`) — every new test should use these verbatim:

```python
async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def _settings() -> Settings:
    return Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=False,
    )


def _app(session_factory: async_sessionmaker[AsyncSession]):
    return create_app(
        settings=_settings(),
        sessionmaker=session_factory,
        lifecycle_worker=NoopLifecycleWorker(),
    )


def _event_time(offset_minutes: int) -> datetime:
    return datetime(2026, 6, 9, 12, 0, tzinfo=timezone.utc) + timedelta(minutes=offset_minutes)
```

Pattern: `httpx.ASGITransport(app=app)` (no Uvicorn) is the project's standard test transport; new tests MUST use it.

**`_seed_incident` helper** (`tests/test_incidents_api.py:106-138`) — seeds an `OPEN` incident via `upsert_open_incident` and commits. New PATCH/DELETE tests can use this to produce a known-OPEN incident; new list-pagination tests can use it to produce multiple incidents with deterministic `last_update_time` ordering.

**Existing list-pagination test shape** (`tests/test_incidents_api.py:140-204`) — pattern for new offset-pagination tests:

```python
async def test_list_incidents_filters_and_cursor_pagination(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        first = await _seed_incident(...)
        second = await _seed_incident(...)
        third = await _seed_incident(...)

    app = _app(session_factory)
    async for client in get_client(app):
        page1 = await client.get("/v1/incidents", params={"limit": 2})
        ...
    assert page1.status_code == 200
    body1 = page1.json()
    ids_page1 = [item["id"] for item in body1["items"]]
    assert len(ids_page1) == 2
    assert body1["next_cursor"]
    ...
```

Pattern: seed 3+ incidents with increasing `event_time` offsets (deterministic ordering), call the endpoint, assert `status_code == 200` and assert exact `id` lists. New offset-pagination tests follow the same shape with `params={"offset": 1, "limit": 1}` etc. and assert `body["total"]`, `body["limit"]`, `body["offset"]` per D-02. Also seed a test for `?status=ACKNOWLEDGED` returning only incidents with `acknowledged_at` set — call `client.patch(f"/v1/incidents/{id}", json={"status": "ACKNOWLEDGED"})` first to ack one of the seeded incidents, then `client.get("/v1/incidents", params={"status": "ACKNOWLEDGED"})` and assert the ack'd one is the only result. Also seed a regression test that `?status=RESOLVED` still works (D-08 — `RESOLVED` is in the new `IncidentStatusFilter`). Also seed a test that confirms `total` is independent of pagination params: with the same base filters, `?offset=1&limit=1` and `?cursor=...` (advancing one row) must both return the same `total` value (the cursor is pagination, not part of the matching-count filter set).

**Existing ack/close idempotency test shapes** (`tests/test_incidents_api.py:256-288, 290-323`) — pattern for new PATCH/DELETE tests:

```python
async def test_ack_is_idempotent_and_keeps_incident_open(...) -> None:
    async with session_factory() as session:
        incident = await _seed_incident(...)

    app = _app(session_factory)
    payload = {"operator": "operator-a"}
    async for client in get_client(app):
        first = await client.post(f"/v1/incidents/{incident.id}/ack", json=payload)
        second = await client.post(f"/v1/incidents/{incident.id}/ack", json=payload)

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["status"] == "OPEN"
    assert second.json()["status"] == "OPEN"
    assert second.json()["acknowledgement"]["acknowledged_by"] == "operator-a"
```

Pattern for new PATCH/DELETE tests (case-aware — ACK and CLOSE behave differently, see persistence caveat above):
- Use `client.patch(...)` with `json={"status": "ACKNOWLEDGED"}` and `client.patch(...)` with `json={"status": "CLOSED"}`; `client.delete(...)` takes no payload.
- D-14 idempotency, PATCH `ACKNOWLEDGED` case: assert BOTH calls return 200; do NOT assert full-body equality. The first call writes `acknowledged_at` / `acknowledged_by` / `updated_at`; the second call re-runs the UPDATE because the row is still `status == OPEN`, bumping `updated_at` and overwriting `acknowledged_by` to `"vigilo-compat"` (same value, so still equal), while `acknowledged_at` is preserved by `coalesce`. Stable semantic fields to assert: `["status"]` (still `"OPEN"`) and `["acknowledgement"]["acknowledged_by"]` (`"vigilo-compat"`). Do NOT assert `updated_at` equality — the second call bumps it.
- D-14 idempotency, PATCH/DELETE `CLOSED` case: assert BOTH calls return 200. The first call moves the row out of `OPEN` to `CLOSED` (writing `closed_at` and `updated_at`); the second call hits the noop branch because the row no longer matches `status == OPEN`, and returns the existing closed row without writing. The two bodies are byte-identical — `["status"]` is `"CLOSED"`, `["closed_at"]` and `["updated_at"]` are unchanged. Stable semantic fields to assert: `["status"]` and (optionally) `["closed_at"]`/`["updated_at"]` equality. The CLOSE case permits full-body equality in principle, but asserting on `["status"]` is sufficient and consistent with the ACK case.
- D-09: after PATCH `ACKNOWLEDGED`, `response.json()["status"] == "OPEN"` and `response.json()["acknowledgement"]["acknowledged_by"] == "vigilo-compat"`.
- D-13: the audit log captured by `caplog` (mirror the pattern in `test_operator_mutations_emit_safe_json_logs` at `tests/test_incidents_api.py:325-401`) MUST record `operator="vigilo-compat"` for the PATCH/DELETE calls, not the caller's identity.

**Existing 422 / 400 error-path test shape** (`tests/test_incidents_api.py:403-428`) — pattern for the new summary-mutation / missing-status 422 tests:

```python
async def test_incident_api_rejects_invalid_inputs_without_source_exception_text(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    app = _app(session_factory)
    async for client in get_client(app):
        bad_cursor = await client.get("/v1/incidents", params={"cursor": "not-a-cursor"})
        bad_uuid = await client.get("/v1/incidents/not-a-uuid")
        bad_body = await client.post(
            "/v1/incidents/00000000-0000-0000-0000-000000000000/ack",
            json={},
        )
        ...
    assert bad_cursor.status_code == 400
    assert bad_uuid.status_code == 422
    assert bad_body.status_code == 422
    ...
```

Pattern: use the nil-UUID `00000000-0000-0000-0000-000000000000` to exercise the not-found path (matches the existing test), and call `client.patch(...)` / `client.delete(...)` with the various summary-mutation and missing-status bodies. New PATCH 422 tests must assert:
- `client.patch(f"/v1/incidents/{id}", json={}).status_code == 422` and `response.json() == {"detail": "status is required"}` (D-17).
- `client.patch(f"/v1/incidents/{id}", json={"summary": "x"}).status_code == 422` and detail `"summary mutation is not supported"` (D-15/D-16).
- `client.patch(f"/v1/incidents/{id}", json={"status": "ACKNOWLEDGED", "summary": "x"}).status_code == 422` and detail `"summary mutation is not supported"` (D-15 — extra key takes precedence).
- `client.patch(f"/v1/incidents/{id}", json=[1, 2, 3]).status_code == 422` and detail `"status is required"` (D-17 — non-dict body).

## Shared Patterns

### Authentication
**Source:** `app/api/routers/incidents.py:24` (router-level dependency)
**Apply to:** every new endpoint in `app/api/routers/incidents.py` (PATCH, DELETE).
```python
router = APIRouter(prefix="/v1/incidents", dependencies=[Security(require_operator_token)])
```
The new PATCH/DELETE handlers need NO additional auth code — the router-level dependency auto-applies. Confirmed by Phase 5 CONTEXT (router-level `Security(require_operator_token)` is the canonical posture).

### Error Handling (404 → 422 dispatch)
**Source:** `app/api/routers/incidents.py:138-141` (404 mapping for lifecycle functions) and `app/main.py:48-58` (global 422 validation handler).
**Apply to:** the new PATCH and DELETE handlers.
- 404 mapping for `result is None`: `raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="incident not found")`. Reuse the exact string `"incident not found"` so the response is byte-identical to the existing POST endpoints.
- For 422 with compact string detail: bypass the global `RequestValidationError` handler by accepting `Request` and raising `HTTPException(status_code=422, detail="...")` directly. The PATCH body parser is the only place this is needed; DELETE takes no body.

### Audit Logging
**Source:** `app/api/routers/incidents.py:144-154` (ack) and `175-186` (close).
**Apply to:** PATCH (status=ACKNOWLEDGED → reason="acknowledged") and PATCH/DELETE (status=CLOSED → reason="manual_close").
```python
logger.info(
    "incident acknowledged" / "incident manually closed",
    extra=safe_log_extra(
        event="operator_mutation",
        incident_id=str(result.incident.id),
        status=result.incident.status,
        effect=result.effect,
        reason="acknowledged" / "manual_close",
        operator="vigilo-compat",
    ),
)
```
`safe_log_extra` keys MUST be in `SAFE_LOG_KEYS` (`app/processing/logging.py:6-37`) — `"event"`, `"incident_id"`, `"status"`, `"effect"`, `"reason"`, `"operator"` are all present.

### Pydantic model conventions
**Source:** `app/domain/incidents.py:149-193`.
**Apply to:** the new fields on `IncidentListFilters` and `IncidentListResponse`. **Not** the new `IncidentStatusFilter` StrEnum (StrEnums do not accept `model_config`).
- `model_config = ConfigDict(strict=True, extra="forbid")` is for `BaseModel` subclasses only. Apply to any new Pydantic model fields added to `IncidentListFilters` or `IncidentListResponse`.
- `Annotated[T, Field(min_length=1, max_length=N)]` for bounded strings.
- `int = Field(default=N, ge=..., le=...)` for bounded ints (used at `app/domain/incidents.py:159` for `limit`). The new `offset` field on `IncidentListFilters` is `Annotated[int, Field(ge=0)] | None = None` (None-default to preserve the cursor-first-page discriminator). The new response fields on `IncidentListResponse` (`total`, `limit`, `offset`) are NON-NULL `int = Field(default=..., ge=..., le=...)` with no `Optional`/`| None` — D-02 requires always-present non-null ints, see "IncidentListResponse shape" above.
- The new `IncidentStatusFilter` StrEnum sits beside `IncidentStatus` (`app/domain/incidents.py:13-16`), is a plain StrEnum (no `model_config`) with exactly four members (`OPEN`, `ACKNOWLEDGED`, `RESOLVED`, `CLOSED` — see "IncidentStatusFilter required member set" above), and is query-filter-only — never use it for PATCH dispatch (D-10).

### Persistence query composition
**Source:** `app/persistence/incidents.py:458-497`.
**Apply to:** the new offset branch in `list_incidents`, the new ACKNOWLEDGED WHERE clause, and the COUNT(*) computation.
- Filter construction is a chained sequence of `if filters.X is not None: stmt = stmt.where(...)` blocks. The non-pagination filters (`status`, `severity`, `rule_name`, `host`, `service`, `updated_since`) live in the upper non-pagination region. The cursor predicate (`if filters.cursor is not None: ...`) is **pagination**, not a filter — it lives AFTER the non-pagination filters and BEFORE the ORDER BY.
- `COUNT(*)` is derived from the **base filtered stmt**: build `base_stmt` with only the non-pagination filters applied, then `total = await session.scalar(select(func.count()).select_from(base_stmt.subquery())) or 0`. Do NOT include the cursor predicate or the offset/LIMIT/ORDER BY in the count source. After `total` is computed, apply the cursor/offset branch + ORDER BY + LIMIT to a separate `page_stmt` for the page query.
- Branch selection on `page_stmt` (the cursor/offset predicates are pagination, not filters):
  - Cursor branch (D-03 wins over offset): apply the cursor predicate to `page_stmt`, then `.order_by(...).limit(filters.limit + 1)`. The `+1` lets the existing `next_cursor` detection work.
  - Offset branch: skip the cursor predicate. `page_stmt` carries only the base filters, then `.order_by(...).offset(filters.offset).limit(filters.limit)`. The offset branch is the **only** branch that calls `.offset(...)` and the **only** branch without the `+1` — offset pages are exactly `limit` rows and `next_cursor` is `None` per D-02.
  - No-param default branch: skip both cursor and offset. `page_stmt` carries only the base filters, then `.order_by(...).limit(filters.limit + 1)` — the `+1` preserves the pre-Phase-6 cursor first-page behavior so existing callers still get a populated `next_cursor` when more rows exist.
- The "no-param" path must be preserved — pre-Phase-6 callers that hit `GET /v1/incidents` with no params still get the cursor first page (with `next_cursor`).
- ORDER BY is `(last_update_time desc, id desc)` — identical across all three branches; the limit operation differs as above.
- The `with_for_update()` row lock pattern (at the top of `ack_open_incident` and `close_open_incident`) is owned by the lifecycle functions; the new PATCH/DELETE handlers do NOT lock — they delegate.
- Status-filter dispatch (replacement for the first `if filters.status is not None` block in `list_incidents`):

  ```python
  if filters.status == IncidentStatusFilter.ACKNOWLEDGED:
      stmt = stmt.where(
          Incident.status == IncidentStatus.OPEN.value,
          Incident.acknowledged_at.is_not(None),
          Incident.acknowledged_by.is_not(None),
      )
  elif filters.status is not None:
      stmt = stmt.where(Incident.status == filters.status.value)
  ```

  This `if/elif` is a non-pagination filter and MUST be applied to **both** `base_stmt` (for `total`) and `page_stmt` (for the page) so the count and the page agree on what "matches the filters" means. The ACKNOWLEDGED branch maps the compatibility filter to a compound predicate on `status=OPEN` and non-null acknowledgement columns (D-05); the `elif` keeps the canonical status branch unchanged and continues to accept `OPEN` / `RESOLVED` / `CLOSED` (D-08). `IncidentStatusFilter` must be imported in `app/persistence/incidents.py` (see imports note above).

## No Analog Found

None. Every file Phase 6 modifies has a direct in-file analog, and there are no genuinely novel cross-cutting patterns that lack a precedent in the existing codebase. The four files are the right scope.

## Metadata

**Analog search scope:** `app/domain/incidents.py`, `app/persistence/incidents.py`, `app/api/routers/incidents.py`, `tests/test_incidents_api.py`, `app/main.py`, `app/processing/logging.py`.
**Files scanned:** 6 (the four target files plus `app/main.py` for the global validation handler and `app/processing/logging.py` for `safe_log_extra` / `SAFE_LOG_KEYS`).
**Pattern extraction date:** 2026-06-17.

## PATTERN MAPPING COMPLETE
