# Phase 4: Lifecycle, Operator APIs, and Operability - Pattern Map

**Mapped:** 2026-06-09
**Files analyzed:** 21 (new + modified)
**Analogs found:** 21 / 21 (every Phase 4 file has at least one role/dataflow match in the existing codebase)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `app/processing/lifecycle.py` (NEW) | service | request-response / scheduled sweep → persistence | `app/processing/incident_manager.py` (`IncidentManager.apply_problem`) | exact (typed async pipeline step that calls into persistence) |
| `app/processing/lifecycle_worker.py` (NEW) | service | scheduled sweep (lifespan-managed asyncio) | `app/processing/task_runner.py` (`AsyncIOTaskRunner` lifecycle) | role-match (in-process async task with start/stop discipline) |
| `app/processing/ingress.py` (MODIFIED) | service | request-response | `app/processing/ingress.py` (current `Icinga2DecisionProcessor`) | exact (branch `EventType.RECOVERY` to lifecycle; leave `PROBLEM` path) |
| `app/processing/incident_manager.py` (UNCHANGED) | service | request-response | itself | n/a (do not touch) |
| `app/processing/task_runner.py` (UNCHANGED) | service | fire-and-forget | itself | n/a (do not bend into scheduler per D-08) |
| `app/persistence/incidents.py` (MODIFIED — append lifecycle functions) | repository | CRUD | `app/persistence/incidents.py` (`record_notification_result`, `_insert_problem_incident`, `record_problem_incident` update branch) | exact (clone `select(...).with_for_update()` + `update(...).values(...).returning(*Incident.__table__.columns)` + `_incident_from_mapping`) |
| `app/persistence/models.py` (UNCHANGED unless missing column) | model | persistence schema | `app/persistence/models.py` (current `Incident`) | exact — column inventory already satisfies D-04/D-05/D-09 |
| `app/api/routers/incidents.py` (NEW) | router | request-response | `app/api/routers/plugins.py` (`list_plugins`) | exact (clone lightweight read-only router pattern) |
| `app/api/routers/config_status.py` (NEW) | router | request-response | `app/api/routers/plugins.py` (`list_plugins`) | exact (clone safe-summary pattern; same allowlisted fields style) |
| `app/api/routers/metrics.py` (NEW) | router | request-response | `app/api/routers/health.py` (`/health`, `/readyz`) | exact (return a non-secret `Response` from a router function) |
| `app/api/routers/ingress.py` (MODIFIED — move to `/v1/icinga2/events`) | router | request-response | `app/api/routers/ingress.py` (current) | exact (move prefix only) |
| `app/api/routers/health.py` (MODIFIED — move to `/v1/health`, `/v1/readyz`) | router | request-response | `app/api/routers/health.py` (current) | exact (broaden readiness probes only after moving) |
| `app/api/routers/plugins.py` (MODIFIED — move to `/v1/plugins`) | router | request-response | `app/api/routers/plugins.py` (current) | exact (move prefix only) |
| `app/api/deps.py` (MODIFIED — add dependency factories) | middleware/dependency | request-response | `app/api/deps.py` (current `get_app_settings`, `get_sessionmaker`, `get_icinga2_processor`) | exact (clone `cast(...) from request.app.state` pattern) |
| `app/main.py` (MODIFIED) | app factory | lifespan | `app/main.py` (current `lifespan` + `create_app`) | exact (extend lifespan; add `include_router` calls for `/v1` namespaces) |
| `app/domain/incidents.py` (MODIFIED — add lifecycle response/context models) | domain model | n/a | `app/domain/incidents.py` (current `Acknowledgement`, `DecisionContext`, `validate_incident_transition`) | exact (extend in place; reuse `_FORBIDDEN_NOTE_FRAGMENTS` for non-secret safety) |
| `app/domain/rules.py` (MODIFIED — extend envelope with lifecycle fields) | domain model | n/a | `app/domain/rules.py` (current `IngressDecisionEnvelope`, `IncidentEffectSummary`, `NotificationResult`) | exact (extend envelope; add new strict bounded fields) |
| `app/processing/metrics.py` (NEW — metric names + counter helpers) | service | in-process counters | none (no metrics seam exists) | no-analog (follow prometheus_client `Counter`/`Gauge` shape from research; safe identifiers only) |
| `app/processing/logging.py` (NEW — JSON formatter + safe `extra` helpers) | utility | structured logging | `app/processing/task_runner.py:64-77` (`logger.error(... extra={...}, exc_info=...)`) | role-match (extend current `extra={...}` pattern with JSON formatter) |
| `tests/test_lifecycle_repository.py` (NEW) | test | integration (Testcontainers) | `tests/test_incident_repository.py` (current `db_session` + `postgres_url` fixtures) | exact (clone Testcontainers/alembic/TRUNCATE pattern) |
| `tests/test_lifecycle_worker.py` (NEW) | test | unit | `tests/test_task_runner.py` (current `AsyncIOTaskRunner` tests) | role-match (lifespan-driven async worker with start/stop) |
| `tests/test_lifecycle_expiration.py` (NEW) | test | integration (Testcontainers) | `tests/test_incident_repository.py` (DB-time tests) | exact (clone Testcontainers fixtures; assert `now()` semantics) |
| `tests/test_incidents_api.py` (NEW) | test | API + integration | `tests/test_ingress_router.py` (`get_client`, `_write_plugins`, `_write_rules`); `tests/test_health.py` (`SuccessfulSession`/`FailingSession`) | exact (clone ASGITransport + lifespan_context pattern; assert no-secret body) |
| `tests/test_config_status_api.py` (NEW) | test | API | `tests/test_plugins_router.py` (current `/plugins` safety test) | exact (clone `assert "password" not in serialized` etc.) |
| `tests/test_metrics_api.py` (NEW) | test | API | `tests/test_health.py` (current `/health` and `/readyz` shape) | exact (assert content-type, low-cardinality labels) |
| `tests/test_structured_logging.py` (NEW) | test | unit | `tests/test_task_runner.py::test_handler_exception_is_retrieved_and_logged` (current `caplog` usage) | role-match (assert JSON keys; assert no raw payload / no secret) |
| `tests/test_health.py` (MODIFIED — broaden `/v1/readyz`) | test | API | `tests/test_health.py` (current `SuccessfulSession`/`FailingSession` for `select 1`) | exact (extend the existing fake-session pattern for new probes) |
| `tests/test_ingress_router.py` (MODIFIED — cover `/v1` route) | test | API + integration | itself (current `/webhooks/icinga2` coverage) | exact (assert route moved under `/v1`; recover behavior) |
| `tests/test_plugins_router.py` (MODIFIED — cover `/v1` route) | test | API | itself (current `/plugins` safety test) | exact (assert route moved under `/v1`; preserve secret-leak guards) |

## Pattern Assignments

### `app/processing/lifecycle.py` (NEW — service, request-response + scheduled sweep)

**Analog:** `app/processing/incident_manager.py:47-159` (`IncidentManager.apply_problem`)

