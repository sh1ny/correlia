"""Pure unit coverage for recursive redaction, semantic size capping, and pre-redaction HMAC."""

from __future__ import annotations

import hashlib
import hmac
import json
from datetime import UTC, datetime
from uuid import uuid4

import pytest
from pydantic import SecretStr, ValidationError

from app.domain.events import (
    EVENT_TAG_MAX_BYTES,
    EVENT_TAG_MAX_ENTRIES,
    validate_event_tags,
)
from app.plugins.inputs.icinga2 import Icinga2WebhookPayload
from scripts.qualify_audit_bounds import (
    BODY_CEILING,
    HISTORICAL_LENGTHS,
    exact_tag_bytes,
    make_corpus,
)

from app.persistence.audit import (
    AUDIT_REDACTION_PLACEHOLDER,
    REDACTION_VERSION,
    AuditEventCursor,
    _project_normalized_event_message,
    _project_normalized_event_tags,
    compute_payload_hmac,
    decode_audit_cursor,
    encode_audit_cursor,
    redact_payload,
)


def _canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def test_qualification_corpus_reconstructs_historical_sizes_without_accepting_old_maps() -> (
    None
):
    cases = make_corpus()
    reconstructed = [case for case in cases if not case.ingress_permitted]
    assert [len(case.payload["tags"]) for case in reconstructed] == list(
        HISTORICAL_LENGTHS
    )
    for case, expected in zip(reconstructed, HISTORICAL_LENGTHS.values(), strict=True):
        assert case.parameters["kind"] == "reconstructed_not_original"
        assert len(case.canonical_bytes) == expected
        assert len(case.digest) == 64
        with pytest.raises(ValidationError):
            Icinga2WebhookPayload.model_validate(case.payload)


def test_qualification_corpus_is_valid_separate_ingress_maxima() -> None:
    cases = {case.name: case for case in make_corpus() if case.ingress_permitted}
    assert len(cases["count_128"].payload["tags"]) == EVENT_TAG_MAX_ENTRIES
    assert len(cases["max_key_64"].payload["tags"]) == EVENT_TAG_MAX_ENTRIES
    assert all(len(key) == 64 for key in cases["max_key_64"].payload["tags"])
    assert len(_canonical_bytes(cases["exact_tag_bytes_16384"].payload["tags"])) == (
        EVENT_TAG_MAX_BYTES
    )
    assert len(cases["message_4096"].payload["check_output"]) == 4096
    assert len(cases["near_1mib_body"].canonical_bytes) == BODY_CEILING - 512
    assert cases["near_1mib_body"].payload["check_output"] == "x"
    assert len(cases["near_1mib_body"].payload["ip_address"]) > 1_000_000
    assert any(
        len(value.encode("utf-8")) == 80
        for value in cases["four_byte_unicode"].payload["tags"].values()
    )
    assert any(
        all(chr(code) in value for code in (10, 34, 92, 9))
        for value in cases["escape_heavy"].payload["tags"].values()
    )
    assert set(cases["redaction_expansion"].payload["tags"].values()) == {"token"}
    assert len(cases["redaction_expansion"].payload["tags"]) == 128
    for case in cases.values():
        validate_event_tags(case.payload["tags"])
        assert (
            Icinga2WebhookPayload.model_validate(case.payload).model_dump(mode="json")
            == case.payload
        )
        assert len(case.canonical_bytes) <= BODY_CEILING
        assert len(case.digest) == 64
    with_collision = exact_tag_bytes(topology_collision=True)
    assert len(with_collision) == EVENT_TAG_MAX_ENTRIES
    assert len(_canonical_bytes(with_collision)) == EVENT_TAG_MAX_BYTES
    assert with_collision["topology.datacenter"] == "u4"
    validate_event_tags(with_collision)


