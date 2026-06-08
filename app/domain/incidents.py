from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.domain.events import TagKey, TagValue


class IncidentStatus(StrEnum):
    OPEN = "OPEN"
    RESOLVED = "RESOLVED"
    CLOSED = "CLOSED"


BoundedString = Annotated[str, Field(min_length=1, max_length=256)]
BoundedStringTuple = Annotated[tuple[BoundedString, ...], Field(max_length=20)]

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


def is_terminal_status(status: IncidentStatus) -> bool:
    return status in {IncidentStatus.RESOLVED, IncidentStatus.CLOSED}


def validate_incident_transition(current: IncidentStatus, target: IncidentStatus) -> IncidentStatus:
    if current is IncidentStatus.OPEN and target in {IncidentStatus.RESOLVED, IncidentStatus.CLOSED}:
        return target
    raise ValueError(f"cannot transition incident from {current.value} to {target.value}")
