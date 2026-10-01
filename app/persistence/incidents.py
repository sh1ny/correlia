"""Atomic open-incident aggregation repository for PostgreSQL."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Literal
from uuid import UUID, uuid4

from sqlalchemy import Integer, and_, func, or_, select, text, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.events import Severity
from app.domain.incidents import (
    MAX_WINDOW_FINGERPRINTS,
    DecisionContext,
    IncidentListFilters,
    IncidentObject,
    IncidentStatus,
    IncidentStatusFilter,
    IncidentWindowState,
    validate_incident_transition,
)
from app.domain.notifications import NotificationDeliveryRecord, NotificationResult
from app.persistence.models import Incident

MAX_AFFECTED_HOSTS = 100
MAX_AFFECTED_SERVICES = 100


_SAFE_NOTIFICATION_MESSAGES = frozenset(
    {
        "configured output plugin is missing",
        "notification dispatched",
        "notification plugin failed",
        "notification result redacted",
        "notification task runner is unavailable",
        "notification task submission failed",
        "stale plugin configuration",
    }
)

IncidentEffect = Literal["inserted", "updated"]


def _severity_rank(value: str) -> int:
    return {
        "OK": 0,
        "WARNING": 1,
        "UNKNOWN": 2,
        "CRITICAL": 3,
    }.get(value, 0)


def _max_severity(existing: str, incoming: Severity) -> str:
    if _severity_rank(incoming.value) > _severity_rank(existing):
        return incoming.value
    return existing


@dataclass(frozen=True, slots=True)
class IncidentUpsertInput:
    rule_name: str
    group_key: str
    severity: Severity
    event_time: datetime
    summary: str
    affected_hosts: tuple[str, ...]
    affected_services: tuple[str, ...] = ()
    decision_context: DecisionContext | None = None
    fingerprint: str | None = None
    threshold_count: int = 1
    window_seconds: int = 300
    max_window_fingerprints: int = MAX_WINDOW_FINGERPRINTS

    def __post_init__(self) -> None:
        if not self.rule_name or not self.rule_name.strip():
            raise ValueError("rule_name must be non-empty")
        if not self.group_key or not self.group_key.strip():
            raise ValueError("group_key must be non-empty")
        if not self.summary or not self.summary.strip():
            raise ValueError("summary must be non-empty")
        if self.event_time.tzinfo is None or self.event_time.utcoffset() is None:
            raise ValueError("event_time must be timezone-aware")
        if type(self.threshold_count) is not int or self.threshold_count < 1:
            raise ValueError("threshold_count must be a positive integer")
        if self.window_seconds < 1:
            raise ValueError("window_seconds must be positive")
        if (
            type(self.max_window_fingerprints) is not int
            or not 1 <= self.max_window_fingerprints <= MAX_WINDOW_FINGERPRINTS
        ):
            raise ValueError("max_window_fingerprints is out of bounds")
        if self.threshold_count > self.max_window_fingerprints:
            raise ValueError("threshold_count exceeds max_window_fingerprints")

        hosts = tuple(sorted(set(self.affected_hosts)))
        if not hosts:
            raise ValueError("affected_hosts must be non-empty")
        for h in hosts:
            if not h or not h.strip():
                raise ValueError("affected_hosts must not contain empty strings")

        services = tuple(sorted(set(self.affected_services)))
        for s in services:
            if not s or not s.strip():
                raise ValueError("affected_services must not contain empty strings")

        object.__setattr__(self, "affected_hosts", hosts)
        object.__setattr__(self, "affected_services", services)

        fingerprint = self.fingerprint
        if fingerprint is None:
            fingerprint = f"{self.rule_name}:{self.group_key}:{self.event_time.isoformat()}:{self.summary}"
        if not fingerprint or not fingerprint.strip():
            raise ValueError("fingerprint must be non-empty")
        object.__setattr__(self, "fingerprint", fingerprint)

        if self.decision_context is not None:
            if isinstance(self.decision_context, dict):
                object.__setattr__(
                    self,
                    "decision_context",
                    DecisionContext.model_validate(self.decision_context),
                )
            elif not isinstance(self.decision_context, DecisionContext):
                raise TypeError(
                    "decision_context must be a DecisionContext instance, dict, or None"
                )


@dataclass(frozen=True, slots=True)
class IncidentAggregationWriteResult:
    incident: Incident
    effect: IncidentEffect
    replay: bool
    inside_window: bool
    counted: bool
    threshold_count: int
    window_started_at: datetime
    window_ended_at: datetime
    window_crossed: bool
    threshold_crossed: bool
    first_threshold_transition: bool
    counted_count: int
    counted_fingerprints: tuple[str, ...]


LifecycleEffect = Literal[
    "affected_set_shrunk",
    "resolved",
    "noop",
    "acknowledged",
    "closed",
    "expired",
]


@dataclass(frozen=True, slots=True)
class LifecycleWriteResult:
    incident: Incident
    effect: LifecycleEffect
    transitioned_to: str | None
    previous_host_count: int
    previous_service_count: int
    affected_object_removed: bool


@dataclass(frozen=True, slots=True)
class IncidentCursor:
    last_update_time: datetime
    id: UUID


@dataclass(frozen=True, slots=True)
class IncidentListPage:
    incidents: tuple[Incident, ...]
    next_cursor: str | None
    total: int
    offset: int


def _parse_timestamp(value: Any) -> datetime:
    if isinstance(value, datetime):
        return value
    if isinstance(value, str):
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    raise TypeError("window timestamp must be a datetime or ISO string")


def _window_state_dump(state: IncidentWindowState) -> dict[str, Any]:
    return state.model_dump(mode="json")


def _window_state_from_json(data: dict[str, Any]) -> IncidentWindowState:
    return IncidentWindowState.model_validate(
        {
            **data,
            "schema_version": data["schema_version"],
            "window_started_at": _parse_timestamp(data["window_started_at"]),
            "window_ended_at": _parse_timestamp(data["window_ended_at"]),
            "counted_fingerprint_timestamps": {
                fingerprint: _parse_timestamp(timestamp)
                for fingerprint, timestamp in data.get(
                    "counted_fingerprint_timestamps", {}
                ).items()
            },
            "active_objects": tuple(
                IncidentObject.model_validate(obj) for obj in data["active_objects"]
            ),
        }
    )


def _active_objects_from_input(
    input: IncidentUpsertInput,
) -> tuple[IncidentObject, ...]:
    return tuple(
        IncidentObject(host=host, service=service)
        for host in input.affected_hosts
        for service in (input.affected_services or (None,))
    )


def _affected_sets_from_objects(
    active_objects: tuple[IncidentObject, ...],
) -> tuple[list[str], list[str]]:
    hosts = {obj.host for obj in active_objects}
    services = {obj.service for obj in active_objects if obj.service is not None}
    return (
        sorted(hosts)[:MAX_AFFECTED_HOSTS],
        sorted(services)[:MAX_AFFECTED_SERVICES],
    )


def _initial_window_state(input: IncidentUpsertInput) -> IncidentWindowState:
    fingerprint = input.fingerprint
    assert fingerprint is not None
    window_started_at = input.event_time - timedelta(seconds=input.window_seconds)
    return IncidentWindowState(
        window_started_at=window_started_at,
        window_ended_at=input.event_time,
        window_seconds=input.window_seconds,
        threshold_count=input.threshold_count,
        counted_fingerprint_timestamps={fingerprint: input.event_time},
        counted_count=1,
        max_size=input.max_window_fingerprints,
        active_objects=_active_objects_from_input(input),
    )


def _next_window_state(
    existing: Incident,
    input: IncidentUpsertInput,
) -> tuple[IncidentWindowState, bool, bool, bool]:
    window_end = max(existing.last_update_time, input.event_time)
    window_start = window_end - timedelta(seconds=input.window_seconds)
    existing_state = _window_state_from_json(existing.window_state)

    retained: dict[str, datetime] = {}
    for (
        retained_fingerprint,
        timestamp,
    ) in existing_state.counted_fingerprint_timestamps.items():
        if window_start <= timestamp <= window_end:
            retained[retained_fingerprint] = timestamp

    inside_window = window_start <= input.event_time <= window_end
    fingerprint = input.fingerprint
    assert fingerprint is not None
    replay = fingerprint in retained
    counted = inside_window and not replay
    if counted:
        retained[fingerprint] = input.event_time

    if len(retained) > input.max_window_fingerprints:
        newest = sorted(
            retained.items(), key=lambda item: (item[1], item[0]), reverse=True
        )[: input.max_window_fingerprints]
        retained = dict(newest)

    retained = dict(sorted(retained.items()))
    active_objects = tuple(
        sorted(
            {
                *existing_state.active_objects,
                *_active_objects_from_input(input),
            },
            key=lambda obj: (obj.host, obj.service or ""),
        )
    )
    state = IncidentWindowState(
        window_started_at=window_start,
        window_ended_at=window_end,
        window_seconds=input.window_seconds,
        threshold_count=input.threshold_count,
        counted_fingerprint_timestamps=retained,
        counted_count=len(retained),
        max_size=input.max_window_fingerprints,
        active_objects=active_objects,
    )
    return state, replay, inside_window, counted


def _decision_context_dump(input: IncidentUpsertInput) -> dict[str, Any]:
    if input.decision_context is None:
        return {}
    data = input.decision_context.model_dump(mode="json")
    if not input.decision_context.notification_delivery_results:
        data.pop("notification_delivery_results")
    return data


def _normalizable_decision_context(context: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(context)
    for key in (
        "matched_rule_names",
        "enrichment_refs",
        "action_names",
        "notification_delivery_results",
    ):
        value = normalized.get(key)
        if isinstance(value, list):
            normalized[key] = tuple(value)
    return normalized


def _safe_delivery_result(result: NotificationResult) -> NotificationResult:
    if result.message in _SAFE_NOTIFICATION_MESSAGES:
        return result
    return result.model_copy(update={"message": "notification result redacted"})


def _validated_notification_context(
    context: dict[str, Any], plugin_name: str, result: NotificationResult
) -> dict[str, Any]:
    existing = DecisionContext.model_validate(_normalizable_decision_context(context))
    records_by_plugin = {
        record.plugin_name: record for record in existing.notification_delivery_results
    }
    records_by_plugin[plugin_name] = NotificationDeliveryRecord(
        plugin_name=plugin_name,
        result=_safe_delivery_result(result),
    )
    return DecisionContext.model_validate(
        {
            **existing.model_dump(),
            "notification_delivery_results": tuple(
                records_by_plugin[name] for name in sorted(records_by_plugin)
            ),
        }
    ).model_dump(mode="json")


def _preserve_notification_delivery_results(
    existing_context: dict[str, Any], incoming_context: dict[str, Any]
) -> dict[str, Any]:
    existing = _normalizable_decision_context(existing_context)
    incoming = _normalizable_decision_context(incoming_context)
    records = existing.get("notification_delivery_results")
    if records is None:
        return incoming
    merged = dict(incoming)
    merged["notification_delivery_results"] = records
    return DecisionContext.model_validate(merged).model_dump(mode="json")


async def record_notification_result(
    session: AsyncSession,
    incident_id: UUID,
    plugin_name: str,
    result: NotificationResult,
) -> bool:
    selected = await session.execute(
        select(Incident).where(Incident.id == incident_id).with_for_update()
    )
    incident = selected.scalar_one_or_none()
    if incident is None:
        return False

    context = _validated_notification_context(
        dict(incident.decision_context or {}),
        plugin_name,
        result,
    )
    update_values: dict[str, Any] = {
        "decision_context": context,
        "updated_at": func.now(),
    }
    if result.success:
        update_values["notified_at"] = func.now()
    await session.execute(
        update(Incident).where(Incident.id == incident_id).values(**update_values)
    )
    incident.decision_context = context
    return True


def _incident_from_mapping(mapping: Any) -> Incident:
    return Incident(**mapping)


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


async def list_incidents(
    session: AsyncSession,
    filters: IncidentListFilters,
) -> IncidentListPage:
    def apply_filters(stmt: Any) -> Any:
        if filters.status == IncidentStatusFilter.ACKNOWLEDGED:
            stmt = stmt.where(
                Incident.status == IncidentStatus.OPEN.value,
                Incident.acknowledged_at.is_not(None),
                Incident.acknowledged_by.is_not(None),
            )
        elif filters.status is not None:
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
        return stmt

    base_stmt = apply_filters(select(Incident))
    total = (
        await session.scalar(select(func.count()).select_from(base_stmt.subquery()))
        or 0
    )

    page_stmt = apply_filters(select(Incident))
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
        offset_value = 0
    elif filters.offset is not None:
        page_stmt = (
            page_stmt.order_by(Incident.last_update_time.desc(), Incident.id.desc())
            .offset(filters.offset)
            .limit(filters.limit)
        )
        result = await session.execute(page_stmt)
        incidents = tuple(result.scalars().all())
        next_cursor = None
        offset_value = filters.offset
    else:
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
        offset_value = 0

    return IncidentListPage(
        incidents=incidents,
        next_cursor=next_cursor,
        total=int(total),
        offset=offset_value,
    )


async def get_incident_by_id(
    session: AsyncSession, incident_id: UUID
) -> Incident | None:
    result = await session.execute(select(Incident).where(Incident.id == incident_id))
    return result.scalar_one_or_none()


async def upsert_open_incident(
    session: AsyncSession, input: IncidentUpsertInput
) -> Incident:
    result = await record_problem_incident(session, input)
    return result.incident


async def record_problem_incident(
    session: AsyncSession, input: IncidentUpsertInput
) -> IncidentAggregationWriteResult:
    inserted = await _insert_problem_incident(session, input)
    if inserted is not None:
        threshold_crossed = bool(inserted.threshold_crossed)
        window_state = _window_state_from_json(inserted.window_state)
        window_crossed = window_state.counted_count >= window_state.threshold_count
        return IncidentAggregationWriteResult(
            incident=inserted,
            effect="inserted",
            replay=False,
            inside_window=True,
            counted=True,
            threshold_count=window_state.threshold_count,
            window_started_at=window_state.window_started_at,
            window_ended_at=window_state.window_ended_at,
            window_crossed=window_crossed,
            threshold_crossed=threshold_crossed,
            first_threshold_transition=threshold_crossed,
            counted_count=window_state.counted_count,
            counted_fingerprints=tuple(
                window_state.counted_fingerprint_timestamps.keys()
            ),
        )

    existing_result = await session.execute(
        select(Incident)
        .where(
            Incident.rule_name == input.rule_name,
            Incident.group_key == input.group_key,
            Incident.status == IncidentStatus.OPEN.value,
        )
        .with_for_update()
    )
    existing = existing_result.scalar_one()

    window_state, replay, inside_window, counted = _next_window_state(existing, input)
    window_crossed = window_state.counted_count >= window_state.threshold_count
    threshold_crossed = existing.threshold_crossed or window_crossed
    first_threshold_transition = not existing.threshold_crossed and threshold_crossed
    affected_hosts, affected_services = _affected_sets_from_objects(
        window_state.active_objects
    )

    updated_result = await session.execute(
        update(Incident)
        .where(Incident.id == existing.id)
        .values(
            event_count=Incident.event_count + (1 if counted else 0),
            last_update_time=func.greatest(Incident.last_update_time, input.event_time),
            severity=_max_severity(existing.severity, input.severity),
            summary=input.summary if counted else existing.summary,
            affected_hosts=affected_hosts,
            affected_services=affected_services,
            decision_context=_preserve_notification_delivery_results(
                dict(existing.decision_context or {}), _decision_context_dump(input)
            ),
            window_state=_window_state_dump(window_state),
            threshold_crossed=threshold_crossed,
            updated_at=func.now(),
        )
        .returning(*Incident.__table__.columns)
    )
    updated = _incident_from_mapping(updated_result.mappings().one())
    return IncidentAggregationWriteResult(
        incident=updated,
        effect="updated",
        replay=replay,
        inside_window=inside_window,
        counted=counted,
        threshold_count=window_state.threshold_count,
        window_started_at=window_state.window_started_at,
        window_ended_at=window_state.window_ended_at,
        window_crossed=window_crossed,
        threshold_crossed=threshold_crossed,
        first_threshold_transition=first_threshold_transition,
        counted_count=window_state.counted_count,
        counted_fingerprints=tuple(window_state.counted_fingerprint_timestamps.keys()),
    )


async def _insert_problem_incident(
    session: AsyncSession, input: IncidentUpsertInput
) -> Incident | None:
    decision_data = _decision_context_dump(input)
    initial_state = _initial_window_state(input)
    threshold_crossed = initial_state.counted_count >= input.threshold_count
    affected_hosts, affected_services = _affected_sets_from_objects(
        initial_state.active_objects
    )
    stmt: Any = (
        insert(Incident)
        .values(
            id=uuid4(),
            rule_name=input.rule_name,
            group_key=input.group_key,
            status=IncidentStatus.OPEN.value,
            severity=input.severity.value,
            summary=input.summary,
            event_count=1,
            affected_hosts=affected_hosts,
            affected_services=affected_services,
            decision_context=decision_data,
            window_state=_window_state_dump(initial_state),
            threshold_crossed=threshold_crossed,
            notified_at=None,
            start_time=input.event_time,
            last_update_time=input.event_time,
        )
        .on_conflict_do_nothing(
            index_elements=[Incident.rule_name, Incident.group_key],
            index_where=text(f"status = '{IncidentStatus.OPEN.value}'"),
        )
        .returning(*Incident.__table__.columns)
    )
    result = await session.execute(stmt)
    mapping = result.mappings().one_or_none()
    if mapping is None:
        return None
    return _incident_from_mapping(mapping)


def _lifecycle_notes(
    *,
    reason: str,
    fingerprint: str | None = None,
    source_id: str | None = None,
    host: str | None = None,
    service: str | None = None,
    recovery_time: datetime | None = None,
    operator: str | None = None,
    detail: str | None = None,
    rule_name: str | None = None,
    window_seconds: int | None = None,
    last_update_time: datetime | None = None,
    expiration_time: datetime | None = None,
    previous_host_count: int = 0,
    previous_service_count: int = 0,
) -> dict[str, str]:
    notes = {
        "lifecycle.reason": reason,
        "lifecycle.previous_host_count": str(previous_host_count),
        "lifecycle.previous_service_count": str(previous_service_count),
    }
    if fingerprint is not None:
        notes["lifecycle.fingerprint"] = fingerprint[:256]
    if source_id is not None:
        notes["lifecycle.source_id"] = source_id[:256]
    if host is not None:
        notes["lifecycle.host"] = host[:256]
    if service is not None:
        notes["lifecycle.service"] = service[:256]
    if recovery_time is not None:
        notes["lifecycle.recovery_timestamp"] = recovery_time.isoformat()[:256]
    if operator is not None:
        notes["lifecycle.operator"] = operator[:256]
    if detail is not None:
        notes["lifecycle.detail"] = detail[:256]
    if rule_name is not None:
        notes["lifecycle.rule_name"] = rule_name[:256]
    if window_seconds is not None:
        notes["lifecycle.window_seconds"] = str(window_seconds)
    if last_update_time is not None:
        notes["lifecycle.last_update_time"] = last_update_time.isoformat()[:256]
    if expiration_time is not None:
        notes["lifecycle.expired_at"] = expiration_time.isoformat()[:256]
    return notes


def _lifecycle_context(
    incident: Incident,
    *,
    reason: str,
    fingerprint: str | None = None,
    source_id: str | None = None,
    host: str | None = None,
    service: str | None = None,
    recovery_time: datetime | None = None,
    operator: str | None = None,
    detail: str | None = None,
    rule_name: str | None = None,
    window_seconds: int | None = None,
    last_update_time: datetime | None = None,
    expiration_time: datetime | None = None,
    previous_host_count: int = 0,
    previous_service_count: int = 0,
) -> dict[str, Any]:
    candidate = _normalizable_decision_context(dict(incident.decision_context or {}))
    existing_notes = dict(candidate.get("notes") or {})
    lifecycle_notes = _lifecycle_notes(
        reason=reason,
        fingerprint=fingerprint,
        source_id=source_id,
        host=host,
        service=service,
        recovery_time=recovery_time,
        operator=operator,
        detail=detail,
        rule_name=rule_name,
        window_seconds=window_seconds,
        last_update_time=last_update_time,
        expiration_time=expiration_time,
        previous_host_count=previous_host_count,
        previous_service_count=previous_service_count,
    )
    remaining = max(0, 20 - len(lifecycle_notes))
    kept_notes = {
        key: value
        for key, value in existing_notes.items()
        if not key.startswith("lifecycle.")
    }
    candidate["notes"] = dict(
        list(kept_notes.items())[-remaining:] + list(lifecycle_notes.items())
    )
    candidate["fingerprint"] = fingerprint or candidate.get("fingerprint")
    candidate["source_id"] = source_id or candidate.get("source_id")
    candidate["event_count"] = incident.event_count
    return DecisionContext.model_validate(candidate).model_dump(mode="json")


def _window_state_with_active_objects(
    incident: Incident,
    active_objects: tuple[IncidentObject, ...],
) -> dict[str, Any]:
    state = _window_state_from_json(incident.window_state)
    return _window_state_dump(
        state.model_copy(
            update={
                "active_objects": tuple(
                    sorted(
                        active_objects, key=lambda obj: (obj.host, obj.service or "")
                    )
                )
            }
        )
    )


async def _shrink_affected_sets(
    session: AsyncSession,
    incident: Incident,
    *,
    active_objects: tuple[IncidentObject, ...],
    decision_context: dict[str, Any],
) -> Incident:
    new_hosts, new_services = _affected_sets_from_objects(active_objects)
    update_values: dict[str, Any] = {
        "affected_hosts": new_hosts,
        "affected_services": new_services,
        "decision_context": decision_context,
        "window_state": _window_state_with_active_objects(incident, active_objects),
        "updated_at": func.now(),
    }
    result = await session.execute(
        update(Incident)
        .where(Incident.id == incident.id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .values(**update_values)
        .returning(*Incident.__table__.columns)
    )
    return _incident_from_mapping(result.mappings().one())


async def _resolve_to_resolved(
    session: AsyncSession,
    incident: Incident,
    *,
    decision_context: dict[str, Any],
) -> Incident:
    window_state = _window_state_with_active_objects(incident, ())
    target = validate_incident_transition(IncidentStatus.OPEN, IncidentStatus.RESOLVED)
    result = await session.execute(
        update(Incident)
        .where(Incident.id == incident.id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .values(
            status=target.value,
            affected_hosts=[],
            affected_services=[],
            decision_context=decision_context,
            window_state=window_state,
            resolved_at=func.now(),
            updated_at=func.now(),
        )
        .returning(*Incident.__table__.columns)
    )
    return _incident_from_mapping(result.mappings().one())


async def resolve_host_recovery(
    session: AsyncSession,
    *,
    host: str,
    recovery_time: datetime,
    fingerprint: str,
    source_id: str,
) -> tuple[LifecycleWriteResult, ...]:
    candidates = await session.execute(
        select(Incident)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .where(Incident.window_state["active_objects"].contains([{"host": host}]))
        .with_for_update()
    )
    results: list[LifecycleWriteResult] = []
    for incident in candidates.scalars():
        previous_host_count = len(incident.affected_hosts)
        previous_service_count = len(incident.affected_services)
        active_objects = _window_state_from_json(incident.window_state).active_objects
        new_active_objects = tuple(obj for obj in active_objects if obj.host != host)
        if len(new_active_objects) == len(active_objects):
            continue
        decision_context = _lifecycle_context(
            incident,
            reason="source_recovery",
            fingerprint=fingerprint,
            source_id=source_id,
            host=host,
            recovery_time=recovery_time,
            previous_host_count=previous_host_count,
            previous_service_count=previous_service_count,
        )
        if not new_active_objects:
            updated = await _resolve_to_resolved(
                session,
                incident,
                decision_context=decision_context,
            )
            results.append(
                LifecycleWriteResult(
                    incident=updated,
                    effect="resolved",
                    transitioned_to=IncidentStatus.RESOLVED.value,
                    previous_host_count=previous_host_count,
                    previous_service_count=previous_service_count,
                    affected_object_removed=True,
                )
            )
            continue
        updated = await _shrink_affected_sets(
            session,
            incident,
            active_objects=new_active_objects,
            decision_context=decision_context,
        )
        results.append(
            LifecycleWriteResult(
                incident=updated,
                effect="affected_set_shrunk",
                transitioned_to=None,
                previous_host_count=previous_host_count,
                previous_service_count=previous_service_count,
                affected_object_removed=True,
            )
        )
    return tuple(results)


async def resolve_service_recovery(
    session: AsyncSession,
    *,
    host: str,
    service: str,
    recovery_time: datetime,
    fingerprint: str,
    source_id: str,
) -> tuple[LifecycleWriteResult, ...]:
    candidates = await session.execute(
        select(Incident)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .where(
            Incident.window_state["active_objects"].contains(
                [{"host": host, "service": service}]
            )
        )
        .with_for_update()
    )
    results: list[LifecycleWriteResult] = []
    for incident in candidates.scalars():
        previous_host_count = len(incident.affected_hosts)
        previous_service_count = len(incident.affected_services)
        active_objects = _window_state_from_json(incident.window_state).active_objects
        recovered_object = IncidentObject(host=host, service=service)
        if recovered_object not in active_objects:
            continue
        new_active_objects = tuple(
            obj for obj in active_objects if obj != recovered_object
        )
        decision_context = _lifecycle_context(
            incident,
            reason="source_recovery",
            fingerprint=fingerprint,
            source_id=source_id,
            host=host,
            service=service,
            recovery_time=recovery_time,
            previous_host_count=previous_host_count,
            previous_service_count=previous_service_count,
        )
        if not new_active_objects:
            updated = await _resolve_to_resolved(
                session,
                incident,
                decision_context=decision_context,
            )
            results.append(
                LifecycleWriteResult(
                    incident=updated,
                    effect="resolved",
                    transitioned_to=IncidentStatus.RESOLVED.value,
                    previous_host_count=previous_host_count,
                    previous_service_count=previous_service_count,
                    affected_object_removed=True,
                )
            )
            continue
        updated = await _shrink_affected_sets(
            session,
            incident,
            active_objects=new_active_objects,
            decision_context=decision_context,
        )
        results.append(
            LifecycleWriteResult(
                incident=updated,
                effect="affected_set_shrunk",
                transitioned_to=None,
                previous_host_count=previous_host_count,
                previous_service_count=previous_service_count,
                affected_object_removed=True,
            )
        )
    return tuple(results)


async def ack_open_incident(
    session: AsyncSession,
    incident_id: UUID,
    *,
    operator: str,
) -> LifecycleWriteResult | None:
    selected = await session.execute(
        select(Incident)
        .where(Incident.id == incident_id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .with_for_update()
    )
    incident = selected.scalar_one_or_none()
    if incident is None:
        current = await session.execute(
            select(Incident).where(Incident.id == incident_id)
        )
        row = current.scalar_one_or_none()
        if row is None:
            return None
        return LifecycleWriteResult(
            incident=row,
            effect="noop",
            transitioned_to=None,
            previous_host_count=len(row.affected_hosts),
            previous_service_count=len(row.affected_services),
            affected_object_removed=False,
        )
    previous_host_count = len(incident.affected_hosts)
    previous_service_count = len(incident.affected_services)
    decision_context = _lifecycle_context(
        incident,
        reason="acknowledged",
        operator=operator,
        previous_host_count=previous_host_count,
        previous_service_count=previous_service_count,
    )
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
    updated = _incident_from_mapping(result.mappings().one())
    return LifecycleWriteResult(
        incident=updated,
        effect="acknowledged",
        transitioned_to=None,
        previous_host_count=previous_host_count,
        previous_service_count=previous_service_count,
        affected_object_removed=False,
    )


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
    incident = selected.scalar_one_or_none()
    if incident is None:
        current = await session.execute(
            select(Incident).where(Incident.id == incident_id)
        )
        row = current.scalar_one_or_none()
        if row is None:
            return None
        return LifecycleWriteResult(
            incident=row,
            effect="noop",
            transitioned_to=None,
            previous_host_count=len(row.affected_hosts),
            previous_service_count=len(row.affected_services),
            affected_object_removed=False,
        )
    previous_host_count = len(incident.affected_hosts)
    previous_service_count = len(incident.affected_services)
    decision_context = _lifecycle_context(
        incident,
        reason="manual_close",
        operator=operator,
        detail=reason,
        previous_host_count=previous_host_count,
        previous_service_count=previous_service_count,
    )
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
    updated = _incident_from_mapping(result.mappings().one())
    return LifecycleWriteResult(
        incident=updated,
        effect="closed",
        transitioned_to=IncidentStatus.CLOSED.value,
        previous_host_count=previous_host_count,
        previous_service_count=previous_service_count,
        affected_object_removed=False,
    )


def _window_seconds_from_incident(incident: Incident) -> int:
    return int(incident.window_state["window_seconds"])


def _stale_expiration_cutoff() -> Any:
    window_seconds = Incident.window_state["window_seconds"].astext.cast(Integer)
    return Incident.last_update_time + window_seconds * text("interval '1 second'")


async def expire_stale_incidents(
    session: AsyncSession,
    limit: int,
) -> tuple[Incident, ...]:
    if limit < 1:
        return ()
    candidates = await session.execute(
        select(Incident, func.now().label("database_now"))
        .where(Incident.status == IncidentStatus.OPEN.value)
        .where(func.now() > _stale_expiration_cutoff())
        .order_by(Incident.id)
        .limit(limit)
        .with_for_update(skip_locked=True)
    )
    expired: list[Incident] = []
    for incident, database_now in candidates.all():
        previous_host_count = len(incident.affected_hosts)
        previous_service_count = len(incident.affected_services)
        window_seconds = _window_seconds_from_incident(incident)
        decision_context = _lifecycle_context(
            incident,
            reason="expired",
            rule_name=incident.rule_name,
            window_seconds=window_seconds,
            last_update_time=incident.last_update_time,
            expiration_time=database_now,
            previous_host_count=previous_host_count,
            previous_service_count=previous_service_count,
        )
        target = validate_incident_transition(
            IncidentStatus.OPEN, IncidentStatus.CLOSED
        )
        update_result = await session.execute(
            update(Incident)
            .where(Incident.id == incident.id)
            .where(Incident.status == IncidentStatus.OPEN.value)
            .values(
                status=target.value,
                decision_context=decision_context,
                closed_at=func.now(),
                updated_at=func.now(),
            )
            .returning(*Incident.__table__.columns)
        )
        mapping = update_result.mappings().one_or_none()
        if mapping is None:
            continue
        expired.append(_incident_from_mapping(mapping))
    return tuple(expired)