**Why this analog:** `LifecycleManager` is a sibling pipeline step. It (1) accepts typed domain inputs (`NormalizedEvent` or operator action), (2) calls a PostgreSQL update/insert with `RETURNING`, (3) commits before reporting, and (4) returns a typed result. `IncidentManager.apply_problem` is the closest existing reference for session/manager wiring and post-write `decision_context` enrichment.

**Imports pattern** (mirrors `app/processing/incident_manager.py:1-22`):
```python
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal
from uuid import UUID

from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.events import EventType, NormalizedEvent
from app.domain.incidents import DecisionContext, validate_incident_transition
from app.persistence.incidents import (
    # reuse the existing incident_from_mapping helper pattern
    ack_open_incident,
    close_open_incident,
    expire_stale_incidents,
    resolve_host_recovery,
    resolve_service_recovery,
    shrink_affected_sets,
)
from app.persistence.models import Incident
```

**Constructor pattern** (mirrors `app/processing/incident_manager.py:53-62`):
```python
class LifecycleManager:
    def __init__(
        self,
        session: AsyncSession,
        *,
        config_hash: str | None = None,
    ) -> None:
        self._session = session
        self._config_hash = config_hash
```

**Event-type branch + recovery method pattern** (mirrors `app/processing/ingress.py:79-89` and `app/processing/incident_manager.py:64-130`):
```python
    async def resolve_for_event(self, event: NormalizedEvent) -> LifecycleResult:
        # D-01: recovery never enters aggregation/notification
        if event.event_type is not EventType.RECOVERY:
            raise ValueError("LifecycleManager.resolve_for_event only accepts RECOVERY events")
        # D-03: service recovery is host + service exact
        if event.service is not None:
            write_result = await resolve_service_recovery(
                self._session,
                host=event.host,
                service=event.service,
                recovery_time=event.timestamp,
                fingerprint=event.fingerprint,
            )
        else:
            write_result = await resolve_host_recovery(
                self._session,
                host=event.host,
                recovery_time=event.timestamp,
                fingerprint=event.fingerprint,
            )
        await self._session.commit()
        return LifecycleResult(
            incident_id=write_result.incident.id,
            effect=write_result.effect,
            previous_host_count=write_result.previous_host_count,
            previous_service_count=write_result.previous_service_count,
            transitioned_to=write_result.transitioned_to,
        )
```

**Dataclass result pattern** (mirrors `app/processing/incident_manager.py:31-46` — `@dataclass(frozen=True, slots=True)`):
```python
@dataclass(frozen=True, slots=True)
class LifecycleResult:
    incident_id: UUID
    effect: Literal["affected_set_shrunk", "resolved", "noop", "closed", "acknowledged", "expired"]
    transitioned_to: str | None
    previous_host_count: int
    previous_service_count: int
```

**Transition validation** (mirrors `app/domain/incidents.py:113-118`):
```python
target = validate_incident_transition(IncidentStatus.OPEN, IncidentStatus.RESOLVED)  # or CLOSED
```

**Decision-context enrichment** (mirrors `app/processing/incident_manager.py:189-220`):
```python
def _recovery_context(fingerprint: str, source_id: str, host: str, service: str | None, ...) -> DecisionContext:
    return DecisionContext(
        fingerprint=fingerprint,
        source_id=source_id,
        notes={
            "lifecycle.reason": "source_recovery",  # or "expired"
            "lifecycle.host": host,
            ...
        },
    )
```

---

### `app/processing/lifecycle_worker.py` (NEW — service, lifespan-managed asyncio sweep)

**Analog:** `app/processing/task_runner.py:43-100` (`AsyncIOTaskRunner.start`/`drain` lifecycle) and `app/main.py:18-67` (`lifespan`)

**Why this analog:** D-08 requires a single asyncio background task started/stopped by FastAPI lifespan. The project has no scheduler today; `AsyncIOTaskRunner` shows the only in-process async-background seam (start, drain, exception logging). The worker must keep its own `asyncio.Task` (not call `AsyncIOTaskRunner`) per the existing `tests/test_task_runner.py:79-105` AST guard that bans `asyncio.create_task` outside `app/processing/task_runner.py`.

**Imports pattern** (mirrors `app/processing/task_runner.py:1-13`):
```python
from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from typing import Any

from sqlalchemy.ext.asyncio import async_sessionmaker

logger = logging.getLogger(__name__)
```

**Worker skeleton pattern** (mirrors `app/processing/task_runner.py:43-100` and `app/main.py:18-67`):
```python
class LifecycleWorker:
    def __init__(
        self,
        *,
        sessionmaker: async_sessionmaker[Any],
        interval_seconds: int,
        sweep: Callable[[async_sessionmaker[Any]], Awaitable[int]],
    ) -> None:
        self._sessionmaker = sessionmaker
        self._interval = max(1, interval_seconds)
        self._sweep = sweep
        self._task: asyncio.Task[None] | None = None
        self._stop_event = asyncio.Event()
        self._healthy = False

    @property
    def healthy(self) -> bool:
        return self._healthy

    async def start(self) -> None:
        if self._task is not None:
            return
        self._stop_event.clear()
        self._task = asyncio.create_task(self._run(), name="correlia:lifecycle-worker")
        self._task.add_done_callback(self._on_done)

    async def stop(self) -> None:
        if self._task is None:
            return
        self._stop_event.set()
        try:
            await asyncio.wait_for(self._task, timeout=self._interval + 5)
        except asyncio.TimeoutError:
            self._task.cancel()
        finally:
            self._task = None
            self._healthy = False

    async def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                await self._sweep(self._sessionmaker)
                self._healthy = True
            except Exception as exc:  # noqa: BLE001 — D-18: log and continue
                self._healthy = False
                logger.error(
                    "lifecycle worker sweep failed",
                    extra={"exception_type": type(exc).__name__},
                    exc_info=(type(exc), exc, exc.__traceback__),
                )
            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=self._interval)
            except asyncio.TimeoutError:
                continue
```

**Lifespan wiring** (mirrors `app/main.py:18-67`):
```python
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    ...
    if not hasattr(app.state, "lifecycle_worker"):
        from app.processing.lifecycle_worker import LifecycleWorker
        from app.processing.lifecycle import expire_stale_batch
        app.state.lifecycle_worker = LifecycleWorker(
            sessionmaker=app.state.sessionmaker,
            interval_seconds=app.state.settings.lifecycle_scan_interval_seconds,
            sweep=expire_stale_batch,
        )
    await app.state.lifecycle_worker.start()
    try:
        yield
    finally:
        await app.state.lifecycle_worker.stop()
        if task_runner is not None:
            await task_runner.drain()
        await engine.dispose()
```

---

### `app/processing/ingress.py` (MODIFIED — branch `RECOVERY` to lifecycle)

**Analog:** `app/processing/ingress.py:60-160` (current `process_payload` envelope assembly)

**Why this analog:** the only change is adding a sibling branch after rule evaluation. The current code already isolates `_apply_problem` (lines 137-150). Mirror that exact seam for `_apply_recovery` and only re-render the envelope's `incident_effects`/`closure_count`/`incident_id` from the new lifecycle result. Do not re-thread rule/group.

