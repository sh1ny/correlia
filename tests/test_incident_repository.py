"""Testcontainers-backed incident repository upsert tests."""

from __future__ import annotations

import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import Any

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.domain.events import Severity
from app.domain.incidents import DecisionContext, IncidentStatus


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
    )
    if result.returncode != 0:
        raise RuntimeError(f"Alembic upgrade failed: {result.stderr}")


_migrated_url: str | None = None


@pytest.fixture(scope="module")
def postgres_url(postgres_image: str) -> str:
    global _migrated_url
    with PostgresContainer(postgres_image) as postgres:
        url = postgres.get_connection_url()
        url = url.replace("postgresql+psycopg2://", "postgresql+asyncpg://")
        url = url.replace("postgresql://", "postgresql+asyncpg://")
        _run_alembic_upgrade(url)
        _migrated_url = url
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


async def test_second_upsert_updates_same_open_incident(
    db_session: AsyncSession,
) -> None:
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


async def test_record_problem_incident_counts_unique_fingerprints(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import IncidentUpsertInput, record_problem_incident

    first = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="disk full",
            affected_hosts=("db-1",),
            fingerprint="fp-1",
            threshold_count=3,
            window_seconds=300,
        ),
    )
    await db_session.commit()

    second = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.CRITICAL,
            event_time=datetime(2026, 1, 1, 12, 1, 0, tzinfo=timezone.utc),
            summary="disk critical",
            affected_hosts=("db-1", "db-2"),
            fingerprint="fp-2",
            threshold_count=3,
            window_seconds=300,
        ),
    )
    await db_session.commit()

    replay = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.CRITICAL,
            event_time=datetime(2026, 1, 1, 12, 2, 0, tzinfo=timezone.utc),
            summary="disk critical replay",
            affected_hosts=("db-1", "db-3"),
            fingerprint="fp-2",
            threshold_count=3,
            window_seconds=300,
        ),
    )
    await db_session.commit()

    assert first.effect == "inserted"
    assert first.incident.event_count == 1
    assert first.replay is False
    assert first.threshold_count == 3
    assert first.window_started_at == datetime(2026, 1, 1, 11, 55, tzinfo=timezone.utc)
    assert first.window_ended_at == datetime(2026, 1, 1, 12, tzinfo=timezone.utc)
    assert first.window_crossed is False
    assert second.effect == "updated"
    assert second.incident.id == first.incident.id
    assert second.incident.event_count == 2
    assert second.replay is False
    assert second.threshold_count == 3
    assert second.window_crossed is False
    assert replay.effect == "updated"
    assert replay.replay is True
    assert replay.counted_count == 2
    assert replay.window_crossed is False
    assert replay.incident.event_count == 2
    assert replay.incident.affected_hosts == ["db-1", "db-2", "db-3"]


