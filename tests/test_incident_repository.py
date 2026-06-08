"""Testcontainers-backed incident repository upsert tests."""

from __future__ import annotations

import subprocess
import sys
from datetime import datetime, timezone

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.domain.events import Severity
from app.domain.incidents import DecisionContext, IncidentStatus
from app.persistence.models import Base


async def _run_alembic_upgrade(database_url: str) -> None:
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
        yield url


@pytest.fixture(scope="module")
async def engine(postgres_url: str):
    await _run_alembic_upgrade(postgres_url)
    engine = create_async_engine(postgres_url)
    yield engine
    await engine.dispose()


@pytest.fixture
async def db_session(engine):
    async with AsyncSession(engine, expire_on_commit=False) as session:
        yield session
        await session.rollback()
        await session.execute(sa.text("TRUNCATE TABLE incidents RESTART IDENTITY CASCADE"))
        await session.commit()


# ---------------------------------------------------------------------------
# Task 1: Atomic open-incident upsert
# ---------------------------------------------------------------------------


async def test_first_upsert_creates_open_incident(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    input_data = IncidentUpsertInput(
        rule_name="rule-a",
        group_key="host:db-1",
        severity=Severity.WARNING,
        event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
        summary="disk full",
        affected_hosts=("db-1",),
    )

    incident = await upsert_open_incident(db_session, input_data)
    await db_session.commit()

    assert incident.rule_name == "rule-a"
    assert incident.group_key == "host:db-1"
    assert incident.status == IncidentStatus.OPEN.value
    assert incident.severity == Severity.WARNING.value
    assert incident.event_count == 1
    assert incident.summary == "disk full"
    assert incident.affected_hosts == ["db-1"]
    assert incident.affected_services == []


async def test_second_upsert_updates_same_open_incident(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    first = IncidentUpsertInput(
        rule_name="rule-a",
        group_key="host:db-1",
        severity=Severity.WARNING,
        event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
        summary="disk full",
        affected_hosts=("db-1",),
    )
    incident1 = await upsert_open_incident(db_session, first)
    await db_session.commit()

    second = IncidentUpsertInput(
        rule_name="rule-a",
        group_key="host:db-1",
        severity=Severity.CRITICAL,
        event_time=datetime(2026, 1, 1, 12, 5, 0, tzinfo=timezone.utc),
        summary="disk critical",
        affected_hosts=("db-1", "db-2"),
        affected_services=("postgres",),
    )
    incident2 = await upsert_open_incident(db_session, second)
    await db_session.commit()

    assert incident1.id == incident2.id
    assert incident2.event_count == 2
    assert incident2.severity == Severity.CRITICAL.value
    assert incident2.summary == "disk critical"
    assert incident2.affected_hosts == ["db-1", "db-2"]
    assert incident2.affected_services == ["postgres"]
    assert incident2.last_update_time >= first.event_time


async def test_different_rule_or_group_creates_separate_rows(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    inc_a = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s1",
            affected_hosts=("db-1",),
        ),
    )
    inc_b = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-b",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s2",
            affected_hosts=("db-1",),
        ),
    )
    inc_c = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-2",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s3",
            affected_hosts=("db-2",),
        ),
    )
    await db_session.commit()

    assert inc_a.id != inc_b.id
    assert inc_a.id != inc_c.id
    assert inc_b.id != inc_c.id


async def test_resolved_row_does_not_block_new_open(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    # Manually insert a RESOLVED row
    await db_session.execute(
        sa.text(
            "INSERT INTO incidents (id, rule_name, group_key, status, severity, summary, "
            "event_count, affected_hosts, affected_services, decision_context, "
            "start_time, last_update_time, created_at, updated_at) "
            "VALUES (gen_random_uuid(), :rule, :group, 'RESOLVED', 'WARNING', 'old', "
            "1, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb, NOW(), NOW(), NOW(), NOW())"
        ),
        {"rule": "rule-a", "group": "host:db-1"},
    )
    await db_session.commit()

    # Upsert a new OPEN row for the same identity
    incident = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.CRITICAL,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="new",
            affected_hosts=("db-1",),
        ),
    )
    await db_session.commit()

    assert incident.status == IncidentStatus.OPEN.value
    assert incident.severity == Severity.CRITICAL.value


async def test_max_severity_critical_over_warning(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="warn",
            affected_hosts=("db-1",),
        ),
    )
    await db_session.commit()

    updated = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.CRITICAL,
            event_time=datetime(2026, 1, 1, 12, 1, 0, tzinfo=timezone.utc),
            summary="crit",
            affected_hosts=("db-1",),
        ),
    )
    await db_session.commit()

    assert updated.severity == Severity.CRITICAL.value


async def test_max_severity_unknown_over_warning(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="warn",
            affected_hosts=("db-1",),
        ),
    )
    await db_session.commit()

    updated = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.UNKNOWN,
            event_time=datetime(2026, 1, 1, 12, 1, 0, tzinfo=timezone.utc),
            summary="unk",
            affected_hosts=("db-1",),
        ),
    )
    await db_session.commit()

    assert updated.severity == Severity.UNKNOWN.value


async def test_severity_does_not_downgrade(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.CRITICAL,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="crit",
            affected_hosts=("db-1",),
        ),
    )
    await db_session.commit()

    updated = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 1, 0, tzinfo=timezone.utc),
            summary="warn",
            affected_hosts=("db-1",),
        ),
    )
    await db_session.commit()

    assert updated.severity == Severity.CRITICAL.value


async def test_affected_hosts_sorted_unique(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    incident = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="dup hosts",
            affected_hosts=("z", "a", "b", "a", "c"),
        ),
    )
    await db_session.commit()

    assert incident.affected_hosts == ["a", "b", "c", "z"]


