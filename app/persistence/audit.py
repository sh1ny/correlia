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
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.audit import AuditEventListFilters
from app.persistence.models import IncidentEvent

#: Current redaction algorithm version. Bump when the redactor logic changes.
REDACTION_VERSION: int = 1

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


@dataclass(frozen=True, slots=True)
class AuditEventListRow:
    """Default safe list projection for an audit event (D-08/D-15).

    The repository maps projected SQL rows into this dataclass and applies
    ``redact_normalized_event_message_tags`` to the projected message and
    tags before returning, so neither the router nor any caller ever sees
    raw payload or the full normalized event document on the default read
    path.
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
    incident_effect: str
    decision_summary: dict[str, Any]
    raw_payload_original_byte_length: int | None
    raw_payload_stored_byte_length: int | None
    raw_payload_truncated: bool
    redaction_version: int | None
    redacted_path_count: int | None
    raw_payload_hmac: str | None
    normalized_event_message: str
    normalized_event_tags: dict[str, Any] = field(default_factory=dict)


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

    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )


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


def compute_payload_hmac(payload: Any, hmac_key: str | Any) -> str:
    """Compute the keyed HMAC-SHA256 over the canonical pre-redaction payload.

    The HMAC is computed over the canonical JSON of the *pre-redaction*
    payload (D-07), so it stays stable when only the redaction output would
    differ and changes when the pre-redaction payload changes. ``hmac_key``
    may be a raw ``str`` or a ``pydantic.SecretStr``.
    """

    key = _coerce_hmac_key(hmac_key)
    canonical = canonical_json_bytes(payload)
    return hmac.new(key.encode("utf-8"), canonical, hashlib.sha256).hexdigest()


# ---------------------------------------------------------------------------
# Recursive redaction
# ---------------------------------------------------------------------------


def _secret_value_bytes(value: Any) -> str:
    """Return a lowercased string view of ``value`` for fragment matching."""

    if isinstance(value, str):
        return value.lower()
    return str(value).lower()


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


def _stored_byte_length(payload: Any) -> int:
    return len(canonical_json_bytes(payload))


def _semantic_cap_payload(payload: Any, max_bytes: int) -> tuple[Any, bool]:
    """Semantically cap ``payload`` so its canonical JSON fits ``max_bytes``.

    Implements D-06: capping is semantic, not arbitrary byte truncation of
    JSONB. When the redacted payload already fits, it is returned unchanged
    with ``truncated=False``. Otherwise the largest string values are
    progressively shortened; if a string is already no longer than the
    placeholder, the containing field is deleted entirely. If no reducible
    string remains, the payload collapses to a minimal envelope — first
    ``{"truncated":"[redacted]"}``, then ``{}`` if even that envelope
    exceeds the cap. Each loop iteration strictly reduces the serialized
    size, guaranteeing termination and preserving valid JSON throughout.
    """

    if _stored_byte_length(payload) <= max_bytes:
        return payload, False

    capped = _deep_copy_json(payload)
    previous_length = _stored_byte_length(capped)

    while _stored_byte_length(capped) > max_bytes:
        target_path = _largest_string_path(capped)
        if target_path is None:
            break
        container, key, current = target_path
        if isinstance(current, str) and len(current) > len(AUDIT_REDACTION_PLACEHOLDER):
            container[key] = current[: max(0, len(current) // 2)]
        else:
            # Shrink-to-placeholder would not reduce size; drop the field
            # outright so each iteration strictly shrinks the payload.
            del container[key]
        new_length = _stored_byte_length(capped)
        if new_length >= previous_length:
            # No further reduction possible; collapse to minimal envelope.
            break
        previous_length = new_length

    # Fallback envelopes: prefer a redacted truncation marker, then the
    # empty object if even the marker does not fit (e.g. very low test
    # cap or tiny original payload). ``{}`` is 2 bytes and fits any cap
    # that is at least 2 bytes (the Settings floor is 1_024).
    if _stored_byte_length(capped) > max_bytes:
        capped = {"truncated": AUDIT_REDACTION_PLACEHOLDER}
    if _stored_byte_length(capped) > max_bytes:
        capped = {}

    return capped, True


def _deep_copy_json(value: Any) -> Any:
    """Return a deep copy of a JSON-compatible value."""

    return json.loads(json.dumps(value, ensure_ascii=False))


def _largest_string_path(value: Any) -> tuple[Any, Any, str] | None:
    """Find the path to the largest string leaf in ``value``.

    Returns ``(container, key, current_value)`` where ``container[key]`` is
    the largest string leaf, or ``None`` when no string leaves remain.
    """

    best: tuple[Any, Any, str] | None = None
    best_len = -1

    def walk(node: Any) -> None:
        nonlocal best, best_len
        if isinstance(node, dict):
            for key, sub in node.items():
                if isinstance(sub, str):
                    if len(sub) > best_len:
                        best = (node, key, sub)
                        best_len = len(sub)
                else:
                    walk(sub)
        elif isinstance(node, list):
            for idx, sub in enumerate(node):
                if isinstance(sub, str):
                    if len(sub) > best_len:
                        best = (node, idx, sub)
                        best_len = len(sub)
                else:
                    walk(sub)

    walk(value)
    return best


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

    source = payload if payload is not None else {}
    original_byte_length = _stored_byte_length(source)
    payload_hmac = compute_payload_hmac(source, hmac_key)
    redacted = _redact_value(source)
    redacted_path_count = _count_redacted_leaves(source, redacted)
    effective_cap = min(max_bytes, original_byte_length)
    capped, truncated = _semantic_cap_payload(redacted, effective_cap)
    stored_byte_length = _stored_byte_length(capped)

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
# Read-time redaction for normalized_event message/tags
# ---------------------------------------------------------------------------


def _redact_normalized_event_message_tags(
    message: str | None,
    tags: dict[str, Any] | None,
) -> tuple[str, dict[str, Any]]:
    """Idempotently redact a projected normalized event message and tags.

    The repository and the router can both call this safely. Sensitive
    fragments in the message or in tag values are replaced with
    ``AUDIT_REDACTION_PLACEHOLDER``. Tag *keys* are preserved (renaming a
    key to ``[redacted]`` would violate the ``TagKey`` pattern); only the
    value is replaced. If a tag key itself is sensitive the value is still
    replaced, leaving the key intact so the response shape stays valid.
    """

    raw_message = message or ""
    safe_message = (
        AUDIT_REDACTION_PLACEHOLDER
        if (raw_message and _contains_sensitive_fragment(raw_message))
        else raw_message
    )
    # D-08: cap the projected message to the response-surface bound so
    # long non-sensitive messages (up to 4096 chars in NormalizedEvent)
    # do not fail strict AuditEventResponse validation (max 512).
    if len(safe_message) > AUDIT_MESSAGE_MAX_LENGTH:
        safe_message = safe_message[:AUDIT_MESSAGE_MAX_LENGTH]
    safe_tags: dict[str, Any] = {}
    if tags:
        for key, value in tags.items():
            key_text = key.lower() if isinstance(key, str) else str(key).lower()
            if _contains_sensitive_fragment(key_text) or (
                isinstance(value, str) and _contains_sensitive_fragment(value)
            ):
                safe_tags[key] = AUDIT_REDACTION_PLACEHOLDER
            else:
                safe_tags[key] = value
    return safe_message, safe_tags


def redact_normalized_event_message_tags(
    message: str | None,
    tags: dict[str, Any] | None,
) -> tuple[str, dict[str, Any]]:
    """Public alias for the read-time message/tag redactor (D-08)."""

    return _redact_normalized_event_message_tags(message, tags)


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
    UUIDs, and naive datetimes with ``ValueError("invalid audit event
    cursor")``. Unlike the incident cursor helper, this also catches
    ``binascii.Error`` and ``UnicodeDecodeError`` so malformed base64 or
    non-UTF-8 payloads cannot bypass the exception list.
    """

    try:
        padded = value + ("=" * (-len(value) % 4))
        payload = json.loads(base64.urlsafe_b64decode(padded.encode()).decode())
        accepted_at = datetime.fromisoformat(payload["accepted_at"])
        if accepted_at.tzinfo is None or accepted_at.utcoffset() is None:
            raise ValueError("cursor timestamp must be timezone-aware")
        return AuditEventCursor(accepted_at=accepted_at, id=UUID(payload["id"]))
    except UnicodeDecodeError as exc:
        # Valid urlsafe base64 that decodes to non-UTF-8 bytes (e.g. "____")
        # bypasses binascii.Error and fails at .decode(); catch explicitly.
        raise ValueError("invalid audit event cursor") from exc
    except (
        KeyError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
        binascii.Error,
    ) as exc:
        raise ValueError("invalid audit event cursor") from exc


