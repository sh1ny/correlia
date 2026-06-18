"""Testcontainers-backed PostgreSQL migration and schema invariant tests."""

from __future__ import annotations

import os

import subprocess
import sys
from uuid import UUID, uuid4

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

async def _run_alembic_upgrade_from_database_url_env(database_url: str) -> None:
    env = os.environ.copy()
    env["DATABASE_URL"] = database_url
    env.pop("CORRELIA_API_AUTH_ENABLED", None)
    env.pop("CORRELIA_OPERATOR_API_TOKEN", None)
    env.pop("CORRELIA_INGRESS_API_TOKEN", None)
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        capture_output=True,
        text=True,
        check=True,
        env=env,
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

async def test_migration_uses_database_url_env_without_api_tokens(
    postgres_url: str,
) -> None:
    await _run_alembic_upgrade_from_database_url_env(postgres_url)

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
    await engine.dispose()


# Phase 7 incident_events audit table migration tests

async def test_migration_creates_incident_events_table(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.connect() as conn:
        tables = await conn.run_sync(
            lambda sync_conn: sa.inspect(sync_conn).get_table_names()
        )

    assert "incident_events" in tables
    await engine.dispose()


async def test_incident_events_columns_and_types(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.connect() as conn:
        columns_info = await conn.run_sync(
            lambda sync_conn: sa.inspect(sync_conn).get_columns("incident_events")
        )
        columns = {c["name"]: c for c in columns_info}

    expected = {
        "id", "accepted_at", "event_timestamp", "source_id", "fingerprint",
        "event_type", "severity", "host", "service", "incident_ids",
        "incident_effect", "decision_summary", "normalized_event", "raw_payload",
        "raw_payload_original_byte_length", "raw_payload_stored_byte_length",
        "raw_payload_truncated", "redaction_version", "redacted_path_count",
        "raw_payload_hmac",
    }
    assert expected.issubset(set(columns.keys()))

    assert str(columns["incident_ids"]["type"]).lower() == "jsonb"
    assert str(columns["decision_summary"]["type"]).lower() == "jsonb"
    assert str(columns["normalized_event"]["type"]).lower() == "jsonb"
    assert str(columns["raw_payload"]["type"]).lower() == "jsonb"
    assert "timestamp" in str(columns["accepted_at"]["type"]).lower()
    assert str(columns["raw_payload_truncated"]["type"]).lower() == "boolean"
    assert "uuid" in str(columns["id"]["type"]).lower()

    # raw_payload and all raw-payload metadata/HMAC columns are non-null per D-04/D-07
    for non_null_col in (
        "raw_payload",
        "raw_payload_original_byte_length",
        "raw_payload_stored_byte_length",
        "raw_payload_truncated",
        "redaction_version",
        "redacted_path_count",
        "raw_payload_hmac",
    ):
        assert columns[non_null_col]["nullable"] is False, (
            f"{non_null_col} must be non-null per D-04/D-07"
        )
    # service is the only optional audit column
    assert columns["service"]["nullable"] is True

    await engine.dispose()


async def test_incident_events_check_constraints(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.connect() as conn:
        constraints = await conn.run_sync(
            lambda sync_conn: sa.inspect(sync_conn).get_check_constraints("incident_events")
        )

    names = {c["name"] for c in constraints}
    assert "ck_incident_events_event_type" in names
    assert "ck_incident_events_severity" in names
    assert "ck_incident_events_incident_effect" in names
    assert "ck_incident_events_incident_ids_array" in names
    assert "ck_incident_events_decision_summary_object" in names
    assert "ck_incident_events_normalized_event_object" in names
    assert "ck_incident_events_raw_payload_object" in names
    assert "ck_incident_events_raw_payload_byte_lengths_non_negative" in names
    assert "ck_incident_events_raw_payload_stored_lte_original" in names
    assert "ck_incident_events_redaction_version_positive" in names
    assert "ck_incident_events_redacted_path_count_non_negative" in names

    event_type_def = next(c for c in constraints if c["name"] == "ck_incident_events_event_type")
    assert "PROBLEM" in event_type_def["sqltext"]
    assert "RECOVERY" in event_type_def["sqltext"]

    effect_def = next(c for c in constraints if c["name"] == "ck_incident_events_incident_effect")
    assert "none" in effect_def["sqltext"]
    assert "inserted" in effect_def["sqltext"]
    assert "affected_set_shrunk" in effect_def["sqltext"]

    # raw_payload is non-null per D-04/D-07, so the object CHECK must not
    # carry an `IS NULL` escape; it must enforce the jsonb typeof directly.
    raw_payload_def = next(
        c for c in constraints if c["name"] == "ck_incident_events_raw_payload_object"
    )
    assert "jsonb_typeof(raw_payload)" in raw_payload_def["sqltext"]
    assert "IS NULL" not in raw_payload_def["sqltext"].upper()
    await engine.dispose()


async def test_incident_events_indexes(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.connect() as conn:
        indexes = await conn.run_sync(
            lambda sync_conn: sa.inspect(sync_conn).get_indexes("incident_events")
        )

    by_name = {i["name"]: i for i in indexes}
    assert "ix_incident_events_accepted_at_id" in by_name
    assert by_name["ix_incident_events_accepted_at_id"]["column_names"] == ["accepted_at", "id"]

    assert "ix_incident_events_incident_ids_gin" in by_name
    gin = by_name["ix_incident_events_incident_ids_gin"]
    assert gin["column_names"] == ["incident_ids"]
    assert gin.get("dialect_options", {}).get("postgresql_using") == "gin"

    assert "ix_incident_events_no_dispatch_reason" in by_name
    assert "ix_incident_events_fingerprint" in by_name
    assert "ix_incident_events_source_id" in by_name
    assert "ix_incident_events_event_type" in by_name
    assert "ix_incident_events_severity" in by_name
    assert "ix_incident_events_host" in by_name
    assert "ix_incident_events_service" in by_name
    assert "ix_incident_events_incident_effect" in by_name
    assert "ix_incident_events_event_timestamp" in by_name

    await engine.dispose()


async def test_audit_id_is_server_generated(postgres_url: str) -> None:
    await _run_alembic_upgrade(postgres_url)

    engine = create_async_engine(postgres_url)
    async with engine.begin() as conn:
        await conn.execute(
            sa.text("""
                INSERT INTO incident_events (
                    event_timestamp, source_id, fingerprint, event_type, severity,
                    host, incident_ids, incident_effect, decision_summary,
                    normalized_event, raw_payload, raw_payload_original_byte_length,
                    raw_payload_stored_byte_length, raw_payload_truncated,
                    redaction_version, redacted_path_count, raw_payload_hmac
                ) VALUES (
                    NOW(), 'src-1', 'fp-1', 'PROBLEM', 'CRITICAL',
                    'host-1', '[]'::jsonb, 'none', '{}'::jsonb,
                    '{}'::jsonb, '{}'::jsonb, 2, 2, false,
                    1, 0, 'hmac-1'
                )
            """)
        )

    async with engine.connect() as conn:
        result = await conn.execute(
            sa.text("SELECT id, raw_payload_hmac FROM incident_events WHERE source_id = 'src-1'")
        )
        row = result.one()

    assert row[0] is not None
    parsed = UUID(str(row[0]))
    assert parsed is not None
    assert row[1] == "hmac-1"
    await engine.dispose()
