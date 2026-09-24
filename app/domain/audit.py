"""Strict audit domain contracts for the Phase 7 incident event audit trail.

These Pydantic v2 models mirror the bounded, versioned, ``extra="forbid"``
discipline established by ``DecisionContext`` in ``app.domain.incidents``.
They are the read-side and decision-summary contracts for ``incident_events``;
the repository helpers in ``app.persistence.audit`` consume them and project
rows suitable for ``AuditEventResponse``.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.domain.events import EventType, Severity, TagKey, TagValue
from app.domain.incidents import BoundedString, BoundedStringTuple

# D-08: dedicated response-only annotation for the audit-list message
# projection. Matches the router/repository 512-char cap plus the
# empty-string fallback for events whose source payload did not carry a
# message. NOT a storage constraint: stored messages remain bounded by
# ``NormalizedEvent.message`` (max 4096). Reusing ``BoundedString`` here
# would be wrong because it has ``min_length=1`` and would reject the
# empty-string fallback.
BoundedResponseMessage = Annotated[str, Field(min_length=0, max_length=512)]

# D-18: ``no_dispatch_reason`` is a bounded string capped at 128 chars.
BoundedNoDispatchReason = Annotated[str, Field(min_length=1, max_length=128)]

#: The maximum number of incident ids recorded on an audit decision summary.
AUDIT_INCIDENT_IDS_MAX = 20


class AuditDecisionSummary(BaseModel):
    """Bounded, versioned, strict decision-summary contract for an audit row.

    Implements D-17 (versioned, strict, ``extra="forbid"``), D-18 (exactly
    the required decision-summary fields), and D-19 (excludes
    high-cardinality and rule-engine-internal dicts such as
    ``counted_fingerprints``, ``enrichment_diagnostics``, and full
    ``rule_decision``/``threshold_decision`` payloads).
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    decision_kind: Literal["problem", "recovery", "noop"]
    incident_effect: Literal[
        "none", "inserted", "updated", "resolved", "affected_set_shrunk"
    ]
    rule_name: BoundedString | None = None
    group_key: BoundedString | None = None
    incident_ids: BoundedStringTuple = ()
    affected_incident_count: int = Field(default=0, ge=0)
    incident_ids_truncated: bool = False
    decision_reason: BoundedString | None = None
    no_dispatch_reason: BoundedNoDispatchReason | None = None
    notification_intent: Literal["dispatch_planned", "no_dispatch"]
    counted_count: int | None = Field(default=None, ge=0)
    threshold_count: int | None = Field(default=None, ge=1)
    threshold_crossed: bool | None = None
    replay: bool | None = None
    first_threshold_transition: bool | None = None
    recovery_resolution: Literal["noop", "affected_set_shrunk", "resolved"] | None = (
        None
    )
    affected_object_removed: bool | None = None


class AuditEventListFilters(BaseModel):
    """Filter DTO for ``GET /v1/incident-events`` listing.

    Implements D-11 (filter set) and D-12 (``has_incident=False`` maps to
    ``incident_effect == "none"`` in the repository, not here). All
    accepted/event timestamp range fields are validated as timezone-aware
    when present, mirroring ``IncidentListFilters``.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    incident_id: UUID | None = None
    has_incident: bool | None = None
    fingerprint: BoundedString | None = None
    source_id: BoundedString | None = None
    event_type: EventType | None = None
    incident_effect: (
        Literal["none", "inserted", "updated", "resolved", "affected_set_shrunk"] | None
    ) = None
    no_dispatch_reason: BoundedNoDispatchReason | None = None
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
        "accepted_since",
        "accepted_until",
        "event_timestamp_since",
        "event_timestamp_until",
        mode="after",
    )
    @classmethod
    def require_timezone(cls, value: datetime | None) -> datetime | None:
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("timestamp must be timezone-aware")
        return value


class AuditEventResponse(BaseModel):
    """Bounded read response for a single audit event.

    Implements D-08/D-15: no ``raw_payload`` field and no full
    ``normalized_event`` field. Only a bounded ``normalized_event_message``
    (capped at 512 chars) and ``normalized_event_tags`` (typed through the
    existing ``TagKey``/``TagValue`` constraints) are projected. Raw-payload
    metadata (lengths, truncation flag, redaction version, redacted path
    count, HMAC) is included for traceability without exposing the body.
    """

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
    incident_effect: Literal[
        "none", "inserted", "updated", "resolved", "affected_set_shrunk"
    ]
    decision_summary: AuditDecisionSummary
    normalized_event_message: BoundedResponseMessage
    normalized_event_tags: dict[TagKey, TagValue]
    raw_payload_original_byte_length: int | None
    raw_payload_stored_byte_length: int | None
    raw_payload_truncated: bool
    redaction_version: int | None
    redacted_path_count: int | None
    raw_payload_hmac: str | None


class AuditEventListResponse(BaseModel):
    """Bounded list response for ``GET /v1/incident-events``."""

    model_config = ConfigDict(strict=True, extra="forbid")

    items: tuple[AuditEventResponse, ...] = Field(max_length=200)
    total: int = Field(default=0, ge=0)
    limit: int = Field(default=50, ge=1, le=200)
    offset: int = Field(default=0, ge=0)
    next_cursor: str | None = None
