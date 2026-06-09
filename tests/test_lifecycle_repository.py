"""Testcontainers-backed incident lifecycle repository tests."""

from __future__ import annotations

import inspect
import subprocess
import sys
from datetime import datetime, timezone
from uuid import UUID

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.domain.events import Severity
from app.domain.incidents import IncidentStatus
from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident


def _run_alembic_upgrade(database_url: str) -> None:
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "-x", f"database_url={database_url}", "upgrade", "head"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Alembic upgrade failed: {result.stderr}")


@pytest.fixture(scope="module")
def postgres_url() -> str:
    with PostgresContainer("postgres:18-alpine") as postgres:
        url = postgres.get_connection_url()
        url = url.replace("postgresql+psycopg2://", "postgresql+asyncpg://")
        url = url.replace("postgresql://", "postgresql+asyncpg://")
        _run_alembic_upgrade(url)
        yield url


@pytest.fixture
async def db_session(postgres_url: str):
    engine = create_async_engine(postgres_url)
    async with AsyncSession(engine, expire_on_commit=False) as session:
        yield session
    await engine.dispose()

    cleanup = create_async_engine(postgres_url)
    async with AsyncSession(cleanup, expire_on_commit=False) as cs:
        await cs.execute(sa.text("TRUNCATE TABLE incidents RESTART IDENTITY CASCADE"))
        await cs.commit()
    await cleanup.dispose()


def _event_time() -> datetime:
    return datetime(2026, 6, 8, 12, 0, tzinfo=timezone.utc)


async def _seed_incident(
    session: AsyncSession,
    *,
    rule_name: str = "rule-a",
    group_key: str = "host:web-01",
    hosts: tuple[str, ...] = ("web-01",),
    services: tuple[str, ...] = (),
):
    incident = await upsert_open_incident(
        session,
        IncidentUpsertInput(
            rule_name=rule_name,
            group_key=group_key,
            severity=Severity.CRITICAL,
            event_time=_event_time(),
            summary="problem",
            affected_hosts=hosts,
            affected_services=services,
            fingerprint=f"problem:{rule_name}:{group_key}",
        ),
    )
    await session.commit()
    return incident


def _notes(context: dict[str, object]) -> dict[str, str]:
    return dict(context.get("notes") or {})


async def test_host_recovery_resolves_open_host_incident(db_session: AsyncSession) -> None:
    from app.persistence.incidents import resolve_host_recovery

    incident = await _seed_incident(db_session)

    results = await resolve_host_recovery(
        db_session,
        host="web-01",
        recovery_time=_event_time(),
        fingerprint="recovery-fp",
        source_id="icinga2:host:web-01",
    )
    await db_session.commit()

    assert len(results) == 1
    result = results[0]
    assert result.incident.id == incident.id
    assert result.effect == "resolved"
    assert result.transitioned_to == IncidentStatus.RESOLVED.value
    assert result.previous_host_count == 1
    assert result.previous_service_count == 0
    assert result.affected_object_removed is True
    assert result.incident.status == IncidentStatus.RESOLVED.value
    assert result.incident.resolved_at is not None
    assert result.incident.affected_hosts == []
    assert result.incident.affected_services == []
    notes = _notes(result.incident.decision_context)
    assert notes["lifecycle.reason"] == "source_recovery"
    assert notes["lifecycle.fingerprint"] == "recovery-fp"
    assert notes["lifecycle.source_id"] == "icinga2:host:web-01"
    assert notes["lifecycle.host"] == "web-01"
    assert "lifecycle.service" not in notes
    serialized = str(result.incident.decision_context).lower()
    for forbidden in ("raw_payload", "payload", "secret", "token", "password", "plugin_config"):
        assert forbidden not in serialized


