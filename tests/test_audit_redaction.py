"""Pure unit coverage for recursive redaction, semantic size capping, and pre-redaction HMAC."""

from __future__ import annotations

import hashlib
import hmac
import json

import pytest
from pydantic import SecretStr

from app.persistence.audit import (
    AUDIT_REDACTION_PLACEHOLDER,
    REDACTION_VERSION,
    AuditEventCursor,
    compute_payload_hmac,
    decode_audit_cursor,
    encode_audit_cursor,
    redact_normalized_event_message_tags,
    redact_payload,
)
from datetime import UTC, datetime
from uuid import uuid4


def test_redact_payload_redacts_sensitive_keys_and_string_values_recursively() -> None:
    payload = {
        "host": "db-1",
        "password": "supersecret",
        "nested": {
            "api_key": "sk-live-12345",
            "safe_field": "visible",
        },
        "items": [
            {"token": "tok-abc", "name": "ok"},
            {"name": "second"},
        ],
        "secret_in_value": "this contains a secret string",
    }
    result = redact_payload(payload, max_bytes=65_536, hmac_key="test-key")

    assert result.payload["host"] == "db-1"
    assert result.payload["password"] == AUDIT_REDACTION_PLACEHOLDER
    assert result.payload["nested"]["api_key"] == AUDIT_REDACTION_PLACEHOLDER
    assert result.payload["nested"]["safe_field"] == "visible"
    assert result.payload["items"][0]["token"] == AUDIT_REDACTION_PLACEHOLDER
    assert result.payload["items"][0]["name"] == "ok"
    assert result.payload["items"][1]["name"] == "second"
    assert result.payload["secret_in_value"] == AUDIT_REDACTION_PLACEHOLDER

    assert result.redaction_version == REDACTION_VERSION
    assert result.redacted_path_count >= 4
    assert result.truncated is False
    assert result.stored_byte_length <= result.original_byte_length


def test_redact_payload_hmac_uses_pre_redaction_canonical_payload() -> None:
    payload = {"password": "secret-value", "host": "h1"}
    result = redact_payload(payload, max_bytes=65_536, hmac_key="test-key")

    # HMAC must match canonical JSON of the PRE-redaction payload.
    canonical = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    expected_hmac = hmac.new(b"test-key", canonical, hashlib.sha256).hexdigest()
    assert result.payload_hmac == expected_hmac

    # HMAC changes when pre-redaction payload changes.
    payload2 = {"password": "different-secret", "host": "h1"}
    result2 = redact_payload(payload2, max_bytes=65_536, hmac_key="test-key")
    assert result2.payload_hmac != result.payload_hmac

    # HMAC stays stable when only redaction output would differ (same input).
    result_again = redact_payload(payload, max_bytes=65_536, hmac_key="test-key")
    assert result_again.payload_hmac == result.payload_hmac


def test_redact_payload_hmac_accepts_secret_str_key() -> None:
    payload = {"host": "h1"}
    raw_key = "secret-str-key"
    result_str = redact_payload(payload, max_bytes=65_536, hmac_key=raw_key)
    result_secret = redact_payload(
        payload, max_bytes=65_536, hmac_key=SecretStr(raw_key)
    )
    assert result_str.payload_hmac == result_secret.payload_hmac


def test_redact_payload_semantic_cap_preserves_json_and_sets_metadata() -> None:
    # Build a payload that exceeds a small cap.
    big_value = "x" * 500
    payload = {"host": "h1", "large_field": big_value, "nested": {"deep": big_value}}
    cap = 200
    result = redact_payload(payload, max_bytes=cap, hmac_key="test-key")

    assert result.truncated is True
    assert result.stored_byte_length <= cap
    assert result.stored_byte_length <= result.original_byte_length
    # Stored payload must be valid JSON (not byte-truncated).
    parsed = json.loads(json.dumps(result.payload, ensure_ascii=False))
    assert isinstance(parsed, dict)


def test_redact_payload_semantic_cap_with_very_low_cap_produces_valid_json() -> None:
    payload = {"host": "h1", "large": "x" * 10_000}
    result = redact_payload(payload, max_bytes=10, hmac_key="test-key")
    assert result.truncated is True
    assert result.stored_byte_length <= 10
    # Must still be valid JSON.
    json.dumps(result.payload)


def test_redact_payload_redaction_grow_short_secret_respects_original_length() -> None:
    # Redaction can grow a short secret value: "x" -> "[redacted]" (10
    # chars). With padding around it, the effective cap
    # (min(max_bytes, original_byte_length)) lets the semantic cap shrink
    # the padding while preserving the redacted secret, and
    # stored_byte_length stays <= original_byte_length per the migration
    # CHECK constraint.
    payload = {"password": "x", "padding": "p" * 200}
    result = redact_payload(payload, max_bytes=65_536, hmac_key="test-key")
    assert result.payload["password"] == AUDIT_REDACTION_PLACEHOLDER
    assert result.truncated is True
    assert result.stored_byte_length <= result.original_byte_length


def test_redact_payload_none_payload_produces_empty_object() -> None:
    result = redact_payload(None, max_bytes=65_536, hmac_key="test-key")
    assert result.payload == {}
    assert result.original_byte_length == 2  # "{}"
    assert result.truncated is False
    assert result.redacted_path_count == 0


