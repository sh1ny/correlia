
import pytest
from pydantic import ValidationError

from app.domain.events import EventType, Severity


# These imports will fail until Task 2 creates the modules
from app.plugins.inputs.icinga2 import (
    Icinga2InputPlugin,
    Icinga2Rejection,
    Icinga2WebhookPayload,
    fingerprint_icinga_event,
    map_icinga_state,
)


def valid_host_payload() -> dict[str, object]:
    return {
        "source_id": "icinga2:host:web-01",
        "host": "web-01",
        "service": None,
        "state": "DOWN",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "Host is unreachable",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform"},
    }


def valid_service_payload() -> dict[str, object]:
    return {
        "source_id": "icinga2:service:web-01:http",
        "host": "web-01",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "HTTP 503",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform"},
    }


# D-02: Host UP maps to RECOVERY/OK
# D-03: Host DOWN/UNREACHABLE maps to PROBLEM with corresponding severity


@pytest.mark.parametrize(
    ("state", "is_host", "expected_severity", "expected_event_type"),
    [
        ("UP", True, Severity.OK, EventType.RECOVERY),
        ("DOWN", True, Severity.CRITICAL, EventType.PROBLEM),
        ("UNREACHABLE", True, Severity.UNKNOWN, EventType.PROBLEM),
        ("OK", False, Severity.OK, EventType.RECOVERY),
        ("WARNING", False, Severity.WARNING, EventType.PROBLEM),
        ("CRITICAL", False, Severity.CRITICAL, EventType.PROBLEM),
        ("UNKNOWN", False, Severity.UNKNOWN, EventType.PROBLEM),
    ],
)
def test_map_icinga_state_produces_expected_severity_and_event_type(
    state: str,
    is_host: bool,
    expected_severity: Severity,
    expected_event_type: EventType,
) -> None:
    severity, event_type = map_icinga_state(state, is_host)
    assert severity is expected_severity
    assert event_type is expected_event_type


def test_map_icinga_state_rejects_unknown_state() -> None:
    with pytest.raises(ValueError, match="Unknown Icinga2 state"):
        map_icinga_state("PENDING", True)


# ING-02: strict payload validation


def test_host_hard_down_payload_validates() -> None:
    payload = Icinga2WebhookPayload.model_validate(valid_host_payload())
    assert payload.host == "web-01"
    assert payload.state == "DOWN"
    assert payload.state_type == "HARD"


def test_service_hard_critical_payload_validates() -> None:
    payload = Icinga2WebhookPayload.model_validate(valid_service_payload())
    assert payload.host == "web-01"
    assert payload.service == "http"
    assert payload.state == "CRITICAL"


def test_extra_fields_are_rejected() -> None:
    data = valid_service_payload()
    data["extra_field"] = "surprise"
    with pytest.raises(ValidationError):
        Icinga2WebhookPayload.model_validate(data)


def test_naive_timestamp_is_rejected() -> None:
    data = valid_service_payload()
    data["timestamp"] = "2026-06-08T12:00:00"
    with pytest.raises(ValidationError, match="timezone-aware"):
        Icinga2WebhookPayload.model_validate(data)


def test_host_payload_with_service_state_is_rejected() -> None:
    """Host objects must use host states (UP/DOWN/UNREACHABLE), not service states."""
    data = valid_host_payload()
    data["state"] = "OK"
    with pytest.raises(ValidationError):
        Icinga2WebhookPayload.model_validate(data)


def test_service_payload_with_host_state_is_rejected() -> None:
    """Service objects must use service states (OK/WARNING/CRITICAL/UNKNOWN), not host states."""
    data = valid_service_payload()
    data["state"] = "UP"
    with pytest.raises(ValidationError):
        Icinga2WebhookPayload.model_validate(data)


# D-01: SOFT states are non-actionable diagnostics

async def test_soft_state_returns_rejection() -> None:
    plugin = Icinga2InputPlugin()
    data = valid_service_payload()
    data["state_type"] = "SOFT"
    payload = Icinga2WebhookPayload.model_validate(data)
    result = await plugin.process_payload(payload)
    assert isinstance(result, Icinga2Rejection)
    assert result.state_accepted is False
    assert result.state_type == "SOFT"
    assert result.host == "web-01"
def test_fingerprint_is_stable_for_replay() -> None:
    fp1 = fingerprint_icinga_event(
        source_id="icinga2:service:web-01:http",
        host="web-01",
        service="http",
        event_type=EventType.PROBLEM,
        severity=Severity.CRITICAL,
    )
    fp2 = fingerprint_icinga_event(
        source_id="icinga2:service:web-01:http",
        host="web-01",
        service="http",
        event_type=EventType.PROBLEM,
        severity=Severity.CRITICAL,
    )
    assert fp1 == fp2
    assert len(fp1) == 32  # truncated hex


def test_fingerprint_excludes_timestamp_and_check_output() -> None:
    base = {
        "source_id": "icinga2:service:web-01:http",
        "host": "web-01",
        "service": "http",
        "event_type": EventType.PROBLEM,
        "severity": Severity.CRITICAL,
    }
    fp1 = fingerprint_icinga_event(**base)
    # These are not part of the fingerprint per D-05
    assert fp1 == fingerprint_icinga_event(**base)


def test_fingerprint_changes_when_severity_changes() -> None:
    fp_warning = fingerprint_icinga_event(
        source_id="icinga2:service:web-01:http",
        host="web-01",
        service="http",
        event_type=EventType.PROBLEM,
        severity=Severity.WARNING,
    )
    fp_critical = fingerprint_icinga_event(
        source_id="icinga2:service:web-01:http",
        host="web-01",
        service="http",
        event_type=EventType.PROBLEM,
        severity=Severity.CRITICAL,
    )
    assert fp_warning != fp_critical


def test_fingerprint_changes_when_event_type_changes() -> None:
    fp_problem = fingerprint_icinga_event(
        source_id="icinga2:service:web-01:http",
        host="web-01",
        service="http",
        event_type=EventType.PROBLEM,
        severity=Severity.CRITICAL,
    )
    fp_recovery = fingerprint_icinga_event(
        source_id="icinga2:service:web-01:http",
        host="web-01",
        service="http",
        event_type=EventType.RECOVERY,
        severity=Severity.OK,
    )
    assert fp_problem != fp_recovery


# ING-01: plugin produces NormalizedEvent for HARD states

async def test_plugin_produces_normalized_event_for_hard_problem() -> None:
    plugin = Icinga2InputPlugin()
    payload = Icinga2WebhookPayload.model_validate(valid_service_payload())
    result = await plugin.process_payload(payload)
    assert hasattr(result, "fingerprint")
    assert result.source_id == "icinga2:service:web-01:http"
    assert result.host == "web-01"
    assert result.service == "http"
    assert result.severity is Severity.CRITICAL
    assert result.event_type is EventType.PROBLEM

async def test_plugin_produces_normalized_event_for_hard_recovery() -> None:
    plugin = Icinga2InputPlugin()
    data = valid_host_payload()
    data["state"] = "UP"
    payload = Icinga2WebhookPayload.model_validate(data)
    result = await plugin.process_payload(payload)
    assert result.severity is Severity.OK
    assert result.event_type is EventType.RECOVERY

async def test_plugin_message_uses_check_output() -> None:
    plugin = Icinga2InputPlugin()
    payload = Icinga2WebhookPayload.model_validate(valid_service_payload())
    result = await plugin.process_payload(payload)
    assert result.message == "HTTP 503"