async def test_record_problem_incident_counts_out_of_order_only_inside_window(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import IncidentUpsertInput, record_problem_incident

    base = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-window",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 10, 0, tzinfo=timezone.utc),
            summary="base",
            affected_hosts=("db-1",),
            fingerprint="fp-base",
            threshold_count=2,
            window_seconds=300,
        ),
    )
    await db_session.commit()

    window_end = base.window_ended_at
    window_start = base.window_started_at
    assert (window_start, window_end) == (
        datetime(2026, 1, 1, 12, 5, tzinfo=timezone.utc),
        datetime(2026, 1, 1, 12, 10, tzinfo=timezone.utc),
    )
    assert base.threshold_count == 2
    assert base.window_crossed is False
    assert base.threshold_crossed is False

    inside = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-window",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 7, 0, tzinfo=timezone.utc),
            summary="inside",
            affected_hosts=("db-2",),
            fingerprint="fp-inside",
            threshold_count=2,
            window_seconds=300,
        ),
    )
    await db_session.commit()

    replay = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-window",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 8, tzinfo=timezone.utc),
            summary="replay",
            affected_hosts=("db-2",),
            fingerprint="fp-inside",
            threshold_count=2,
            window_seconds=300,
        ),
    )
    await db_session.commit()

    outside = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-window",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 4, 59, tzinfo=timezone.utc),
            summary="outside",
            affected_hosts=("db-3",),
            fingerprint="fp-outside",
            threshold_count=2,
            window_seconds=300,
        ),
    )
    await db_session.commit()

    boundary = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-window",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=window_start,
            summary="boundary",
            affected_hosts=("db-4",),
            fingerprint="fp-boundary",
            threshold_count=2,
            window_seconds=300,
        ),
    )
    await db_session.commit()

    assert inside.inside_window is True
    assert inside.counted_count == 2
    assert inside.counted_fingerprints == ("fp-base", "fp-inside")
    assert inside.window_crossed is True
    assert inside.first_threshold_transition is True
    assert inside.incident.event_count == 2
    assert inside.incident.last_update_time == base.incident.last_update_time
    assert outside.inside_window is False
    assert outside.counted is False
    assert outside.incident.event_count == 2
    assert outside.incident.last_update_time == base.incident.last_update_time
    assert replay.replay is True
    assert replay.counted is False
    assert replay.counted_count == 2
    assert replay.counted_fingerprints == inside.counted_fingerprints
    assert outside.counted_count == 2
    assert outside.counted_fingerprints == inside.counted_fingerprints
    assert boundary.inside_window is True
    assert boundary.counted is True
    assert boundary.counted_count == 3
    assert boundary.counted_fingerprints == (
        "fp-base",
        "fp-boundary",
        "fp-inside",
    )
    for outcome in (inside, replay, outside, boundary):
        assert (outcome.window_started_at, outcome.window_ended_at) == (
            window_start,
            window_end,
        )
        assert outcome.threshold_count == 2
        assert outcome.window_crossed is True
        assert outcome.threshold_crossed is True
    for outcome in (replay, outside, boundary):
        assert outcome.first_threshold_transition is False

    state = (
        await db_session.execute(
            sa.text("SELECT window_state FROM incidents WHERE id = :id"),
            {"id": boundary.incident.id},
        )
    ).scalar_one()
    assert state["counted_count"] == boundary.counted_count
    assert state["threshold_count"] == boundary.threshold_count
    assert datetime.fromisoformat(state["window_started_at"]) == window_start
    assert datetime.fromisoformat(state["window_ended_at"]) == window_end
    assert (
        datetime.fromisoformat(state["counted_fingerprint_timestamps"]["fp-boundary"])
        == window_start
    )
    assert set(state["counted_fingerprint_timestamps"]) == set(
        boundary.counted_fingerprints
    )


async def test_record_problem_incident_reports_first_threshold_transition_once(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import IncidentUpsertInput, record_problem_incident

    first = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-threshold",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="first",
            affected_hosts=("db-1",),
            fingerprint="fp-1",
            threshold_count=2,
            window_seconds=300,
            max_window_fingerprints=2,
        ),
    )
    await db_session.commit()

    second = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-threshold",
            group_key="host:db-1",
            severity=Severity.CRITICAL,
            event_time=datetime(2026, 1, 1, 12, 1, 0, tzinfo=timezone.utc),
            summary="second",
            affected_hosts=("db-2",),
            fingerprint="fp-2",
            threshold_count=2,
            window_seconds=300,
            max_window_fingerprints=2,
        ),
    )
    await db_session.commit()

    third = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-threshold",
            group_key="host:db-1",
            severity=Severity.CRITICAL,
            event_time=datetime(2026, 1, 1, 12, 2, 0, tzinfo=timezone.utc),
            summary="third",
            affected_hosts=("db-3",),
            fingerprint="fp-3",
            threshold_count=2,
            window_seconds=300,
            max_window_fingerprints=2,
        ),
    )
    await db_session.commit()

    assert first.threshold_crossed is False
    assert first.first_threshold_transition is False
    assert second.threshold_crossed is True
    assert second.first_threshold_transition is True
    assert third.threshold_crossed is True
    assert third.first_threshold_transition is False
    assert third.incident.threshold_crossed is True
    assert first.threshold_count == second.threshold_count == third.threshold_count == 2
    assert first.counted_count == 1
    assert first.window_crossed is False
    assert second.counted_count == 2
    assert second.window_crossed is True
    assert third.counted_count == 2
    assert third.window_crossed is True
    assert third.counted_fingerprints == ("fp-2", "fp-3")
    state = (
        await db_session.execute(
            sa.text("SELECT window_state FROM incidents WHERE id = :id"),
            {"id": third.incident.id},
        )
    ).scalar_one()
    assert state["max_size"] == 2
    assert state["counted_count"] == third.counted_count
    assert set(state["counted_fingerprint_timestamps"]) == set(
        third.counted_fingerprints
    )