def test_redact_normalized_event_message_tags_redacts_sensitive_keys_and_values() -> None:
    message = "service token expired"
    tags = {"env": "prod", "api_key": "sk-12345", "safe.tag": "visible"}
    safe_message, safe_tags = redact_normalized_event_message_tags(message, tags)

    assert safe_message == AUDIT_REDACTION_PLACEHOLDER
    assert safe_tags["env"] == "prod"
    assert "api_key" not in safe_tags
    assert safe_tags["safe.tag"] == "visible"

    # Idempotency: running again on already-redacted output is safe.
    safe_message2, safe_tags2 = redact_normalized_event_message_tags(
        safe_message, safe_tags
    )
    assert safe_message2 == safe_message
    assert safe_tags2 == safe_tags  # keys already omitted, values already redacted


def test_redact_normalized_event_message_tags_omits_sensitive_tag_keys() -> None:
    tags = {"api_key": "leaky-value", "safe": "ok"}
    _, safe_tags = redact_normalized_event_message_tags(None, tags)
    # Sensitive keys are omitted entirely (D-08); safe keys remain.
    assert "api_key" not in safe_tags
    assert safe_tags["safe"] == "ok"


def test_redact_normalized_event_message_tags_redacts_nested_contents_without_mutating_input() -> None:
    tags = {
        "environment": "prod",
        "nested": {
            "safe": "visible",
            "api_key": "secret-key",
            "details": {"description": "contains a token", "region": "us-east-1"},
        },
        "items": [{"name": "healthy"}, {"credential": "secret"}],
    }

    _, safe_tags = redact_normalized_event_message_tags(None, tags)

    assert safe_tags == {
        "environment": "prod",
        "nested": {
            "safe": "visible",
            "api_key": AUDIT_REDACTION_PLACEHOLDER,
            "details": {
                "description": AUDIT_REDACTION_PLACEHOLDER,
                "region": "us-east-1",
            },
        },
        "items": [
            {"name": "healthy"},
            {"credential": AUDIT_REDACTION_PLACEHOLDER},
        ],
    }
    assert tags == {
        "environment": "prod",
        "nested": {
            "safe": "visible",
            "api_key": "secret-key",
            "details": {"description": "contains a token", "region": "us-east-1"},
        },
        "items": [{"name": "healthy"}, {"credential": "secret"}],
    }
    assert safe_tags["nested"] is not tags["nested"]
    assert safe_tags["items"] is not tags["items"]

def test_redact_normalized_event_message_tags_truncates_long_message() -> None:
    # D-08: non-sensitive messages up to 4096 chars in NormalizedEvent must
    # be capped to the 512-char response-surface bound.
    safe_message, _ = redact_normalized_event_message_tags("x" * 600, {})
    assert len(safe_message) == 512
    assert safe_message == "x" * 512


def test_compute_payload_hmac_rejects_empty_key() -> None:
    with pytest.raises(ValueError):
        compute_payload_hmac({"a": 1}, "")


def test_audit_cursor_round_trips_timezone_aware() -> None:
    accepted_at = datetime(2026, 6, 18, 12, 0, 0, tzinfo=UTC)
    cursor = AuditEventCursor(accepted_at=accepted_at, id=uuid4())
    encoded = encode_audit_cursor(cursor)
    decoded = decode_audit_cursor(encoded)
    assert decoded.accepted_at == accepted_at
    assert decoded.id == cursor.id


def test_decode_audit_cursor_rejects_invalid_or_naive_values() -> None:
    # Malformed base64.
    with pytest.raises(ValueError, match="invalid audit event cursor"):
        decode_audit_cursor("!!!not-base64!!!")
    # Valid base64 but invalid JSON.
    with pytest.raises(ValueError, match="invalid audit event cursor"):
        decode_audit_cursor("aGVsbG8")
    # Valid JSON but missing keys.
    bad_missing = _encode_raw({"foo": "bar"})
    with pytest.raises(ValueError, match="invalid audit event cursor"):
        decode_audit_cursor(bad_missing)
    # Naive datetime.
    bad_naive = _encode_raw(
        {"accepted_at": "2026-01-01T00:00:00", "id": str(uuid4())}
    )
    with pytest.raises(ValueError, match="invalid audit event cursor"):
        decode_audit_cursor(bad_naive)
    # Invalid UUID.
    bad_uuid = _encode_raw(
        {"accepted_at": "2026-01-01T00:00:00+00:00", "id": "not-a-uuid"}
    )
    with pytest.raises(ValueError, match="invalid audit event cursor"):
        decode_audit_cursor(bad_uuid)
    # Valid urlsafe base64 that decodes to non-UTF-8 bytes.
    with pytest.raises(ValueError, match="invalid audit event cursor"):
        decode_audit_cursor("____")


def test_decode_audit_cursor_rejects_invalid_byte_appended_to_valid_cursor() -> None:
    cursor = AuditEventCursor(
        accepted_at=datetime(2026, 6, 18, 12, 0, 0, tzinfo=UTC),
        id=uuid4(),
    )

    with pytest.raises(ValueError, match="invalid audit event cursor"):
        decode_audit_cursor(f"{encode_audit_cursor(cursor)}!")

def _encode_raw(payload: dict[str, str]) -> str:
    import base64

    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode()
    ).decode()
    return encoded.rstrip("=")