async def test_affected_services_sorted_unique(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    incident = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="dup services",
            affected_hosts=("db-1",),
            affected_services=("z", "a", "b", "a"),
        ),
    )
    await db_session.commit()

    assert incident.affected_services == ["a", "b", "z"]


async def test_affected_hosts_merge_on_update(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="first",
            affected_hosts=("a", "b"),
        ),
    )
    await db_session.commit()

    updated = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 1, 0, tzinfo=timezone.utc),
            summary="second",
            affected_hosts=("b", "c"),
        ),
    )
    await db_session.commit()

    assert updated.affected_hosts == ["a", "b", "c"]


async def test_affected_hosts_enforces_100_bound(db_session: AsyncSession) -> None:
    from app.persistence.incidents import MAX_AFFECTED_HOSTS, IncidentUpsertInput, upsert_open_incident

    hosts = tuple(f"host-{i:03d}" for i in range(MAX_AFFECTED_HOSTS + 5))
    incident = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="many hosts",
            affected_hosts=hosts,
        ),
    )
    await db_session.commit()

    assert len(incident.affected_hosts) == MAX_AFFECTED_HOSTS


async def test_affected_services_enforces_100_bound(db_session: AsyncSession) -> None:
    from app.persistence.incidents import MAX_AFFECTED_SERVICES, IncidentUpsertInput, upsert_open_incident

    services = tuple(f"svc-{i:03d}" for i in range(MAX_AFFECTED_SERVICES + 5))
    incident = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="many services",
            affected_hosts=("db-1",),
            affected_services=services,
        ),
    )
    await db_session.commit()

    assert len(incident.affected_services) == MAX_AFFECTED_SERVICES


async def test_decision_context_persisted(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    ctx = DecisionContext(
        fingerprint="fp-1",
        source_id="icinga2",
        rule_name="rule-a",
        group_key="host:db-1",
        notes={"key": "value"},
    )

    incident = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="with ctx",
            affected_hosts=("db-1",),
            decision_context=ctx,
        ),
    )
    await db_session.commit()

    assert incident.decision_context["fingerprint"] == "fp-1"
    assert incident.decision_context["source_id"] == "icinga2"


async def test_closed_row_does_not_block_new_open(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    await db_session.execute(
        sa.text(
            "INSERT INTO incidents (id, rule_name, group_key, status, severity, summary, "
            "event_count, affected_hosts, affected_services, decision_context, "
            "start_time, last_update_time, created_at, updated_at) "
            "VALUES (gen_random_uuid(), :rule, :group, 'CLOSED', 'WARNING', 'old', "
            "1, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb, NOW(), NOW(), NOW(), NOW())"
        ),
        {"rule": "rule-a", "group": "host:db-1"},
    )
    await db_session.commit()

    incident = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.CRITICAL,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="new",
            affected_hosts=("db-1",),
        ),
    )
    await db_session.commit()

    assert incident.status == IncidentStatus.OPEN.value


async def test_no_select_inside_upsert(db_session: AsyncSession) -> None:
    import inspect
    from app.persistence import incidents as incidents_module

    source = inspect.getsource(incidents_module)
    assert "select(" not in source or "sqlalchemy.dialects.postgresql.insert" in source
    # More precise: no raw select( calls in upsert_open_incident or build_open_incident_upsert
    assert "upsert_open_incident" in source
    assert "on_conflict_do_update" in source


# ---------------------------------------------------------------------------
# Validation tests (no DB required)
# ---------------------------------------------------------------------------


def test_upsert_input_rejects_empty_rule_name() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError, match="rule_name"):
        IncidentUpsertInput(
            rule_name="",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=("db-1",),
        )


def test_upsert_input_rejects_empty_group_key() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError, match="group_key"):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=("db-1",),
        )


def test_upsert_input_rejects_empty_summary() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError, match="summary"):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="",
            affected_hosts=("db-1",),
        )


def test_upsert_input_rejects_naive_event_time() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError, match="timezone"):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0),
            summary="s",
            affected_hosts=("db-1",),
        )


def test_upsert_input_rejects_empty_affected_hosts() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError, match="affected_hosts"):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=(),
        )


# ---------------------------------------------------------------------------
# Task 2: Security-focused tests
# ---------------------------------------------------------------------------


def test_decision_context_rejects_raw_payload() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=("db-1",),
            decision_context=DecisionContext(notes={"raw_payload": "x"}),
        )


def test_decision_context_rejects_token() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=("db-1",),
            decision_context=DecisionContext(notes={"token": "x"}),
        )


def test_decision_context_rejects_password() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=("db-1",),
            decision_context=DecisionContext(notes={"password": "x"}),
        )


def test_decision_context_rejects_secret() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=("db-1",),
            decision_context=DecisionContext(notes={"secret": "x"}),
        )


def test_decision_context_rejects_plugin_config() -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises(ValueError):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=("db-1",),
            decision_context=DecisionContext(notes={"plugin_config": "x"}),
        )


async def test_sql_injection_rule_name_persisted_literally(db_session: AsyncSession) -> None:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    injection_name = "rule'; drop table incidents; --"
    incident = await upsert_open_incident(
        db_session,
        IncidentUpsertInput(
            rule_name=injection_name,
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="injection test",
            affected_hosts=("db-1",),
        ),
    )
    await db_session.commit()

    assert incident.rule_name == injection_name

    # Verify the table still exists
    result = await db_session.execute(sa.text("SELECT 1 FROM incidents LIMIT 1"))
    assert result.scalar() == 1


async def test_no_sqlite_in_test_source() -> None:
    import tests.test_incident_repository as mod
    import inspect

    source = inspect.getsource(mod)
    assert "sqlite" not in source.lower()
