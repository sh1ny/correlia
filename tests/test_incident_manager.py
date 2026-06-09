"""PostgreSQL-backed incident manager aggregation tests."""

from __future__ import annotations

import inspect
import subprocess
import sys
from datetime import datetime, timedelta, timezone

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.domain.events import EventType, NormalizedEvent, Severity
from app.domain.rules import RuleDecision, ThresholdDecision


pytestmark = pytest.mark.anyio


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


def _event(fingerprint: str, timestamp: datetime, host: str = "db-1") -> NormalizedEvent:
    return NormalizedEvent(
        fingerprint=fingerprint,
        source_id="icinga2",
        host=host,
        service="postgres",
        severity=Severity.CRITICAL,
        event_type=EventType.PROBLEM,
        timestamp=timestamp,
        tags={"topology.role": "database"},
        message="postgres is critical",
        ip_address="10.0.0.10",
    )


def _decision(timestamp: datetime, threshold: int = 2) -> RuleDecision:
    return RuleDecision(
        rule_name="database-critical",
        priority=10,
        matched_rules=["database-critical"],
        group_key="service=postgres|topology.role=database",
        threshold_decision=ThresholdDecision(
            rule_name="database-critical",
            group_key="service=postgres|topology.role=database",
            window_start=timestamp - timedelta(minutes=5),
            window_end=timestamp,
            threshold=threshold,
            counted_fingerprints=[],
            counted=0,
            crossed=False,
        ),
        summary="database incident",
        actions=["email-oncall", "audit-log"],
    )

class RecordingRunner:
    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.submissions: list[tuple[str, dict[str, object]]] = []

    async def submit(self, task_name: str, payload: dict[str, object]) -> None:
        if self.fail:
            raise RuntimeError("runner submission failed")
        self.submissions.append((task_name, dict(payload)))


class PluginNames:
    def __init__(self, *names: str) -> None:
        self.names = tuple(sorted(names))
        self.config_hash = "sha256:plugins"


def test_incident_manager_commits_before_notify_submit() -> None:
    import app.processing.incident_manager as incident_manager

    source = inspect.getsource(incident_manager.IncidentManager.apply_problem)
    commit_pos = source.index("await self._session.commit()")
    submit_pos = source.index('await self._task_runner.submit("notify"')
    assert commit_pos < submit_pos



async def test_apply_problem_returns_inserted_below_threshold_result(
    db_session: AsyncSession,
) -> None:
    from app.processing.incident_manager import IncidentManager, NoDispatchReason

    timestamp = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    runner = RecordingRunner()
    result = await IncidentManager(
        db_session,
        task_runner=runner,
        plugin_registry=PluginNames("email-oncall", "audit-log"),
        config_hash="sha256:abc",
    ).apply_problem(
        _event("fp-1", timestamp),
        _decision(timestamp, threshold=2),
    )

    assert result.effect == "inserted"
    assert result.incident_id is not None
    assert result.status == "OPEN"
    assert result.threshold_crossed is False
    assert result.notification_triggered is False
    assert result.notification_failed is False
    assert result.no_dispatch_reason == NoDispatchReason.BELOW_THRESHOLD.value
    assert result.notification_results == ()
    assert runner.submissions == []


async def test_apply_problem_reports_updated_threshold_crossed_then_already_notified(
    db_session: AsyncSession,
) -> None:
    from app.processing.incident_manager import IncidentManager, NoDispatchReason

    runner = RecordingRunner()
    manager = IncidentManager(
        db_session,
        task_runner=runner,
        plugin_registry=PluginNames("email-oncall", "audit-log"),
    )
    first_time = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    await manager.apply_problem(_event("fp-1", first_time), _decision(first_time, threshold=2))

    second_time = datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc)
    crossed = await manager.apply_problem(
        _event("fp-2", second_time, host="db-2"),
        _decision(second_time, threshold=2),
    )

    third_time = datetime(2026, 1, 1, 12, 2, tzinfo=timezone.utc)
    already = await manager.apply_problem(
        _event("fp-3", third_time, host="db-3"),
        _decision(third_time, threshold=2),
    )

    assert crossed.effect == "updated"
    assert crossed.threshold_crossed is True
    assert crossed.first_threshold_transition is True
    assert crossed.notification_triggered is True
    assert crossed.notification_results[0].category == "dispatched"
    assert crossed.notification_results[1].category == "dispatched"
    assert len(runner.submissions) == 2
    assert runner.submissions[0][0] == "notify"
    assert runner.submissions[0][1]["plugin_name"] == "audit-log"
    assert runner.submissions[1][1]["plugin_name"] == "email-oncall"
    assert crossed.no_dispatch_reason is None
    assert already.effect == "updated"
    assert already.threshold_crossed is True
    assert already.first_threshold_transition is False
    assert already.notification_triggered is False
    assert already.no_dispatch_reason == NoDispatchReason.ALREADY_NOTIFIED.value
    assert len(runner.submissions) == 2


