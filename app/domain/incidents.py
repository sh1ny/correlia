from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.domain.events import Severity, TagKey, TagValue


class IncidentStatus(StrEnum):
    OPEN = "OPEN"
    RESOLVED = "RESOLVED"
    CLOSED = "CLOSED"


BoundedString = Annotated[str, Field(min_length=1, max_length=256)]
BoundedStringTuple = Annotated[tuple[BoundedString, ...], Field(max_length=20)]
ServicePairTuple = Annotated[tuple[BoundedString, ...], Field(max_length=100)]
WindowTimestampMap = Annotated[dict[BoundedString, datetime], Field(max_length=100)]


_FORBIDDEN_NOTE_FRAGMENTS = (
    "raw_payload",
    "payload",
    "credential",
    "password",
    "token",
    "secret",
    "plugin_config",
)


class Acknowledgement(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    acknowledged_at: datetime | None = None
    acknowledged_by: Annotated[str, Field(min_length=1, max_length=128)] | None = None

    @field_validator("acknowledged_at", mode="after")
    @classmethod
    def require_timezone(cls, value: datetime | None) -> datetime | None:
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("acknowledged_at must be timezone-aware")
        return value


class DecisionContext(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    fingerprint: BoundedString | None = None
    source_id: BoundedString | None = None
    rule_name: BoundedString | None = None
    group_key: BoundedString | None = None
    matched_rule_names: BoundedStringTuple = ()
    enrichment_refs: BoundedStringTuple = ()
    event_count: int | None = Field(default=None, ge=0)
    config_hash: str | None = Field(default=None, max_length=128)
    notes: dict[TagKey, TagValue] = Field(default_factory=dict, max_length=20)
    threshold_count: int | None = Field(default=None, ge=1)
    counted_count: int | None = Field(default=None, ge=0)
    threshold_crossed: bool | None = None
    first_threshold_transition: bool | None = None
    replay: bool | None = None
    action_names: BoundedStringTuple = ()


    @field_validator("notes", mode="after")
    @classmethod
    def reject_secret_note_content(cls, value: dict[str, str]) -> dict[str, str]:
        for note_key, note_value in value.items():
            key = note_key.lower()
            text = note_value.lower()
            for fragment in _FORBIDDEN_NOTE_FRAGMENTS:
                if fragment in key or fragment in text:
                    raise ValueError("decision context notes must not contain raw payloads or secrets")
        return value


def reject_operator_action_text(value: str) -> str:
    DecisionContext.reject_secret_note_content({"operator_action": value})
    return value


class LifecycleOutcome(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    effect: Literal[
        "affected_set_shrunk",
        "resolved",
        "noop",
        "closed",
        "acknowledged",
        "expired",
    ]
    reason: BoundedString
    previous_host_count: int = Field(ge=0)
    previous_service_count: int = Field(ge=0)
    affected_object_removed: bool = False
    notes: dict[TagKey, TagValue] = Field(default_factory=dict, max_length=20)

    @field_validator("notes", mode="after")
    @classmethod
    def reject_secret_note_content(cls, value: dict[str, str]) -> dict[str, str]:
        return DecisionContext.reject_secret_note_content(value)

    @model_validator(mode="after")
    def include_reason_note(self) -> LifecycleOutcome:
        if "lifecycle.reason" not in self.notes:
            self.notes["lifecycle.reason"] = self.reason
        return self

class IncidentWindowState(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    window_started_at: datetime
    window_ended_at: datetime
    window_seconds: int = Field(ge=1)
    threshold_count: int = Field(ge=1)
    counted_fingerprint_timestamps: WindowTimestampMap = Field(default_factory=dict)
    counted_count: int = Field(ge=0)
    max_size: int = Field(ge=1, le=100)
    active_service_pairs: ServicePairTuple = ()

    @field_validator("window_started_at", "window_ended_at", mode="after")
    @classmethod
    def require_window_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("window timestamps must be timezone-aware")
        return value

    @field_validator("counted_fingerprint_timestamps", mode="after")
    @classmethod
    def require_counted_timestamp_timezones(
        cls, value: dict[str, datetime]
    ) -> dict[str, datetime]:
        for timestamp in value.values():
            if timestamp.tzinfo is None or timestamp.utcoffset() is None:
                raise ValueError("counted fingerprint timestamps must be timezone-aware")
        return value


class IncidentListFilters(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    status: IncidentStatus | None = None
    severity: Severity | None = None
    rule_name: BoundedString | None = None
    host: BoundedString | None = None
    service: BoundedString | None = None
    updated_since: datetime | None = None
    limit: int = Field(default=50, ge=1, le=200)
    cursor: Annotated[str, Field(min_length=1, max_length=512)] | None = None

    @field_validator("updated_since", mode="after")
    @classmethod
    def require_updated_since_timezone(cls, value: datetime | None) -> datetime | None:
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("updated_since must be timezone-aware")
        return value


class IncidentDetailResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    id: UUID
    rule_name: BoundedString
    group_key: BoundedString
    status: IncidentStatus
    severity: Severity
    summary: BoundedString
    event_count: int = Field(ge=0)
    affected_hosts: tuple[BoundedString, ...] = Field(max_length=100)
    affected_services: tuple[BoundedString, ...] = Field(max_length=100)
    acknowledgement: Acknowledgement
    decision_context: DecisionContext
    threshold_crossed: bool
    notified_at: datetime | None = None
    start_time: datetime
    last_update_time: datetime
    resolved_at: datetime | None = None
    closed_at: datetime | None = None
    created_at: datetime
    updated_at: datetime


class IncidentListResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    items: tuple[IncidentDetailResponse, ...] = Field(max_length=200)
    next_cursor: str | None = None


class IncidentAckRequest(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", hide_input_in_errors=True)

    operator: Annotated[str, Field(min_length=1, max_length=128)]

    @field_validator("operator", mode="after")
    @classmethod
    def reject_secret_text(cls, value: str) -> str:
        return reject_operator_action_text(value)


class IncidentCloseRequest(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", hide_input_in_errors=True)

    operator: Annotated[str, Field(min_length=1, max_length=128)]
    reason: Annotated[str, Field(min_length=1, max_length=256)]

    @field_validator("operator", "reason", mode="after")
    @classmethod
    def reject_secret_text(cls, value: str) -> str:
        return reject_operator_action_text(value)


def is_terminal_status(status: IncidentStatus) -> bool:
    return status in {IncidentStatus.RESOLVED, IncidentStatus.CLOSED}


def validate_incident_transition(current: IncidentStatus, target: IncidentStatus) -> IncidentStatus:
    if current is IncidentStatus.OPEN and target in {IncidentStatus.RESOLVED, IncidentStatus.CLOSED}:
        return target
    raise ValueError(f"cannot transition incident from {current.value} to {target.value}")
