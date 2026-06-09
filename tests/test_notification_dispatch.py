from __future__ import annotations

import subprocess
import sys
from datetime import datetime, timezone
from typing import Any
from uuid import UUID, uuid4

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.domain.events import Severity
from app.plugins.interfaces import NotificationEnvelope, PluginStatus

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
async def session_factory(postgres_url: str):
    engine = create_async_engine(postgres_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()

    cleanup = create_async_engine(postgres_url)
    async with AsyncSession(cleanup, expire_on_commit=False) as session:
        await session.execute(sa.text("TRUNCATE TABLE incidents RESTART IDENTITY CASCADE"))
        await session.commit()
    await cleanup.dispose()


class CapturingPlugin:
    def __init__(self) -> None:
        self.envelopes: list[NotificationEnvelope] = []

    async def send_notification(self, envelope: NotificationEnvelope) -> None:
        self.envelopes.append(envelope)

    def plugin_status(self) -> PluginStatus:
        return PluginStatus(plugin_type="email", ready=True, status="ready")


class FailingPlugin:
    async def send_notification(self, envelope: NotificationEnvelope) -> None:
        raise RuntimeError("password=super-secret smtp transcript should not leak")

    def plugin_status(self) -> PluginStatus:
        return PluginStatus(plugin_type="email", ready=True, status="ready")


class Registry:
    def __init__(self, plugins: dict[str, Any]) -> None:
        self._plugins = plugins
        self.config_hash = "sha256:plugins"

    @property
    def names(self) -> tuple[str, ...]:
        return tuple(sorted(self._plugins))

    def get_plugin(self, name: str) -> Any:
        plugin = self._plugins.get(name)
        if plugin is None:
            raise KeyError(name)
        return plugin

    def list_plugins(self) -> tuple[dict[str, object], ...]:
        return ()


async def _insert_incident(session_factory: async_sessionmaker[AsyncSession]) -> UUID:
    from app.domain.events import Severity
    from app.domain.incidents import DecisionContext
    from app.persistence.incidents import IncidentUpsertInput, record_problem_incident

    async with session_factory() as session:
        result = await record_problem_incident(
            session,
            IncidentUpsertInput(
                rule_name="database-critical",
                group_key="service=postgres",
                severity=Severity.CRITICAL,
                event_time=datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc),
                summary="database incident",
                affected_hosts=("db-1",),
                affected_services=("postgres",),
                decision_context=DecisionContext(rule_name="database-critical", group_key="service=postgres"),
                fingerprint="fp-dispatch",
                threshold_count=1,
                window_seconds=300,
            ),
        )
        await session.commit()
        return result.incident.id


async def test_dispatcher_sends_notification_and_records_safe_success(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    from app.processing.notification_dispatcher import NotificationDispatcher

    incident_id = await _insert_incident(session_factory)
    plugin = CapturingPlugin()
    dispatcher = NotificationDispatcher(session_factory, Registry({"email-oncall": plugin}))

    result = await dispatcher.process(
        {"incident_id": str(incident_id), "plugin_name": "email-oncall", "config_hash": "sha256:plugins"}
    )

    assert result.success is True
    assert result.category == "dispatched"
    assert len(plugin.envelopes) == 1
    assert plugin.envelopes[0].incident_id == str(incident_id)
    assert plugin.envelopes[0].severity is Severity.CRITICAL

    async with session_factory() as session:
        row = (
            await session.execute(
                sa.text("SELECT decision_context, notified_at FROM incidents WHERE id = :id"),
                {"id": incident_id},
            )
        ).one()
    context = row.decision_context
    assert row.notified_at is not None
    assert context["notes"]["notification.0.category"] == "dispatched"
    assert context["notes"]["notification.0.plugin"] == "email-oncall"



async def test_dispatcher_rejects_stale_plugin_config_without_sending(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    from app.processing.notification_dispatcher import NotificationDispatcher

    incident_id = await _insert_incident(session_factory)
    plugin = CapturingPlugin()
    dispatcher = NotificationDispatcher(session_factory, Registry({"email-oncall": plugin}))

    result = await dispatcher.process(
        {"incident_id": str(incident_id), "plugin_name": "email-oncall", "config_hash": "sha256:stale"}
    )

    assert result.success is False
    assert result.category == "dispatch_failed"
    assert result.message == "stale plugin configuration"
    assert plugin.envelopes == []

    async with session_factory() as session:
        context = (
            await session.execute(sa.text("SELECT decision_context FROM incidents WHERE id = :id"), {"id": incident_id})
        ).scalar_one()
    assert context["notes"]["notification.0.category"] == "dispatch_failed"
    assert context["notes"]["notification.0.message"] == "stale plugin configuration"

async def test_dispatcher_maps_missing_plugin_missing_incident_plugin_exception_and_bad_payload(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    from app.processing.notification_dispatcher import NotificationDispatcher

    incident_id = await _insert_incident(session_factory)
    dispatcher = NotificationDispatcher(session_factory, Registry({"failing": FailingPlugin()}))

    missing_plugin = await dispatcher.process(
        {"incident_id": str(incident_id), "plugin_name": "missing", "config_hash": "sha256:plugins"}
    )
    missing_incident = await dispatcher.process(
        {"incident_id": str(uuid4()), "plugin_name": "failing", "config_hash": "sha256:plugins"}
    )
    plugin_exception = await dispatcher.process(
        {"incident_id": str(incident_id), "plugin_name": "failing", "config_hash": "sha256:plugins"}
    )
    dispatch_failed = await dispatcher.process({"incident_id": "not-a-uuid", "plugin_name": "failing"})

    assert missing_plugin.category == "missing_plugin"
    assert missing_incident.category == "missing_incident"
    assert plugin_exception.category == "plugin_exception"
    assert dispatch_failed.category == "dispatch_failed"
    for result in (missing_plugin, missing_incident, plugin_exception, dispatch_failed):
        assert result.success is False
        serialized = result.model_dump_json().lower()
        assert "password" not in serialized
        assert "secret" not in serialized
        assert "smtp transcript" not in serialized
        assert "traceback" not in serialized

    async with session_factory() as session:
        context = (
            await session.execute(sa.text("SELECT decision_context FROM incidents WHERE id = :id"), {"id": incident_id})
        ).scalar_one()
    serialized_context = repr(context).lower()
    assert "plugin_exception" in serialized_context
    assert "password" not in serialized_context
    assert "smtp transcript" not in serialized_context