**Branch pattern** (mirrors `app/processing/ingress.py:79-89`):
```python
if isinstance(decision, RuleDecision):
    matched_rules = list(decision.matched_rules)
    group_key = decision.group_key
    threshold_decision = decision.threshold_decision.model_dump(mode="json")
    if event.event_type is EventType.PROBLEM and self._sessionmaker is not None:
        incident_result = await self._apply_problem(event, decision)
    elif event.event_type is EventType.RECOVERY and self._sessionmaker is not None:
        lifecycle_result = await self._apply_recovery(event)
    else:
        lifecycle_result = None
        incident_result = None
```

**Recovery method pattern** (mirrors `app/processing/ingress.py:138-150`):
```python
async def _apply_recovery(self, event: NormalizedEvent) -> LifecycleResult:
    sessionmaker = self._sessionmaker
    if sessionmaker is None:
        raise RuntimeError("sessionmaker is required for recovery resolution")
    async with sessionmaker() as session:
        manager = LifecycleManager(session, config_hash=self._config_hash)
        return await manager.resolve_for_event(event)
```

**Envelope update** (mirrors `app/processing/ingress.py:91-127`): repurpose the existing `closure_count` field and add a new strict `LifecycleOutcome` model to `app/domain/rules.py` (see domain section). Keep `_incident_effects` shape (inserted=0/updated=0/resolved=1 when applicable) but expose lifecycle-specific counts in a new field.

---

### `app/persistence/incidents.py` (MODIFIED — append lifecycle repository functions)

**Analog:** `app/persistence/incidents.py:296-340` (`record_notification_result` update+RETURNING) and `app/persistence/incidents.py:435-490` (`record_problem_incident` existing-branch update with `.with_for_update()`).

**Why this analog:** lifecycle mutations need the same atomic shape — `select(...).with_for_update()` for affected-set shrinking and `update(...).values(...).returning(*Incident.__table__.columns)` followed by `_incident_from_mapping(result.mappings().one())`. Reuse the `_bounded_sorted_union` helper and the `OPEN` partial-unique predicate text.

**Imports delta** (extends `app/persistence/incidents.py:1-18`):
```python
from sqlalchemy import and_, or_, select, tuple_
from sqlalchemy.dialects.postgresql import insert as pg_insert
```

**Idempotent acknowledgement pattern** (mirrors `app/persistence/incidents.py:303-340`):
```python
async def ack_open_incident(
    session: AsyncSession,
    incident_id: UUID,
    operator: str,
) -> Incident | None:
    stmt = (
        update(Incident)
        .where(Incident.id == incident_id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .values(
            acknowledged_at=func.coalesce(Incident.acknowledged_at, func.now()),
            acknowledged_by=operator,
            updated_at=func.now(),
        )
        .returning(*Incident.__table__.columns)
    )
    result = await session.execute(stmt)
    mapping = result.mappings().one_or_none()
    if mapping is None:
        # not open → return current row, do not raise
        current = await session.execute(select(Incident).where(Incident.id == incident_id))
        return current.scalar_one_or_none()
    return _incident_from_mapping(mapping)
```

**Manual close pattern** (mirrors `app/persistence/incidents.py:425-490`):
```python
async def close_open_incident(
    session: AsyncSession,
    incident_id: UUID,
    reason: str,
    operator: str | None = None,
    decision_context: DecisionContext | None = None,
) -> Incident | None:
    existing = await session.execute(
        select(Incident)
        .where(Incident.id == incident_id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .with_for_update()
    )
    row = existing.scalar_one_or_none()
    if row is None:
        return None
    target = validate_incident_transition(IncidentStatus.OPEN, IncidentStatus.CLOSED)
    values: dict[str, Any] = {
        "status": target.value,
        "closed_at": func.now(),
        "updated_at": func.now(),
    }
    if decision_context is not None:
        values["decision_context"] = decision_context.model_dump(mode="json")
    result = await session.execute(
        update(Incident)
        .where(Incident.id == incident_id)
        .values(**values)
        .returning(*Incident.__table__.columns)
    )
    return _incident_from_mapping(result.mappings().one())
```

**Host-recovery pattern** (extends `_bounded_sorted_union` from `app/persistence/incidents.py:43-47`):
```python
async def resolve_host_recovery(
    session: AsyncSession,
    host: str,
    recovery_time: datetime,
    fingerprint: str,
) -> LifecycleWriteResult:
    candidates = await session.execute(
        select(Incident)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .where(Incident.affected_hosts.contains([host]))  # JSONB containment
        .with_for_update()
    )
    candidates = list(candidates.scalars())
    for incident in candidates:
        new_hosts = sorted(h for h in incident.affected_hosts if h != host)
        if len(new_hosts) == len(incident.affected_hosts):
            continue  # not a membership match (e.g., service-only)
        if not new_hosts and not incident.affected_services:
            await _resolve_to_resolved(session, incident, recovery_time, fingerprint)
        else:
            await _shrink_affected_sets(session, incident, new_hosts, incident.affected_services)
    ...
    return LifecycleWriteResult(...)
```

**Service-recovery pattern** (mirrors host-recovery but with `affected_hosts` AND `affected_services` matching):
```python
async def resolve_service_recovery(
    session: AsyncSession,
    host: str,
    service: str,
    recovery_time: datetime,
    fingerprint: str,
) -> LifecycleWriteResult:
    candidates = await session.execute(
        select(Incident)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .where(Incident.affected_hosts.contains([host]))
        .where(Incident.affected_services.contains([service]))
        .with_for_update()
    )
    ...
```

**Affected-set shrink helper** (mirrors `_bounded_sorted_union` semantics):
```python
async def _shrink_affected_sets(
    session: AsyncSession,
    incident: Incident,
    new_hosts: list[str],
    new_services: list[str],
) -> Incident:
    result = await session.execute(
        update(Incident)
        .where(Incident.id == incident.id)
        .values(
            affected_hosts=new_hosts,
            affected_services=new_services,
            updated_at=func.now(),
        )
        .returning(*Incident.__table__.columns)
    )
    return _incident_from_mapping(result.mappings().one())
```

**Stale expiration pattern (uses PostgreSQL `now()`)** — D-06/D-07:
```python
async def expire_stale_incidents(
    session: AsyncSession,
    limit: int = 100,
) -> list[Incident]:
    # The D-06 stale predicate uses last_update_time + window; window lives in window_state JSONB
    candidates = await session.execute(
        select(Incident)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .where(
            func.now() > func.coalesce(
                func.nullif(Incident.window_state["window_ended_at"].astext, "")::timestamptz,
                Incident.last_update_time,
            ) + func.make_interval(0, 0, 0, 0, 0, 0, Incident.window_state["window_seconds"].astext::int)
        )
        .limit(limit)
        .with_for_update(skip_locked=True)
    )
    expired: list[Incident] = []
    for incident in candidates.scalars():
        result = await session.execute(
            update(Incident)
            .where(Incident.id == incident.id)
            .values(
                status=IncidentStatus.CLOSED.value,
                closed_at=func.now(),
                updated_at=func.now(),
            )
            .returning(*Incident.__table__.columns)
        )
        expired.append(_incident_from_mapping(result.mappings().one()))
    return expired
```

