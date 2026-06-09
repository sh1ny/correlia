"""Testcontainers-backed PostgreSQL migration and schema invariant tests."""

from __future__ import annotations

import subprocess
import sys
from uuid import uuid4

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import create_async_engine
from testcontainers.postgres import PostgresContainer



pytestmark = pytest.mark.anyio


async def _run_alembic_upgrade(database_url: str) -> None:
    result = subprocess.run(
        [
            sys.executable, "-m", "alembic",
            "-x", f"database_url={database_url}",
            "upgrade", "head",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Alembic upgrade failed: {result.stderr}")


@pytest.fixture(scope="module")
def postgres_url() -> str:
    with PostgresContainer("postgres:18-alpine") as postgres:
        url = postgres.get_connection_url()
        # Force asyncpg driver for SQLAlchemy async engine compatibility
        url = url.replace("postgresql+psycopg2://", "postgresql+asyncpg://")
        url = url.replace("postgresql://", "postgresql+asyncpg://")
        yield url

async def test_migration_creates_incidents_table(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.connect() as conn:
        tables = await conn.run_sync(
            lambda sync_conn: sa.inspect(sync_conn).get_table_names()
        )

    assert "incidents" in tables
    await engine.dispose()

async def test_incidents_columns_and_types(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.connect() as conn:
        columns_info = await conn.run_sync(
            lambda sync_conn: sa.inspect(sync_conn).get_columns("incidents")
        )
        columns = {c["name"]: c for c in columns_info}

    expected = {
        "id", "rule_name", "group_key", "status", "severity",
        "summary", "event_count", "affected_hosts", "affected_services",
        "decision_context", "window_state", "threshold_crossed", "notified_at",
        "start_time", "last_update_time", "acknowledged_at", "acknowledged_by",
        "resolved_at", "closed_at", "created_at", "updated_at",
    }
    assert expected.issubset(set(columns.keys()))

    assert str(columns["affected_hosts"]["type"]).lower() == "jsonb"
    assert str(columns["affected_services"]["type"]).lower() == "jsonb"
    assert str(columns["decision_context"]["type"]).lower() == "jsonb"
    assert str(columns["window_state"]["type"]).lower() == "jsonb"
    assert str(columns["threshold_crossed"]["type"]).lower() == "boolean"
    assert "timestamp" in str(columns["notified_at"]["type"]).lower()


    assert columns["rule_name"]["nullable"] is False
    assert columns["group_key"]["nullable"] is False
    assert columns["status"]["nullable"] is False
    assert columns["severity"]["nullable"] is False
    assert columns["event_count"]["nullable"] is False

    await engine.dispose()

async def test_check_constraints(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.connect() as conn:
        constraints = await conn.run_sync(
            lambda sync_conn: sa.inspect(sync_conn).get_check_constraints("incidents")
        )

    constraint_names = {c["name"] for c in constraints}
    assert "ck_incidents_status" in constraint_names
    assert "ck_incidents_severity" in constraint_names
    assert "ck_incidents_event_count_positive" in constraint_names

    status_def = next(c for c in constraints if c["name"] == "ck_incidents_status")
    assert "OPEN" in status_def["sqltext"]
    assert "RESOLVED" in status_def["sqltext"]
    assert "CLOSED" in status_def["sqltext"]
    assert "ACKNOWLEDGED" not in status_def["sqltext"]

    await engine.dispose()


async def test_partial_unique_index(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.connect() as conn:
        indexes = await conn.run_sync(
            lambda sync_conn: sa.inspect(sync_conn).get_indexes("incidents")
        )

    index_names = {i["name"] for i in indexes}
    assert "incidents_one_open_per_rule_group" in index_names

    partial = next(i for i in indexes if i["name"] == "incidents_one_open_per_rule_group")
    assert partial["unique"] is True
    assert partial["column_names"] == ["rule_name", "group_key"]
    assert "OPEN" in partial.get("dialect_options", {}).get("postgresql_where", "")

    await engine.dispose()


async def test_duplicate_open_row_blocked(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.begin() as conn:
        await conn.execute(
            sa.text("""
                INSERT INTO incidents (
                    id, rule_name, group_key, status, severity, summary,
                    event_count, affected_hosts, affected_services, decision_context,
                    start_time, last_update_time, created_at, updated_at
                ) VALUES (
                    :id, :rule_name, :group_key, :status, :severity, :summary,
                    1, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb,
                    NOW(), NOW(), NOW(), NOW()
                )
            """),
            {
                "id": str(uuid4()),
                "rule_name": "rule-a",
                "group_key": "group-1",
                "status": "OPEN",
                "severity": "CRITICAL",
                "summary": "first",
            },
        )

    async with engine.begin() as conn:
        with pytest.raises(Exception):
            await conn.execute(
                sa.text("""
                    INSERT INTO incidents (
                        id, rule_name, group_key, status, severity, summary,
                        event_count, affected_hosts, affected_services, decision_context,
                        start_time, last_update_time, created_at, updated_at
                    ) VALUES (
                        :id, :rule_name, :group_key, :status, :severity, :summary,
                        1, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb,
                        NOW(), NOW(), NOW(), NOW()
                    )
                """),
                {
                    "id": str(uuid4()),
                    "rule_name": "rule-a",
                    "group_key": "group-1",
                    "status": "OPEN",
                    "severity": "CRITICAL",
                    "summary": "duplicate",
                },
            )

    await engine.dispose()


async def test_resolved_does_not_block_new_open(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.begin() as conn:
        await conn.execute(
            sa.text("""
                INSERT INTO incidents (
                    id, rule_name, group_key, status, severity, summary,
                    event_count, affected_hosts, affected_services, decision_context,
                    start_time, last_update_time, resolved_at, created_at, updated_at
                ) VALUES (
                    :id, :rule_name, :group_key, :status, :severity, :summary,
                    1, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb,
                    NOW(), NOW(), NOW(), NOW(), NOW()
                )
            """),
            {
                "id": str(uuid4()),
                "rule_name": "rule-b",
                "group_key": "group-2",
                "status": "RESOLVED",
                "severity": "WARNING",
                "summary": "resolved",
            },
        )

    async with engine.begin() as conn:
        await conn.execute(
            sa.text("""
                INSERT INTO incidents (
                    id, rule_name, group_key, status, severity, summary,
                    event_count, affected_hosts, affected_services, decision_context,
                    start_time, last_update_time, created_at, updated_at
                ) VALUES (
                    :id, :rule_name, :group_key, :status, :severity, :summary,
                    1, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb,
                    NOW(), NOW(), NOW(), NOW()
                )
            """),
            {
                "id": str(uuid4()),
                "rule_name": "rule-b",
                "group_key": "group-2",
                "status": "OPEN",
                "severity": "CRITICAL",
                "summary": "new open after resolved",
            },
        )

    await engine.dispose()
