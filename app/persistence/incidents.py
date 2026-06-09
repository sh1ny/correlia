"""Atomic open-incident aggregation repository for PostgreSQL."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Literal
from uuid import uuid4

from sqlalchemy import case, func, literal, select, text, update
from sqlalchemy.dialects.postgresql import JSONB, insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.events import Severity
from app.domain.incidents import DecisionContext, IncidentStatus, IncidentWindowState
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
    window_started_at = input.event_time - timedelta(seconds=input.window_seconds)
    return IncidentWindowState(
        window_started_at=window_started_at,
        window_ended_at=input.event_time,
        window_seconds=input.window_seconds,
        threshold_count=input.threshold_count,
        counted_fingerprint_timestamps={input.fingerprint: input.event_time},
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
    replay = input.fingerprint in retained
    counted = inside_window and not replay
    if counted:
        retained[input.fingerprint] = input.event_time

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
