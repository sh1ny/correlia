"""Testcontainers-backed persistence tests for the audit event repository."""

from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.domain.audit import AuditDecisionSummary, AuditEventListFilters
from app.domain.events import EventType, NormalizedEvent, Severity
from app.persistence.audit import (
    AuditEventCursor,
    IncidentEventListPage,
    compute_payload_hmac,
    decode_audit_cursor,
    encode_audit_cursor,
    insert_incident_event,
    list_incident_events,
    redact_payload,
)
from app.persistence.models import IncidentEvent


_TEST_HMAC_KEY = "test-audit-hmac-key"


def _run_alembic_upgrade(database_url: str) -> None:
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "alembic",
            "-x",
            f"database_url={database_url}",
            "upgrade",
            "head",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Alembic upgrade failed: {result.stderr}")


@pytest.fixture(scope="module")
def postgres_url(postgres_image: str) -> str:
    with PostgresContainer(postgres_image, driver="asyncpg") as postgres:
        url = postgres.get_connection_url()
        _run_alembic_upgrade(url)
        yield url


@pytest.fixture
async def db_session(postgres_url: str):
    engine = create_async_engine(postgres_url)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    session = maker()
    yield session
    await session.close()
    await engine.dispose()


@pytest.fixture(autouse=True)
async def clean_audit_events(db_session: AsyncSession):
    yield
    await db_session.execute(sa.text("TRUNCATE incident_events"))
    await db_session.commit()


def _base_event(
    payload: dict[str, Any], *, raw_cap: int = 65_536
) -> tuple[NormalizedEvent, dict[str, Any], Any]:
    """Build a normalized event, raw payload, and redacted payload metadata."""
    event = NormalizedEvent(
        fingerprint="fp-" + payload.get("host", "test"),
        source_id="icinga2",
        host=payload.get("host", "test-host"),
        service=payload.get("service", "test-service"),
        severity=Severity(payload.get("severity", "CRITICAL")),
        event_type=EventType(payload.get("event_type", "PROBLEM")),
        timestamp=datetime.now(timezone.utc),
        tags={"source": "icinga2"},
        message=payload.get("message", "test message"),
    )
    redacted = redact_payload(payload, max_bytes=raw_cap, hmac_key=_TEST_HMAC_KEY)
    return event, event.model_dump(mode="json"), redacted


def _decision_summary(
    *,
    decision_kind: str = "problem",
    incident_effect: str = "inserted",
    no_dispatch_reason: str | None = None,
    incident_ids: tuple[str, ...] = (),
) -> dict[str, Any]:
    summary = AuditDecisionSummary(
        decision_kind=decision_kind,  # type: ignore[arg-type]
        incident_effect=incident_effect,  # type: ignore[arg-type]
        notification_intent="dispatch_planned",
        no_dispatch_reason=no_dispatch_reason,
        incident_ids=incident_ids,
    )
    return summary.model_dump(mode="json")


async def _seed_event(
    session: AsyncSession,
    *,
    payload: dict[str, Any] | None = None,
    decision_summary: dict[str, Any] | None = None,
    normalized_event: dict[str, Any] | None = None,
    accepted_at: datetime | None = None,
    raw_cap: int = 65_536,
) -> UUID:
    payload = payload or {
        "host": "test-host",
        "service": "test-service",
        "severity": "CRITICAL",
        "event_type": "PROBLEM",
        "message": "test message",
    }
    event_obj, normalized, redacted = _base_event(payload, raw_cap=raw_cap)
    summary = decision_summary or _decision_summary()

    event = await insert_incident_event(
        session,
        event_timestamp=event_obj.timestamp,
        source_id=event_obj.source_id,
        fingerprint=event_obj.fingerprint,
        event_type=event_obj.event_type.value,
        severity=event_obj.severity.value,
        host=event_obj.host,
        service=event_obj.service,
        incident_ids=list(summary.get("incident_ids", ())),
        incident_effect=summary["incident_effect"],
        decision_summary=summary,
        normalized_event=normalized_event or normalized,
        raw_payload=redacted.payload,
        raw_payload_original_byte_length=redacted.original_byte_length,
        raw_payload_stored_byte_length=redacted.stored_byte_length,
        raw_payload_truncated=redacted.truncated,
        redaction_version=redacted.redaction_version,
        redacted_path_count=redacted.redacted_path_count,
        raw_payload_hmac=redacted.payload_hmac,
    )
    if accepted_at is not None:
        await session.execute(
            sa.update(IncidentEvent)
            .where(IncidentEvent.id == event.id)
            .values(accepted_at=accepted_at)
        )
    await session.commit()
    return event.id