# ---------------------------------------------------------------------------
# Repository helpers
# ---------------------------------------------------------------------------


# Default safe list projection (D-08/D-15). ``raw_payload`` and the full
# ``normalized_event`` document are deliberately NOT selected; only the
# bounded ``message`` and ``tags`` fields are projected from
# ``normalized_event``.
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
    IncidentEvent.normalized_event["tags"].label("normalized_event_tags"),
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
    if raw_payload_original_byte_length is None or raw_payload_stored_byte_length is None:
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
        stmt = stmt.where(IncidentEvent.event_timestamp >= filters.event_timestamp_since)
    if filters.event_timestamp_until is not None:
        stmt = stmt.where(IncidentEvent.event_timestamp < filters.event_timestamp_until)
    return stmt


def _row_to_audit_event_list_row(row: tuple[Any, ...]) -> AuditEventListRow:
    """Map a projected SQL row into a safe ``AuditEventListRow``.

    Normalizes JSONB arrays/objects returned by asyncpg into tuples/dicts
    before redaction so strict Pydantic validation in the API layer never
    fails on a list-where-tuple mismatch. Applies read-time redaction to
    the projected message and tags (D-08).
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
    ) = row

    incident_ids_tuple = tuple(incident_ids) if incident_ids is not None else ()
    decision_summary_dict = dict(decision_summary) if decision_summary is not None else {}
    # Normalize ``incident_ids`` inside the decision summary from a JSONB
    # list to a tuple so strict Pydantic validation
    # (``AuditDecisionSummary.incident_ids: BoundedStringTuple``) in the
    # API layer never rejects rows read from Postgres.
    if (
        isinstance(decision_summary_dict.get("incident_ids"), list)
    ):
        decision_summary_dict["incident_ids"] = tuple(
            decision_summary_dict["incident_ids"]
        )
    tags_dict = dict(normalized_event_tags) if normalized_event_tags is not None else {}

    safe_message, safe_tags = _redact_normalized_event_message_tags(
        normalized_event_message, tags_dict
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

    base_stmt = _apply_audit_filters(select(*_AUDIT_LIST_COLUMNS), filters)
    total = await session.scalar(
        select(func.count()).select_from(base_stmt.subquery())
    ) or 0

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
        page_stmt = page_stmt.order_by(
            IncidentEvent.accepted_at.desc(), IncidentEvent.id.desc()
        ).offset(filters.offset).limit(filters.limit)
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