async def test_apply_problem_reports_replay_without_retriggering(
    db_session: AsyncSession,
) -> None:
    from app.processing.incident_manager import IncidentManager, NoDispatchReason

    runner = RecordingRunner()
    manager = IncidentManager(
        db_session,
        task_runner=runner,
        plugin_registry=PluginNames("email-oncall", "audit-log"),
    )
    first_time = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    await manager.apply_problem(_event("fp-1", first_time), _decision(first_time, threshold=2))

    replay_time = datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc)
    replay = await manager.apply_problem(
        _event("fp-1", replay_time),
        _decision(replay_time, threshold=2),
    )

    assert replay.replay is True
    assert replay.notification_triggered is False
    assert replay.no_dispatch_reason == NoDispatchReason.REPLAY.value
    assert runner.submissions == []


async def test_apply_problem_returns_missing_plugin_and_submission_failures_after_commit(
    db_session: AsyncSession,
) -> None:
    from app.processing.incident_manager import IncidentManager

    timestamp = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    missing_plugin = await IncidentManager(
        db_session,
        task_runner=RecordingRunner(),
        plugin_registry=PluginNames("email-oncall"),
    ).apply_problem(_event("fp-missing", timestamp), _decision(timestamp, threshold=1))

    assert missing_plugin.notification_failed is True
    assert missing_plugin.notification_results[0].category == "missing_plugin"

    row = await db_session.execute(
        sa.text("SELECT COUNT(*) FROM incidents WHERE id = :id"),
        {"id": missing_plugin.incident_id},
    )
    assert row.scalar_one() == 1

    fail_time = datetime(2026, 1, 1, 12, 10, tzinfo=timezone.utc)
    submission_failed = await IncidentManager(
        db_session,
        task_runner=RecordingRunner(fail=True),
        plugin_registry=PluginNames("email-oncall", "audit-log"),
    ).apply_problem(_event("fp-submit", fail_time, host="db-2"), _decision(fail_time, threshold=1))

    assert submission_failed.notification_failed is True
    assert {r.category for r in submission_failed.notification_results} == {"dispatch_failed"}


async def test_apply_problem_persists_only_safe_decision_context(
    db_session: AsyncSession,
) -> None:
    from app.processing.incident_manager import IncidentManager

    timestamp = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    result = await IncidentManager(
        db_session,
        plugin_registry=PluginNames("email-oncall", "audit-log"),
        config_hash="sha256:abc",
    ).apply_problem(
        _event("fp-safe", timestamp),
        _decision(timestamp, threshold=2),
    )

    row = await db_session.execute(
        sa.text("SELECT decision_context FROM incidents WHERE id = :id"),
        {"id": result.incident_id},
    )
    context = row.scalar_one()
    assert context["fingerprint"] == "fp-safe"
    assert context["source_id"] == "icinga2"
    assert context["rule_name"] == "database-critical"
    assert context["group_key"] == "service=postgres|topology.role=database"
    assert context["threshold_count"] == 2
    assert context["replay"] is False
    assert context["action_names"] == ["email-oncall", "audit-log"]
    serialized = repr(context).lower()
    for forbidden in (
        "raw_payload",
        "smtp",
        "credential",
        "password",
        "token",
        "secret",
        "traceback",
        "rendered",
        "plugin_config",
    ):
        assert forbidden not in serialized


def test_incident_manager_source_does_not_store_unsafe_context() -> None:
    import app.processing.incident_manager as incident_manager

    source = inspect.getsource(incident_manager)
    for forbidden in (
        "raw_payload",
        "smtp transcript",
        "credentials",
        "full exception",
        "rendered notification",
        "plugin options",
    ):
        assert forbidden not in source.lower()
