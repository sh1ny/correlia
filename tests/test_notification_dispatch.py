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
from pydantic import ValidationError

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



def _notification_envelope(**overrides: object) -> NotificationEnvelope:
    values: dict[str, object] = {
        "incident_id": "550e8400-e29b-41d4-a716-446655440000",
        "rule_name": "database-critical",
        "group_key": "service=postgres",
        "severity": Severity.CRITICAL,
        "summary": "database incident",
        "affected_hosts": ("db-1",),
        "affected_services": ("postgres",),
    }
    values.update(overrides)
    return NotificationEnvelope(**values)


def test_notification_envelope_accepts_exact_field_and_collection_limits() -> None:
    envelope = _notification_envelope(
        incident_id="i" * 256,
        rule_name="r" * 256,
        group_key="g" * 256,
        summary="s" * 256,
        affected_hosts=tuple("h" * 256 for _ in range(100)),
        affected_services=tuple("v" * 256 for _ in range(100)),
    )

    assert envelope.severity is Severity.CRITICAL
    assert isinstance(envelope.affected_hosts, tuple)
    assert isinstance(envelope.affected_services, tuple)
    assert len(envelope.affected_hosts) == 100
    assert len(envelope.affected_services) == 100


@pytest.mark.parametrize("field", ("incident_id", "rule_name", "group_key", "summary"))
@pytest.mark.parametrize("invalid_value", ("", "x" * 257))
def test_notification_envelope_rejects_required_string_boundary_violations(
    field: str, invalid_value: str
) -> None:
    with pytest.raises(ValidationError):
        _notification_envelope(**{field: invalid_value})


@pytest.mark.parametrize("field", ("affected_hosts", "affected_services"))
@pytest.mark.parametrize(
    "invalid_value",
    (tuple("entry" for _ in range(101)), ("x" * 257,)),
)
def test_notification_envelope_rejects_collection_boundary_violations(
    field: str, invalid_value: tuple[str, ...]
) -> None:
    with pytest.raises(ValidationError):
        _notification_envelope(**{field: invalid_value})


@pytest.mark.parametrize(
    ("field", "value"),
    (
        ("raw_plugin_options", {"password": "super-secret"}),
        ("incident", {"id": "raw-incident"}),
    ),
)
def test_notification_envelope_rejects_raw_data_extras(field: str, value: object) -> None:
    with pytest.raises(ValidationError):
        _notification_envelope(**{field: value})


def test_notification_envelope_rejects_non_enum_severity() -> None:
    with pytest.raises(ValidationError):
        _notification_envelope(severity="CRITICAL")


@pytest.mark.parametrize(
    ("field", "replacement"),
    (
        ("incident_id", "updated-incident"),
        ("rule_name", "updated-rule"),
        ("group_key", "host=updated"),
        ("severity", Severity.WARNING),
        ("summary", "updated summary"),
        ("affected_hosts", ("db-2",)),
        ("affected_services", ("mysql",)),
    ),
)
def test_notification_envelope_is_frozen_after_construction(field: str, replacement: object) -> None:
    envelope = _notification_envelope()
    original = envelope.model_dump()

    with pytest.raises(ValidationError) as exc_info:
        setattr(envelope, field, replacement)

    assert exc_info.value.errors()[0]["type"] == "frozen_instance"
    assert envelope.model_dump() == original

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
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.processing.notification_dispatcher import NotificationDispatcher

    incident_id = await _insert_incident(session_factory)
    plugin = CapturingPlugin()
    attempts: list[tuple[str, str]] = []
    monkeypatch.setattr(
        "app.processing.notification_dispatcher.record_notification_attempt",
        lambda plugin_name, category: attempts.append((plugin_name, category)),
    )
    dispatcher = NotificationDispatcher(session_factory, Registry({"email-oncall": plugin}))

    result = await dispatcher.process(
        {"incident_id": str(incident_id), "plugin_name": "email-oncall", "config_hash": "sha256:plugins"}
    )

    assert result.success is True
    assert result.category == "dispatched"
    assert len(plugin.envelopes) == 1
    assert attempts == [("email-oncall", "dispatched")]
    envelope = plugin.envelopes[0]
    assert isinstance(envelope, NotificationEnvelope)
    assert envelope.affected_hosts == ("db-1",)
    assert envelope.affected_services == ("postgres",)
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
    assert context["notification_delivery_results"] == [
        {
            "schema_version": 1,
            "plugin_name": "email-oncall",
            "result": {
                "success": False,
                "category": "dispatch_failed",
                "message": "stale plugin configuration",
            },
        }
    ]

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
    assert context["notification_delivery_results"] == [
        {
            "schema_version": 1,
            "plugin_name": "failing",
            "result": {
                "success": False,
                "category": "plugin_exception",
                "message": "notification plugin failed",
            },
        },
        {
            "schema_version": 1,
            "plugin_name": "missing",
            "result": {
                "success": False,
                "category": "missing_plugin",
                "message": "configured output plugin is missing",
            },
        },
    ]
    assert "smtp transcript" not in serialized_context


async def test_ingress_persists_post_commit_terminal_runner_failure(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    from app.domain.notifications import NotificationResult
    from app.domain.rules import RuleDecision, ThresholdDecision
    from app.processing.ingress import Icinga2DecisionProcessor

    incident_id = await _insert_incident(session_factory)
    timestamp = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    processor = Icinga2DecisionProcessor(
        object(),
        sessionmaker=session_factory,
        task_runner=None,
        plugin_registry=Registry({}),
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-key",
    )
    results = await processor._submit_notifications(
        incident_id,
        RuleDecision(
            rule_name="database-critical",
            priority=1,
            matched_rules=["database-critical"],
            group_key="service=postgres",
            threshold_decision=ThresholdDecision(
                rule_name="database-critical",
                group_key="service=postgres",
                window_start=timestamp,
                window_end=timestamp,
                threshold=1,
                counted_fingerprints=[],
                counted=1,
                crossed=True,
            ),
            summary="database incident",
            actions=["email-oncall"],
        ),
    )

    assert results == (
        NotificationResult(
            success=False,
            category="dispatch_failed",
            message="notification task runner is unavailable",
        ),
    )
    async with session_factory() as session:
        context = (
            await session.execute(
                sa.text(
                    "SELECT decision_context FROM incidents WHERE id = :id"
                ),
                {"id": incident_id},
            )
        ).scalar_one()
    assert context["notification_delivery_results"] == [
        {
            "schema_version": 1,
            "plugin_name": "email-oncall",
            "result": {
                "success": False,
                "category": "dispatch_failed",
                "message": "notification task runner is unavailable",
            },
        }
    ]