async def test_host_recovery_shrinks_multi_host_incident_before_resolving(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import resolve_host_recovery

    incident = await _seed_incident(
        db_session,
        group_key="site:dc1",
        hosts=("web-01", "web-02"),
    )

    results = await resolve_host_recovery(
        db_session,
        host="web-01",
        recovery_time=_event_time(),
        fingerprint="recovery-fp",
        source_id="icinga2:host:web-01",
    )
    await db_session.commit()

    assert len(results) == 1
    result = results[0]
    assert result.incident.id == incident.id
    assert result.effect == "affected_set_shrunk"
    assert result.transitioned_to is None
    assert result.previous_host_count == 2
    assert result.previous_service_count == 0
    assert result.affected_object_removed is True
    assert result.incident.status == IncidentStatus.OPEN.value
    assert result.incident.resolved_at is None
    assert result.incident.affected_hosts == ["web-02"]


async def test_service_recovery_does_not_close_host_only_incident(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import resolve_service_recovery

    incident = await _seed_incident(db_session)

    results = await resolve_service_recovery(
        db_session,
        host="web-01",
        service="http",
        recovery_time=_event_time(),
        fingerprint="recovery-fp",
        source_id="icinga2:service:web-01:http",
    )
    await db_session.commit()

    assert results == ()
    current = await db_session.get(type(incident), incident.id)
    assert current is not None
    assert current.status == IncidentStatus.OPEN.value
    assert current.affected_hosts == ["web-01"]
    assert current.affected_services == []


async def test_service_recovery_requires_host_and_service_membership(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import resolve_service_recovery

    host_mismatch = await _seed_incident(
        db_session,
        rule_name="rule-b",
        group_key="service:other:http",
        hosts=("other",),
        services=("http",),
    )
    service_match = await _seed_incident(
        db_session,
        rule_name="rule-c",
        group_key="service:web-01:http",
        hosts=("web-01",),
        services=("http",),
    )

    results = await resolve_service_recovery(
        db_session,
        host="web-01",
        service="http",
        recovery_time=_event_time(),
        fingerprint="recovery-fp",
        source_id="icinga2:service:web-01:http",
    )
    await db_session.commit()

    assert len(results) == 1
    assert results[0].incident.id == service_match.id
    assert results[0].effect == "resolved"
    assert results[0].incident.affected_hosts == []
    assert results[0].incident.affected_services == []
    untouched = await db_session.get(type(host_mismatch), host_mismatch.id)
    assert untouched is not None
    assert untouched.status == IncidentStatus.OPEN.value
    assert untouched.affected_hosts == ["other"]
    assert untouched.affected_services == ["http"]


async def test_ack_open_incident_is_idempotent_metadata(db_session: AsyncSession) -> None:
    from app.persistence.incidents import ack_open_incident

    incident = await _seed_incident(db_session)

    first = await ack_open_incident(db_session, incident.id, operator="operator")
    await db_session.commit()
    second = await ack_open_incident(db_session, incident.id, operator="operator")
    await db_session.commit()

    assert first is not None
    assert second is not None
    assert first.incident.id == incident.id
    assert first.effect == "acknowledged"
    assert first.incident.status == IncidentStatus.OPEN.value
    assert first.incident.acknowledged_at is not None
    assert second.incident.status == IncidentStatus.OPEN.value
    assert second.incident.acknowledged_at == first.incident.acknowledged_at
    assert second.incident.acknowledged_by == "operator"
    count = (
        await db_session.execute(
            sa.text("SELECT COUNT(*) FROM incidents WHERE rule_name = :rule AND group_key = :group"),
            {"rule": incident.rule_name, "group": incident.group_key},
        )
    ).scalar_one()
    assert count == 1


async def test_manual_close_is_idempotent_and_frees_open_slot(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import close_open_incident

    incident = await _seed_incident(db_session)

    first = await close_open_incident(db_session, incident.id, operator="operator", reason="maintenance")
    await db_session.commit()
    second = await close_open_incident(db_session, incident.id, operator="operator", reason="maintenance")
    await db_session.commit()
    replacement = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name=incident.rule_name,
            group_key=incident.group_key,
            severity=Severity.WARNING,
            event_time=datetime(2026, 6, 8, 12, 5, tzinfo=timezone.utc),
            summary="new problem",
            affected_hosts=("web-01",),
            fingerprint="replacement-fp",
        ),
    )
    await db_session.commit()

    assert first is not None
    assert first.effect == "closed"
    assert first.transitioned_to == IncidentStatus.CLOSED.value
    assert first.incident.status == IncidentStatus.CLOSED.value
    assert first.incident.closed_at is not None
    assert second is not None
    assert second.effect == "noop"
    assert second.incident.id == incident.id
    assert second.incident.status == IncidentStatus.CLOSED.value
    assert replacement.id != incident.id
    assert replacement.status == IncidentStatus.OPEN.value


def test_lifecycle_repository_source_is_postgresql_only_and_non_insert_path() -> None:
    from app.persistence import incidents as incidents_module

    source = inspect.getsource(incidents_module)
    assert "sqlite" not in source.lower()
    for forbidden in ("raw_payload", "plugin_config", "password", "token", "secret"):
        assert forbidden not in source.lower()
    assert "def resolve_host_recovery" in source
    assert "def resolve_service_recovery" in source
    recovery_source = inspect.getsource(incidents_module.resolve_host_recovery)
    recovery_source += inspect.getsource(incidents_module.resolve_service_recovery)
    assert "insert(" not in recovery_source
    assert ".with_for_update()" in recovery_source