async def test_record_problem_incident_reaches_maximum_threshold(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import IncidentUpsertInput, record_problem_incident

    start = datetime(2026, 1, 1, 12, tzinfo=timezone.utc)
    transitions = 0
    before_crossing = None
    at_crossing = None
    for count in range(1, 101):
        result = await record_problem_incident(
            db_session,
            IncidentUpsertInput(
                rule_name="rule-max-threshold",
                group_key="host:db-1",
                severity=Severity.WARNING,
                event_time=start + timedelta(seconds=count),
                summary="distinct problem",
                affected_hosts=("db-1",),
                fingerprint=f"fp-{count:03}",
                threshold_count=100,
            ),
        )
        transitions += int(result.first_threshold_transition)
        if count == 99:
            before_crossing = result
        if count == 100:
            at_crossing = result
    await db_session.commit()

    assert before_crossing is not None
    assert at_crossing is not None
    assert transitions == 1
    assert before_crossing.counted_count == 99
    assert before_crossing.threshold_count == 100
    assert before_crossing.window_crossed is False
    assert before_crossing.threshold_crossed is False
    assert before_crossing.first_threshold_transition is False
    assert at_crossing.counted_count == 100
    assert at_crossing.counted_fingerprints == tuple(
        f"fp-{count:03}" for count in range(1, 101)
    )
    assert at_crossing.threshold_count == 100
    assert at_crossing.window_crossed is True
    assert at_crossing.threshold_crossed is True
    assert at_crossing.first_threshold_transition is True
    assert (at_crossing.window_started_at, at_crossing.window_ended_at) == (
        start + timedelta(seconds=100 - 300),
        start + timedelta(seconds=100),
    )

    state, threshold_crossed = (
        await db_session.execute(
            sa.text(
                "SELECT window_state, threshold_crossed FROM incidents WHERE id = :id"
            ),
            {"id": at_crossing.incident.id},
        )
    ).one()
    assert threshold_crossed is True
    assert state["counted_count"] == at_crossing.counted_count
    assert state["threshold_count"] == at_crossing.threshold_count
    assert state["max_size"] == 100
    assert tuple(sorted(state["counted_fingerprint_timestamps"])) == (
        at_crossing.counted_fingerprints
    )
    assert datetime.fromisoformat(state["window_started_at"]) == (
        at_crossing.window_started_at
    )
    assert datetime.fromisoformat(state["window_ended_at"]) == (
        at_crossing.window_ended_at
    )

    # The result is an operation snapshot, not a view of mutable ORM JSONB.
    at_crossing.incident.window_state["threshold_count"] = 1
    at_crossing.incident.window_state["counted_count"] = 0
    at_crossing.incident.window_state["window_started_at"] = "2000-01-01T00:00:00+00:00"
    at_crossing.incident.window_state["window_ended_at"] = "2000-01-01T00:00:00+00:00"
    at_crossing.incident.threshold_crossed = False
    assert at_crossing.threshold_count == 100
    assert at_crossing.counted_count == 100
    assert at_crossing.window_crossed is True
    assert at_crossing.threshold_crossed is True
    assert at_crossing.window_started_at == start + timedelta(seconds=100 - 300)
    assert at_crossing.window_ended_at == start + timedelta(seconds=100)
    assert before_crossing.counted_count == 99
    assert before_crossing.window_crossed is False


async def test_record_problem_incident_pruning_separates_window_and_marker(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import (
        IncidentAggregationWriteResult,
        IncidentUpsertInput,
        record_problem_incident,
    )

    start = datetime(2026, 1, 1, 12, tzinfo=timezone.utc)

    async def record(
        fingerprint: str, event_time: datetime
    ) -> IncidentAggregationWriteResult:
        result = await record_problem_incident(
            db_session,
            IncidentUpsertInput(
                rule_name="rule-pruning",
                group_key="host:db-1",
                severity=Severity.WARNING,
                event_time=event_time,
                summary="distinct problem",
                affected_hosts=("db-1",),
                fingerprint=fingerprint,
                threshold_count=2,
                window_seconds=60,
            ),
        )
        await db_session.commit()
        return result

    first = await record("fp-1", start)
    crossed = await record("fp-2", start + timedelta(seconds=30))
    pruned = await record("fp-3", start + timedelta(seconds=120))
    recrossed = await record("fp-4", start + timedelta(seconds=130))

    assert first.window_crossed is False
    assert crossed.window_crossed is True
    assert crossed.threshold_crossed is True
    assert crossed.first_threshold_transition is True
    assert pruned.counted_count == 1
    assert pruned.counted_fingerprints == ("fp-3",)
    assert pruned.threshold_count == 2
    assert pruned.window_started_at == start + timedelta(seconds=60)
    assert pruned.window_ended_at == start + timedelta(seconds=120)
    assert pruned.window_crossed is False
    assert pruned.threshold_crossed is True
    assert pruned.first_threshold_transition is False
    assert recrossed.counted_count == 2
    assert recrossed.window_crossed is True
    assert recrossed.threshold_crossed is True
    assert recrossed.first_threshold_transition is False

    state, threshold_crossed = (
        await db_session.execute(
            sa.text(
                "SELECT window_state, threshold_crossed FROM incidents WHERE id = :id"
            ),
            {"id": recrossed.incident.id},
        )
    ).one()
    assert threshold_crossed is True
    assert state["counted_count"] == recrossed.counted_count
    assert tuple(sorted(state["counted_fingerprint_timestamps"])) == (
        recrossed.counted_fingerprints
    )
    assert pruned.counted_count == 1
    assert pruned.window_crossed is False


async def test_record_problem_incident_saturation_evicts_out_of_order_tie(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import (
        IncidentAggregationWriteResult,
        IncidentUpsertInput,
        record_problem_incident,
    )

    start = datetime(2026, 1, 1, 12, tzinfo=timezone.utc)

    async def record(
        fingerprint: str, event_time: datetime
    ) -> IncidentAggregationWriteResult:
        return await record_problem_incident(
            db_session,
            IncidentUpsertInput(
                rule_name="rule-saturation",
                group_key="host:db-1",
                severity=Severity.WARNING,
                event_time=event_time,
                summary="distinct problem",
                affected_hosts=("db-1",),
                fingerprint=fingerprint,
                threshold_count=100,
            ),
        )

    await record("fp-newest", start + timedelta(minutes=1))
    for index in range(1, 100):
        at_capacity = await record(f"fp-{index:03}", start)
    rejected_by_tie = await record("fp-000", start)
    await db_session.commit()

    assert at_capacity.counted_count == 100
    assert at_capacity.window_crossed is True
    assert rejected_by_tie.counted is True
    assert rejected_by_tie.inside_window is True
    assert rejected_by_tie.replay is False
    assert rejected_by_tie.counted_count == 100
    assert rejected_by_tie.threshold_count == 100
    assert rejected_by_tie.window_crossed is True
    assert rejected_by_tie.threshold_crossed is True
    assert rejected_by_tie.first_threshold_transition is False
    assert rejected_by_tie.window_ended_at == start + timedelta(minutes=1)
    assert rejected_by_tie.counted_fingerprints == tuple(
        f"fp-{index:03}" for index in range(1, 100)
    ) + ("fp-newest",)
    assert "fp-000" not in rejected_by_tie.counted_fingerprints
    assert rejected_by_tie.counted_fingerprints == at_capacity.counted_fingerprints

    state = (
        await db_session.execute(
            sa.text("SELECT window_state FROM incidents WHERE id = :id"),
            {"id": rejected_by_tie.incident.id},
        )
    ).scalar_one()
    assert state["counted_count"] == rejected_by_tie.counted_count
    assert state["threshold_count"] == rejected_by_tie.threshold_count
    assert state["max_size"] == 100
    assert tuple(sorted(state["counted_fingerprint_timestamps"])) == (
        rejected_by_tie.counted_fingerprints
    )
    assert "fp-000" not in state["counted_fingerprint_timestamps"]
    assert (
        datetime.fromisoformat(state["counted_fingerprint_timestamps"]["fp-001"])
        == start
    )
    assert datetime.fromisoformat(
        state["counted_fingerprint_timestamps"]["fp-newest"]
    ) == start + timedelta(minutes=1)


async def test_different_rule_or_group_creates_separate_rows(
    db_session: AsyncSession,
) -> None:
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
    from app.persistence.incidents import (
        IncidentUpsertInput,
        record_problem_incident,
        resolve_host_recovery,
        upsert_open_incident,
    )

    previous = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 11, 0, tzinfo=timezone.utc),
            summary="old",
            affected_hosts=("db-1",),
        ),
    )
    await resolve_host_recovery(
        db_session,
        host="db-1",
        recovery_time=datetime(2026, 1, 1, 11, 1, tzinfo=timezone.utc),
        fingerprint="recovery-old",
        source_id="icinga2:host:db-1",
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
    assert incident.severity == Severity.CRITICAL.value
    assert incident.id != previous.incident.id
    resolved = await db_session.get(
        type(incident), previous.incident.id, populate_existing=True
    )
    assert resolved is not None
    assert resolved.status == IncidentStatus.RESOLVED.value


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


async def test_host_recovery_uses_full_membership_beyond_capped_display(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import (
        MAX_AFFECTED_HOSTS,
        IncidentUpsertInput,
        record_problem_incident,
        resolve_host_recovery,
    )

    hosts = tuple(f"host-{i:03d}" for i in range(MAX_AFFECTED_HOSTS + 5))
    created = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="site:dc1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
            summary="many hosts",
            affected_hosts=hosts,
        ),
    )
    await db_session.commit()
    incident_id = created.incident.id
    assert created.incident.affected_hosts == list(hosts[:MAX_AFFECTED_HOSTS])

    for host, remaining in (
        (hosts[-1], hosts[:-1]),
        (hosts[0], hosts[1:-1]),
    ):
        results = await resolve_host_recovery(
            db_session,
            host=host,
            recovery_time=datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc),
            fingerprint=f"recovery:{host}",
            source_id=f"icinga2:host:{host}",
        )
        await db_session.commit()
        current = await db_session.get(
            type(created.incident), incident_id, populate_existing=True
        )
        assert len(results) == 1
        assert results[0].incident.id == incident_id
        assert results[0].effect == "affected_set_shrunk"
        assert results[0].transitioned_to is None
        assert current is not None
        assert current.status == IncidentStatus.OPEN.value
        assert current.resolved_at is None
        assert current.affected_hosts == list(remaining[:MAX_AFFECTED_HOSTS])
        assert current.affected_services == []
        assert current.window_state["active_objects"] == [
            {"host": host, "service": None} for host in remaining
        ]
        assert results[0].previous_host_count == len(remaining) + 1
        assert results[0].previous_service_count == 0
        notes = current.decision_context["notes"]
        assert notes["lifecycle.previous_host_count"] == str(len(remaining) + 1)
        assert notes["lifecycle.previous_service_count"] == "0"


