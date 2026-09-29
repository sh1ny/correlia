from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime
from enum import StrEnum
import json
import re
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

# These limits apply to accepted events, not to incident notes or rule matches.
EVENT_TAG_MAX_KEY_BYTES = 64
EVENT_TAG_MAX_ENTRIES = 128
EVENT_TAG_MAX_BYTES = 16_384
EVENT_TAG_ERROR_MESSAGE = "invalid event tags"
EventTagKey = Annotated[
    str,
    Field(
        min_length=1,
        max_length=EVENT_TAG_MAX_KEY_BYTES,
        pattern=r"^[a-z][a-z0-9_.-]*$",
    ),
]
EventTags = dict[EventTagKey, TagValue]
_EVENT_TAG_KEY_PATTERN = re.compile(r"[a-z][a-z0-9_.-]*", re.ASCII)


class EventTagValidationError(ValueError):
    """An event tag map cannot be accepted; never include input in the message."""

    def __init__(self) -> None:
        super().__init__(EVENT_TAG_ERROR_MESSAGE)


def validate_event_tags(tags: Mapping[str, str]) -> None:
    """Validate an accepted event map without copying or changing its entries.

    JSON accounting uses sorted keys, compact separators and UTF-8, exactly
    as the canonical stored representation does. Stop once the cap is exceeded.
    """
    if not isinstance(tags, Mapping) or len(tags) > EVENT_TAG_MAX_ENTRIES:
        raise EventTagValidationError()

    try:
        keys = sorted(tags)
    except TypeError as exc:
        raise EventTagValidationError() from exc

    encoded_bytes = 2  # Braces, including for the empty map.
    for index, key in enumerate(keys):
        if (
            not isinstance(key, str)
            or not _EVENT_TAG_KEY_PATTERN.fullmatch(key)
            or len(key) > EVENT_TAG_MAX_KEY_BYTES
        ):
            raise EventTagValidationError()
        value = tags[key]
        if not isinstance(value, str) or not 1 <= len(value) <= 256 or "\x00" in value:
            raise EventTagValidationError()
        try:
            encoded_bytes += (
                len(json.dumps(key, ensure_ascii=False).encode("utf-8"))
                + 1  # Colon
                + len(json.dumps(value, ensure_ascii=False).encode("utf-8"))
                + (index != 0)  # Comma
            )
        except UnicodeError as exc:
            raise EventTagValidationError() from exc
        if encoded_bytes > EVENT_TAG_MAX_BYTES:
            raise EventTagValidationError()


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
    tags: EventTags
    message: Annotated[str, Field(min_length=1, max_length=4096)]
    ip_address: Annotated[str, Field(min_length=1)] | None = None

    @field_validator("tags")
    @classmethod
    def require_valid_event_tags(cls, value: EventTags) -> EventTags:
        validate_event_tags(value)
        return value

    @field_validator("timestamp", mode="after")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("timestamp must be timezone-aware")
        return value
