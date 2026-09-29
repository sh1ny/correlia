"""Audit-trail repository, redactor, HMAC, and cursor helpers (Phase 7).

This module is the single home for the audit-owned raw-payload redactor
(D-05), the pre-redaction HMAC (D-07), the cursor helpers for
``(accepted_at, id)`` pagination (D-10), and the
``insert_incident_event``/``list_incident_events`` repository helpers.

It deliberately does NOT import ``DecisionContext`` or any private
forbidden-fragment symbol from ``app.domain.incidents``. The redactor is
audit-owned and operates on arbitrary JSON payload trees, not on the
bounded key-value notes that ``DecisionContext`` validates.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime
from itertools import islice
from typing import Any, Literal
from uuid import UUID

from sqlalchemy import (
    Text,
    and_,
    case,
    cast,
    false,
    func,
    literal_column,
    or_,
    select,
    true,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.audit import (
    AUDIT_INCIDENT_IDS_MAX,
    AUDIT_TAG_MAX_BYTES,
    AUDIT_TAG_MAX_ENTRIES,
    AuditEventListFilters,
    AuditTagOmissionReason,
)
from app.domain.events import EventTagValidationError, validate_event_tags
from app.persistence.models import IncidentEvent

#: Current redaction algorithm version. Bump when the redactor logic changes.
REDACTION_VERSION: int = 2

#: Placeholder substituted for sensitive keys/values during redaction.
AUDIT_REDACTION_PLACEHOLDER: str = "[redacted]"

#: Fragments that mark a key or scalar string value as sensitive. Mirrors
#: the semantic intent of ``_FORBIDDEN_NOTE_FRAGMENTS`` in
#: ``app.domain.incidents`` but is owned by the audit module so the
#: redactor never couples to incident decision-context validation.
AUDIT_SENSITIVE_FRAGMENTS: tuple[str, ...] = (
    "raw_payload",
    "payload",
    "credential",
    "password",
    "token",
    "secret",
    "plugin_config",
    "api_key",
    "apikey",
    "auth",
)

#: Maximum length of the projected ``normalized_event_message`` on the
#: default read surface (D-08). Matches ``BoundedResponseMessage`` in
#: ``app/domain/audit.py``. Stored messages may be up to 4096 chars per
#: ``NormalizedEvent.message``; the read surface caps to this bound.
AUDIT_MESSAGE_MAX_LENGTH: int = 512


@dataclass(frozen=True, slots=True)
class RedactedPayload:
    """Result of redacting an accepted source payload object.

    Carries the redacted, semantically size-capped payload plus the
    metadata required by D-07: original/stored byte lengths, truncation
    flag, redaction version, redacted leaf count, and the keyed HMAC of
    the pre-redaction canonical payload.
    """

    payload: dict[str, Any]
    original_byte_length: int
    stored_byte_length: int
    truncated: bool
    redaction_version: int
    redacted_path_count: int
    payload_hmac: str


@dataclass(frozen=True, slots=True)
class AuditEventCursor:
    """Immutable cursor tuple for audit event pagination (D-10)."""

    accepted_at: datetime
    id: UUID


class InvalidAuditCursorError(ValueError):
    """Raised when an audit pagination cursor cannot be decoded safely."""


@dataclass(frozen=True, slots=True)
class AuditEventListRow:
    """Default safe list projection for an audit event (D-08/D-15).

    The repository bounds and redacts the SQL-projected message and tags
    before returning; neither the router nor any caller sees raw payload
    or the full normalized event document on the default read path.
    """

    id: UUID
    accepted_at: datetime
    event_timestamp: datetime
    source_id: str
    fingerprint: str
    event_type: str
    severity: str
    host: str
    service: str | None
    incident_ids: tuple[str, ...]
    incident_effect: Literal[
        "none", "inserted", "updated", "resolved", "affected_set_shrunk"
    ]
    decision_summary: dict[str, Any]
    raw_payload_original_byte_length: int | None
    raw_payload_stored_byte_length: int | None
    raw_payload_truncated: bool
    redaction_version: int | None
    redacted_path_count: int | None
    raw_payload_hmac: str | None
    normalized_event_message: str
    normalized_event_tags: dict[str, str] = field(default_factory=dict)
    normalized_event_tags_omitted: bool = False
    normalized_event_tags_omission_reasons: frozenset[AuditTagOmissionReason] = (
        frozenset()
    )


@dataclass(frozen=True, slots=True)
class IncidentEventListPage:
    """A page of audit events plus pagination metadata."""

    events: tuple[AuditEventListRow, ...]
    next_cursor: str | None
    total: int
    offset: int


# ---------------------------------------------------------------------------
# Canonical JSON + HMAC
# ---------------------------------------------------------------------------


def canonical_json_bytes(value: Any) -> bytes:
    """Serialize ``value`` to deterministic canonical JSON bytes.

    Keys are sorted and separators are compact so the byte output is stable
    across process runs, which is required for the pre-redaction HMAC to be
    reproducible.
    """

    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def _coerce_hmac_key(hmac_key: str | Any) -> str:
    """Coerce a raw string or ``pydantic.SecretStr`` key into the raw secret.

    ``Settings.audit_raw_payload_hmac_key`` is a ``SecretStr``; callers that
    pass it directly (rather than calling ``.get_secret_value()``) would
    otherwise hit ``AttributeError`` at ``hmac_key.encode``. Accept either
    form and return the raw secret string, rejecting empty values.
    """

    if hasattr(hmac_key, "get_secret_value"):
        hmac_key = hmac_key.get_secret_value()
    if not isinstance(hmac_key, str) or not hmac_key:
        raise ValueError("audit_raw_payload_hmac_key must be non-empty")
    return hmac_key


def _hmac_canonical_bytes(canonical: bytes, key: str) -> str:
    return hmac.new(key.encode("utf-8"), canonical, hashlib.sha256).hexdigest()


def compute_payload_hmac(payload: Any, hmac_key: str | Any) -> str:
    """Compute the keyed HMAC-SHA256 over the canonical pre-redaction payload.

    The HMAC is computed over the canonical JSON of the *pre-redaction*
    payload (D-07), so it stays stable when only the redaction output would
    differ and changes when the pre-redaction payload changes. ``hmac_key``
    may be a raw ``str`` or a ``pydantic.SecretStr``.
    """

    key = _coerce_hmac_key(hmac_key)
    return _hmac_canonical_bytes(canonical_json_bytes(payload), key)


# ---------------------------------------------------------------------------
# Recursive redaction
# ---------------------------------------------------------------------------


def _contains_sensitive_fragment(text: str) -> bool:
    lowered = text.lower()
    return any(fragment in lowered for fragment in AUDIT_SENSITIVE_FRAGMENTS)


def _redact_value(value: Any) -> Any:
    """Recursively redact sensitive keys and scalar string values.

    A dict key or list element is replaced with ``AUDIT_REDACTION_PLACEHOLDER``
    when either the key text or the scalar string value contains a sensitive
    fragment. Nested containers are walked in place. The original key is
    preserved when redacting a sensitive *value* so callers (and Pydantic
    tag constraints) still see a valid key; only the value becomes
    ``[redacted]``. When the *key* itself is sensitive, the value is
    replaced with ``[redacted]`` under that same key.
    """

    if isinstance(value, dict):
        redacted: dict[str, Any] = {}
        for key, sub in value.items():
            key_text = key.lower() if isinstance(key, str) else str(key).lower()
            if _contains_sensitive_fragment(key_text):
                redacted[key] = AUDIT_REDACTION_PLACEHOLDER
                continue
            redacted[key] = _redact_value(sub)
        return redacted
    if isinstance(value, list):
        return [_redact_value(item) for item in value]
    if isinstance(value, str):
        if _contains_sensitive_fragment(value):
            return AUDIT_REDACTION_PLACEHOLDER
        return value
    return value


def _count_redacted_leaves(original: Any, redacted: Any) -> int:
    """Count leaf positions where redaction replaced the original value."""

    count = 0
    if isinstance(original, dict) and isinstance(redacted, dict):
        for key, original_sub in original.items():
            redacted_sub = redacted.get(key, original_sub)
            key_text = key.lower() if isinstance(key, str) else str(key).lower()
            if _contains_sensitive_fragment(key_text):
                count += 1
                continue
            count += _count_redacted_leaves(original_sub, redacted_sub)
    elif isinstance(original, list) and isinstance(redacted, list):
        for original_sub, redacted_sub in zip(original, redacted, strict=False):
            count += _count_redacted_leaves(original_sub, redacted_sub)
    elif original != redacted:
        count += 1
    return count


def _semantic_cap_payload(
    payload: dict[str, Any], max_bytes: int
) -> tuple[dict[str, Any], bool, int]:
    """Keep full redacted JSON if it fits; otherwise omit whole top-level fields.

    Each field's encoded key/value contribution is measured once. Removing a
    field also removes one comma except when it was the only remaining field.
    No nested value is shortened or serialized again during removal.
    """

    stored_byte_length = len(canonical_json_bytes(payload))
    if stored_byte_length <= max_bytes:
        return payload, False, stored_byte_length

    fields = sorted(
        (
            (len(canonical_json_bytes({key: value})) - 2, key)
            for key, value in payload.items()
        ),
        key=lambda field: (-field[0], field[1]),
    )
    for field_bytes, key in fields:
        if stored_byte_length <= max_bytes:
            break
        stored_byte_length -= field_bytes + (len(payload) > 1)
        del payload[key]

    return payload, True, len(canonical_json_bytes(payload))


def redact_payload(
    payload: dict[str, Any] | None,
    *,
    max_bytes: int,
    hmac_key: str | Any,
) -> RedactedPayload:
    """Redact, semantically cap, and HMAC an accepted source payload.

    Implements D-04 (redacted, size-capped snapshot), D-05 (recursive
    secret stripping), D-06 (semantic, configurable cap), and D-07
    (pre-redaction keyed HMAC plus metadata). When ``payload`` is ``None``
    an empty object is recorded so the non-null ``raw_payload`` column
    contract is satisfied.

    The effective cap is ``min(max_bytes, original_byte_length)`` because
    redaction can grow a short payload (e.g. ``"x"`` → ``"[redacted]"``)
    while the migration CHECK ``raw_payload_stored_byte_length <=
    raw_payload_original_byte_length`` must always hold.
    """

    if max_bytes < 2:
        raise ValueError("max_bytes must be at least 2")

    source = payload if payload is not None else {}
    original_bytes = canonical_json_bytes(source)
    original_byte_length = len(original_bytes)
    payload_hmac = _hmac_canonical_bytes(original_bytes, _coerce_hmac_key(hmac_key))
    redacted = _redact_value(source)
    redacted_path_count = _count_redacted_leaves(source, redacted)
    effective_cap = min(max_bytes, original_byte_length)
    capped, truncated, stored_byte_length = _semantic_cap_payload(
        redacted, effective_cap
    )

    return RedactedPayload(
        payload=capped,
        original_byte_length=original_byte_length,
        stored_byte_length=stored_byte_length,
        truncated=truncated,
        redaction_version=REDACTION_VERSION,
        redacted_path_count=redacted_path_count,
        payload_hmac=payload_hmac,
    )


# ---------------------------------------------------------------------------
# Read-time message redaction and bounded tag projection
# ---------------------------------------------------------------------------


def _project_normalized_event_message(message: str | None) -> str:
    """Check the whole message for sensitive content before the 512-char cap."""
    raw_message = message or ""
    safe_message = (
        AUDIT_REDACTION_PLACEHOLDER
        if raw_message and _contains_sensitive_fragment(raw_message)
        else raw_message
    )
    return safe_message[:AUDIT_MESSAGE_MAX_LENGTH]


def _project_normalized_event_tags(
    tags: Mapping[str, str],
    *,
    invalid_legacy_shape: bool = False,
    size_limit: bool = False,
) -> tuple[dict[str, str], frozenset[AuditTagOmissionReason]]:
    """Keep valid flat tags in lexical order, within the response JSON budget.

    SQL has already excluded non-string values and oversized source objects.
    Account for redacted scalar values, JSON escapes, and commas before adding
    a pair. A pair that does not fit does not prevent later small pairs.
    """
    reasons: set[AuditTagOmissionReason] = set()
    if invalid_legacy_shape:
        reasons.add("invalid_legacy_shape")
    if size_limit:
        reasons.add("size_limit")

    projected: dict[str, str] = {}
    encoded_bytes = 2  # Braces
    for key in sorted(tags):
        value = tags[key]
        try:
            validate_event_tags({key: value})
        except EventTagValidationError:
            reasons.add("invalid_legacy_shape")
            continue
        if _contains_sensitive_fragment(key):
            reasons.add("sensitive_key")
            continue
        if len(projected) >= AUDIT_TAG_MAX_ENTRIES:
            reasons.add("size_limit")
            continue
        safe_value = (
            AUDIT_REDACTION_PLACEHOLDER
            if _contains_sensitive_fragment(value)
            else value
        )
        pair_bytes = len(canonical_json_bytes({key: safe_value})) - 2
        additional_bytes = pair_bytes + bool(projected)
        if encoded_bytes + additional_bytes > AUDIT_TAG_MAX_BYTES:
            reasons.add("size_limit")
            continue
        projected[key] = safe_value
        encoded_bytes += additional_bytes
    return projected, frozenset(reasons)


# ---------------------------------------------------------------------------
# Cursor helpers
# ---------------------------------------------------------------------------


def encode_audit_cursor(cursor: AuditEventCursor) -> str:
    """Encode an audit cursor as urlsafe base64 of compact JSON (D-10)."""

    payload = {
        "accepted_at": cursor.accepted_at.isoformat(),
        "id": str(cursor.id),
    }
    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode()
    ).decode()
    return encoded.rstrip("=")


def decode_audit_cursor(value: str) -> AuditEventCursor:
    """Decode and validate an audit cursor.

    Rejects malformed base64/JSON, non-UTF-8 bytes, missing keys, invalid
    UUIDs, and naive datetimes with ``InvalidAuditCursorError``. Strict
    URL-safe base64 validation also rejects malformed trailing bytes and
    non-UTF-8 payloads.
    """

    try:
        padded = value + ("=" * (-len(value) % 4))
        payload = json.loads(
            base64.b64decode(padded.encode(), altchars=b"-_", validate=True).decode()
        )
        accepted_at = datetime.fromisoformat(payload["accepted_at"])
        if accepted_at.tzinfo is None or accepted_at.utcoffset() is None:
            raise ValueError("cursor timestamp must be timezone-aware")
        return AuditEventCursor(accepted_at=accepted_at, id=UUID(payload["id"]))
    except UnicodeDecodeError as exc:
        # Valid urlsafe base64 that decodes to non-UTF-8 bytes (e.g. "____")
        # bypasses binascii.Error and fails at .decode(); catch explicitly.
        raise InvalidAuditCursorError("invalid audit event cursor") from exc
    except (
        KeyError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
        binascii.Error,
    ) as exc:
        raise InvalidAuditCursorError("invalid audit event cursor") from exc


# ---------------------------------------------------------------------------
# Repository helpers
# ---------------------------------------------------------------------------


# An unbounded JSONB value must never reach the driver's JSON decoder. CASE
# protects the jsonb_each argument itself (not merely a WHERE condition), so
# neither non-object containers nor objects above the textual transfer cap
# are visited. The filtered aggregate contains string-valued siblings only.
_AUDIT_TAG_SQL_MAX_BYTES = 32_768
_EMPTY_TAG_OBJECT = literal_column("'{}'::jsonb", type_=JSONB)
_tag_source = IncidentEvent.normalized_event["tags"]
_tag_is_object = func.jsonb_typeof(_tag_source) == "object"
_tag_within_sql_limit = (
    func.octet_length(cast(_tag_source, Text)) <= _AUDIT_TAG_SQL_MAX_BYTES
)
_guarded_tags = case(
    (and_(_tag_is_object, _tag_within_sql_limit), _tag_source),
    else_=_EMPTY_TAG_OBJECT,
)
_tag_entries = (
    func.jsonb_each(_guarded_tags).table_valued("key", "value").alias("audit_tags")
)
_tag_is_string = func.jsonb_typeof(_tag_entries.c.value) == "string"
_projected_sql_tags = (
    select(
        func.coalesce(
            func.jsonb_object_agg(_tag_entries.c.key, _tag_entries.c.value).filter(
                _tag_is_string
            ),
            _EMPTY_TAG_OBJECT,
        )
    )
    .select_from(_tag_entries)
    .scalar_subquery()
)
_has_nonstring_tags = (
    select(_tag_entries.c.key).select_from(_tag_entries).where(~_tag_is_string).exists()
)
_tag_size_limited = case(
    (_tag_is_object, ~_tag_within_sql_limit),
    else_=false(),
)
_tag_invalid_shape = case(
    (
        _tag_is_object,
        case(
            (_tag_within_sql_limit, _has_nonstring_tags),
            else_=false(),
        ),
    ),
    else_=true(),
)

# Default safe list projection (D-08/D-15). Raw payload and the full
# normalized document are not selected; only a message and guarded tags.
_AUDIT_LIST_COLUMNS = (
    IncidentEvent.id,
    IncidentEvent.accepted_at,
    IncidentEvent.event_timestamp,
    IncidentEvent.source_id,
    IncidentEvent.fingerprint,
    IncidentEvent.event_type,
    IncidentEvent.severity,
    IncidentEvent.host,
    IncidentEvent.service,
    IncidentEvent.incident_ids,
    IncidentEvent.incident_effect,
    IncidentEvent.decision_summary,
    IncidentEvent.raw_payload_original_byte_length,
    IncidentEvent.raw_payload_stored_byte_length,
    IncidentEvent.raw_payload_truncated,
    IncidentEvent.redaction_version,
    IncidentEvent.redacted_path_count,
    IncidentEvent.raw_payload_hmac,
    IncidentEvent.normalized_event["message"].astext.label("normalized_event_message"),
    _projected_sql_tags.label("normalized_event_tags"),
    _tag_size_limited.label("normalized_event_tags_size_limited"),
    _tag_invalid_shape.label("normalized_event_tags_invalid_shape"),
)


async def insert_incident_event(
    session: AsyncSession,
    *,
    event_timestamp: datetime,
    source_id: str,
    fingerprint: str,
    event_type: str,
    severity: str,
    host: str,
    service: str | None,
    incident_ids: list[str],
    incident_effect: str,
    decision_summary: dict[str, Any],
    normalized_event: dict[str, Any],
    raw_payload: dict[str, Any],
    raw_payload_original_byte_length: int,
    raw_payload_stored_byte_length: int,
    raw_payload_truncated: bool,
    redaction_version: int,
    redacted_path_count: int,
    raw_payload_hmac: str,
) -> IncidentEvent:
    """Insert one audit row and return the persisted ORM instance.

    The row id is generated by PostgreSQL (D-13); callers never set it.
    The caller owns the transaction (D-02) and commits after this insert.
    All raw-payload metadata fields are required and non-null so the helper
    fails fast instead of surfacing as a database IntegrityError.
    """

    if raw_payload is None:
        raise ValueError("raw_payload must be a JSON object, not None")
    if (
        raw_payload_original_byte_length is None
        or raw_payload_stored_byte_length is None
    ):
        raise ValueError("raw_payload byte lengths must not be None")
    if redaction_version is None or redacted_path_count is None:
        raise ValueError("redaction_version and redacted_path_count must not be None")
    if raw_payload_hmac is None:
        raise ValueError("raw_payload_hmac must not be None")

    event = IncidentEvent(
        event_timestamp=event_timestamp,
        source_id=source_id,
        fingerprint=fingerprint,
        event_type=event_type,
        severity=severity,
        host=host,
        service=service,
        incident_ids=incident_ids,
        incident_effect=incident_effect,
        decision_summary=decision_summary,
        normalized_event=normalized_event,
        raw_payload=raw_payload,
        raw_payload_original_byte_length=raw_payload_original_byte_length,
        raw_payload_stored_byte_length=raw_payload_stored_byte_length,
        raw_payload_truncated=raw_payload_truncated,
        redaction_version=redaction_version,
        redacted_path_count=redacted_path_count,
        raw_payload_hmac=raw_payload_hmac,
    )
    session.add(event)
    await session.flush()
    return event


def _apply_audit_filters(stmt: Any, filters: AuditEventListFilters) -> Any:
    """Apply ``AuditEventListFilters`` to a select statement."""

    if filters.incident_id is not None:
        stmt = stmt.where(
            IncidentEvent.incident_ids.contains([str(filters.incident_id)])
        )
    if filters.has_incident is False:
        stmt = stmt.where(IncidentEvent.incident_effect == "none")
    elif filters.has_incident is True:
        stmt = stmt.where(IncidentEvent.incident_effect != "none")
    if filters.fingerprint is not None:
        stmt = stmt.where(IncidentEvent.fingerprint == filters.fingerprint)
    if filters.source_id is not None:
        stmt = stmt.where(IncidentEvent.source_id == filters.source_id)
    if filters.event_type is not None:
        stmt = stmt.where(IncidentEvent.event_type == filters.event_type.value)
    if filters.incident_effect is not None:
        stmt = stmt.where(IncidentEvent.incident_effect == filters.incident_effect)
    if filters.no_dispatch_reason is not None:
        stmt = stmt.where(
            IncidentEvent.decision_summary["no_dispatch_reason"].astext
            == filters.no_dispatch_reason
        )
    if filters.severity is not None:
        stmt = stmt.where(IncidentEvent.severity == filters.severity.value)
    if filters.host is not None:
        stmt = stmt.where(IncidentEvent.host == filters.host)
    if filters.service is not None:
        stmt = stmt.where(IncidentEvent.service == filters.service)
    if filters.accepted_since is not None:
        stmt = stmt.where(IncidentEvent.accepted_at >= filters.accepted_since)
    if filters.accepted_until is not None:
        stmt = stmt.where(IncidentEvent.accepted_at < filters.accepted_until)
    if filters.event_timestamp_since is not None:
        stmt = stmt.where(
            IncidentEvent.event_timestamp >= filters.event_timestamp_since
        )
    if filters.event_timestamp_until is not None:
        stmt = stmt.where(IncidentEvent.event_timestamp < filters.event_timestamp_until)
    return stmt


def _row_to_audit_event_list_row(row: Sequence[Any]) -> AuditEventListRow:
    """Map a projected SQL row into a safe ``AuditEventListRow``.

    Normalizes JSONB arrays in decision summaries into tuples for strict
    response validation, then redacts the projected message and string-only
    tags. SQL has already excluded non-string values and oversized objects.
    """

    (
        id_,
        accepted_at,
        event_timestamp,
        source_id,
        fingerprint,
        event_type,
        severity,
        host,
        service,
        incident_ids,
        incident_effect,
        decision_summary,
        raw_payload_original_byte_length,
        raw_payload_stored_byte_length,
        raw_payload_truncated,
        redaction_version,
        redacted_path_count,
        raw_payload_hmac,
        normalized_event_message,
        normalized_event_tags,
        normalized_event_tags_size_limited,
        normalized_event_tags_invalid_shape,
    ) = row

    # SQL filtering operates on complete persisted JSONB values; cap only
    # the returned response projection.
    incident_ids_tuple = (
        tuple(islice(incident_ids, AUDIT_INCIDENT_IDS_MAX))
        if incident_ids is not None
        else ()
    )
    decision_summary_dict = (
        dict(decision_summary) if decision_summary is not None else {}
    )
    # Normalize ``incident_ids`` inside the decision summary from a JSONB
    # list to a tuple so strict Pydantic validation
    # (``AuditDecisionSummary.incident_ids: BoundedStringTuple``) in the
    # API layer never rejects rows read from Postgres.
    if isinstance(decision_summary_dict.get("incident_ids"), list):
        decision_summary_dict["incident_ids"] = tuple(
            decision_summary_dict["incident_ids"]
        )
    safe_message = _project_normalized_event_message(normalized_event_message)
    safe_tags, omission_reasons = _project_normalized_event_tags(
        normalized_event_tags,
        size_limit=bool(normalized_event_tags_size_limited),
        invalid_legacy_shape=bool(normalized_event_tags_invalid_shape),
    )

    return AuditEventListRow(
        id=id_,
        accepted_at=accepted_at,
        event_timestamp=event_timestamp,
        source_id=source_id,
        fingerprint=fingerprint,
        event_type=event_type,
        severity=severity,
        host=host,
        service=service,
        incident_ids=incident_ids_tuple,
        incident_effect=incident_effect,
        decision_summary=decision_summary_dict,
        raw_payload_original_byte_length=raw_payload_original_byte_length,
        raw_payload_stored_byte_length=raw_payload_stored_byte_length,
        raw_payload_truncated=bool(raw_payload_truncated),
        redaction_version=redaction_version,
        redacted_path_count=redacted_path_count,
        raw_payload_hmac=raw_payload_hmac,
        normalized_event_message=safe_message,
        normalized_event_tags=safe_tags,
        normalized_event_tags_omitted=bool(omission_reasons),
        normalized_event_tags_omission_reasons=omission_reasons,
    )


async def list_incident_events(
    session: AsyncSession,
    filters: AuditEventListFilters,
) -> IncidentEventListPage:
    """List audit events with filters, cursor/offset pagination, and safe projection.

    The default read path never returns ORM ``IncidentEvent`` entities and
    never selects ``raw_payload`` or the full ``normalized_event`` document
    (D-08/D-15). Cursor pagination is on the immutable tuple
    ``(accepted_at, id)`` descending (D-10). Offset pagination is
    diagnostic-only and reports a filtered ``total``.
    """

    count_stmt = _apply_audit_filters(
        select(func.count()).select_from(IncidentEvent), filters
    )
    total = await session.scalar(count_stmt) or 0

    page_stmt = _apply_audit_filters(select(*_AUDIT_LIST_COLUMNS), filters)
    if filters.cursor is not None:
        cursor = decode_audit_cursor(filters.cursor)
        page_stmt = page_stmt.where(
            or_(
                IncidentEvent.accepted_at < cursor.accepted_at,
                and_(
                    IncidentEvent.accepted_at == cursor.accepted_at,
                    IncidentEvent.id < cursor.id,
                ),
            )
        )
        page_stmt = page_stmt.order_by(
            IncidentEvent.accepted_at.desc(), IncidentEvent.id.desc()
        ).limit(filters.limit + 1)
        result = await session.execute(page_stmt)
        rows = tuple(result.all())
        page_rows = rows[: filters.limit]
        next_cursor = None
        if len(rows) > filters.limit:
            last = page_rows[-1]
            next_cursor = encode_audit_cursor(
                AuditEventCursor(accepted_at=last[1], id=last[0])
            )
        offset_value = 0
    elif filters.offset is not None:
        page_stmt = (
            page_stmt.order_by(
                IncidentEvent.accepted_at.desc(), IncidentEvent.id.desc()
            )
            .offset(filters.offset)
            .limit(filters.limit)
        )
        result = await session.execute(page_stmt)
        rows = tuple(result.all())
        page_rows = rows
        next_cursor = None
        offset_value = filters.offset
    else:
        page_stmt = page_stmt.order_by(
            IncidentEvent.accepted_at.desc(), IncidentEvent.id.desc()
        ).limit(filters.limit + 1)
        result = await session.execute(page_stmt)
        rows = tuple(result.all())
        page_rows = rows[: filters.limit]
        next_cursor = None
        if len(rows) > filters.limit:
            last = page_rows[-1]
            next_cursor = encode_audit_cursor(
                AuditEventCursor(accepted_at=last[1], id=last[0])
            )
        offset_value = 0

    events = tuple(_row_to_audit_event_list_row(row) for row in page_rows)
    return IncidentEventListPage(
        events=events,
        next_cursor=next_cursor,
        total=int(total),
        offset=offset_value,
    )
