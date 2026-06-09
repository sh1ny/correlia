"""Atomic open-incident aggregation repository for PostgreSQL."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Literal
from uuid import UUID, uuid4

from sqlalchemy import Integer, case, func, literal, select, text, update
from sqlalchemy.dialects.postgresql import JSONB, insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.events import Severity
from app.domain.incidents import DecisionContext, IncidentStatus, IncidentWindowState, validate_incident_transition
from app.domain.rules import NotificationResult
from app.persistence.models import Incident

MAX_AFFECTED_HOSTS = 100
MAX_AFFECTED_SERVICES = 100
MAX_WINDOW_FINGERPRINTS = 100

IncidentEffect = Literal["inserted", "updated"]


def _severity_rank_expr(column: Any) -> Any:
    return case(
        (column == "OK", 0),
        (column == "WARNING", 1),
        (column == "UNKNOWN", 2),
        (column == "CRITICAL", 3),
        else_=0,
    )


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


def _bounded_sorted_union(
    existing: list[str], incoming: tuple[str, ...], max_items: int
) -> list[str]:
    return sorted({*existing, *incoming})[:max_items]


def _jsonb_sorted_union(existing_column: Any, excluded_name: str, max_items: int) -> Any:
    existing_elems = select(
        func.jsonb_array_elements_text(existing_column).label("elem")
    ).subquery("e1")

    excluded_elems = select(
        func.jsonb_array_elements_text(text(f"excluded.{excluded_name}")).label("elem")
    ).subquery("e2")

    combined = select(existing_elems.c.elem).union(
        select(excluded_elems.c.elem)
    ).subquery("u")

    ordered_limited = select(combined.c.elem).order_by(
        combined.c.elem
    ).limit(max_items).subquery("o")

    agg = select(func.jsonb_agg(ordered_limited.c.elem)).select_from(ordered_limited)

    return func.coalesce(agg.scalar_subquery(), literal("[]").cast(JSONB))


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
        if self.threshold_count < 1:
            raise ValueError("threshold_count must be positive")
        if self.window_seconds < 1:
            raise ValueError("window_seconds must be positive")
        if not 1 <= self.max_window_fingerprints <= MAX_WINDOW_FINGERPRINTS:
            raise ValueError("max_window_fingerprints is out of bounds")

        hosts = tuple(sorted(set(self.affected_hosts)))
        if not hosts:
            raise ValueError("affected_hosts must be non-empty")
        for h in hosts:
            if not h or not h.strip():
                raise ValueError("affected_hosts must not contain empty strings")
        if len(hosts) > MAX_AFFECTED_HOSTS:
            hosts = hosts[:MAX_AFFECTED_HOSTS]

        services = tuple(sorted(set(self.affected_services)))
        for s in services:
            if not s or not s.strip():
                raise ValueError("affected_services must not contain empty strings")
        if len(services) > MAX_AFFECTED_SERVICES:
            services = services[:MAX_AFFECTED_SERVICES]

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


def _parse_timestamp(value: Any) -> datetime:
    if isinstance(value, datetime):
        return value
    if isinstance(value, str):
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    raise TypeError("window timestamp must be a datetime or ISO string")


def _window_state_dump(state: IncidentWindowState) -> dict[str, Any]:
    return state.model_dump(mode="json")


def _window_state_from_json(data: dict[str, Any]) -> IncidentWindowState:
    timestamps = {
        str(fingerprint): _parse_timestamp(timestamp)
        for fingerprint, timestamp in data.get("counted_fingerprint_timestamps", {}).items()
    }
    return IncidentWindowState(
        window_started_at=_parse_timestamp(data["window_started_at"]),
        window_ended_at=_parse_timestamp(data["window_ended_at"]),
        window_seconds=int(data["window_seconds"]),
        threshold_count=int(data["threshold_count"]),
        counted_fingerprint_timestamps=timestamps,
        counted_count=int(data["counted_count"]),
        max_size=int(data["max_size"]),
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
    )


def _next_window_state(
    existing: Incident,
    input: IncidentUpsertInput,
) -> tuple[IncidentWindowState, bool, bool, bool]:
    window_end = max(existing.last_update_time, input.event_time)
    window_start = window_end - timedelta(seconds=input.window_seconds)
    existing_state = existing.window_state or {}
    raw_timestamps = existing_state.get("counted_fingerprint_timestamps", {})

    retained: dict[str, datetime] = {}
    for fingerprint, timestamp_value in raw_timestamps.items():
        timestamp = _parse_timestamp(timestamp_value)
        if window_start <= timestamp <= window_end:
            retained[str(fingerprint)] = timestamp

    inside_window = window_start <= input.event_time <= window_end
    fingerprint = input.fingerprint
    assert fingerprint is not None
    replay = fingerprint in retained
    counted = inside_window and not replay
    if counted:
        retained[fingerprint] = input.event_time

    if len(retained) > input.max_window_fingerprints:
        newest = sorted(retained.items(), key=lambda item: (item[1], item[0]), reverse=True)[
            : input.max_window_fingerprints
        ]
        retained = dict(newest)

    retained = dict(sorted(retained.items()))
    state = IncidentWindowState(
        window_started_at=window_start,
        window_ended_at=window_end,
        window_seconds=input.window_seconds,
        threshold_count=input.threshold_count,
        counted_fingerprint_timestamps=retained,
        counted_count=len(retained),
        max_size=input.max_window_fingerprints,
    )
    return state, replay, inside_window, counted


def _decision_context_dump(input: IncidentUpsertInput) -> dict[str, Any]:
    if input.decision_context is None:
        return {}
    return input.decision_context.model_dump(mode="json")


def _safe_notification_notes(
    context: dict[str, Any], plugin_name: str, result: NotificationResult
) -> dict[str, Any]:
    notes = dict(context.get("notes") or {})
    existing_indexes = [
        int(key.split(".")[1])
        for key in notes
        if key.startswith("notification.") and key.endswith(".category") and key.split(".")[1].isdigit()
    ]
    next_index = max(existing_indexes, default=-1) + 1
    prefix = f"notification.{next_index}"
    notes[f"{prefix}.plugin"] = plugin_name[:256]
    notes[f"{prefix}.category"] = result.category
    notes[f"{prefix}.success"] = "true" if result.success else "false"
    notes[f"{prefix}.message"] = result.message[:256]
    if len(notes) > 20:
        ordered = sorted(notes.items())
        notification_items = [item for item in ordered if item[0].startswith("notification.")]
        other_items = [item for item in ordered if not item[0].startswith("notification.")]
        notes = dict((other_items + notification_items)[-20:])
    return notes


def _normalizable_decision_context(context: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(context)
    for key in ("matched_rule_names", "enrichment_refs", "action_names"):
        value = normalized.get(key)
        if isinstance(value, list):
            normalized[key] = tuple(value)
    return normalized


def _validated_notification_context(
    context: dict[str, Any], plugin_name: str, result: NotificationResult
) -> dict[str, Any]:
    candidate = _normalizable_decision_context(context)
    candidate["notes"] = _safe_notification_notes(candidate, plugin_name, result)
    try:
        return DecisionContext.model_validate(candidate).model_dump(mode="json")
    except ValueError:
        redacted = NotificationResult(
            success=result.success,
            category=result.category,
            message="notification result redacted",
        )
        redacted_candidate = _normalizable_decision_context(context)
        redacted_candidate["notes"] = _safe_notification_notes(redacted_candidate, plugin_name, redacted)
        return DecisionContext.model_validate(redacted_candidate).model_dump(mode="json")


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
    update_values: dict[str, Any] = {"decision_context": context, "updated_at": func.now()}
    if result.success:
        update_values["notified_at"] = func.now()
    await session.execute(
        update(Incident)
        .where(Incident.id == incident_id)
        .values(**update_values)
    )
    incident.decision_context = context
    return True


def _incident_from_mapping(mapping: Any) -> Incident:
    return Incident(**mapping)


def build_open_incident_upsert(input: IncidentUpsertInput) -> Any:
    decision_data = _decision_context_dump(input)
    initial_state = _initial_window_state(input)
    threshold_crossed = initial_state.counted_count >= input.threshold_count

    stmt: Any = insert(Incident).values(
        id=uuid4(),
        rule_name=input.rule_name,
        group_key=input.group_key,
        status=IncidentStatus.OPEN.value,
        severity=input.severity.value,
        summary=input.summary,
        event_count=1,
        affected_hosts=list(input.affected_hosts),
        affected_services=list(input.affected_services),
        decision_context=decision_data,
        window_state=_window_state_dump(initial_state),
        threshold_crossed=threshold_crossed,
        notified_at=None,
        start_time=input.event_time,
        last_update_time=input.event_time,
    )

    excluded_severity = stmt.excluded.severity
    existing_severity = Incident.severity

    new_severity = case(
        (
            _severity_rank_expr(excluded_severity) > _severity_rank_expr(existing_severity),
            excluded_severity,
        ),
        else_=existing_severity,
    )

    new_hosts = _jsonb_sorted_union(
        Incident.affected_hosts,
        "affected_hosts",
        MAX_AFFECTED_HOSTS,
    )

    new_services = _jsonb_sorted_union(
        Incident.affected_services,
        "affected_services",
        MAX_AFFECTED_SERVICES,
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=[Incident.rule_name, Incident.group_key],
        index_where=text(f"status = '{IncidentStatus.OPEN.value}'"),
        set_={
            Incident.event_count: Incident.event_count + 1,
            Incident.last_update_time: func.greatest(
                Incident.last_update_time, stmt.excluded.last_update_time
            ),
            Incident.severity: new_severity,
            Incident.summary: stmt.excluded.summary,
            Incident.affected_hosts: new_hosts,
            Incident.affected_services: new_services,
            Incident.decision_context: stmt.excluded.decision_context,
            Incident.window_state: stmt.excluded.window_state,
            Incident.threshold_crossed: case(
                (Incident.threshold_crossed.is_(False), stmt.excluded.threshold_crossed),
                else_=Incident.threshold_crossed,
            ),
            Incident.updated_at: func.now(),
        },
    ).returning(*Incident.__table__.columns)

    return stmt


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
        return IncidentAggregationWriteResult(
            incident=inserted,
            effect="inserted",
            replay=False,
            inside_window=True,
            counted=True,
            threshold_crossed=threshold_crossed,
            first_threshold_transition=threshold_crossed,
            counted_count=window_state.counted_count,
            counted_fingerprints=tuple(window_state.counted_fingerprint_timestamps.keys()),
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
    threshold_crossed = existing.threshold_crossed or window_state.counted_count >= input.threshold_count
    first_threshold_transition = not existing.threshold_crossed and threshold_crossed

    updated_result = await session.execute(
        update(Incident)
        .where(Incident.id == existing.id)
        .values(
            event_count=Incident.event_count + (1 if counted else 0),
            last_update_time=func.greatest(Incident.last_update_time, input.event_time),
            severity=_max_severity(existing.severity, input.severity),
            summary=input.summary if counted else existing.summary,
            affected_hosts=_bounded_sorted_union(
                existing.affected_hosts,
                input.affected_hosts,
                MAX_AFFECTED_HOSTS,
            ),
            affected_services=_bounded_sorted_union(
                existing.affected_services,
                input.affected_services,
                MAX_AFFECTED_SERVICES,
            ),
            decision_context=_decision_context_dump(input),
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
            affected_hosts=list(input.affected_hosts),
            affected_services=list(input.affected_services),
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
):
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
    candidate["notes"] = dict(list(kept_notes.items())[-remaining:] + list(lifecycle_notes.items()))
    candidate["fingerprint"] = fingerprint or candidate.get("fingerprint")
    candidate["source_id"] = source_id or candidate.get("source_id")
    candidate["event_count"] = incident.event_count
    return DecisionContext.model_validate(candidate).model_dump(mode="json")


async def _shrink_affected_sets(
    session: AsyncSession,
    incident: Incident,
    *,
    new_hosts: list[str],
    new_services: list[str],
    decision_context: dict[str, Any],
) -> Incident:
    result = await session.execute(
        update(Incident)
        .where(Incident.id == incident.id)
        .where(Incident.status == IncidentStatus.OPEN.value)
        .values(
            affected_hosts=new_hosts,
            affected_services=new_services,
            decision_context=decision_context,
            updated_at=func.now(),
        )
        .returning(*Incident.__table__.columns)
    )
    return _incident_from_mapping(result.mappings().one())


async def _resolve_to_resolved(
    session: AsyncSession,
    incident: Incident,
    *,
    decision_context: dict[str, Any],
) -> Incident:
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
        .where(Incident.affected_hosts.contains([host]))
        .with_for_update()
    )
    results: list[LifecycleWriteResult] = []
    for incident in candidates.scalars():
        previous_host_count = len(incident.affected_hosts)
        previous_service_count = len(incident.affected_services)
        new_hosts = sorted(item for item in incident.affected_hosts if item != host)
        if len(new_hosts) == previous_host_count:
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
        if not new_hosts and not incident.affected_services:
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
            new_hosts=new_hosts,
            new_services=list(incident.affected_services),
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
        .where(Incident.affected_hosts.contains([host]))
        .where(Incident.affected_services.contains([service]))
        .with_for_update()
    )
    results: list[LifecycleWriteResult] = []
    for incident in candidates.scalars():
        previous_host_count = len(incident.affected_hosts)
        previous_service_count = len(incident.affected_services)
        new_services = sorted(item for item in incident.affected_services if item != service)
        new_hosts = sorted(item for item in incident.affected_hosts if item != host)
        if (
            len(new_hosts) == previous_host_count
            and len(new_services) == previous_service_count
        ):
            continue
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
        if not new_hosts and not new_services:
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
            new_hosts=new_hosts,
            new_services=new_services,
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
        current = await session.execute(select(Incident).where(Incident.id == incident_id))
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
        current = await session.execute(select(Incident).where(Incident.id == incident_id))
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
        target = validate_incident_transition(IncidentStatus.OPEN, IncidentStatus.CLOSED)
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