**Cursor-paginated list pattern** — D-12 (mirrors `select`/`limit` discipline of `app/persistence/incidents.py:400-420`):
```python
async def list_incidents(
    session: AsyncSession,
    *,
    status_filter: IncidentStatus | None = None,
    severity_filter: str | None = None,
    rule_name: str | None = None,
    host: str | None = None,
    service: str | None = None,
    updated_since: datetime | None = None,
    cursor: tuple[datetime, UUID] | None = None,
    limit: int = 50,
) -> list[Incident]:
    stmt = select(Incident).order_by(
        Incident.last_update_time.desc(),
        Incident.id.desc(),
    )
    if status_filter is not None:
        stmt = stmt.where(Incident.status == status_filter.value)
    if severity_filter is not None:
        stmt = stmt.where(Incident.severity == severity_filter)
    if rule_name is not None:
        stmt = stmt.where(Incident.rule_name == rule_name)
    if host is not None:
        stmt = stmt.where(Incident.affected_hosts.contains([host]))
    if service is not None:
        stmt = stmt.where(Incident.affected_services.contains([service]))
    if updated_since is not None:
        stmt = stmt.where(Incident.last_update_time >= updated_since)
    if cursor is not None:
        cursor_time, cursor_id = cursor
        stmt = stmt.where(
            tuple_(Incident.last_update_time, Incident.id) < tuple_(cursor_time, cursor_id)
        )
    stmt = stmt.limit(limit + 1)
    return list((await session.execute(stmt)).scalars())
```

**Get by id** (mirrors `record_notification_result` lookup at `app/persistence/incidents.py:303-313`):
```python
async def get_incident_by_id(session: AsyncSession, incident_id: UUID) -> Incident | None:
    result = await session.execute(select(Incident).where(Incident.id == incident_id))
    return result.scalar_one_or_none()
```

**`LifecycleWriteResult` dataclass** (mirrors `IncidentAggregationWriteResult` at `app/persistence/incidents.py:158-168`):
```python
@dataclass(frozen=True, slots=True)
class LifecycleWriteResult:
    incident: Incident
    effect: Literal["affected_set_shrunk", "resolved", "noop"]
    transitioned_to: str | None
    previous_host_count: int
    previous_service_count: int
```

---

### `app/api/routers/incidents.py` (NEW — router, request-response)

**Analog:** `app/api/routers/plugins.py:1-17` (current `/plugins` shape) and `app/api/routers/ingress.py:1-29` (current `/webhooks/icinga2` shape).

**Why these analogs:** the current routers show the exact dependency-injection style and the return-shape style (Pydantic v2 strict `BaseModel` instances, never raw dicts). Use `APIRouter(prefix="/v1")` so the path prefix is colocated with the include call.

**Imports pattern** (mirrors `app/api/routers/ingress.py:1-10`):
```python
from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.api.deps import get_sessionmaker
from app.domain.incidents import (
    IncidentDetailResponse,
    IncidentListResponse,
    IncidentAckRequest,
    IncidentCloseRequest,
    IncidentListFilters,
)
from app.persistence.incidents import (
    ack_open_incident,
    close_open_incident,
    get_incident_by_id,
    list_incidents,
)

router = APIRouter(prefix="/v1/incidents", tags=["incidents"])
```

**List handler pattern** (mirrors `app/api/routers/plugins.py:11-15`):
```python
@router.get("", response_model=IncidentListResponse)
async def list_incidents_endpoint(
    sessionmaker: Annotated[async_sessionmaker[AsyncSession], Depends(get_sessionmaker)],
    status_filter: Annotated[str | None, Query(alias="status")] = None,
    severity: Annotated[str | None, Query()] = None,
    rule_name: Annotated[str | None, Query()] = None,
    host: Annotated[str | None, Query()] = None,
    service: Annotated[str | None, Query()] = None,
    updated_since: Annotated[datetime | None, Query()] = None,
    cursor: Annotated[str | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> IncidentListResponse:
    parsed_filters = IncidentListFilters.model_validate({...})  # Pydantic strict
    async with sessionmaker() as session:
        rows = await list_incidents(session, **parsed_filters.model_dump(), limit=limit)
    return IncidentListResponse(items=[IncidentDetailResponse.model_validate(r) for r in rows[:limit]], next_cursor=...)
```

**Detail handler pattern** (mirrors `app/api/routers/plugins.py:11-15`):
```python
@router.get("/{incident_id}", response_model=IncidentDetailResponse)
async def get_incident(
    incident_id: UUID,
    sessionmaker: Annotated[async_sessionmaker[AsyncSession], Depends(get_sessionmaker)],
) -> IncidentDetailResponse:
    async with sessionmaker() as session:
        incident = await get_incident_by_id(session, incident_id)
    if incident is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="not found")
    return IncidentDetailResponse.model_validate(incident)
```

**Idempotent ack pattern** (mirrors `app/api/routers/ingress.py:17-28` exception shape):
```python
@router.post("/{incident_id}/ack", response_model=IncidentDetailResponse)
async def acknowledge_incident(
    incident_id: UUID,
    body: IncidentAckRequest,
    sessionmaker: Annotated[async_sessionmaker[AsyncSession], Depends(get_sessionmaker)],
) -> IncidentDetailResponse:
    async with sessionmaker() as session:
        incident = await ack_open_incident(session, incident_id, operator=body.operator)
        await session.commit()
    if incident is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="not found")
    return IncidentDetailResponse.model_validate(incident)
```

**Manual close pattern** (mirrors ack pattern, returns 200 even when already closed to preserve idempotency per D-14):
```python
@router.post("/{incident_id}/close", response_model=IncidentDetailResponse)
async def close_incident_endpoint(
    incident_id: UUID,
    body: IncidentCloseRequest,
    sessionmaker: Annotated[async_sessionmaker[AsyncSession], Depends(get_sessionmaker)],
) -> IncidentDetailResponse:
    async with sessionmaker() as session:
        existing = await get_incident_by_id(session, incident_id)
        if existing is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="not found")
        if existing.status == IncidentStatus.CLOSED.value:
            return IncidentDetailResponse.model_validate(existing)  # idempotent
        incident = await close_open_incident(
            session, incident_id, reason=body.reason, operator=body.operator
        )
        await session.commit()
    return IncidentDetailResponse.model_validate(incident)
```

---

### `app/api/routers/config_status.py` (NEW — router, request-response)

**Analog:** `app/api/routers/plugins.py:1-17` and `app/plugins/loader.py:30-45` (`PluginRegistry.list_plugins`)

**Why this analog:** D-19 requires a non-secret summary with hashes — same shape as the existing plugin listing. Expose rule names/priorities/group_by/action plugin names and topology rule ids/match types/tag keys from the `CompiledRuleConfig` / `CompiledTopologyConfig` dataclasses.

