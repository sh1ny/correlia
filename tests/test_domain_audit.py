"""Pydantic contract coverage for audit domain models (Phase 7)."""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.domain.audit import (
    AUDIT_INCIDENT_IDS_MAX,
    AuditDecisionSummary,
    AuditEventListFilters,
    AuditEventListResponse,
    AuditEventResponse,
)
from app.domain.events import EventType, Severity


def _valid_decision_summary_kwargs() -> dict[str, object]:
    return {
        "decision_kind": "problem",
        "incident_effect": "inserted",
        "notification_intent": "dispatch_planned",
    }


def test_audit_decision_summary_accepts_required_fields_and_defaults_schema_version() -> (
    None
):
    summary = AuditDecisionSummary.model_validate(_valid_decision_summary_kwargs())
    assert summary.schema_version == 1
    assert summary.decision_kind == "problem"
    assert summary.incident_effect == "inserted"
    assert summary.incident_ids == ()
    assert summary.affected_incident_count == 0
    assert summary.incident_ids_truncated is False
    assert summary.notification_intent == "dispatch_planned"
    assert summary.recovery_resolution is None
    assert summary.affected_object_removed is None


def test_audit_decision_summary_rejects_extra_fields() -> None:
    data = _valid_decision_summary_kwargs()
    data["counted_fingerprints"] = ["fp-1"]  # D-19 excluded
    with pytest.raises(ValidationError):
        AuditDecisionSummary.model_validate(data)


def test_audit_decision_summary_rejects_invalid_literals() -> None:
    bad: list[tuple[str, object]] = [
        ("decision_kind", "resolved"),
        ("incident_effect", "deleted"),
        ("notification_intent", "submitted"),
        ("recovery_resolution", "escalated"),
    ]
    for field, value in bad:
        data = _valid_decision_summary_kwargs()
        data[field] = value
        with pytest.raises(ValidationError):
            AuditDecisionSummary.model_validate(data)


def test_audit_decision_summary_bounds_incident_ids_and_strings() -> None:
    too_many = [f"incident-{i}" for i in range(AUDIT_INCIDENT_IDS_MAX + 1)]
    with pytest.raises(ValidationError):
        AuditDecisionSummary.model_validate(
            {**_valid_decision_summary_kwargs(), "incident_ids": too_many}
        )
    overlong_reason = "x" * 257
    with pytest.raises(ValidationError):
        AuditDecisionSummary.model_validate(
            {**_valid_decision_summary_kwargs(), "decision_reason": overlong_reason}
        )
    overlong_no_dispatch = "y" * 129
    with pytest.raises(ValidationError):
        AuditDecisionSummary.model_validate(
            {
                **_valid_decision_summary_kwargs(),
                "no_dispatch_reason": overlong_no_dispatch,
            }
        )


def test_audit_event_filters_require_timezone_aware_ranges() -> None:
    naive = datetime(2026, 1, 1, 0, 0, 0)
    aware = datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)
    for field in (
        "accepted_since",
        "accepted_until",
        "event_timestamp_since",
        "event_timestamp_until",
    ):
        with pytest.raises(ValidationError):
            AuditEventListFilters.model_validate({field: naive})
    filters = AuditEventListFilters.model_validate(
        {
            "accepted_since": aware,
            "accepted_until": aware,
            "event_timestamp_since": aware,
            "event_timestamp_until": aware,
        }
    )
    assert filters.accepted_since == aware


def _valid_response_kwargs() -> dict[str, object]:
    aware = datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)
    return {
        "id": uuid4(),
        "accepted_at": aware,
        "event_timestamp": aware,
        "source_id": "src-1",
        "event_type": EventType.PROBLEM,
        "severity": Severity.CRITICAL,
        "fingerprint": "fp-1",
        "host": "host-1",
        "service": None,
        "incident_ids": (),
        "incident_effect": "none",
        "decision_summary": _valid_decision_summary_kwargs(),
        "normalized_event_message": "",
        "normalized_event_tags": {},
        "normalized_event_tags_omitted": False,
        "normalized_event_tags_omission_reasons": frozenset(),
        "raw_payload_original_byte_length": 0,
        "raw_payload_stored_byte_length": 0,
        "raw_payload_truncated": False,
        "redaction_version": 1,
        "redacted_path_count": 0,
        "raw_payload_hmac": "a" * 64,
    }


def test_audit_event_response_excludes_raw_payload_and_full_normalized_event() -> None:
    valid_kwargs = _valid_response_kwargs()
    response = AuditEventResponse.model_validate(valid_kwargs)
    payload = response.model_dump(mode="json")
    assert "raw_payload" not in payload
    assert "normalized_event" not in payload
    assert payload["normalized_event_tags_omitted"] is False
    assert payload["normalized_event_tags_omission_reasons"] == []

    for forbidden in ("raw_payload", "normalized_event"):
        bad = dict(valid_kwargs)
        bad[forbidden] = {"secret": "leak"}
        with pytest.raises(ValidationError):
            AuditEventResponse.model_validate(bad)


def test_audit_response_rejects_invalid_hmac_tags_and_omission_reasons() -> None:
    valid = _valid_response_kwargs()
    for digest in ("a" * 63, "A" * 64, "z" * 64):
        with pytest.raises(ValidationError):
            AuditEventResponse.model_validate({**valid, "raw_payload_hmac": digest})
    for tags in (
        {"bad": "v" * 257},
        {"Bad": "ok"},
        {"a" * 65: "ok"},
        {f"k{i:02}": "v" for i in range(33)},
        {f"k{i:02}": "v" * 128 for i in range(32)},
    ):
        with pytest.raises(ValidationError):
            AuditEventResponse.model_validate({**valid, "normalized_event_tags": tags})
    with pytest.raises(ValidationError):
        AuditEventResponse.model_validate(
            {**valid, "normalized_event_tags_omission_reasons": frozenset({"unknown"})}
        )
    with pytest.raises(ValidationError):
        AuditEventResponse.model_validate(
            {**valid, "normalized_event_tags_omitted": True}
        )
    with pytest.raises(ValidationError):
        AuditEventResponse.model_validate(
            {
                **valid,
                "normalized_event_tags_omission_reasons": frozenset({"size_limit"}),
            }
        )

    complete = AuditEventResponse.model_validate(
        {**valid, "normalized_event_tags": {"safe": "ok"}}
    )
    assert complete.normalized_event_tags == {"safe": "ok"}


def test_audit_event_list_response_rejects_more_than_200_rows() -> None:
    row = AuditEventResponse.model_validate(_valid_response_kwargs())
    assert len(AuditEventListResponse(items=(row,) * 200).items) == 200
    with pytest.raises(ValidationError):
        AuditEventListResponse(items=(row,) * 201)
