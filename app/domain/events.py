from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, field_validator


class EventType(StrEnum):
    PROBLEM = "PROBLEM"
    RECOVERY = "RECOVERY"


class Severity(StrEnum):
    OK = "OK"
    WARNING = "WARNING"
    UNKNOWN = "UNKNOWN"
    CRITICAL = "CRITICAL"


SEVERITY_RANK: dict[Severity, int] = {
    Severity.OK: 0,
    Severity.WARNING: 1,
    Severity.UNKNOWN: 2,
    Severity.CRITICAL: 3,
}

TagKey = Annotated[str, Field(min_length=1, pattern=r"^[a-z][a-z0-9_.-]*$")]
TagValue = Annotated[str, Field(min_length=1, max_length=256)]


def max_severity(left: Severity, right: Severity) -> Severity:
    if SEVERITY_RANK[left] >= SEVERITY_RANK[right]:
        return left
    return right


class NormalizedEvent(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    fingerprint: Annotated[str, Field(min_length=1)]
    source_id: Annotated[str, Field(min_length=1)]
    host: Annotated[str, Field(min_length=1)]
    service: Annotated[str, Field(min_length=1)] | None = None
    severity: Severity
    event_type: EventType
    timestamp: datetime
    tags: dict[TagKey, TagValue]
    message: Annotated[str, Field(min_length=1, max_length=4096)]
    ip_address: Annotated[str, Field(min_length=1)] | None = None

    @field_validator("timestamp", mode="after")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("timestamp must be timezone-aware")
        return value