async def test_insert_incident_event_persists_non_null_raw_payload_metadata(
    db_session: AsyncSession,
) -> None:
    event_id = await _seed_event(db_session)

    row = await db_session.execute(
        sa.select(IncidentEvent).where(IncidentEvent.id == event_id)
    )
    persisted = row.scalar_one()

    assert persisted.id is not None
    assert persisted.raw_payload is not None
    assert persisted.raw_payload_original_byte_length is not None
    assert persisted.raw_payload_stored_byte_length is not None
    assert persisted.raw_payload_truncated is not None
    assert persisted.redaction_version is not None
    assert persisted.redacted_path_count is not None
    assert persisted.raw_payload_hmac
    assert persisted.accepted_at is not None


@pytest.mark.parametrize(
    ("payload", "cap", "expected_payload", "redacted_paths"),
    [
        ({"password": "x", "host": "db"}, 2, {}, 1),
        (
            {"password": "x", "padding": "p" * 200},
            65_536,
            {"password": "[redacted]"},
            1,
        ),
        ({"host": "db", "large": "🙂" * 1_000}, 1_024, {"host": "db"}, 0),
    ],
)
async def test_capped_audit_metadata_satisfies_postgres_check_constraints(
    db_session: AsyncSession,
    payload: dict[str, Any],
    cap: int,
    expected_payload: dict[str, Any],
    redacted_paths: int,
) -> None:
    # _seed_event commits the row; PostgreSQL validates the existing CHECK
    # constraints (object payload, non-negative lengths, stored <= original,
    # positive version, and non-negative count) on the real JSONB column.
    event_id = await _seed_event(db_session, payload=payload, raw_cap=cap)
    persisted = await db_session.get(IncidentEvent, event_id)
    assert persisted is not None

    original_bytes = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    stored_bytes = json.dumps(
        persisted.raw_payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    assert persisted.raw_payload == expected_payload
    assert persisted.raw_payload_original_byte_length == len(original_bytes)
    assert persisted.raw_payload_stored_byte_length == len(stored_bytes)
    assert len(stored_bytes) <= min(cap, len(original_bytes))
    assert persisted.raw_payload_truncated is True
    assert persisted.redaction_version == 2
    assert persisted.redacted_path_count == redacted_paths
    assert persisted.raw_payload_hmac == compute_payload_hmac(payload, _TEST_HMAC_KEY)


async def test_legacy_redaction_version_metadata_survives_new_writes_and_reads(
    db_session: AsyncSession,
) -> None:
    old_id = await _seed_event(db_session, payload={"host": "legacy"})
    await db_session.execute(
        sa.update(IncidentEvent)
        .where(IncidentEvent.id == old_id)
        .values(redaction_version=1)
    )
    await db_session.commit()
    old_row = await db_session.get(IncidentEvent, old_id)
    assert old_row is not None
    old_metadata = (
        old_row.raw_payload,
        old_row.raw_payload_original_byte_length,
        old_row.raw_payload_stored_byte_length,
        old_row.raw_payload_truncated,
        old_row.redaction_version,
        old_row.redacted_path_count,
        old_row.raw_payload_hmac,
    )

    new_id = await _seed_event(db_session, payload={"host": "new"})
    await list_incident_events(db_session, AuditEventListFilters(limit=10))
    db_session.expire_all()
    persisted_old = await db_session.get(IncidentEvent, old_id)
    persisted_new = await db_session.get(IncidentEvent, new_id)
    assert persisted_old is not None
    assert persisted_new is not None
    assert old_metadata == (
        persisted_old.raw_payload,
        persisted_old.raw_payload_original_byte_length,
        persisted_old.raw_payload_stored_byte_length,
        persisted_old.raw_payload_truncated,
        persisted_old.redaction_version,
        persisted_old.redacted_path_count,
        persisted_old.raw_payload_hmac,
    )
    assert persisted_old.redaction_version == 1
    assert persisted_new.redaction_version == 2


async def test_insert_incident_event_rejects_null_raw_payload_metadata() -> None:
    from unittest.mock import AsyncMock

    session = AsyncMock()
    with pytest.raises(ValueError, match="raw_payload must be a JSON object"):
        await insert_incident_event(
            session,
            event_timestamp=datetime.now(timezone.utc),
            source_id="icinga2",
            fingerprint="fp-1",
            event_type="PROBLEM",
            severity="CRITICAL",
            host="h",
            service=None,
            incident_ids=[],
            incident_effect="none",
            decision_summary={},
            normalized_event={},
            raw_payload=None,  # type: ignore[arg-type]
            raw_payload_original_byte_length=10,
            raw_payload_stored_byte_length=10,
            raw_payload_truncated=False,
            redaction_version=1,
            redacted_path_count=0,
            raw_payload_hmac="hmac",
        )


async def test_list_incident_events_uses_safe_projection(
    db_session: AsyncSession,
) -> None:
    payload = {
        "host": "safe-host",
        "service": "safe-service",
        "severity": "CRITICAL",
        "event_type": "PROBLEM",
        "message": "hello secret-password here",
        "api_key": "super-secret",
    }
    await _seed_event(db_session, payload=payload)

    page = await list_incident_events(db_session, AuditEventListFilters(limit=10))

    assert len(page.events) == 1
    row = page.events[0]
    assert not hasattr(row, "raw_payload")
    assert not hasattr(row, "normalized_event")
    assert "secret-password" not in row.normalized_event_message
    assert "[redacted]" in row.normalized_event_message
    assert row.normalized_event_tags == {"source": "icinga2"}
    assert row.normalized_event_tags_omitted is False
    assert row.normalized_event_tags_omission_reasons == frozenset()


async def _replace_legacy_tags(
    session: AsyncSession, event_id: UUID, tags_json: str
) -> None:
    # A text parameter is cast inside PostgreSQL; Python never parses the
    # 5,000-digit number as an integer, nor decodes the historical JSONB.
    await session.execute(
        sa.text(
            "UPDATE incident_events SET normalized_event = "
            "jsonb_set(normalized_event, '{tags}', CAST(:tags AS jsonb), true) "
            "WHERE id = CAST(:event_id AS uuid)"
        ),
        {"tags": tags_json, "event_id": str(event_id)},
    )
    await session.commit()


async def test_legacy_object_entries_are_projected_without_mutating_storage(
    db_session: AsyncSession,
) -> None:
    valid_id = await _seed_event(db_session)
    source = {
        **{f"k{i:03}": "value" for i in range(129)},
        "oversized": "v" * 257,
        "invalid key": "no",
        "a" * 65: "no",
        "safe": "contains token",
        "api_key": "private",
        "nested": {"password": "private"},
        "missing": None,
    }
    await _replace_legacy_tags(db_session, valid_id, json.dumps(source))
    page = await list_incident_events(db_session, AuditEventListFilters(limit=10))
    row = page.events[0]

    assert page.total == 1
    assert len(row.normalized_event_tags) == 32
    assert list(row.normalized_event_tags) == sorted(row.normalized_event_tags)
    assert row.normalized_event_tags_omission_reasons == {
        "size_limit",
        "invalid_legacy_shape",
        "sensitive_key",
    }
    assert row.normalized_event_tags_omitted
    stored = await db_session.scalar(
        sa.select(IncidentEvent.normalized_event["tags"]).where(
            IncidentEvent.id == valid_id
        )
    )
    assert stored == source


async def test_preexisting_aggregate_bytes_above_ingress_limit_keep_siblings(
    db_session: AsyncSession,
) -> None:
    event_id = await _seed_event(db_session)
    source = {f"k{i:03}": "x" * 200 for i in range(110)}
    assert 16_384 < len(json.dumps(source, separators=(",", ":")).encode()) < 32_768
    await _replace_legacy_tags(db_session, event_id, json.dumps(source))

    page = await list_incident_events(db_session, AuditEventListFilters(limit=10))
    projected = page.events[0]
    assert projected.normalized_event_tags == {f"k{i:03}": "x" * 200 for i in range(19)}
    assert projected.normalized_event_tags_omission_reasons == {"size_limit"}
    stored = await db_session.scalar(
        sa.select(IncidentEvent.normalized_event["tags"]).where(
            IncidentEvent.id == event_id
        )
    )
    assert stored == source


async def test_sql_guard_omits_oversized_object_without_driver_materialization(
    db_session: AsyncSession,
) -> None:
    event_id = await _seed_event(db_session, payload={"host": "oversized"})
    before = await db_session.execute(
        sa.select(
            IncidentEvent.raw_payload_hmac,
            IncidentEvent.raw_payload_original_byte_length,
            IncidentEvent.raw_payload_stored_byte_length,
            IncidentEvent.raw_payload_truncated,
            IncidentEvent.redaction_version,
        ).where(IncidentEvent.id == event_id)
    )
    raw_metadata = before.one()
    giant = {"safe": "kept only in storage", "large": "z" * 33_000}
    await _replace_legacy_tags(db_session, event_id, json.dumps(giant))

    page = await list_incident_events(db_session, AuditEventListFilters(limit=10))
    row = page.events[0]
    assert page.total == 1
    assert row.normalized_event_tags == {}
    assert row.normalized_event_tags_omitted
    assert row.normalized_event_tags_omission_reasons == {"size_limit"}
    after = await db_session.execute(
        sa.select(
            IncidentEvent.raw_payload_hmac,
            IncidentEvent.raw_payload_original_byte_length,
            IncidentEvent.raw_payload_stored_byte_length,
            IncidentEvent.raw_payload_truncated,
            IncidentEvent.redaction_version,
            IncidentEvent.normalized_event["tags"],
        ).where(IncidentEvent.id == event_id)
    )
    assert (*raw_metadata, giant) == tuple(after.one())


@pytest.mark.parametrize(
    ("target_bytes", "expected_tags", "expected_reasons"),
    [
        pytest.param(
            32_768,
            {"safe": "ok"},
            {"invalid_legacy_shape"},
            id="exactly-32768-bytes",
        ),
        pytest.param(32_769, {}, {"size_limit"}, id="32769-bytes"),
    ],
)
async def test_sql_tag_guard_uses_server_text_byte_boundary(
    db_session: AsyncSession,
    target_bytes: int,
    expected_tags: dict[str, str],
    expected_reasons: set[str],
) -> None:
    event_id = await _seed_event(db_session)
    # JSONB renders its own text (including spacing/key order); measure that
    # representation rather than assuming json.dumps has the same byte length.
    empty_large = json.dumps({"safe": "ok", "zz_large": ""})
    base_text = await db_session.scalar(
        sa.text("SELECT CAST(CAST(:tags AS jsonb) AS text)"),
        {"tags": empty_large},
    )
    # At the inclusive SQL cap this legacy value exceeds the 256-character
    # event-tag limit; only the over-cap object is omitted for "size_limit".
    large_value = "x" * (target_bytes - len(base_text.encode("utf-8")))
    await _replace_legacy_tags(
        db_session, event_id, json.dumps({"safe": "ok", "zz_large": large_value})
    )
    stored = await db_session.execute(
        sa.text(
            "SELECT (normalized_event -> 'tags')::text, "
            "octet_length((normalized_event -> 'tags')::text) "
            "FROM incident_events WHERE id = CAST(:event_id AS uuid)"
        ),
        {"event_id": str(event_id)},
    )
    server_text, server_bytes = stored.one()
    assert server_bytes == len(server_text.encode("utf-8")) == target_bytes

    page = await list_incident_events(db_session, AuditEventListFilters(limit=10))
    assert page.total == 1
    row = page.events[0]
    assert row.normalized_event_tags == expected_tags
    assert row.normalized_event_tags_omitted
    assert row.normalized_event_tags_omission_reasons == expected_reasons


async def test_sql_tag_guard_counts_multibyte_server_text_octets(
    db_session: AsyncSession,
) -> None:
    event_id = await _seed_event(db_session)
    await _replace_legacy_tags(
        db_session,
        event_id,
        json.dumps({"safe": "ok", "zz_large": "é" * 16_384}, ensure_ascii=False),
    )
    stored = await db_session.execute(
        sa.text(
            "SELECT (normalized_event -> 'tags')::text, "
            "length((normalized_event -> 'tags')::text), "
            "octet_length((normalized_event -> 'tags')::text) "
            "FROM incident_events WHERE id = CAST(:event_id AS uuid)"
        ),
        {"event_id": str(event_id)},
    )
    server_text, server_chars, server_bytes = stored.one()
    assert "é" in server_text
    assert server_chars == len(server_text) < 32_768
    assert server_bytes == len(server_text.encode("utf-8")) > 32_768

    page = await list_incident_events(db_session, AuditEventListFilters(limit=10))
    assert page.total == 1
    row = page.events[0]
    assert row.normalized_event_tags == {}
    assert row.normalized_event_tags_omitted
    assert row.normalized_event_tags_omission_reasons == {"size_limit"}


async def test_sql_filters_nonstring_numeric_before_driver_json_decode(
    db_session: AsyncSession,
) -> None:
    event_id = await _seed_event(db_session)
    big_number = "9" * 5_000
    await _replace_legacy_tags(
        db_session, event_id, '{"safe":"still here","numeric":' + big_number + "}"
    )

    page = await list_incident_events(db_session, AuditEventListFilters(limit=10))
    assert page.events[0].normalized_event_tags == {"safe": "still here"}
    assert page.events[0].normalized_event_tags_omission_reasons == {
        "invalid_legacy_shape"
    }
    stored = await db_session.execute(
        sa.text(
            "SELECT normalized_event -> 'tags' ->> 'numeric', "
            "normalized_event -> 'tags' ->> 'safe' "
            "FROM incident_events WHERE id = CAST(:event_id AS uuid)"
        ),
        {"event_id": str(event_id)},
    )
    assert tuple(stored.one()) == (big_number, "still here")


@pytest.mark.parametrize(
    ("tags_json", "expected_tags", "reasons"),
    [
        (
            '{"safe":"ok","nested":{"secret":"x"}}',
            {"safe": "ok"},
            {"invalid_legacy_shape"},
        ),
        ('{"safe":"ok","number":3}', {"safe": "ok"}, {"invalid_legacy_shape"}),
        ("[]", {}, {"invalid_legacy_shape"}),
        ('"string"', {}, {"invalid_legacy_shape"}),
        ("null", {}, {"invalid_legacy_shape"}),
    ],
)
async def test_legacy_tag_containers_and_values_remain_readable(
    db_session: AsyncSession,
    tags_json: str,
    expected_tags: dict[str, str],
    reasons: set[str],
) -> None:
    event_id = await _seed_event(db_session)
    await _replace_legacy_tags(db_session, event_id, tags_json)
    page = await list_incident_events(db_session, AuditEventListFilters(limit=10))
    assert page.total == 1
    assert page.events[0].normalized_event_tags == expected_tags
    assert page.events[0].normalized_event_tags_omission_reasons == reasons


async def test_missing_historical_tag_field_remains_readable(
    db_session: AsyncSession,
) -> None:
    event_id = await _seed_event(db_session)
    await db_session.execute(
        sa.text(
            "UPDATE incident_events SET normalized_event = normalized_event - 'tags' "
            "WHERE id = CAST(:event_id AS uuid)"
        ),
        {"event_id": str(event_id)},
    )
    await db_session.commit()
    page = await list_incident_events(db_session, AuditEventListFilters(limit=10))
    assert page.events[0].normalized_event_tags == {}
    assert page.events[0].normalized_event_tags_omitted
    assert page.events[0].normalized_event_tags_omission_reasons == {
        "invalid_legacy_shape"
    }


async def test_audit_cursor_round_trips_and_paginates(
    db_session: AsyncSession,
) -> None:
    now = datetime.now(timezone.utc)
    for i in range(3):
        await _seed_event(
            db_session,
            payload={
                "host": f"host-{i}",
                "service": "svc",
                "severity": "CRITICAL",
                "event_type": "PROBLEM",
                "message": f"msg {i}",
            },
            accepted_at=now - timedelta(minutes=i),
        )

    first_page = await list_incident_events(db_session, AuditEventListFilters(limit=2))
    assert isinstance(first_page, IncidentEventListPage)
    assert len(first_page.events) == 2
    assert first_page.next_cursor is not None

    second_page = await list_incident_events(
        db_session,
        AuditEventListFilters(limit=2, cursor=first_page.next_cursor),
    )
    assert len(second_page.events) == 1
    assert second_page.next_cursor is None


async def test_incident_id_filter_uses_jsonb_containment(
    db_session: AsyncSession,
) -> None:
    incident_a = "11111111-1111-1111-1111-111111111111"
    incident_b = "22222222-2222-2222-2222-222222222222"
    await _seed_event(
        db_session,
        payload={
            "host": "a",
            "service": "svc",
            "severity": "CRITICAL",
            "event_type": "PROBLEM",
            "message": "a",
        },
        decision_summary=_decision_summary(incident_ids=(incident_a,)),
    )
    await _seed_event(
        db_session,
        payload={
            "host": "b",
            "service": "svc",
            "severity": "CRITICAL",
            "event_type": "PROBLEM",
            "message": "b",
        },
        decision_summary=_decision_summary(incident_ids=(incident_b,)),
    )

    page = await list_incident_events(
        db_session,
        AuditEventListFilters(incident_id=UUID(incident_a), limit=10),
    )
    assert len(page.events) == 1
    assert page.events[0].host == "a"


async def test_has_incident_false_maps_only_to_incident_effect_none(
    db_session: AsyncSession,
) -> None:
    await _seed_event(
        db_session,
        payload={
            "host": "noop",
            "service": "svc",
            "severity": "CRITICAL",
            "event_type": "PROBLEM",
            "message": "noop",
        },
        decision_summary=_decision_summary(
            incident_effect="none",
            no_dispatch_reason="below_threshold",
        ),
    )
    await _seed_event(
        db_session,
        payload={
            "host": "problem",
            "service": "svc",
            "severity": "CRITICAL",
            "event_type": "PROBLEM",
            "message": "problem",
        },
        decision_summary=_decision_summary(incident_effect="inserted"),
    )

    false_page = await list_incident_events(
        db_session, AuditEventListFilters(has_incident=False, limit=10)
    )
    assert len(false_page.events) == 1
    assert false_page.events[0].host == "noop"

    true_page = await list_incident_events(
        db_session, AuditEventListFilters(has_incident=True, limit=10)
    )
    assert len(true_page.events) == 1
    assert true_page.events[0].host == "problem"


async def test_no_dispatch_reason_filter_reads_decision_summary(
    db_session: AsyncSession,
) -> None:
    await _seed_event(
        db_session,
        payload={
            "host": "below",
            "service": "svc",
            "severity": "CRITICAL",
            "event_type": "PROBLEM",
            "message": "below",
        },
        decision_summary=_decision_summary(
            incident_effect="inserted",
            no_dispatch_reason="below_threshold",
        ),
    )
    await _seed_event(
        db_session,
        payload={
            "host": "replay",
            "service": "svc",
            "severity": "CRITICAL",
            "event_type": "PROBLEM",
            "message": "replay",
        },
        decision_summary=_decision_summary(
            incident_effect="inserted",
            no_dispatch_reason="replay",
        ),
    )

    page = await list_incident_events(
        db_session,
        AuditEventListFilters(no_dispatch_reason="below_threshold", limit=10),
    )
    assert len(page.events) == 1
    assert page.events[0].host == "below"


async def test_offset_pagination_reports_total_and_offset(
    db_session: AsyncSession,
) -> None:
    now = datetime.now(timezone.utc)
    for i in range(3):
        await _seed_event(
            db_session,
            payload={
                "host": f"off-{i}",
                "service": "svc",
                "severity": "CRITICAL",
                "event_type": "PROBLEM",
                "message": f"msg {i}",
            },
            accepted_at=now - timedelta(minutes=i),
        )

    page = await list_incident_events(
        db_session, AuditEventListFilters(offset=1, limit=2)
    )
    assert page.total == 3
    assert page.offset == 1
    assert len(page.events) == 2
    assert page.next_cursor is None


async def test_scalar_and_timestamp_filters(
    db_session: AsyncSession,
) -> None:
    now = datetime.now(timezone.utc)
    await _seed_event(
        db_session,
        payload={
            "host": "filter-host",
            "service": "filter-service",
            "severity": "WARNING",
            "event_type": "RECOVERY",
            "message": "filter msg",
        },
        accepted_at=now - timedelta(minutes=5),
        decision_summary=_decision_summary(
            decision_kind="recovery",
            incident_effect="resolved",
        ),
    )
    await _seed_event(
        db_session,
        payload={
            "host": "other-host",
            "service": "other-service",
            "severity": "CRITICAL",
            "event_type": "PROBLEM",
            "message": "other msg",
        },
        accepted_at=now - timedelta(hours=1),
        decision_summary=_decision_summary(incident_effect="inserted"),
    )

    page = await list_incident_events(
        db_session,
        AuditEventListFilters(
            source_id="icinga2",
            fingerprint="fp-filter-host",
            event_type=EventType.RECOVERY,
            severity=Severity.WARNING,
            host="filter-host",
            service="filter-service",
            accepted_since=now - timedelta(minutes=10),
            accepted_until=now,
            event_timestamp_since=now - timedelta(minutes=10),
            event_timestamp_until=now + timedelta(minutes=1),
            limit=10,
        ),
    )
    assert len(page.events) == 1
    assert page.events[0].host == "filter-host"
    assert page.events[0].event_type == EventType.RECOVERY.value


async def test_decode_audit_cursor_rejects_invalid_or_naive_values() -> None:
    with pytest.raises(ValueError):
        decode_audit_cursor("not-valid-base64!!!")
    with pytest.raises(ValueError):
        decode_audit_cursor("____")
    with pytest.raises(ValueError):
        decode_audit_cursor(
            encode_audit_cursor(
                AuditEventCursor(
                    accepted_at=datetime(2024, 1, 1, 0, 0, 0),
                    id=UUID("12345678-1234-5678-1234-567812345678"),
                )
            )
        )

    cursor = AuditEventCursor(
        accepted_at=datetime(2024, 1, 1, 0, 0, 0, tzinfo=timezone.utc),
        id=UUID("12345678-1234-5678-1234-567812345678"),
    )
    decoded = decode_audit_cursor(encode_audit_cursor(cursor))
    assert decoded == cursor