**Imports pattern** (mirrors `app/api/routers/plugins.py:1-9`):
```python
from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Request

from app.api.deps import get_app_settings
from app.config.settings import Settings

router = APIRouter(prefix="/v1", tags=["config"])
```

**Rules summary pattern** (mirrors `app/plugins/loader.py:30-45`):
```python
@router.get("/rules")
async def list_rules_summary(request: Request) -> dict[str, object]:
    config = getattr(request.app.state, "rules_config", None)
    if config is None:
        return {"rules": [], "config_hash": None}
    return {
        "config_hash": config.config_hash,
        "rules": [
            {
                "name": r.definition.name,
                "priority": r.definition.priority,
                "group_by": list(r.definition.window.group_by),
                "actions": [{"name": a.name, "plugin": a.plugin} for a in r.definition.actions],
            }
            for r in config.rules
        ],
    }
```

**Topology summary pattern** (mirrors `app/plugins/loader.py:30-45`, but with `tags_keys` only):
```python
@router.get("/topology")
async def list_topology_summary(request: Request) -> dict[str, object]:
    config = getattr(request.app.state, "topology_config", None)
    if config is None:
        return {"hostname_rules": [], "subnet_rules": []}
    return {
        "hostname_rules": [
            {"id": r.id, "name": r.name, "match_type": "hostname", "tag_keys": sorted(r.tags.keys())}
            for r in config.hostname_rules
        ],
        "subnet_rules": [
            {"id": r.id, "name": r.name, "match_type": "subnet", "tag_keys": sorted(r.tags.keys())}
            for r in config.subnet_rules
        ],
    }
```

**Plugin status pattern (move and reuse)** — see `app/api/routers/plugins.py` excerpt; only the prefix changes from `""` to `"/v1"`.

---

### `app/api/routers/metrics.py` (NEW — router, request-response)

**Analog:** `app/api/routers/health.py:1-37` (current `/health`, `/readyz` shape)

**Why this analog:** the route returns a non-JSON `Response` with a fixed media type and no auth — same shape as `/readyz`. Only the body is the Prometheus text format from `prometheus_client.generate_latest(registry)`.

**Imports pattern** (mirrors `app/api/routers/health.py:1-7`):
```python
from fastapi import APIRouter
from fastapi.responses import Response

from app.processing.metrics import registry, render_metrics

router = APIRouter(prefix="/v1", tags=["operability"])


@router.get("/metrics")
async def metrics() -> Response:
    return Response(content=render_metrics(), media_type="text/plain; version=0.0.4; charset=utf-8")
```

---

### `app/api/routers/ingress.py` (MODIFIED — move to `/v1/icinga2/events`)

**Analog:** `app/api/routers/ingress.py:1-29` (current `/webhooks/icinga2`)

**Why this analog:** D-11 is a clean cutover. The handler logic does not change; only the `APIRouter(prefix=...)` moves to `"/v1"` and the route path becomes `"/icinga2/events"`.

**Path change pattern** (mirrors `app/api/routers/ingress.py:10`):
```python
router = APIRouter(prefix="/v1", tags=["ingress"])

@router.post("/icinga2/events")
async def ingest_icinga2(...) -> IngressDecisionEnvelope:
    ...  # unchanged
```

---

### `app/api/routers/health.py` (MODIFIED — move to `/v1`, broaden `/v1/readyz`)

**Analog:** `app/api/routers/health.py:1-37` (current `/health` and `/readyz`)

**Why this analog:** D-16 broadens the readiness probe to include config, plugin registry, and lifecycle worker. The current shape — `Depends(get_sessionmaker)` and `Depends(get_app_settings)` — is the seam to extend.

**Move + broaden pattern** (mirrors `app/api/routers/health.py:1-37`):
```python
router = APIRouter(prefix="/v1", tags=["operability"])


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz")
async def readyz(
    settings: Annotated[Settings, Depends(get_app_settings)],
    sessionmaker: Annotated[async_sessionmaker[AsyncSession], Depends(get_sessionmaker)],
    plugin_registry: Annotated[PluginRegistry, Depends(get_plugin_registry)],
    request: Request,
) -> dict[str, str]:
    try:
        await check_database_ready(sessionmaker)
    except Exception:
        raise HTTPException(status_code=503, detail="not ready")
    # New probes per D-16:
    if not plugin_registry.names:
        raise HTTPException(status_code=503, detail="not ready")
    worker = getattr(request.app.state, "lifecycle_worker", None)
    if worker is None or not worker.healthy:
        raise HTTPException(status_code=503, detail="not ready")
    return {"status": "ready"}
```

---

### `app/api/deps.py` (MODIFIED — add dependency factories)

**Analog:** `app/api/deps.py:1-29` (current factories)

**Why this analog:** all state objects are stored on `app.state`; the dependency factories simply `cast()` them off the `Request`. Reuse that exact shape for `get_rules_config`, `get_topology_config`, `get_lifecycle_worker`, `get_plugin_registry` (last already exists).

**Pattern to add** (mirrors `app/api/deps.py:11-29`):
```python
from app.config.rules import CompiledRuleConfig
from app.config.topology import CompiledTopologyConfig
from app.processing.lifecycle_worker import LifecycleWorker

def get_rules_config(request: Request) -> CompiledRuleConfig | None:
    return cast(CompiledRuleConfig | None, getattr(request.app.state, "rules_config", None))


def get_topology_config(request: Request) -> CompiledTopologyConfig | None:
    return cast(CompiledTopologyConfig | None, getattr(request.app.state, "topology_config", None))


def get_lifecycle_worker(request: Request) -> LifecycleWorker | None:
    return cast(LifecycleWorker | None, getattr(request.app.state, "lifecycle_worker", None))
```

---

### `app/main.py` (MODIFIED — lifespan + `/v1` router inclusion)

**Analog:** `app/main.py:18-67` (current `lifespan`) and `app/main.py:69-91` (current `create_app`)

**Why this analog:** D-06/D-08 require the lifecycle worker to be created in the lifespan and stopped on shutdown. The existing lifespan shows the exact `getattr(app.state, "x", None)` pattern for idempotent wiring.

**Lifespan extension pattern** (mirrors `app/main.py:18-67`):
```python
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    if not hasattr(app.state, "settings"):
        app.state.settings = get_settings()
    if not hasattr(app.state, "sessionmaker"):
        engine = create_engine(app.state.settings)
        app.state.engine = engine
        app.state.sessionmaker = create_sessionmaker(engine)
    if not hasattr(app.state, "plugin_registry"):
        ...
    if not hasattr(app.state, "task_runner"):
        ...
    if not hasattr(app.state, "lifecycle_worker"):
        from app.processing.lifecycle import expire_stale_batch
        from app.processing.lifecycle_worker import LifecycleWorker
        app.state.lifecycle_worker = LifecycleWorker(
            sessionmaker=app.state.sessionmaker,
            interval_seconds=app.state.settings.lifecycle_scan_interval_seconds,
            sweep=expire_stale_batch,
        )
    if not hasattr(app.state, "icinga2_processor"):
        ...
    if not hasattr(app.state, "rules_config") and getattr(app.state.settings, "rules_path", None) is not None:
        from app.config.rules import load_rules_config
        app.state.rules_config = load_rules_config(app.state.settings.rules_path)
    if not hasattr(app.state, "topology_config") and getattr(app.state.settings, "topology_path", None) is not None:
        from app.config.topology import load_topology_config
        app.state.topology_config = load_topology_config(app.state.settings.topology_path)
    await app.state.lifecycle_worker.start()
    try:
        yield
    finally:
        await app.state.lifecycle_worker.stop()
        task_runner = getattr(app.state, "task_runner", None)
        if task_runner is not None:
            await task_runner.drain()
        engine = getattr(app.state, "engine", None)
        if engine is not None:
            await engine.dispose()
```

