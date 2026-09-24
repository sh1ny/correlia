"""Testcontainers-backed persistence tests for the audit event repository."""

from __future__ import annotations

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
    decode_audit_cursor,
    encode_audit_cursor,
    insert_incident_event,
    list_incident_events,
    redact_payload,
)
from app.persistence.models import IncidentEvent


pytestmark = pytest.mark.anyio


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
def postgres_url() -> str:
    with PostgresContainer("postgres:16", driver="asyncpg") as postgres:
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


def _base_event(payload: dict[str, Any]) -> tuple[NormalizedEvent, dict[str, Any], Any]:
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
    redacted = redact_payload(payload, max_bytes=65_536, hmac_key=_TEST_HMAC_KEY)
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
) -> UUID:
    payload = payload or {
        "host": "test-host",
        "service": "test-service",
        "severity": "CRITICAL",
        "event_type": "PROBLEM",
        "message": "test message",
    }
    event_obj, normalized, redacted = _base_event(payload)
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
    assert row.normalized_event_tags.get("source") == "icinga2"


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