async def test_service_recovery_uses_full_membership_beyond_capped_display(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import (
        MAX_AFFECTED_SERVICES,
        IncidentUpsertInput,
        record_problem_incident,
        resolve_host_recovery,
        resolve_service_recovery,
    )

    services = tuple(f"svc-{i:03d}" for i in range(MAX_AFFECTED_SERVICES + 5))
    created = await record_problem_incident(
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
    incident_id = created.incident.id
    assert created.incident.affected_services == list(services[:MAX_AFFECTED_SERVICES])

    for service, remaining in (
        (services[-1], services[:-1]),
        (services[0], services[1:-1]),
    ):
        results = await resolve_service_recovery(
            db_session,
            host="db-1",
            service=service,
            recovery_time=datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc),
            fingerprint=f"recovery:db-1:{service}",
            source_id=f"icinga2:service:db-1:{service}",
        )
        await db_session.commit()
        current = await db_session.get(
            type(created.incident), incident_id, populate_existing=True
        )
        assert len(results) == 1
        assert results[0].incident.id == incident_id
        assert results[0].effect == "affected_set_shrunk"
        assert results[0].transitioned_to is None
        assert current is not None
        assert current.status == IncidentStatus.OPEN.value
        assert current.resolved_at is None
        assert current.affected_hosts == ["db-1"]
        assert current.affected_services == list(remaining[:MAX_AFFECTED_SERVICES])
        assert current.window_state["active_objects"] == [
            {"host": "db-1", "service": service} for service in remaining
        ]
        assert results[0].previous_host_count == 1
        assert results[0].previous_service_count == len(remaining) + 1
        notes = current.decision_context["notes"]
        assert notes["lifecycle.previous_host_count"] == "1"
        assert notes["lifecycle.previous_service_count"] == str(len(remaining) + 1)

    final = await resolve_host_recovery(
        db_session,
        host="db-1",
        recovery_time=datetime(2026, 1, 1, 12, 2, tzinfo=timezone.utc),
        fingerprint="recovery:db-1",
        source_id="icinga2:host:db-1",
    )
    await db_session.commit()
    assert len(final) == 1
    assert final[0].incident.id == incident_id
    assert final[0].effect == "resolved"
    assert final[0].incident.status == IncidentStatus.RESOLVED.value
    assert final[0].incident.resolved_at is not None
    assert final[0].incident.affected_hosts == []
    assert final[0].incident.affected_services == []
    assert final[0].incident.window_state["active_objects"] == []
    assert final[0].previous_host_count == 1
    assert final[0].previous_service_count == len(services) - 2


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


async def test_delivery_records_replace_per_plugin_preserve_notes_and_reject_overflow(
    db_session: AsyncSession,
) -> None:
    from app.domain.notifications import NotificationResult
    from app.persistence.incidents import (
        IncidentUpsertInput,
        record_notification_result,
        record_problem_incident,
    )

    created = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="delivery-rule",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc),
            summary="delivery records",
            affected_hosts=("db-1",),
            fingerprint="delivery-first",
            decision_context=DecisionContext(
                notes={"notification.0.plugin": "legacy-output"}
            ),
        ),
    )
    for index in range(20):
        assert await record_notification_result(
            db_session,
            created.incident.id,
            f"plugin-{index:02d}",
            NotificationResult(
                success=True,
                category="dispatched",
                message="notification dispatched",
            ),
        )
    await db_session.commit()

    assert await record_notification_result(
        db_session,
        created.incident.id,
        "plugin-00",
        NotificationResult(
            success=False,
            category="plugin_exception",
            message="notification plugin failed",
        ),
    )
    assert await record_notification_result(
        db_session,
        created.incident.id,
        "plugin-00",
        NotificationResult(
            success=False,
            category="plugin_exception",
            message="password=must-not-persist",
        ),
    )
    with pytest.raises(ValueError):
        await record_notification_result(
            db_session,
            created.incident.id,
            "plugin-overflow",
            NotificationResult(
                success=False,
                category="dispatch_failed",
                message="notification task submission failed",
            ),
        )
    await db_session.commit()

    row = (
        await db_session.execute(
            sa.text(
                "SELECT decision_context, notified_at FROM incidents WHERE id = :id"
            ),
            {"id": created.incident.id},
        )
    ).one()
    assert row.notified_at is not None
    context = row.decision_context
    assert context["notes"] == {"notification.0.plugin": "legacy-output"}
    records = context["notification_delivery_results"]
    assert [record["plugin_name"] for record in records] == [
        f"plugin-{index:02d}" for index in range(20)
    ]
    assert records[0]["result"] == {
        "success": False,
        "category": "plugin_exception",
        "message": "notification result redacted",
    }