**Router inclusion pattern** (mirrors `app/main.py:89-91`):
```python
from app.api.routers.incidents import router as incidents_router
from app.api.routers.config_status import router as config_status_router
from app.api.routers.metrics import router as metrics_router

def create_app(...) -> FastAPI:
    app = FastAPI(lifespan=lifespan)
    ...
    app.include_router(health_router)  # already self-prefixes /v1
    app.include_router(ingress_router)  # already self-prefixes /v1
    app.include_router(plugins_router)  # already self-prefixes /v1
    app.include_router(incidents_router)
    app.include_router(config_status_router)
    app.include_router(metrics_router)
    return app
```

---

### `app/domain/incidents.py` (MODIFIED — add lifecycle response/context models)

**Analog:** `app/domain/incidents.py:18-30` (`Acknowledgement`), `app/domain/incidents.py:48-78` (`DecisionContext`), `app/domain/incidents.py:80-100` (`IncidentWindowState`).

**Why this analog:** every Phase 4 lifecycle payload is a strict Pydantic v2 model with bounded strings, bounded tuples, and a non-secret `notes` map. Reuse the `_FORBIDDEN_NOTE_FRAGMENTS` constant for any new context models so secrets remain rejected at the validation boundary.

**Imports delta** (extends `app/domain/incidents.py:1-12`):
```python
from pydantic import ConfigDict, Field
```

**Detail response model pattern** (mirrors `app/domain/incidents.py:18-30` strict `ConfigDict`):
```python
class IncidentDetailResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    id: UUID
    status: IncidentStatus
    severity: str = Field(min_length=1, max_length=32)
    summary: str = Field(min_length=1, max_length=256)
    rule_name: str = Field(min_length=1, max_length=256)
    group_key: str = Field(min_length=1, max_length=256)
    event_count: int = Field(ge=1)
    affected_hosts: tuple[BoundedString, ...] = Field(default=(), max_length=100)
    affected_services: tuple[BoundedString, ...] = Field(default=(), max_length=100)
    acknowledged_at: datetime | None = None
    acknowledged_by: str | None = None
    resolved_at: datetime | None = None
    closed_at: datetime | None = None
    start_time: datetime
    last_update_time: datetime
    decision_context: DecisionContext
```

**Ack/close action bodies pattern** (mirrors `app/domain/incidents.py:18-30`):
```python
class IncidentAckRequest(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    operator: Annotated[str, Field(min_length=1, max_length=128)]
    reason: BoundedString | None = None


class IncidentCloseRequest(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    operator: Annotated[str, Field(min_length=1, max_length=128)]
    reason: BoundedString
```

**List response and cursor model pattern** (mirrors `BoundedStringTuple` discipline at `app/domain/incidents.py:11`):
```python
class IncidentListResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    items: tuple[IncidentDetailResponse, ...] = Field(max_length=200)
    next_cursor: str | None = None  # opaque base64 of (last_update_time, id)


class IncidentListFilters(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    status_filter: IncidentStatus | None = None
    severity: BoundedString | None = None
    rule_name: BoundedString | None = None
    host: BoundedString | None = None
    service: BoundedString | None = None
    updated_since: datetime | None = None
```

**Lifecycle outcome sub-model pattern** (mirrors `DecisionContext.notes` validator at `app/domain/incidents.py:65-77`):
```python
class LifecycleOutcome(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    effect: Literal["affected_set_shrunk", "resolved", "noop", "closed", "acknowledged", "expired"]
    reason: BoundedString
    previous_host_count: int = Field(ge=0)
    previous_service_count: int = Field(ge=0)
    notes: dict[TagKey, TagValue] = Field(default_factory=dict, max_length=20)
```

---

### `app/domain/rules.py` (MODIFIED — extend `IngressDecisionEnvelope` with lifecycle fields)

**Analog:** `app/domain/rules.py:90-100` (`IncidentEffectSummary`) and `app/domain/rules.py:108-146` (`IngressDecisionEnvelope`).

**Why this analog:** the envelope is the contract for ingress responses. Adding a strict, bounded, optional `lifecycle_outcome` field keeps the same shape and avoids breaking Phase 3 callers.

**Field additions** (mirrors `app/domain/rules.py:108-146`):
```python
class IngressDecisionEnvelope(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    ...
    lifecycle_outcome: LifecycleOutcome | None = None  # populated for RECOVERY
    recovery_resolution: Literal["noop", "affected_set_shrunk", "resolved"] | None = None
    affected_object_removed: bool = False
    matched_rule_names: tuple[BoundedString, ...] = Field(default=(), max_length=20)  # remains None for RECOVERY
```

**Stale expiration result pattern** (mirrors `NotificationResult` at `app/domain/rules.py:101-106`):
```python
class ExpirationResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    expired_count: int = Field(ge=0)
    expired_incident_ids: tuple[UUID, ...] = Field(default=(), max_length=1000)
```

---

### `app/processing/metrics.py` (NEW — service, in-process counters)

**Analog:** none in the existing codebase (no metrics seam today). Follow the `prometheus_client` standard pattern from the research seam.

**Why this is safe:** the file is new and has no analog to copy from. Keep labels low-cardinality per D-17. The standard library is `prometheus_client.Counter` / `prometheus_client.Gauge`; if the package is not adopted, the helpers in this file are the only `app/` seam that imports the package, so a hand-rolled text renderer can be substituted without touching call sites.