def test_qualification_corpus_raw_outputs_preserve_cap_and_original_integrity() -> None:
    for case in make_corpus():
        original = case.canonical_bytes
        result = redact_payload(case.payload, max_bytes=1_024, hmac_key="fixture-key")
        assert result.original_byte_length == len(original)
        assert result.stored_byte_length == len(_canonical_bytes(result.payload))
        assert result.stored_byte_length <= min(1_024, len(original))
        assert (
            result.payload_hmac
            == hmac.new(b"fixture-key", original, hashlib.sha256).hexdigest()
        )
        assert result.redaction_version == REDACTION_VERSION
        assert case.canonical_bytes == original
    expanded = next(
        case for case in make_corpus() if case.name == "redaction_expansion"
    )
    expanded_result = redact_payload(
        expanded.payload, max_bytes=65_536, hmac_key="fixture-key"
    )
    assert expanded_result.truncated
    assert expanded_result.redacted_path_count == 128


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
    original = _canonical_bytes(payload)
    result = redact_payload(payload, max_bytes=65_536, hmac_key="test-key")

    assert _canonical_bytes(payload) == original
    assert result.payload is not payload
    assert result.payload["nested"] is not payload["nested"]
    assert result.payload["items"] is not payload["items"]
    assert result.payload["host"] == "db-1"
    assert result.payload["password"] == AUDIT_REDACTION_PLACEHOLDER
    assert result.payload["nested"]["api_key"] == AUDIT_REDACTION_PLACEHOLDER
    assert result.payload["nested"]["safe_field"] == "visible"
    assert result.payload["items"][0]["token"] == AUDIT_REDACTION_PLACEHOLDER
    assert result.payload["items"][0]["name"] == "ok"
    assert result.payload["items"][1]["name"] == "second"
    assert result.payload["secret_in_value"] == AUDIT_REDACTION_PLACEHOLDER

    assert result.redaction_version == REDACTION_VERSION
    assert result.redacted_path_count == 4
    assert result.truncated is False
    assert result.original_byte_length == len(original)
    assert result.stored_byte_length == len(_canonical_bytes(result.payload))
    assert result.stored_byte_length <= result.original_byte_length


def test_redact_payload_hmac_uses_pre_redaction_canonical_payload() -> None:
    payload = {"password": "secret-value", "host": "h1"}
    result = redact_payload(payload, max_bytes=65_536, hmac_key="test-key")

    # HMAC must match canonical JSON of the PRE-redaction payload.
    canonical = _canonical_bytes(payload)
    expected_hmac = hmac.new(b"test-key", canonical, hashlib.sha256).hexdigest()
    assert result.payload_hmac == expected_hmac
    assert result.original_byte_length == len(canonical)
    assert compute_payload_hmac(payload, "test-key") == expected_hmac

    reordered = {"host": "h1", "password": "secret-value"}
    assert (
        redact_payload(reordered, max_bytes=65_536, hmac_key="test-key").payload_hmac
        == expected_hmac
    )

    # Different originals can have identical redacted output but different HMACs.
    payload2 = {"password": "different-secret", "host": "h1"}
    result2 = redact_payload(payload2, max_bytes=65_536, hmac_key="test-key")
    assert result2.payload == result.payload
    assert result2.payload_hmac != result.payload_hmac


def test_redact_payload_hmac_accepts_secret_str_key() -> None:
    payload = {"host": "h1"}
    raw_key = "secret-str-key"
    result_str = redact_payload(payload, max_bytes=65_536, hmac_key=raw_key)
    result_secret = redact_payload(
        payload, max_bytes=65_536, hmac_key=SecretStr(raw_key)
    )
    assert result_str.payload_hmac == result_secret.payload_hmac
    assert compute_payload_hmac(payload, SecretStr(raw_key)) == result_str.payload_hmac


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
    # The redacted value grows while the original byte length remains the
    # effective cap. The larger padding field is omitted as a whole.
    payload = {"password": "x", "padding": "p" * 200}
    result = redact_payload(payload, max_bytes=65_536, hmac_key="test-key")
    assert result.payload == {"password": AUDIT_REDACTION_PLACEHOLDER}
    assert result.truncated is True
    assert result.redacted_path_count == 1
    assert result.original_byte_length == len(_canonical_bytes(payload))
    assert result.stored_byte_length == len(_canonical_bytes(result.payload))
    assert result.stored_byte_length <= result.original_byte_length


def test_redact_payload_none_payload_produces_empty_object() -> None:
    result = redact_payload(None, max_bytes=65_536, hmac_key="test-key")
    assert result.payload == {}
    assert result.original_byte_length == 2  # "{}"
    assert result.truncated is False
    assert result.redacted_path_count == 0


def test_redact_payload_exact_cap_one_over_and_lexical_ties() -> None:
    payload = {"b": "y", "a": "x"}
    length = len(_canonical_bytes(payload))
    exact = redact_payload(payload, max_bytes=length, hmac_key="key")
    assert exact.payload == payload
    assert exact.stored_byte_length == length
    assert exact.truncated is False

    one_over = redact_payload(payload, max_bytes=length - 1, hmac_key="key")
    assert one_over.payload == {"b": "y"}
    assert one_over.original_byte_length == length
    assert one_over.stored_byte_length == len(_canonical_bytes({"b": "y"}))
    assert one_over.truncated is True