async def test_aggregation_preserves_delivery_records_under_locked_update(
    db_session: AsyncSession,
) -> None:
    from app.domain.notifications import NotificationResult
    from app.persistence.incidents import (
        IncidentUpsertInput,
        record_notification_result,
        record_problem_incident,
    )

    first = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="aggregate-delivery",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc),
            summary="first",
            affected_hosts=("db-1",),
            fingerprint="aggregate-first",
            decision_context=DecisionContext(notes={"legacy.note": "historical"}),
        ),
    )
    await record_notification_result(
        db_session,
        first.incident.id,
        "email-oncall",
        NotificationResult(
            success=True,
            category="dispatched",
            message="notification dispatched",
        ),
    )
    await db_session.commit()

    updated = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="aggregate-delivery",
            group_key="host:db-1",
            severity=Severity.CRITICAL,
            event_time=datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc),
            summary="second",
            affected_hosts=("db-1",),
            fingerprint="aggregate-second",
            decision_context=DecisionContext(notes={"ordinary.note": "updated"}),
        ),
    )
    await db_session.commit()

    assert updated.incident.decision_context["notes"] == {"ordinary.note": "updated"}
    assert updated.incident.decision_context["notification_delivery_results"] == [
        {
            "schema_version": 1,
            "plugin_name": "email-oncall",
            "result": {
                "success": True,
                "category": "dispatched",
                "message": "notification dispatched",
            },
        }
    ]


