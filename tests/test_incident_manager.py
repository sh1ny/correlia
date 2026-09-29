"""PostgreSQL-backed incident manager aggregation tests."""

from __future__ import annotations

import subprocess
import sys
from datetime import datetime, timedelta, timezone

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.domain.events import EventType, NormalizedEvent, Severity
from app.domain.rules import RuleMatch, RuleWindow


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


@pytest.fixture(scope="module")
def postgres_url(postgres_image: str) -> str:
    with PostgresContainer(postgres_image) as postgres:
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


def _event(
    fingerprint: str, timestamp: datetime, host: str = "db-1"
) -> NormalizedEvent:
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


def _match(
    threshold: int = 2,
    group_key: str = "service=postgres|topology.role=database",
    duration_seconds: int = 300,
) -> RuleMatch:
    return RuleMatch(
        rule_name="database-critical",
        priority=10,
        matched_rules=["database-critical"],
        group_key=group_key,
        window=RuleWindow(
            duration_seconds=duration_seconds,
            group_by=["service", "topology.role"],
            trigger_threshold=threshold,
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


async def test_apply_problem_defers_commit_to_caller(
    db_session: AsyncSession,
) -> None:
    """apply_problem must write the incident but not commit, so a second
    independent session cannot see the row until the caller commits.
    Proves D-01/D-02: commit ownership belongs to ingress."""

    from sqlalchemy.ext.asyncio import async_sessionmaker

    from app.processing.incident_manager import IncidentManager

    timestamp = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    result = await IncidentManager(
        db_session,
        plugin_registry=PluginNames("email-oncall"),
    ).apply_problem(_event("fp-defer", timestamp), _match(threshold=1))

    # The same session can see its own uncommitted writes.
    visible_in_session = await db_session.scalar(
        sa.text("SELECT id FROM incidents WHERE id = :id"),
        {"id": result.incident_id},
    )
    assert visible_in_session is not None

    # A second, independent session (no implicit transaction sharing) must
    # NOT see the row until the caller commits. This is the D-01
    # transaction-ownership proof.
    factory = async_sessionmaker(db_session.bind, expire_on_commit=False)
    async with factory() as other_session:
        isolated = await other_session.scalar(
            sa.text("SELECT id FROM incidents WHERE id = :id"),
            {"id": result.incident_id},
        )
    assert isolated is None, (
        "IncidentManager.apply_problem must defer commit; the row leaked into "
        "an independent session, which means the manager committed."
    )


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
        _match(threshold=2, duration_seconds=60),
    )

    assert result.effect == "inserted"
    assert result.incident_id is not None
    assert result.status == "OPEN"
    assert result.threshold_crossed is False
    assert result.threshold_decision.window_start == timestamp - timedelta(seconds=60)
    assert result.threshold_decision.window_end == timestamp
    assert result.threshold_decision.threshold == 2
    assert result.threshold_decision.counted_fingerprints == ["fp-1"]
    assert result.threshold_decision.counted == 1
    assert result.threshold_decision.crossed is False
    assert result.notification_intent == "no_dispatch"
    assert result.no_dispatch_reason == NoDispatchReason.BELOW_THRESHOLD.value
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
    await manager.apply_problem(_event("fp-1", first_time), _match(threshold=2))

    second_time = datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc)
    crossed = await manager.apply_problem(
        _event("fp-2", second_time, host="db-2"),
        _match(threshold=2),
    )

    third_time = datetime(2026, 1, 1, 12, 2, tzinfo=timezone.utc)
    already = await manager.apply_problem(
        _event("fp-3", third_time, host="db-3"),
        _match(threshold=2),
    )

    assert crossed.effect == "updated"
    assert crossed.threshold_crossed is True
    assert crossed.threshold_decision.counted == 2
    assert crossed.threshold_decision.crossed is True
    assert crossed.threshold_decision.window_end == second_time
    assert crossed.first_threshold_transition is True
    assert crossed.notification_intent == "dispatch_planned"
    assert crossed.no_dispatch_reason is None
    assert len(runner.submissions) == 0
    assert already.effect == "updated"
    assert already.threshold_crossed is True
    assert already.first_threshold_transition is False
    assert already.notification_intent == "no_dispatch"
    assert already.no_dispatch_reason == NoDispatchReason.ALREADY_NOTIFIED.value
    assert len(runner.submissions) == 0


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
    await manager.apply_problem(_event("fp-1", first_time), _match(threshold=2))

    replay_time = datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc)
    replay = await manager.apply_problem(
        _event("fp-1", replay_time),
        _match(threshold=2),
    )

    assert replay.replay is True
    assert replay.threshold_decision.counted == 1
    assert replay.threshold_decision.counted_fingerprints == ["fp-1"]
    assert replay.threshold_decision.replay_or_skip_reasons == [
        "replay: fingerprint fp-1 already counted in window"
    ]
    assert replay.notification_intent == "no_dispatch"
    assert replay.no_dispatch_reason == NoDispatchReason.REPLAY.value
    assert runner.submissions == []


async def test_apply_problem_does_not_submit_or_record_notifications(
    db_session: AsyncSession,
) -> None:
    """Manager no longer owns notification dispatch (D-02/D-03); it returns
    a notification_intent field and leaves submission to the ingress caller."""

    from app.processing.incident_manager import IncidentManager

    timestamp = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    missing_plugin = await IncidentManager(
        db_session,
        task_runner=RecordingRunner(),
        plugin_registry=PluginNames("email-oncall"),
    ).apply_problem(_event("fp-missing", timestamp), _match(threshold=1))

    # Manager must report dispatch_planned intent without actually submitting
    # or recording per-plugin metrics; that is the ingress layer's job.
    assert missing_plugin.notification_intent == "dispatch_planned"

    row = await db_session.execute(
        sa.text("SELECT COUNT(*) FROM incidents WHERE id = :id"),
        {"id": missing_plugin.incident_id},
    )
    assert row.scalar_one() == 1


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
        _match(threshold=2),
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


async def test_apply_problem_preserves_existing_delivery_records(
    db_session: AsyncSession,
) -> None:
    from app.domain.notifications import NotificationResult
    from app.persistence.incidents import record_notification_result
    from app.processing.incident_manager import IncidentManager

    manager = IncidentManager(
        db_session,
        plugin_registry=PluginNames("email-oncall", "audit-log"),
    )
    first_time = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    first = await manager.apply_problem(
        _event("delivery-first", first_time), _match(threshold=2)
    )
    await db_session.commit()
    assert await record_notification_result(
        db_session,
        first.incident_id,
        "email-oncall",
        NotificationResult(
            success=True,
            category="dispatched",
            message="notification dispatched",
        ),
    )
    await db_session.commit()

    second_time = datetime(2026, 1, 1, 12, 1, tzinfo=timezone.utc)
    second = await manager.apply_problem(
        _event("delivery-second", second_time), _match(threshold=2)
    )
    await db_session.commit()

    context = await db_session.scalar(
        sa.text("SELECT decision_context FROM incidents WHERE id = :id"),
        {"id": second.incident_id},
    )
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