def test_redact_payload_two_byte_floor_and_short_secret_expansion() -> None:
    payload = {"password": "x"}
    result = redact_payload(payload, max_bytes=65_536, hmac_key="key")
    assert result.payload == {}
    assert result.truncated is True
    assert result.redacted_path_count == 1
    assert result.original_byte_length == len(_canonical_bytes(payload))
    assert result.stored_byte_length == 2
    assert redact_payload({"a": 1}, max_bytes=2, hmac_key="key").payload == {}
    assert redact_payload({}, max_bytes=2, hmac_key="key").truncated is False


@pytest.mark.parametrize("max_bytes", [0, 1])
def test_redact_payload_rejects_caps_below_json_object_floor(max_bytes: int) -> None:
    with pytest.raises(ValueError, match="at least 2"):
        redact_payload({"a": 1}, max_bytes=max_bytes, hmac_key="key")


def test_redact_payload_counts_secrets_inside_omitted_subtree() -> None:
    payload = {
        "keep": "ok",
        "large": {
            "api_key": "short",
            "items": ["contains a token", {"safe": "contains a secret"}],
            "padding": "x" * 300,
        },
    }
    original = _canonical_bytes(payload)
    cap = len(_canonical_bytes({"keep": "ok"}))
    result = redact_payload(payload, max_bytes=cap, hmac_key="key")

    assert result.payload == {"keep": "ok"}
    assert result.truncated is True
    assert result.redacted_path_count == 3
    assert result.payload_hmac == compute_payload_hmac(payload, "key")
    assert result.original_byte_length == len(original)
    assert result.stored_byte_length == cap
    assert _canonical_bytes(payload) == original


@pytest.mark.parametrize("cap", [1_024, 65_536])
def test_redact_payload_production_caps_remove_whole_large_field(cap: int) -> None:
    payload = {"small": "ok", "blob": "🙂" * 20_000}
    result = redact_payload(payload, max_bytes=cap, hmac_key="key")
    assert result.payload == {"small": "ok"}
    assert result.truncated is True
    assert result.stored_byte_length == len(_canonical_bytes(result.payload))
    assert result.stored_byte_length <= min(cap, result.original_byte_length)


def test_redact_payload_many_short_fields_deterministically_remove_largest_first() -> (
    None
):
    payload = {f"k{i:03}": "v" for i in range(256)}
    contribution_with_comma = len(_canonical_bytes({"k000": "v"})) - 1
    cap = len(_canonical_bytes(payload)) - 80 * contribution_with_comma
    first = redact_payload(payload, max_bytes=cap, hmac_key="key")
    again = redact_payload(payload, max_bytes=cap, hmac_key="key")

    assert first.payload == {f"k{i:03}": "v" for i in range(80, 256)}
    assert first.payload == again.payload
    assert first.stored_byte_length == cap
    assert first.stored_byte_length == len(_canonical_bytes(first.payload))
    assert first.truncated is True


def test_redact_payload_large_keys_and_nested_arrays_drop_whole_fields() -> None:
    huge_key = "z" * 9_000
    large_key_result = redact_payload(
        {huge_key: "ok", "a": "ok"}, max_bytes=1_024, hmac_key="key"
    )
    assert large_key_result.payload == {"a": "ok"}
    assert large_key_result.truncated is True
    assert large_key_result.stored_byte_length <= 1_024

    payload = {"c": [1, 2, 3, 4], "b": 2, "a": 1}
    one_over = redact_payload(
        payload, max_bytes=len(_canonical_bytes(payload)) - 1, hmac_key="key"
    )
    assert one_over.payload == {"a": 1, "b": 2}
    tie = redact_payload(
        payload, max_bytes=len(_canonical_bytes({"b": 2})), hmac_key="key"
    )
    assert tie.payload == {"b": 2}
    assert tie.redacted_path_count == 0
    assert tie.stored_byte_length == len(_canonical_bytes(tie.payload))


def test_redact_payload_multibyte_keys_and_escaped_strings_count_bytes() -> None:
    payload = {
        "🍋": "雪",
        "escaped": "line\n\\snow",
        "emoji": "😀" * 100,
    }
    result = redact_payload(
        payload, max_bytes=len(_canonical_bytes(payload)) - 1, hmac_key="key"
    )
    assert result.payload == {"🍋": "雪", "escaped": "line\n\\snow"}
    assert result.original_byte_length == len(_canonical_bytes(payload))
    assert result.stored_byte_length == len(_canonical_bytes(result.payload))
    assert result.stored_byte_length < result.original_byte_length
    assert json.loads(_canonical_bytes(result.payload)) == result.payload
    assert result.truncated is True