async def test_problem_replay_preserves_existing_delivery_records(
    db_session: AsyncSession,
) -> None:
    from app.domain.notifications import NotificationResult
    from app.persistence.incidents import (
        IncidentUpsertInput,
        record_notification_result,
        record_problem_incident,
    )

    created = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="atomic-delivery",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc),
            summary="first",
            affected_hosts=("db-1",),
            fingerprint="atomic-first",
        ),
    )
    await record_notification_result(
        db_session,
        created.incident.id,
        "email-oncall",
        NotificationResult(
            success=True,
            category="dispatched",
            message="notification dispatched",
        ),
    )
    await db_session.commit()
    replay = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="atomic-delivery",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc),
            summary="first",
            affected_hosts=("db-1",),
            fingerprint="atomic-first",
            decision_context=DecisionContext(notes={"ordinary.note": "updated"}),
        ),
    )
    await db_session.commit()

    context = (
        await db_session.execute(
            sa.text("SELECT decision_context FROM incidents WHERE id = :id"),
            {"id": created.incident.id},
        )
    ).scalar_one()
    assert replay.incident.id == created.incident.id
    assert replay.replay is True
    assert replay.incident.event_count == 1
    assert context["notification_delivery_results"] == [
        {
            "schema_version": 1,
            "plugin_name": "email-oncall",
            "result": {
                "success": True,
                "category": "dispatched",
                "message": "notification dispatched",
            },
        }
    ]


