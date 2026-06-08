from datetime import UTC, datetime

import pytest
from pydantic import ValidationError

from app.domain.events import EventType, NormalizedEvent, Severity, SEVERITY_RANK, max_severity


def valid_event_data() -> dict[str, object]:
    return {
        "fingerprint": "icinga:web-01:http",
        "source_id": "icinga2",
        "host": "web-01",
        "service": "http",
        "severity": Severity.WARNING,
        "event_type": EventType.PROBLEM,
        "timestamp": datetime(2026, 6, 8, 12, 0, tzinfo=UTC),
        "tags": {"team.name": "platform", "site-1": "iad"},
        "message": "HTTP check is warning",
        "ip_address": "192.0.2.10",
    }


def test_event_type_and_severity_contracts_are_explicit() -> None:
    assert set(EventType) == {EventType.PROBLEM, EventType.RECOVERY}
    assert set(Severity) == {Severity.OK, Severity.WARNING, Severity.UNKNOWN, Severity.CRITICAL}
    assert SEVERITY_RANK == {
        Severity.OK: 0,
        Severity.WARNING: 1,
        Severity.UNKNOWN: 2,
        Severity.CRITICAL: 3,
    }
    assert max_severity(Severity.WARNING, Severity.CRITICAL) is Severity.CRITICAL
    assert max_severity(Severity.UNKNOWN, Severity.WARNING) is Severity.UNKNOWN


def test_complete_normalized_event_validates_with_timezone_and_tags() -> None:
    event = NormalizedEvent.model_validate(valid_event_data())

    assert event.fingerprint == "icinga:web-01:http"
    assert event.source_id == "icinga2"
    assert event.tags == {"team.name": "platform", "site-1": "iad"}
    assert event.timestamp.tzinfo is not None


@pytest.mark.parametrize(
    "field",
    [
        "fingerprint",
        "source_id",
        "host",
        "severity",
        "event_type",
        "timestamp",
        "tags",
        "message",
    ],
)
def test_required_fields_are_rejected_when_missing(field: str) -> None:
    data = valid_event_data()
    data.pop(field)

    with pytest.raises(ValidationError):
        NormalizedEvent.model_validate(data)


def test_extra_fields_are_forbidden() -> None:
    data = valid_event_data()
    data["raw_payload"] = {"secret": "do-not-store"}

    with pytest.raises(ValidationError):
        NormalizedEvent.model_validate(data)


def test_enum_like_strings_are_not_coerced() -> None:
    data = valid_event_data()
    data["severity"] = "WARNING"
    data["event_type"] = "PROBLEM"

    with pytest.raises(ValidationError):
        NormalizedEvent.model_validate(data)


def test_naive_timestamps_are_rejected_with_explicit_error() -> None:
    data = valid_event_data()
    data["timestamp"] = datetime(2026, 6, 8, 12, 0)

    with pytest.raises(ValidationError) as exc_info:
        NormalizedEvent.model_validate(data)

    assert "timezone-aware" in str(exc_info.value)


@pytest.mark.parametrize(
    "tags",
    [
        {"Team Name": "platform"},
        {"": "platform"},
        {"team": ""},
        ["x"],
    ],
)
def test_tags_must_be_normalized_non_empty_string_map(tags: object) -> None:
    data = valid_event_data()
    data["tags"] = tags

    with pytest.raises(ValidationError):
        NormalizedEvent.model_validate(data)