**Counter helper pattern** (mirrors `app/processing/task_runner.py:64-77` `extra={...}` discipline — pass a structlog/JSON-safe dict, not strings with secrets):
```python
from prometheus_client import Counter, Gauge, CollectorRegistry, generate_latest, CONTENT_TYPE_LATEST

registry = CollectorRegistry()

events_accepted = Counter(
    "correlia_events_accepted_total",
    "Accepted normalized events by event_type",
    ["event_type"],
    registry=registry,
)

events_rejected = Counter(
    "correlia_events_rejected_total",
    "Rejected events by reason",
    ["reason"],
    registry=registry,
)

matched_rules = Counter(
    "correlia_matched_rules_total",
    "Rule evaluations that produced a match",
    ["rule_name"],
    registry=registry,
)

incident_inserts = Counter(
    "correlia_incident_inserts_total",
    "Incidents inserted",
    registry=registry,
)
incident_updates = Counter(
    "correlia_incident_updates_total",
    "Incidents updated",
    registry=registry,
)
incident_resolutions = Counter(
    "correlia_incident_resolutions_total",
    "Incidents resolved via source recovery",
    registry=registry,
)
incident_expirations = Counter(
    "correlia_incident_expirations_total",
    "Incidents closed via stale expiration",
    registry=registry,
)
notification_attempts = Counter(
    "correlia_notification_attempts_total",
    "Notification attempts by plugin and category",
    ["plugin_name", "category"],
    registry=registry,
)
notification_failures = Counter(
    "correlia_notification_failures_total",
    "Notification failures by plugin and category",
    ["plugin_name", "category"],
    registry=registry,
)
task_failures = Counter(
    "correlia_task_failures_total",
    "Async task handler failures by task name",
    ["task_name"],
    registry=registry,
)
lifecycle_worker_healthy = Gauge(
    "correlia_lifecycle_worker_healthy",
    "1 when the lifecycle worker last sweep succeeded, 0 otherwise",
    registry=registry,
)


def render_metrics() -> bytes:
    return generate_latest(registry)
```

---

### `app/processing/logging.py` (NEW — utility, structured JSON)

**Analog:** `app/processing/task_runner.py:64-77` (`logger.error("...", extra={"task_name": ...})`) and `app/processing/notification_dispatcher.py:14` (`logger = logging.getLogger(__name__)`).

**Why this analog:** current code uses stdlib `logging` with `extra=` payloads. Adding a JSON formatter at the root handler is the smallest change that satisfies D-18. The helper module centralizes the safe `extra={...}` keys.

**JSON formatter pattern** (mirrors `app/processing/task_runner.py:64-77`):
```python
import json
import logging
from typing import Any, Mapping


class JsonFormatter(logging.Formatter):
    SAFE_KEYS = frozenset({
        "event", "incident_id", "rule_name", "group_key", "status", "severity",
        "reason", "category", "count", "task_name", "plugin_name", "exception_type",
        "lifecycle_outcome",
    })

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key in self.SAFE_KEYS and isinstance(value, (str, int, float, bool, type(None))):
                payload[key] = value
        return json.dumps(payload, sort_keys=True)


def configure_json_logging(level: str = "INFO") -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)
```

---

## Shared Patterns

### Strict Pydantic v2 boundary validation

**Source:** `app/domain/events.py:39-58` (`NormalizedEvent`); `app/domain/incidents.py:18-30` (`Acknowledgement`); `app/domain/rules.py:9-93` (all `*BaseModel` declarations).

**Apply to:** every new request/response/context model in `app/domain/incidents.py`, `app/domain/rules.py`, `app/api/routers/incidents.py` body models, and `app/processing/lifecycle.py` result models.

```python
class Foo(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    name: Annotated[str, Field(min_length=1, max_length=128)]
```

**Invariants:**
- Always `strict=True, extra="forbid"`.
- Always bound strings with `min_length=1` and `max_length` (≤ 256 for identifiers, ≤ 128 for operator names, ≤ 4096 for messages).
- All tuple fields use `max_length=...` to keep payloads bounded.
- All `datetime` fields must be timezone-aware — see validator in `app/domain/events.py:54-58`.

### Non-secret decision context

**Source:** `app/domain/incidents.py:13-16` and `app/domain/incidents.py:65-77` (`_FORBIDDEN_NOTE_FRAGMENTS` + `reject_secret_note_content`).

**Apply to:** `LifecycleOutcome.notes`, `DecisionContext.notes`, and any operator-context payloads.

```python
_FORBIDDEN_NOTE_FRAGMENTS = (
    "raw_payload", "payload", "credential", "password", "token", "secret", "plugin_config",
)
```

### PostgreSQL atomic row mutation

**Source:** `app/persistence/incidents.py:296-340` (`record_notification_result`), `app/persistence/incidents.py:425-490` (`record_problem_incident` update branch).

**Apply to:** every lifecycle repository function — `ack_open_incident`, `close_open_incident`, `resolve_host_recovery`, `resolve_service_recovery`, `_shrink_affected_sets`, `_resolve_to_resolved`, `expire_stale_incidents`.

```python
result = await session.execute(
    update(Incident)
    .where(Incident.id == incident_id)
    .where(Incident.status == IncidentStatus.OPEN.value)  # status guard
    .values(...)
    .returning(*Incident.__table__.columns)
)
return _incident_from_mapping(result.mappings().one_or_none())
```

**Invariants:**
- Every transition out of `OPEN` carries `.where(Incident.status == IncidentStatus.OPEN.value)` to preserve D-15.
- Every update appends `.values(updated_at=func.now())`.
- `select(...).with_for_update()` is required before any read-modify-write that depends on the current `affected_hosts` / `affected_services` set (mirrors `app/persistence/incidents.py:404-414`).
- For batch expiration, use `.with_for_update(skip_locked=True)` to avoid blocking the worker under contention.

### JSONB containment membership query

**Source:** SQLAlchemy `JSONB` column. `Incident.affected_hosts` and `Incident.affected_services` are typed `JSONB` in `app/persistence/models.py:31-36`.

**Apply to:** recovery candidate selection (D-02/D-03) and host/service filters in `list_incidents` (D-12).

```python
stmt = stmt.where(Incident.affected_hosts.contains([host]))         # @> ARRAY['host']::jsonb
stmt = stmt.where(Incident.affected_services.contains([service]))   # @> ARRAY['service']::jsonb
```

### Keyset cursor pagination

**Source:** locked decision D-12 (`last_update_time DESC, id DESC`).

**Apply to:** `list_incidents` and `IncidentListResponse.next_cursor` (base64 of `(last_update_time, id)` tuple — opaque to the client).

```python
stmt = stmt.order_by(Incident.last_update_time.desc(), Incident.id.desc())
if cursor is not None:
    cursor_time, cursor_id = cursor
    stmt = stmt.where(
        tuple_(Incident.last_update_time, Incident.id) < tuple_(cursor_time, cursor_id)
    )
stmt = stmt.limit(limit + 1)  # +1 lets the router return `next_cursor`
```

### Lifespan worker start/stop

**Source:** `app/main.py:18-67` (current `lifespan`).

**Apply to:** `app/processing/lifecycle_worker.py` `LifecycleWorker.start()` / `stop()` integration in `app/main.py` `lifespan`.

**Invariants:**
- Start in the `try` block before `yield`.
- Stop in `finally` after the existing `task_runner.drain()` call.
- Never use `asyncio.create_task` outside `app/processing/task_runner.py` per the AST guard in `tests/test_task_runner.py:79-105`.

### Safe plugin/config summary envelope

**Source:** `app/plugins/loader.py:30-45` (`list_plugins`); `tests/test_plugins_router.py:55-67` (assertion that no secret appears in the body).

**Apply to:** `/v1/rules`, `/v1/topology`, `/v1/plugins` summaries per D-05/D-19.