async def test_closed_row_does_not_block_new_open(db_session: AsyncSession) -> None:
    from app.persistence.incidents import (
        IncidentUpsertInput,
        close_open_incident,
        record_problem_incident,
        upsert_open_incident,
    )

    previous = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 11, 0, tzinfo=timezone.utc),
            summary="old",
            affected_hosts=("db-1",),
        ),
    )
    await close_open_incident(
        db_session,
        previous.incident.id,
        operator="operator",
        reason="maintenance",
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
    assert incident.id != previous.incident.id
    closed = await db_session.get(
        type(incident), previous.incident.id, populate_existing=True
    )
    assert closed is not None
    assert closed.status == IncidentStatus.CLOSED.value


# ---------------------------------------------------------------------------
# Validation tests (no DB required)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("threshold,capacity", [(1, 1), (2, 2), (100, 100)])
def test_upsert_input_accepts_reachable_threshold_and_capacity(
    threshold: int, capacity: int
) -> None:
    from app.persistence.incidents import IncidentUpsertInput

    input_data = IncidentUpsertInput(
        rule_name="rule-a",
        group_key="host:db-1",
        severity=Severity.WARNING,
        event_time=datetime(2026, 1, 1, 12, tzinfo=timezone.utc),
        summary="s",
        affected_hosts=("db-1",),
        threshold_count=threshold,
        max_window_fingerprints=capacity,
    )
    assert (input_data.threshold_count, input_data.max_window_fingerprints) == (
        threshold,
        capacity,
    )


@pytest.mark.parametrize(
    "threshold,capacity",
    [
        (0, 1),
        (3, 2),
        (101, 100),
        (1, 0),
        (1, 101),
        (True, 1),
        (1.0, 1),
        ("1", 1),
        (1, True),
        (1, 1.5),
        (1, "2"),
    ],
)
def test_upsert_input_rejects_unreachable_or_non_integer_window_parameters(
    threshold: Any, capacity: Any
) -> None:
    from app.persistence.incidents import IncidentUpsertInput

    with pytest.raises((TypeError, ValueError)):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=("db-1",),
            threshold_count=threshold,
            max_window_fingerprints=capacity,
        )


