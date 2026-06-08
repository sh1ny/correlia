from datetime import UTC, datetime
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.domain.incidents import (
    Acknowledgement,
    DecisionContext,
    IncidentStatus,
    is_terminal_status,
    validate_incident_transition,
)


def test_incident_status_values_are_lifecycle_only() -> None:
    assert [status.value for status in IncidentStatus] == ["OPEN", "RESOLVED", "CLOSED"]
    assert "ACKNOWLEDGED" not in {status.value for status in IncidentStatus}
    assert "ACKNOWLEDGED" not in Path("app/domain/incidents.py").read_text()


def test_acknowledgement_is_metadata_on_open_incident() -> None:
    status = IncidentStatus.OPEN
    acknowledgement = Acknowledgement.model_validate(
        {"acknowledged_at": datetime(2026, 6, 8, 12, 0, tzinfo=UTC), "acknowledged_by": "operator"}
    )

    assert status is IncidentStatus.OPEN
    assert acknowledgement.acknowledged_by == "operator"


def test_acknowledgement_rejects_naive_timestamp() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Acknowledgement.model_validate(
            {"acknowledged_at": datetime(2026, 6, 8, 12, 0), "acknowledged_by": "operator"}
        )

    assert "timezone-aware" in str(exc_info.value)


@pytest.mark.parametrize(
    ("current", "target"),
    [
        (IncidentStatus.OPEN, IncidentStatus.RESOLVED),
        (IncidentStatus.OPEN, IncidentStatus.CLOSED),
    ],
)
def test_allowed_incident_transitions(current: IncidentStatus, target: IncidentStatus) -> None:
    assert validate_incident_transition(current, target) is target


@pytest.mark.parametrize(
    ("current", "target"),
    [
        (IncidentStatus.RESOLVED, IncidentStatus.OPEN),
        (IncidentStatus.CLOSED, IncidentStatus.OPEN),
        (IncidentStatus.RESOLVED, IncidentStatus.CLOSED),
        (IncidentStatus.CLOSED, IncidentStatus.RESOLVED),
    ],
)
def test_terminal_incident_transitions_are_forbidden(current: IncidentStatus, target: IncidentStatus) -> None:
    assert is_terminal_status(current)

    with pytest.raises(ValueError, match="cannot transition"):
        validate_incident_transition(current, target)


def test_open_is_not_terminal() -> None:
    assert not is_terminal_status(IncidentStatus.OPEN)
    assert is_terminal_status(IncidentStatus.RESOLVED)
    assert is_terminal_status(IncidentStatus.CLOSED)


def test_decision_context_accepts_compact_allowed_facts() -> None:
    context = DecisionContext.model_validate(
        {
            "schema_version": 1,
            "fingerprint": "fp",
            "source_id": "icinga",
            "rule_name": "rule",
            "group_key": "group",
            "matched_rule_names": ("rule",),
            "enrichment_refs": ("topology:host:web-01",),
            "event_count": 1,
            "config_hash": "sha256:abc",
            "notes": {"decision.reason": "threshold-crossed"},
        }
    )

    assert context.schema_version == 1
    assert context.fingerprint == "fp"
    assert context.matched_rule_names == ("rule",)
    assert context.notes == {"decision.reason": "threshold-crossed"}


@pytest.mark.parametrize(
    "forbidden_key",
    [
        "raw_payload",
        "credentials",
        "password",
        "token",
        "secret",
        "plugin_config",
        "unknown_extra",
    ],
)
def test_decision_context_rejects_forbidden_or_unknown_top_level_keys(forbidden_key: str) -> None:
    data = {
        "schema_version": 1,
        "fingerprint": "fp",
        "source_id": "icinga",
        "rule_name": "rule",
        "group_key": "group",
        "event_count": 1,
        forbidden_key: "rejected",
    }

    with pytest.raises(ValidationError):
        DecisionContext.model_validate(data)


@pytest.mark.parametrize(
    "notes",
    [
        {"raw_payload": "source body"},
        {"payload.ref": "source body"},
        {"credential.ref": "operator"},
        {"safe.key": "contains password value"},
        {"safe.key": "contains TOKEN value"},
        {"safe.key": "contains secret value"},
        {"plugin_config": "smtp"},
        {"safe.key": "x" * 257},
        {"Team Name": "platform"},
    ],
)
def test_decision_context_notes_are_bounded_and_secret_safe(notes: dict[str, str]) -> None:
    with pytest.raises(ValidationError):
        DecisionContext.model_validate({"schema_version": 1, "notes": notes})


def test_decision_context_rejects_too_many_tuple_entries() -> None:
    with pytest.raises(ValidationError):
        DecisionContext.model_validate(
            {"schema_version": 1, "matched_rule_names": tuple(f"rule-{index}" for index in range(21))}
        )