```python
rows.append({
    "name": name,
    "plugin_type": entry.plugin_type,
    "status": status.status,
    "ready": status.ready,
})
# NEVER include `entry.options`, raw `class_path`, SMTP credentials, plugin_config, or rendered settings.
```

### `Depends(...)` request-state access

**Source:** `app/api/deps.py:11-29` and `app/api/routers/health.py:1-37` / `app/api/routers/plugins.py:1-17`.

**Apply to:** every new router — `get_sessionmaker`, `get_plugin_registry`, `get_rules_config`, `get_topology_config`, `get_lifecycle_worker`, `get_app_settings`, `get_icinga2_processor`.

```python
def get_foo(request: Request) -> Foo:
    return cast(Foo, request.app.state.foo)
```

**Test pattern** (mirrors `tests/test_plugins_router.py:62-75`):
```python
app = create_app(
    settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
    sessionmaker=lambda: object(),
    plugin_registry=registry,
)
```

### Testcontainers-backed integration tests

**Source:** `tests/test_incident_repository.py:25-53` (`postgres_url` + `_run_alembic_upgrade`) and `tests/test_incident_repository.py:55-75` (`db_session` with `TRUNCATE` cleanup).

**Apply to:** `tests/test_lifecycle_repository.py`, `tests/test_lifecycle_expiration.py`, `tests/test_incidents_api.py` (DB paths).

```python
@pytest.fixture(scope="module")
def postgres_url() -> str:
    with PostgresContainer("postgres:18-alpine") as postgres:
        url = postgres.get_connection_url()
        url = url.replace("postgresql+psycopg2://", "postgresql+asyncpg://")
        url = url.replace("postgresql://", "postgresql+asyncpg://")
        _run_alembic_upgrade(url)
        yield url


@pytest.fixture
async def db_session(postgres_url: str):
    engine = create_async_engine(postgres_url)
    async with AsyncSession(engine, expire_on_commit=False) as session:
        yield session
    await engine.dispose()

    cleanup = create_async_engine(postgres_url)
    async with AsyncSession(cleanup, expire_on_commit=False) as cs:
        await cs.execute(sa.text("TRUNCATE TABLE incidents RESTART IDENTITY CASCADE"))
        await cs.commit()
    await cleanup.dispose()
```

### ASGI lifespan-aware API tests

**Source:** `tests/test_ingress_router.py:60-66` (`get_client`) and `tests/test_plugins_router.py:17-23` (same pattern).

**Apply to:** `tests/test_incidents_api.py`, `tests/test_config_status_api.py`, `tests/test_metrics_api.py`, `tests/test_health.py` (broadened readiness).

```python
async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client
```

### Non-secret failure response

**Source:** `tests/test_health.py:9-25` (`SuccessfulSession`/`FailingSession`) and `tests/test_health.py::test_readyz_returns_non_secret_503_when_database_check_fails` (parametrized secret-fragment check).

**Apply to:** `/v1/readyz` broadened probes; `/v1/incidents/...` 4xx/5xx responses; logging assertions.

```python
# Failure must NOT include raw exception text with secrets
raise HTTPException(status_code=503, detail="not ready")  # no DB URL, no password
```

### Structured logging assertions

**Source:** `tests/test_task_runner.py::test_handler_exception_is_retrieved_and_logged` (current `caplog` usage with `extra={"task_name": ...}`).

**Apply to:** `tests/test_structured_logging.py` (assert JSON keys; assert no raw payload / no secret in `caplog.records`).

```python
async def test_handler_exception_is_retrieved_and_logged(caplog):
    with caplog.at_level("ERROR"):
        ...  # trigger
    assert "async task handler failed" in caplog.text
    assert "RuntimeError" in caplog.text
```

---

## No Analog Found

Files with no close match in the codebase (planner should use RESEARCH.md patterns or new stdlib/Prometheus conventions instead):

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `app/processing/metrics.py` | service | in-process counters | No metrics seam exists in the repo today. Use `prometheus_client` (Counter/Gauge/CollectorRegistry) per research seam; if the package is rejected, expose a registry-agnostic `render_metrics()` and substitute the renderer without touching call sites. |
| `app/processing/lifecycle_worker.py` | service | scheduled sweep (lifespan-managed asyncio) | No scheduler/background-loop seam exists. Replicate `AsyncIOTaskRunner` discipline (`_task`, `_stop_event`, exception logging) without using `asyncio.create_task` outside `task_runner.py` (per AST guard in `tests/test_task_runner.py:79-105`). |
| `app/processing/logging.py` | utility | structured logging | No JSON formatter exists today; existing code uses stdlib `logging` with `extra=...`. Build a `JsonFormatter` subclass and a `configure_json_logging()` installer. |
| `migrations/versions/0002_lifecycle_context.py` (if needed) | migration | schema | If the planner adds new context fields beyond what `DecisionContext.notes` can hold, mirror the shape of `migrations/versions/0001_create_incidents.py:43-80` for `add_column` + `op.create_check_constraint` + `op.create_index`. If context fits in `DecisionContext.notes`, no migration is needed (D-05 already fits). |
| `tests/test_lifecycle_worker.py` | test | unit | No existing test starts/stops a lifespan worker; replicate the discipline of `tests/test_task_runner.py::test_handler_exception_is_retrieved_and_logged` and assert the worker stops within one interval on cancellation. |
| `tests/test_structured_logging.py` | test | unit | No existing JSON-log test. Use stdlib `caplog` to capture `LogRecord` and assert `SAFE_KEYS` are present and `_FORBIDDEN_NOTE_FRAGMENTS` are absent. |

---

## Metadata

**Analog search scope:** `app/`, `tests/`, `migrations/`
**Files scanned:** 27 source files in `app/`, 18 test files in `tests/`, 1 migration in `migrations/versions/`
**Pattern extraction date:** 2026-06-09

**Key patterns identified:**
- Phase 4 lifecycle code reuses the **strict Pydantic v2 + PostgreSQL atomic RETURNING** pair from Phase 1/3 — never SELECT-then-act, never permissive coercion, never raw payloads in context.
- Phase 4 routers reuse the **`APIRouter(prefix="/v1")` + `Depends(get_sessionmaker)`** pair from Phase 3; route moves are prefix-only and preserve Pydantic response models.
- Phase 4 lifespan reuses the **idempotent `getattr(app.state, "x", None)` + `try/finally` worker discipline** from `app/main.py:18-67` and `AsyncIOTaskRunner.drain` in `app/processing/task_runner.py:84-87`.
- Phase 4 repository functions reuse the **`select(...).with_for_update()` + `update(...).values(...).returning(*Incident.__table__.columns)` + `_incident_from_mapping`** pattern from `app/persistence/incidents.py:296-490`.
- Phase 4 operability surfaces reuse the **non-secret allowlisted-fields** discipline from `app/plugins/loader.py:30-45` and `app/domain/incidents.py:13-16` (`_FORBIDDEN_NOTE_FRAGMENTS`).
- Phase 4 tests reuse the **Testcontainers `postgres:18-alpine` + Alembic + TRUNCATE + ASGITransport** triple from `tests/test_incident_repository.py` and `tests/test_ingress_router.py`.
