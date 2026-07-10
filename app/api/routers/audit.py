"""Read-only operator audit-event router and bounded response mapping.

Exposes ``GET /v1/incident-events`` with operator auth (D-09/D-16),
cursor-first pagination (D-10), all D-11 filters, and a bounded
response projection that omits ``raw_payload`` and full
``normalized_event`` (D-08/D-15).  Read-time redaction of
``normalized_event_message`` and ``normalized_event_tags`` is applied
idempotently here even though the repository also redacts.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Security, status
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import get_sessionmaker
from app.api.security import require_operator_token
from app.domain.audit import (
    AuditDecisionSummary,
    AuditEventListFilters,
    AuditEventListResponse,
    AuditEventResponse,
)
from app.domain.events import EventType, Severity
from app.persistence.audit import (
    InvalidAuditCursorError,
    list_incident_events,
    redact_normalized_event_message_tags,
)

router = APIRouter(
    prefix="/v1/incident-events",
    dependencies=[Security(require_operator_token)],
)


async def audit_event_list_filters(
    incident_id: UUID | None = None,
    has_incident: bool | None = None,
    fingerprint: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
    source_id: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
    event_type: EventType | None = None,
    incident_effect: Literal[
        "none", "inserted", "updated", "resolved", "affected_set_shrunk"
    ] | None = None,
    no_dispatch_reason: Annotated[str | None, Query(min_length=1, max_length=128)] = None,
    severity: Severity | None = None,
    host: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
    service: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
    accepted_since: datetime | None = None,
    accepted_until: datetime | None = None,
    event_timestamp_since: datetime | None = None,
    event_timestamp_until: datetime | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    cursor: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
    offset: Annotated[int | None, Query(ge=0)] = None,
) -> AuditEventListFilters:
    try:
        return AuditEventListFilters(
            incident_id=incident_id,
            has_incident=has_incident,
            fingerprint=fingerprint,
            source_id=source_id,
            event_type=event_type,
            incident_effect=incident_effect,
            no_dispatch_reason=no_dispatch_reason,
            severity=severity,
            host=host,
            service=service,
            accepted_since=accepted_since,
            accepted_until=accepted_until,
            event_timestamp_since=event_timestamp_since,
            event_timestamp_until=event_timestamp_until,
            limit=limit,
            cursor=cursor,
            offset=offset,
        )
    except ValidationError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(exc),
        ) from exc


def _audit_event_response(row: Any) -> AuditEventResponse:
    """Map an ``AuditEventListRow`` to a bounded ``AuditEventResponse``.

    Applies idempotent read-time redaction to the projected message and
    tags (D-08).  Never handles ``raw_payload`` or full ``normalized_event``.
    """
    safe_message, safe_tags = redact_normalized_event_message_tags(
        row.normalized_event_message,
        row.normalized_event_tags,
    )
    return AuditEventResponse(
        id=row.id,
        accepted_at=row.accepted_at,
        event_timestamp=row.event_timestamp,
        source_id=row.source_id,
        fingerprint=row.fingerprint,
        event_type=EventType(row.event_type),
        severity=Severity(row.severity),
        host=row.host,
        service=row.service,
        incident_ids=row.incident_ids,
        incident_effect=row.incident_effect,
        decision_summary=AuditDecisionSummary(**row.decision_summary),
        normalized_event_message=safe_message,
        normalized_event_tags=safe_tags,
        raw_payload_original_byte_length=row.raw_payload_original_byte_length,
        raw_payload_stored_byte_length=row.raw_payload_stored_byte_length,
        raw_payload_truncated=row.raw_payload_truncated,
        redaction_version=row.redaction_version,
        redacted_path_count=row.redacted_path_count,
        raw_payload_hmac=row.raw_payload_hmac,
    )


@router.get("", response_model=AuditEventListResponse)
async def list_incident_events_endpoint(
    filters: Annotated[AuditEventListFilters, Depends(audit_event_list_filters)],
    sessionmaker: Annotated[async_sessionmaker[AsyncSession], Depends(get_sessionmaker)],
) -> AuditEventListResponse:
    try:
        async with sessionmaker() as session:
            page = await list_incident_events(session, filters)
    except InvalidAuditCursorError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="invalid cursor",
        ) from exc
    items = tuple(_audit_event_response(row) for row in page.events)
    return AuditEventListResponse(
        items=items,
        total=page.total,
        limit=filters.limit,
        offset=page.offset,
        next_cursor=page.next_cursor,
    )
