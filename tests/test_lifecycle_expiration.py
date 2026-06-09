"""Testcontainers-backed stale incident expiration tests."""

from __future__ import annotations

import inspect
import subprocess
import sys
from datetime import datetime, timezone

import pytest
from sqlalchemy import func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import sessionmaker
from testcontainers.postgres import PostgresContainer

from app.domain.events import Severity
from app.domain.incidents import DecisionContext, IncidentStatus
from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident
from app.persistence.models import Incident


def _run_alembic_upgrade(database_url: str) -> None:
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        env={"DATABASE_URL": database_url},
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Alembic upgrade failed: {result.stderr}")


_migrated_url: str | None = None


@pytest.fixture(scope="module")
def postgres_url() -> str:
    global _migrated_url
    with PostgresContainer("postgres:18-alpine") as postgres:
        url = postgres.get_connection_url().replace(
            "postgresql+psycopg2://", "postgresql+asyncpg://"
        )
        if _migrated_url != url:
            _run_alembic_upgrade(url)
            _migrated_url = url
        yield url


@pytest.fixture
async def db_session(postgres_url: str):
    engine = create_async_engine(postgres_url)
    async_session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with async_session() as session:
        await session.execute(text("TRUNCATE TABLE incidents RESTART IDENTITY CASCADE"))
        await session.commit()
        yield session
        await session.rollback()
    cleanup = create_async_engine(postgres_url, isolation_level="AUTOCOMMIT")
    async with cleanup.begin() as connection:
        await connection.execute(text("TRUNCATE TABLE incidents RESTART IDENTITY CASCADE"))
    await engine.dispose()
    await cleanup.dispose()


def _input(rule_name: str, window_seconds: int, *, host: str = "db-1") -> IncidentUpsertInput:
    return IncidentUpsertInput(
        rule_name=rule_name,
        group_key=host,
        severity=Severity.CRITICAL,
        event_time=datetime(2026, 1, 1, tzinfo=timezone.utc),
        summary=f"{host} down",
        affected_hosts=(host,),
        decision_context=DecisionContext(
            fingerprint=f"fingerprint-{rule_name}",
            source_id="icinga2",
            notes={"rule_name": rule_name},
        ),
        fingerprint=f"fingerprint-{rule_name}",
        threshold_count=1,
        window_seconds=window_seconds,
    )


async def _set_db_relative_last_update(
    db_session: AsyncSession,
    incident_id,
    interval_literal: str,
) -> None:
    await db_session.execute(
        update(Incident)
        .where(Incident.id == incident_id)
        .values(
            last_update_time=text(interval_literal),
            updated_at=func.now(),
        )
    )
    await db_session.commit()


async def test_expiration_uses_database_time_and_rule_window(db_session: AsyncSession) -> None:
    from app.persistence.incidents import expire_stale_incidents

    short_window = await upsert_open_incident(db_session, _input("short-window", 10, host="db-1"))
    long_window = await upsert_open_incident(db_session, _input("long-window", 30, host="db-2"))
    await db_session.commit()
    await _set_db_relative_last_update(
        db_session,
        short_window.id,
        "now() - interval '20 seconds'",
    )
    await _set_db_relative_last_update(
        db_session,
        long_window.id,
        "now() - interval '20 seconds'",
    )

    expired = await expire_stale_incidents(db_session, limit=10)
    await db_session.commit()

    assert [incident.id for incident in expired] == [short_window.id]
    rows = (
        await db_session.execute(select(Incident).order_by(Incident.rule_name))
    ).scalars().all()
    assert [(row.rule_name, row.status) for row in rows] == [
        ("long-window", IncidentStatus.OPEN.value),
        ("short-window", IncidentStatus.CLOSED.value),
    ]


async def test_expiration_closes_only_stale_open_rows(db_session: AsyncSession) -> None:
    from app.persistence.incidents import close_open_incident, expire_stale_incidents

    stale_open = await upsert_open_incident(db_session, _input("stale-open", 5, host="db-1"))
    fresh_open = await upsert_open_incident(db_session, _input("fresh-open", 60, host="db-2"))
    closed = await upsert_open_incident(db_session, _input("already-closed", 5, host="db-3"))
    resolved = await upsert_open_incident(db_session, _input("already-resolved", 5, host="db-4"))
    await db_session.commit()

    await close_open_incident(db_session, closed.id, operator="operator", reason="manual")
    await db_session.execute(
        update(Incident)
        .where(Incident.id == resolved.id)
        .values(status=IncidentStatus.RESOLVED.value, resolved_at=func.now(), updated_at=func.now())
    )
    await _set_db_relative_last_update(db_session, stale_open.id, "now() - interval '10 seconds'")
    await _set_db_relative_last_update(db_session, fresh_open.id, "now() - interval '10 seconds'")
    await _set_db_relative_last_update(db_session, closed.id, "now() - interval '10 seconds'")
    await _set_db_relative_last_update(db_session, resolved.id, "now() - interval '10 seconds'")

    expired = await expire_stale_incidents(db_session, limit=10)
    await db_session.commit()

    assert [incident.id for incident in expired] == [stale_open.id]
    rows = {
        row.rule_name: row
        for row in (await db_session.execute(select(Incident))).scalars().all()
    }
    assert rows["stale-open"].status == IncidentStatus.CLOSED.value
    assert rows["stale-open"].closed_at is not None
    assert rows["stale-open"].resolved_at is None
    assert rows["fresh-open"].status == IncidentStatus.OPEN.value
    assert rows["already-closed"].status == IncidentStatus.CLOSED.value
    assert rows["already-resolved"].status == IncidentStatus.RESOLVED.value


async def test_expiration_context_is_non_secret(db_session: AsyncSession) -> None:
    from app.persistence.incidents import expire_stale_incidents

    stale = await upsert_open_incident(db_session, _input("safe-rule", 5, host="db-1"))
    await db_session.commit()
    await _set_db_relative_last_update(db_session, stale.id, "now() - interval '10 seconds'")

    expired = await expire_stale_incidents(db_session, limit=10)
    await db_session.commit()

    assert len(expired) == 1
    notes = expired[0].decision_context["notes"]
    assert notes["lifecycle.reason"] == "expired"
    assert notes["lifecycle.rule_name"] == "safe-rule"
    assert notes["lifecycle.window_seconds"] == "5"
    serialized = str(expired[0].decision_context).lower()
    for forbidden in (
        "raw_payload",
        "password",
        "token",
        "secret",
        "smtp transcript",
        "traceback",
        "plugin_options",
    ):
        assert forbidden not in serialized


def test_expiration_source_uses_database_time_not_app_clock() -> None:
    import app.persistence.incidents as incidents_module

    source = inspect.getsource(incidents_module.expire_stale_incidents)
    assert "func.now()" in source or "CURRENT_TIMESTAMP" in source or "statement_timestamp" in source
    assert "datetime.now" not in source
    assert "last_update_time" in source
    assert "window_seconds" in source