def test_historical_unreachable_window_remains_readable_but_not_writable() -> None:
    from app.persistence.incidents import IncidentUpsertInput, _window_state_from_json

    historical_state = _window_state_from_json(
        {
            "schema_version": 2,
            "window_started_at": "2026-01-01T11:55:00+00:00",
            "window_ended_at": "2026-01-01T12:00:00+00:00",
            "window_seconds": 300,
            "threshold_count": 101,
            "counted_fingerprint_timestamps": {"fp-1": "2026-01-01T12:00:00+00:00"},
            "counted_count": 1,
            "max_size": 100,
            "active_objects": [{"host": "db-1", "service": None}],
        }
    )
    assert historical_state.threshold_count == 101
    assert historical_state.max_size == 100
    assert historical_state.counted_fingerprint_timestamps == {
        "fp-1": datetime(2026, 1, 1, 12, tzinfo=timezone.utc)
    }
    with pytest.raises(ValueError):
        IncidentUpsertInput(
            rule_name="rule-a",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, tzinfo=timezone.utc),
            summary="s",
            affected_hosts=("db-1",),
            threshold_count=historical_state.threshold_count,
            max_window_fingerprints=historical_state.max_size,
        )


async def test_historical_unreachable_window_merges_under_valid_threshold(
    db_session: AsyncSession,
) -> None:
    from app.persistence.incidents import IncidentUpsertInput, record_problem_incident

    first = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="historical-rule",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, tzinfo=timezone.utc),
            summary="first",
            affected_hosts=("db-1",),
            fingerprint="fp-first",
            threshold_count=1,
        ),
    )
    await db_session.commit()
    assert first.first_threshold_transition is True
    assert first.threshold_count == 1
    assert first.counted_count == 1
    assert first.window_crossed is True
    assert first.window_started_at == datetime(2026, 1, 1, 11, 55, tzinfo=timezone.utc)
    assert first.window_ended_at == datetime(2026, 1, 1, 12, tzinfo=timezone.utc)
    first_state = (
        await db_session.execute(
            sa.text("SELECT window_state FROM incidents WHERE id = :id"),
            {"id": first.incident.id},
        )
    ).scalar_one()
    assert first_state["counted_count"] == first.counted_count
    assert first_state["threshold_count"] == first.threshold_count
    assert tuple(first_state["counted_fingerprint_timestamps"]) == (
        first.counted_fingerprints
    )
    assert datetime.fromisoformat(first_state["window_started_at"]) == (
        first.window_started_at
    )
    assert datetime.fromisoformat(first_state["window_ended_at"]) == (
        first.window_ended_at
    )

    await db_session.execute(
        sa.text(
            "UPDATE incidents SET window_state = jsonb_set("
            "window_state, '{threshold_count}', '101'::jsonb) WHERE id = :id"
        ),
        {"id": first.incident.id},
    )
    await db_session.commit()

    second = await record_problem_incident(
        db_session,
        IncidentUpsertInput(
            rule_name="historical-rule",
            group_key="host:db-1",
            severity=Severity.WARNING,
            event_time=datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc),
            summary="second",
            affected_hosts=("db-1",),
            fingerprint="fp-second",
            threshold_count=2,
        ),
    )
    await db_session.commit()
    window_state, threshold_crossed = (
        await db_session.execute(
            sa.text(
                "SELECT window_state, threshold_crossed FROM incidents WHERE id = :id"
            ),
            {"id": second.incident.id},
        )
    ).one()

    assert second.effect == "updated"
    assert second.counted_fingerprints == ("fp-first", "fp-second")
    assert second.counted_count == 2
    assert second.threshold_count == 2
    assert second.window_started_at == datetime(2026, 1, 1, 11, 56, tzinfo=timezone.utc)
    assert second.window_ended_at == datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc)
    assert second.window_crossed is True
    assert second.threshold_crossed is True
    assert second.first_threshold_transition is False
    assert threshold_crossed is True
    assert window_state["threshold_count"] == second.threshold_count
    assert window_state["counted_count"] == second.counted_count
    assert window_state["max_size"] == 100
    assert tuple(sorted(window_state["counted_fingerprint_timestamps"])) == (
        second.counted_fingerprints
    )


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


async def test_sql_injection_rule_name_persisted_literally(
    db_session: AsyncSession,
) -> None:
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