def test_project_flat_tags_distinguishes_sensitive_keys_from_redacted_values() -> None:
    original = {
        "z": "plain",
        "safe": "contains a token",
        "api_key": "private",
        "a": "ok",
    }
    projected, reasons = _project_normalized_event_tags(original)
    assert list(projected) == ["a", "safe", "z"]
    assert projected["safe"] == AUDIT_REDACTION_PLACEHOLDER
    assert reasons == {"sensitive_key"}
    assert original["safe"] == "contains a token"

    redacted_only, no_omissions = _project_normalized_event_tags(
        {"safe": "contains a secret"}
    )
    assert redacted_only == {"safe": AUDIT_REDACTION_PLACEHOLDER}
    assert not no_omissions


def test_project_flat_tags_exact_count_and_overflow_in_lexical_order() -> None:
    original = dict(reversed([(f"k{i:02}", "v") for i in range(32)]))
    exact, reasons = _project_normalized_event_tags(original)
    assert list(exact) == sorted(original)
    assert len(exact) == 32
    assert not reasons

    original["z"] = "later"
    projected, reasons = _project_normalized_event_tags(original)
    assert projected == exact
    assert reasons == {"size_limit"}


def test_project_flat_tags_exact_json_bytes_and_skip_then_continue() -> None:
    base = {f"k{i:02}": "x" * 120 for i in range(31)}
    remaining = 4_096 - len(_canonical_bytes(base)) - 1
    last_length = remaining - (len(_canonical_bytes({"zz": ""})) - 2)
    assert 1 <= last_length <= 256
    exact, reasons = _project_normalized_event_tags({**base, "zz": "v" * last_length})
    assert len(exact) == 32
    assert len(_canonical_bytes(exact)) == 4_096
    assert not reasons

    overflow, reasons = _project_normalized_event_tags(
        {**base, "zz": "v" * (last_length + 1)}
    )
    assert overflow == base
    assert reasons == {"size_limit"}

    # An earlier lexical pair can be too large without crowding out a later one.
    nearly_full = {f"k{i:02}": "x" * 120 for i in range(31)}
    larger = {"l": "q" * 256, "z": "ok"}
    projected, reasons = _project_normalized_event_tags({**larger, **nearly_full})
    assert "l" not in projected
    assert projected["z"] == "ok"
    assert reasons == {"size_limit"}


def test_project_flat_tags_counts_redaction_expansion_and_encoded_characters() -> None:
    base = {f"k{i:02}": "x" * 120 for i in range(31)}
    space = 4_096 - len(_canonical_bytes(base))
    redacted_pair = len(_canonical_bytes({"z": AUDIT_REDACTION_PLACEHOLDER})) - 2
    padding = space - (redacted_pair + 1) + 1
    assert 0 < padding <= 136
    base["k00"] += "x" * padding
    projected, reasons = _project_normalized_event_tags({**base, "z": "token"})
    assert "z" not in projected
    assert reasons == {"size_limit"}
    assert len(_canonical_bytes(projected)) <= 4_096

    escaped = {"b": "\\" * 256, "a": "\U00010348" * 256, "c": "\x01" * 256}
    safe, no_omissions = _project_normalized_event_tags(escaped)
    assert safe == escaped
    assert not no_omissions
    assert len(_canonical_bytes(safe)) <= 4_096
    over_limit = {**escaped, "d": "\U00010348" * 256, "z": "ok"}
    assert len(_canonical_bytes(over_limit)) > 4_096
    safe, reasons = _project_normalized_event_tags(over_limit)
    assert "d" not in safe
    assert safe["z"] == "ok"
    assert reasons == {"size_limit"}


@pytest.mark.parametrize(
    "invalid",
    [
        {"1bad": "ok"},
        {"Upper": "ok"},
        {"a" * 65: "ok"},
        {"empty": ""},
        {"long": "v" * 257},
        {"nul": "a\x00b"},
        {"nested": {"api_key": "secret"}},
    ],
)
def test_project_flat_tags_omits_invalid_legacy_pairs(
    invalid: dict[str, object],
) -> None:
    projected, reasons = _project_normalized_event_tags(
        {**invalid, "good": "visible"}  # type: ignore[arg-type]
    )
    assert projected == {"good": "visible"}
    assert reasons == {"invalid_legacy_shape"}


def test_project_message_checks_secret_after_response_truncation_boundary() -> None:
    assert _project_normalized_event_message("x" * 600) == "x" * 512
    assert _project_normalized_event_message("x" * 512 + " token") == (
        AUDIT_REDACTION_PLACEHOLDER
    )
    assert _project_normalized_event_message(None) == ""


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
    bad_naive = _encode_raw({"accepted_at": "2026-01-01T00:00:00", "id": str(uuid4())})
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
