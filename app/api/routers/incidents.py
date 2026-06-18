from __future__ import annotations
import logging

from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request, Security, status

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
    IncidentStatusFilter,
)
from app.persistence.incidents import (
    ack_open_incident,
    close_open_incident,
    get_incident_by_id,
    list_incidents,
)
from app.processing.logging import safe_log_extra
from app.persistence.models import Incident

router = APIRouter(prefix="/v1/incidents", dependencies=[Security(require_operator_token)])
logger = logging.getLogger(__name__)

VIGILO_COMPAT_OPERATOR = "vigilo-compat"
VIGILO_COMPAT_REASON = "vigilo-compat"



def _safe_decision_context(incident: Incident) -> DecisionContext:
    data = dict(incident.decision_context or {})
    for key in ("matched_rule_names", "enrichment_refs", "action_names"):
        value = data.get(key)
        if isinstance(value, list):
            data[key] = tuple(value)
    try:
        return DecisionContext.model_validate(data)
    except ValidationError:
        return DecisionContext()


def _incident_response(incident: Incident) -> IncidentDetailResponse:
    return IncidentDetailResponse(
        id=incident.id,
        rule_name=incident.rule_name,
        group_key=incident.group_key,
        status=IncidentStatus(incident.status),
        severity=Severity(incident.severity),
        summary=incident.summary,
        event_count=incident.event_count,
        affected_hosts=tuple(incident.affected_hosts),
        affected_services=tuple(incident.affected_services),
        acknowledgement=Acknowledgement(
            acknowledged_at=incident.acknowledged_at,
            acknowledged_by=incident.acknowledged_by,
        ),
        decision_context=_safe_decision_context(incident),
        window_state=dict(incident.window_state or {}),
        threshold_crossed=incident.threshold_crossed,
        notified_at=incident.notified_at,
        start_time=incident.start_time,
        last_update_time=incident.last_update_time,
        resolved_at=incident.resolved_at,
        closed_at=incident.closed_at,
        created_at=incident.created_at,
        updated_at=incident.updated_at,
    )


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
    return IncidentListFilters(
        status=status_filter,
        severity=severity,
        rule_name=rule_name,
        host=host,
        service=service,
        updated_since=updated_since,
        limit=limit,
        cursor=cursor,
        offset=offset,
    )


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
        total=page.total,
        limit=filters.limit,
        offset=page.offset,
        next_cursor=page.next_cursor,
    )


@router.get("/{incident_id}", response_model=IncidentDetailResponse)
async def get_incident(
    incident_id: UUID,
    sessionmaker: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_sessionmaker)
    ],
) -> IncidentDetailResponse:
    async with sessionmaker() as session:
        incident = await get_incident_by_id(session, incident_id)
    if incident is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="incident not found")
    return _incident_response(incident)


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


@router.post("/{incident_id}/close", response_model=IncidentDetailResponse)
async def close_incident_endpoint(
    incident_id: UUID,
    sessionmaker: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_sessionmaker)
    ],
    body: IncidentCloseRequest = Body(...),
) -> IncidentDetailResponse:
    async with sessionmaker() as session:
        result = await close_open_incident(
            session,
            incident_id,
            operator=body.operator,
            reason=body.reason,
        )
        if result is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="incident not found")
        await session.commit()
        logger.info(
            "incident manually closed",
            extra=safe_log_extra(
                event="operator_mutation",
                incident_id=str(result.incident.id),
                status=result.incident.status,
                effect=result.effect,
                reason="manual_close",
                operator=body.operator,
            ),
        )
    return _incident_response(result.incident)


@router.patch("/{incident_id}", response_model=IncidentDetailResponse)
async def patch_incident(
    incident_id: UUID,
    request: Request,
    sessionmaker: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_sessionmaker)
    ],
) -> IncidentDetailResponse:
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="status is required",
        )
    if not isinstance(body, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="status is required",
        )
    if any(key != "status" for key in body):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="summary mutation is not supported",
        )
    status_value = body.get("status")
    if status_value == "ACKNOWLEDGED":
        async with sessionmaker() as session:
            result = await ack_open_incident(
                session, incident_id, operator=VIGILO_COMPAT_OPERATOR
            )
            if result is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="incident not found",
                )
            await session.commit()
            logger.info(
                "incident acknowledged",
                extra=safe_log_extra(
                    event="operator_mutation",
                    incident_id=str(result.incident.id),
                    status=result.incident.status,
                    effect=result.effect,
                    reason="acknowledged",
                    operator=VIGILO_COMPAT_OPERATOR,
                ),
            )
        return _incident_response(result.incident)
    if status_value == "CLOSED":
        async with sessionmaker() as session:
            result = await close_open_incident(
                session,
                incident_id,
                operator=VIGILO_COMPAT_OPERATOR,
                reason=VIGILO_COMPAT_REASON,
            )
            if result is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="incident not found",
                )
            await session.commit()
            logger.info(
                "incident manually closed",
                extra=safe_log_extra(
                    event="operator_mutation",
                    incident_id=str(result.incident.id),
                    status=result.incident.status,
                    effect=result.effect,
                    reason="manual_close",
                    operator=VIGILO_COMPAT_OPERATOR,
                ),
            )
        return _incident_response(result.incident)
    raise HTTPException(
        status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        detail="status is required",
    )


@router.delete("/{incident_id}", response_model=IncidentDetailResponse)
async def delete_incident(
    incident_id: UUID,
    sessionmaker: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_sessionmaker)
    ],
) -> IncidentDetailResponse:
    async with sessionmaker() as session:
        result = await close_open_incident(
            session,
            incident_id,
            operator=VIGILO_COMPAT_OPERATOR,
            reason=VIGILO_COMPAT_REASON,
        )
        if result is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="incident not found",
            )
        await session.commit()
        logger.info(
            "incident manually closed",
            extra=safe_log_extra(
                event="operator_mutation",
                incident_id=str(result.incident.id),
                status=result.incident.status,
                effect=result.effect,
                reason="manual_close",
                operator=VIGILO_COMPAT_OPERATOR,
            ),
        )
    return _incident_response(result.incident)
