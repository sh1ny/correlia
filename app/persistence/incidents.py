"""Atomic open-incident upsert repository for PostgreSQL."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import case, func, select, text
from sqlalchemy.dialects.postgresql import JSONB, insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.events import Severity
from app.domain.incidents import DecisionContext, IncidentStatus
from app.persistence.models import Incident

MAX_AFFECTED_HOSTS = 100
MAX_AFFECTED_SERVICES = 100


def _severity_rank_expr(column):
    return case(
        (column == "OK", 0),
        (column == "WARNING", 1),
        (column == "UNKNOWN", 2),
        (column == "CRITICAL", 3),
        else_=0,
    )


def _jsonb_sorted_union(existing_column, excluded_name: str, max_items: int):
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

    return func.coalesce(agg.scalar_subquery(), func.cast("[]", JSONB))


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

    def __post_init__(self):
        if not self.rule_name or not self.rule_name.strip():
            raise ValueError("rule_name must be non-empty")
        if not self.group_key or not self.group_key.strip():
            raise ValueError("group_key must be non-empty")
        if not self.summary or not self.summary.strip():
            raise ValueError("summary must be non-empty")
        if self.event_time.tzinfo is None or self.event_time.utcoffset() is None:
            raise ValueError("event_time must be timezone-aware")

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


def build_open_incident_upsert(input: IncidentUpsertInput):
    decision_data = {}
    if input.decision_context is not None:
        decision_data = input.decision_context.model_dump(mode="json")

    stmt = insert(Incident).values(
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
            Incident.updated_at: func.now(),
        },
    ).returning(*Incident.__table__.columns)

    return stmt


async def upsert_open_incident(
    session: AsyncSession, input: IncidentUpsertInput
) -> Incident:
    stmt = build_open_incident_upsert(input)
    result = await session.execute(stmt)
    mapping = result.mappings().one()
    return Incident(**mapping)
