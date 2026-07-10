from __future__ import annotations

import hashlib
from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.domain.events import EventType, NormalizedEvent, Severity, TagKey, TagValue


_ICINGA_HOST_STATES = {
    "UP": (Severity.OK, EventType.RECOVERY),
    "DOWN": (Severity.CRITICAL, EventType.PROBLEM),
    "UNREACHABLE": (Severity.UNKNOWN, EventType.PROBLEM),
}

_ICINGA_SERVICE_STATES = {
    "OK": (Severity.OK, EventType.RECOVERY),
    "WARNING": (Severity.WARNING, EventType.PROBLEM),
    "CRITICAL": (Severity.CRITICAL, EventType.PROBLEM),
    "UNKNOWN": (Severity.UNKNOWN, EventType.PROBLEM),
}


class Icinga2WebhookPayload(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    source_id: Annotated[str, Field(min_length=1, max_length=256)]
    host: Annotated[str, Field(min_length=1, max_length=256)]
    service: Annotated[str, Field(min_length=1, max_length=256)] | None = None
    state: str
    state_type: Literal["HARD", "SOFT"]
    timestamp: datetime
    check_output: Annotated[str, Field(min_length=1)]
    ip_address: Annotated[str, Field(min_length=1)] | None = None
    tags: dict[TagKey, TagValue] = Field(default_factory=dict)

    @field_validator("timestamp", mode="before")
    @classmethod
    def parse_timestamp(cls, value: object) -> datetime:
        if isinstance(value, datetime):
            return value
        if isinstance(value, str):
            # Pydantic v2 strict mode won't coerce strings; parse explicitly
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        raise ValueError("timestamp must be a string or datetime")

    @field_validator("timestamp", mode="after")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("timestamp must be timezone-aware")
        return value

    @model_validator(mode="after")
    def validate_state_against_object_type(self) -> "Icinga2WebhookPayload":
        is_host = self.service is None
        valid_states = set(_ICINGA_HOST_STATES if is_host else _ICINGA_SERVICE_STATES)
        if self.state not in valid_states:
            object_type = "host" if is_host else "service"
            raise ValueError(
                f"invalid state '{self.state}' for {object_type} object; "
                f"allowed: {', '.join(sorted(valid_states))}"
            )
        return self


class Icinga2Rejection(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    state_accepted: Literal[False] = False
    reason: Annotated[str, Field(min_length=1)]
    source_id: Annotated[str, Field(min_length=1)]
    host: Annotated[str, Field(min_length=1)]
    service: Annotated[str, Field(min_length=1)] | None = None
    state: str
    state_type: Literal["HARD", "SOFT"]


def map_icinga_state(state: str, is_host: bool) -> tuple[Severity, EventType]:
    mapping = _ICINGA_HOST_STATES if is_host else _ICINGA_SERVICE_STATES
    if state not in mapping:
        raise ValueError(f"Unknown Icinga2 state: {state}")
    return mapping[state]


def fingerprint_icinga_event(
    source_id: str,
    host: str,
    service: str | None,
    event_type: EventType,
    severity: Severity,
) -> str:
    parts = [source_id, host, event_type.value, severity.value]
    if service is not None:
        parts.append(service)
    raw = "|".join(parts)
    return hashlib.sha256(raw.encode()).hexdigest()[:32]


class Icinga2InputPlugin:
    async def process_payload(
        self, payload: object
    ) -> NormalizedEvent | Icinga2Rejection:
        if not isinstance(payload, Icinga2WebhookPayload):
            payload = Icinga2WebhookPayload.model_validate(payload)
        if payload.state_type == "SOFT":
            return Icinga2Rejection(
                reason="SOFT state is non-actionable",
                source_id=payload.source_id,
                host=payload.host,
                service=payload.service,
                state=payload.state,
                state_type=payload.state_type,
            )

        is_host = payload.service is None
        severity, event_type = map_icinga_state(payload.state, is_host)
        fingerprint = fingerprint_icinga_event(
            source_id=payload.source_id,
            host=payload.host,
            service=payload.service,
            event_type=event_type,
            severity=severity,
        )

        event_data: dict[str, Any] = {
            "fingerprint": fingerprint,
            "source_id": payload.source_id,
            "host": payload.host,
            "service": payload.service,
            "severity": severity,
            "event_type": event_type,
            "timestamp": payload.timestamp,
            "tags": payload.tags,
            "message": payload.check_output,
            "ip_address": payload.ip_address,
        }

        return NormalizedEvent.model_validate(event_data)
