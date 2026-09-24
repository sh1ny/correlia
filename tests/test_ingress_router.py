from collections.abc import AsyncIterator, Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
import asyncio
import inspect
import logging
import subprocess
import os
import sys

import yaml

import pytest
import sqlalchemy as sa
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.config.plugins import load_plugin_registry_config
from app.config.settings import Settings
from app.domain.events import Severity
from app.domain.rules import RuleDecision, ThresholdDecision
from app.main import create_app
from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident
from app.plugins.inputs.icinga2 import Icinga2InputPlugin
from app.plugins.loader import PluginRegistry
from app.processing.ingress import (
    Icinga2DecisionProcessor,
    build_icinga2_processor as _real_build_icinga2_processor,
)
from app.processing.task_runner import AsyncIOTaskRunner
from app.plugins.interfaces import NotificationEnvelope, PluginStatus


def build_icinga2_processor(
    topology_path=None,
    rules_path=None,
    *,
    sessionmaker=None,
    task_runner=None,
    plugin_registry=None,
    **extra: object,
):
    """Test wrapper supplying default audit kwargs.

    Real-DB tests must pass their own ``sessionmaker=``; rejection and
    422 validation tests can leave ``sessionmaker=None`` because ingress
    short-circuits before AUD-02 audit writes. The fail-fast test
    ``test_accepted_event_without_sessionmaker_fails_fast_for_audit``
    calls ``_real_build_icinga2_processor`` directly to exercise the
    audit-misconfiguration path without wrapper interference.
    """
    return _real_build_icinga2_processor(
        topology_path=topology_path,
        rules_path=rules_path,
        sessionmaker=sessionmaker,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )


async def _count_audit_rows(session_factory: async_sessionmaker[AsyncSession]) -> int:
    async with session_factory() as session:
        result = await session.execute(sa.text("SELECT COUNT(*) FROM incident_events"))
    return int(result.scalar_one())


VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


def _event_time() -> datetime:
    return datetime(2026, 6, 8, 12, 0, tzinfo=timezone.utc)


pytestmark = pytest.mark.anyio


@pytest.fixture(autouse=True)
def _disable_auth_for_ingress_tests(
    monkeypatch: pytest.MonkeyPatch, clean_settings_env: None
) -> None:
    monkeypatch.setenv("CORRELIA_API_AUTH_ENABLED", "false")
    monkeypatch.setenv("CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY", "test-audit-hmac")


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
        env={**os.environ, "CORRELIA_API_AUTH_ENABLED": "false"},
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
async def session_factory(postgres_url: str):
    engine = create_async_engine(postgres_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()

    cleanup = create_async_engine(postgres_url)
    async with AsyncSession(cleanup, expire_on_commit=False) as session:
        # incident_events holds correlation IDs as JSONB, not FKs, so
        # CASCADE does not reach it; truncate it explicitly.
        await session.execute(
            sa.text(
                "TRUNCATE TABLE incident_events, incidents RESTART IDENTITY CASCADE"
            )
        )
        await session.commit()
    await cleanup.dispose()


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


class NoopLifecycleWorker:
    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None


class GateOutputPlugin:
    def __init__(self, *, raises_after_release: bool = False) -> None:
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.raises_after_release = raises_after_release
        self.envelopes: list[NotificationEnvelope] = []

    async def send_notification(self, envelope: NotificationEnvelope) -> None:
        self.envelopes.append(envelope)
        self.started.set()
        await self.release.wait()
        if self.raises_after_release:
            raise RuntimeError("controlled output failure")

    def plugin_status(self) -> PluginStatus:
        return PluginStatus(plugin_type="test", ready=True, status="ready")


class SynchronizedOutputRegistry:
    def __init__(self, plugins: Mapping[str, GateOutputPlugin]) -> None:
        self._plugins = dict(plugins)
        self.available_names = set(plugins)
        self.config_hash = "sha256:integration-plugins"

    @property
    def names(self) -> tuple[str, ...]:
        return tuple(sorted(self.available_names))

    def get_plugin(self, name: str) -> GateOutputPlugin:
        return self._plugins[name]

    def list_plugins(self) -> tuple[dict[str, object], ...]:
        return ()


class RaisingSubmitRunner:
    registered_task_names: tuple[str, ...] = ()

    def __init__(self) -> None:
        self.submissions: list[tuple[str, dict[str, Any]]] = []

    @property
    def pending_count(self) -> int:
        return 0

    def register(self, task_name: str, handler: Any) -> None:
        return None

    async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None:
        self.submissions.append((task_name, dict(payload)))
        raise RuntimeError("controlled submit failure")

    async def drain(self) -> None:
        return None


def valid_icinga2_service_payload() -> dict[str, object]:
    return {
        "source_id": "icinga2:service:web-01:http",
        "host": "web-01",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "HTTP 503",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform"},
    }


def valid_icinga2_host_payload() -> dict[str, object]:
    return {
        "source_id": "icinga2:host:web-01",
        "host": "web-01",
        "service": None,
        "state": "DOWN",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "Host is unreachable",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform"},
    }


def _write_rules(
    path: Path,
    threshold: int = 2,
    actions: tuple[str, ...] = ("email-oncall",),
    rule_name: str = "service-critical",
) -> None:
    path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": rule_name,
                        "priority": 10,
                        "match": {
                            "severities": ["CRITICAL"],
                            "host_pattern": ".*",
                            "service_pattern": "http",
                        },
                        "window": {
                            "duration_seconds": 300,
                            "group_by": ["service"],
                            "trigger_threshold": threshold,
                        },
                        "output_summary": "Critical {service} in {topology.site}",
                        "actions": [
                            {"name": "create_incident", "plugin": plugin_name}
                            for plugin_name in actions
                        ],
                    }
                ]
            }
        )
    )


def _write_topology(path: Path) -> None:
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [],
                "subnet_rules": [
                    {
                        "id": "dc1-subnet",
                        "name": "DC1 Subnet",
                        "subnet": "192.0.2.0/24",
                        "tags": {"topology.site": "dc1"},
                    }
                ],
            }
        )
    )


def _write_plugins(path: Path) -> PluginRegistry:
    path.write_text(
        yaml.safe_dump(
            {
                "outputs": [
                    {
                        "name": "email-oncall",
                        "plugin_type": "email",
                        "class_path": "app.plugins.outputs.email.SmtpOutputPlugin",
                        "options": {
                            "host": "localhost",
                            "port": 1025,
                            "to_addresses": ["ops@example.test"],
                            "username": "operator",
                            "password": "super-secret",
                            "start_tls": True,
                        },
                    }
                ]
            }
        )
    )
    config = load_plugin_registry_config(path)
    return PluginRegistry(config.outputs, config.config_hash)


def _payload(
    *,
    host: str,
    source_id: str,
    timestamp: str = "2026-06-08T12:00:00+00:00",
) -> dict[str, object]:
    payload = valid_icinga2_service_payload()
    payload["host"] = host
    payload["source_id"] = source_id
    payload["timestamp"] = timestamp
    return payload


async def test_submit_notifications_without_task_runner_reports_failed_result_per_action(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    submissions: list[str] = []
    monkeypatch.setattr(
        "app.processing.ingress.record_notification_submission",
        submissions.append,
    )
    decision = RuleDecision(
        rule_name="critical-rule",
        priority=10,
        matched_rules=["critical-rule"],
        group_key="service=http",
        threshold_decision=ThresholdDecision(
            rule_name="critical-rule",
            group_key="service=http",
            window_start=_event_time(),
            window_end=_event_time(),
            threshold=1,
            counted_fingerprints=["first"],
            counted=1,
            crossed=True,
        ),
        summary="critical http service",
        actions=["zeta", "alpha", "zeta"],
    )
    processor = Icinga2DecisionProcessor(
        plugin=Icinga2InputPlugin(),
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )

    results = await processor._submit_notifications("incident-1", decision)

    assert [(result.success, result.category) for result in results] == [
        (False, "dispatch_failed"),
        (False, "dispatch_failed"),
    ]
    assert submissions == ["missing_runner", "missing_runner"]
    assert await processor._submit_notifications("incident-1", None) == ()
    assert submissions == ["missing_runner", "missing_runner"]


async def test_rejected_notification_submission_is_not_accepted(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class RejectingRunner:
        async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None:
            raise RuntimeError("submission rejected")

    class KnownRegistry:
        names = ("email-oncall",)

    class Decision:
        actions = ("email-oncall",)

    submissions: list[str] = []
    monkeypatch.setattr(
        "app.processing.ingress.record_notification_submission", submissions.append
    )
    processor = Icinga2DecisionProcessor(
        plugin=Icinga2InputPlugin(),
        task_runner=RejectingRunner(),  # type: ignore[arg-type]
        plugin_registry=KnownRegistry(),
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )

    results = await processor._submit_notifications("incident-1", Decision())  # type: ignore[arg-type]

    assert [(result.success, result.category) for result in results] == [
        (False, "dispatch_failed")
    ]
    assert submissions == ["submit_failed"]


async def test_icinga2_problem_webhook_aggregates_and_submits_notifications_once(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    rules_path = tmp_path / "rules.yaml"
    topology_path = tmp_path / "topology.yaml"
    plugins_path = tmp_path / "plugins.yaml"
    _write_rules(rules_path)
    _write_topology(topology_path)
    plugin_registry = _write_plugins(plugins_path)
    task_runner = AsyncIOTaskRunner()
    submissions: list[str] = []
    monkeypatch.setattr(
        "app.processing.ingress.record_notification_submission", submissions.append
    )
    submitted: list[dict[str, object]] = []

    async def capture_notify(payload: dict[str, object]) -> None:
        submitted.append(dict(payload))

    task_runner.register("notify", capture_notify)
    processor = build_icinga2_processor(
        topology_path=topology_path,
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
    )

    async for client in get_client(app):
        first = await client.post(
            "/v1/icinga2/events",
            json=_payload(host="web-01", source_id="icinga2:service:web-01:http"),
        )
        second = await client.post(
            "/v1/icinga2/events",
            json=_payload(
                host="web-02",
                source_id="icinga2:service:web-02:http",
                timestamp="2026-06-08T12:01:00+00:00",
            ),
        )
        replay = await client.post(
            "/v1/icinga2/events",
            json=_payload(
                host="web-02",
                source_id="icinga2:service:web-02:http",
                timestamp="2026-06-08T12:01:00+00:00",
            ),
        )
        already = await client.post(
            "/v1/icinga2/events",
            json=_payload(
                host="web-03",
                source_id="icinga2:service:web-03:http",
                timestamp="2026-06-08T12:02:00+00:00",
            ),
        )
        await task_runner.drain()

    first_body = first.json()
    second_body = second.json()
    replay_body = replay.json()
    already_body = already.json()
    assert first_body["incident_id"] is not None
    assert first_body["incident_effects"] == {"inserted": 1, "updated": 0}
    assert first_body["threshold_crossed"] is False
    assert first_body["notification_triggered"] is False
    assert first_body["notification_count"] == 0
    assert first_body["notification_failed"] is False
    assert first_body["no_dispatch_reason"] == "below_threshold"
    assert first_body["notification_results"] == []
    assert first_body["final_tags"]["topology.site"] == "dc1"

    assert second_body["incident_id"] == first_body["incident_id"]
    assert second_body["incident_effects"] == {"inserted": 0, "updated": 1}
    assert second_body["threshold_crossed"] is True
    assert second_body["notification_triggered"] is True
    assert second_body["notification_count"] == 1
    assert second_body["notification_failed"] is False
    assert second_body["no_dispatch_reason"] is None
    assert second_body["notification_results"][0]["category"] == "dispatched"
    assert submitted == [
        {
            "incident_id": second_body["incident_id"],
            "plugin_name": "email-oncall",
            "config_hash": plugin_registry.config_hash,
        }
    ]

    assert replay_body["incident_effects"] == {"inserted": 0, "updated": 1}
    assert replay_body["notification_triggered"] is False
    assert replay_body["notification_count"] == 0
    assert replay_body["no_dispatch_reason"] == "replay"
    assert already_body["notification_triggered"] is False
    assert already_body["notification_count"] == 0
    assert already_body["no_dispatch_reason"] == "already_notified"
    assert len(submitted) == 1
    assert submissions == ["accepted"]
    # AUD-02: every accepted event must write exactly one audit row.
    assert (await _count_audit_rows(session_factory)) == 4


async def test_ingress_returns_after_submission_before_slow_plugin_exception_is_terminal(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
    caplog: pytest.LogCaptureFixture,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    rules_path = tmp_path / "rules.yaml"
    topology_path = tmp_path / "topology.yaml"
    _write_rules(rules_path, threshold=1)
    _write_topology(topology_path)
    plugin = GateOutputPlugin(raises_after_release=True)
    plugin_registry = SynchronizedOutputRegistry({"email-oncall": plugin})
    task_runner = AsyncIOTaskRunner()
    submissions: list[str] = []
    deliveries: list[tuple[str, str]] = []
    monkeypatch.setattr(
        "app.processing.ingress.record_notification_submission", submissions.append
    )
    monkeypatch.setattr(
        "app.processing.notification_dispatcher.record_notification_delivery",
        lambda outcome, category: deliveries.append((outcome, category)),
    )
    processor = build_icinga2_processor(
        topology_path=topology_path,
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
        plugin_registry=plugin_registry,  # type: ignore[arg-type]
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )

    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=_payload(host="web-01", source_id="icinga2:service:web-01:http"),
        )
        body = response.json()
        assert response.status_code == 200
        assert body["notification_results"] == [
            {
                "success": True,
                "category": "dispatched",
                "message": "notification task submitted",
            }
        ]
        assert submissions == ["accepted"]
        assert deliveries == []

        await plugin.started.wait()
        before_release = await client.get(f"/v1/incidents/{body['incident_id']}")
        assert before_release.status_code == 200
        assert before_release.json()["notified_at"] is None
        assert (
            before_release.json()["decision_context"]["notification_delivery_results"]
            == []
        )
        assert await _count_audit_rows(session_factory) == 1

        assert deliveries == []
        plugin.release.set()
        await task_runner.drain()
        assert deliveries == [("failure", "plugin_exception")]
        after_release = await client.get(f"/v1/incidents/{body['incident_id']}")

    assert after_release.status_code == 200
    assert after_release.json()["notified_at"] is None
    assert after_release.json()["decision_context"][
        "notification_delivery_results"
    ] == [
        {
            "schema_version": 1,
            "plugin_name": "email-oncall",
            "result": {
                "success": False,
                "category": "plugin_exception",
                "message": "notification plugin failed",
            },
        }
    ]
    assert plugin.envelopes[0].incident_id == body["incident_id"]
    assert not [
        record
        for record in caplog.records
        if record.getMessage() == "async task handler failed"
    ]


async def test_ingress_returns_before_slow_plugin_success_becomes_terminal(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    rules_path = tmp_path / "rules.yaml"
    topology_path = tmp_path / "topology.yaml"
    _write_rules(rules_path, threshold=1)
    _write_topology(topology_path)
    plugin = GateOutputPlugin()
    plugin_registry = SynchronizedOutputRegistry({"email-oncall": plugin})
    task_runner = AsyncIOTaskRunner()
    processor = build_icinga2_processor(
        topology_path=topology_path,
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
        plugin_registry=plugin_registry,  # type: ignore[arg-type]
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )

    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=_payload(host="web-01", source_id="icinga2:service:web-01:http"),
        )
        body = response.json()
        assert response.status_code == 200
        await plugin.started.wait()

        before_release = await client.get(f"/v1/incidents/{body['incident_id']}")
        assert before_release.json()["notified_at"] is None
        assert (
            before_release.json()["decision_context"]["notification_delivery_results"]
            == []
        )

        plugin.release.set()
        await task_runner.drain()
        after_release = await client.get(f"/v1/incidents/{body['incident_id']}")

    assert after_release.json()["notified_at"] is not None
    assert after_release.json()["decision_context"][
        "notification_delivery_results"
    ] == [
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


async def test_ingress_retains_twenty_terminal_results_through_aggregation_and_restart(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
    postgres_url: str,
) -> None:
    plugin_names = tuple(f"output-{index:02d}" for index in range(20))
    rules_path = tmp_path / "rules.yaml"
    topology_path = tmp_path / "topology.yaml"
    _write_rules(rules_path, threshold=1, actions=plugin_names)
    _write_topology(topology_path)
    plugins = {name: GateOutputPlugin() for name in plugin_names}
    for plugin in plugins.values():
        plugin.release.set()
    plugin_registry = SynchronizedOutputRegistry(plugins)
    task_runner = AsyncIOTaskRunner()
    processor = build_icinga2_processor(
        topology_path=topology_path,
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
        plugin_registry=plugin_registry,  # type: ignore[arg-type]
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )

    async for client in get_client(app):
        first = await client.post(
            "/v1/icinga2/events",
            json=_payload(host="web-01", source_id="icinga2:service:web-01:http"),
        )
        assert first.status_code == 200
        assert len(first.json()["notification_results"]) == 20
        assert all(
            result
            == {
                "success": True,
                "category": "dispatched",
                "message": "notification task submitted",
            }
            for result in first.json()["notification_results"]
        )
        incident_id = first.json()["incident_id"]
        await task_runner.drain()
        completed = await client.get(f"/v1/incidents/{incident_id}")
        assert completed.status_code == 200
        completed_context = completed.json()["decision_context"]
        assert [
            record["plugin_name"]
            for record in completed_context["notification_delivery_results"]
        ] == list(plugin_names)
        assert all(
            record["result"]
            == {
                "success": True,
                "category": "dispatched",
                "message": "notification dispatched",
            }
            for record in completed_context["notification_delivery_results"]
        )
        notes_before_aggregation = completed_context["notes"]

        later = await client.post(
            "/v1/icinga2/events",
            json=_payload(
                host="web-02",
                source_id="icinga2:service:web-02:http",
                timestamp="2026-06-08T12:01:00+00:00",
            ),
        )
        assert later.status_code == 200
        assert later.json()["incident_id"] == incident_id
        assert later.json()["notification_results"] == []
        aggregated = await client.get(f"/v1/incidents/{incident_id}")

    assert aggregated.status_code == 200
    aggregated_context = aggregated.json()["decision_context"]
    assert {
        key: aggregated_context["notes"][key] for key in notes_before_aggregation
    } == notes_before_aggregation
    assert [
        record["plugin_name"]
        for record in aggregated_context["notification_delivery_results"]
    ] == list(plugin_names)

    fresh_engine = create_async_engine(postgres_url)
    fresh_session_factory = async_sessionmaker(fresh_engine, expire_on_commit=False)
    fresh_plugins = {name: GateOutputPlugin() for name in plugin_names}
    fresh_registry = SynchronizedOutputRegistry(fresh_plugins)
    fresh_runner = AsyncIOTaskRunner()
    fresh_processor = build_icinga2_processor(
        topology_path=topology_path,
        rules_path=rules_path,
        sessionmaker=fresh_session_factory,
        task_runner=fresh_runner,
        plugin_registry=fresh_registry,
    )
    fresh_app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=fresh_session_factory,
        icinga2_processor=fresh_processor,
        task_runner=fresh_runner,
        plugin_registry=fresh_registry,  # type: ignore[arg-type]
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )
    try:
        async for fresh_client in get_client(fresh_app):
            reopened = await fresh_client.get(f"/v1/incidents/{incident_id}")
    finally:
        await fresh_engine.dispose()

    assert reopened.status_code == 200
    reopened_context = reopened.json()["decision_context"]
    assert reopened_context["notes"] == aggregated_context["notes"]
    assert (
        reopened_context["notification_delivery_results"]
        == aggregated_context["notification_delivery_results"]
    )


async def test_ingress_persists_terminal_submission_failures_without_tasks(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async def assert_submission_failure(
        *,
        scenario: str,
        processor_runner: Any,
        app_runner: Any,
        category: str,
        message: str,
        hide_plugin_before_submission: bool = False,
    ) -> None:
        rules_path = tmp_path / f"{scenario}-rules.yaml"
        topology_path = tmp_path / f"{scenario}-topology.yaml"
        _write_rules(
            rules_path,
            threshold=1,
            rule_name=f"submission-{scenario}",
        )
        _write_topology(topology_path)
        registry = SynchronizedOutputRegistry({"email-oncall": GateOutputPlugin()})
        processor = build_icinga2_processor(
            topology_path=topology_path,
            rules_path=rules_path,
            sessionmaker=session_factory,
            task_runner=processor_runner,
            plugin_registry=registry,
        )
        if hide_plugin_before_submission:
            registry.available_names.clear()
        app = create_app(
            settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
            sessionmaker=session_factory,
            icinga2_processor=processor,
            task_runner=app_runner,
            plugin_registry=registry,  # type: ignore[arg-type]
            lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
        )

        async for client in get_client(app):
            response = await client.post(
                "/v1/icinga2/events",
                json=_payload(
                    host=f"{scenario}-host",
                    source_id=f"icinga2:service:{scenario}-host:http",
                ),
            )
            assert response.status_code == 200
            body = response.json()
            assert body["notification_results"] == [
                {"success": False, "category": category, "message": message}
            ]
            detail = await client.get(f"/v1/incidents/{body['incident_id']}")

        assert detail.status_code == 200
        assert detail.json()["notified_at"] is None
        assert detail.json()["decision_context"]["notification_delivery_results"] == [
            {
                "schema_version": 1,
                "plugin_name": "email-oncall",
                "result": {
                    "success": False,
                    "category": category,
                    "message": message,
                },
            }
        ]
        assert app_runner.pending_count == 0

    unavailable_app_runner = AsyncIOTaskRunner()
    await assert_submission_failure(
        scenario="no-runner",
        processor_runner=None,
        app_runner=unavailable_app_runner,
        category="dispatch_failed",
        message="notification task runner is unavailable",
    )

    missing_runner = AsyncIOTaskRunner()
    await assert_submission_failure(
        scenario="missing-plugin",
        processor_runner=missing_runner,
        app_runner=missing_runner,
        category="missing_plugin",
        message="configured output plugin is missing",
        hide_plugin_before_submission=True,
    )

    raising_runner = RaisingSubmitRunner()
    await assert_submission_failure(
        scenario="submit-raises",
        processor_runner=raising_runner,
        app_runner=raising_runner,
        category="dispatch_failed",
        message="notification task submission failed",
    )
    assert raising_runner.submissions and raising_runner.submissions[0][0] == "notify"


async def test_ingress_without_rule_engine_persists_configuration_reason(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )

    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
        assert response.status_code == 200
        audit_response = await client.get("/v1/incident-events")

    assert audit_response.status_code == 200
    assert (
        audit_response.json()["items"][0]["decision_summary"]["no_dispatch_reason"]
        == "no rule engine configured"
    )


async def test_ingress_maps_long_missing_group_by_reason_to_bounded_audit_code(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    long_missing_field = "a" * 256
    rules_path = tmp_path / "rules.yaml"
    rules_path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "missing-group-by",
                        "priority": 10,
                        "match": {
                            "severities": ["CRITICAL"],
                            "host_pattern": ".*",
                            "service_pattern": "http",
                        },
                        "window": {
                            "duration_seconds": 300,
                            "group_by": [long_missing_field],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "Critical service",
                        "actions": [
                            {"name": "create_incident", "plugin": "email-oncall"}
                        ],
                    }
                ]
            }
        )
    )
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )

    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
        audit_response = await client.get("/v1/incident-events")

    assert response.status_code == 200
    body = response.json()
    assert body["state_accepted"] is True
    assert body["rule_decision"]["reason"] == (
        f"missing required group-by field: {long_missing_field}"
    )
    assert audit_response.status_code == 200
    summary = audit_response.json()["items"][0]["decision_summary"]
    assert summary["decision_kind"] == "noop"
    assert summary["decision_reason"] == "missing_required_group_by_field"
    assert summary["no_dispatch_reason"] == "missing_required_group_by_field"


async def test_ingress_logs_safe_json_events(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
    caplog: pytest.LogCaptureFixture,
) -> None:
    rules_path = tmp_path / "rules.yaml"
    topology_path = tmp_path / "topology.yaml"
    plugins_path = tmp_path / "plugins.yaml"
    _write_rules(rules_path, threshold=1)
    _write_topology(topology_path)
    plugin_registry = _write_plugins(plugins_path)
    task_runner = AsyncIOTaskRunner()
    submitted: list[dict[str, object]] = []

    async def capture_notify(payload: dict[str, object]) -> None:
        submitted.append(dict(payload))

    task_runner.register("notify", capture_notify)
    processor = build_icinga2_processor(
        topology_path=topology_path,
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
        lifecycle_worker=NoopLifecycleWorker(),
    )

    caplog.set_level(logging.INFO)
    payload = _payload(host="web-01", source_id="icinga2:service:web-01:http")
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
        await task_runner.drain()

    assert response.status_code == 200
    events = {
        record.__dict__.get("event"): record
        for record in caplog.records
        if record.name.startswith("app.processing")
    }
    for expected in (
        "ingestion_received",
        "normalization_succeeded",
        "enrichment_completed",
        "rule_matched",
        "incident_upserted",
        "notification_decision",
    ):
        assert expected in events
    assert (
        events["incident_upserted"].__dict__["incident_id"]
        == response.json()["incident_id"]
    )
    assert events["incident_upserted"].__dict__["rule_name"] == "service-critical"
    assert events["incident_upserted"].__dict__["group_key"] == "service=http"
    assert events["notification_decision"].__dict__["notification_count"] == 1
    serialized = "\n".join(
        record.getMessage() + repr(record.__dict__) for record in caplog.records
    )
    for fragment in ("token-secret", "raw_payload", "password", "smtp transcript"):
        assert fragment not in serialized


async def test_recovery_event_does_not_enter_problem_aggregation(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=1)
    task_runner = AsyncIOTaskRunner()
    task_runner.register("notify", lambda payload: None)
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
        plugin_registry=PluginRegistry((), "sha256:empty"),
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
    )
    payload = valid_icinga2_host_payload()
    payload["state"] = "UP"

    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)

    body = response.json()
    assert body["event_type"] == "RECOVERY"
    assert body["incident_id"] is None
    assert body["incident_effects"] == {"inserted": 0, "updated": 0}
    async with session_factory() as session:
        count = (
            await session.execute(sa.text("SELECT COUNT(*) FROM incidents"))
        ).scalar_one()
    assert count == 0


async def test_recovery_routes_to_lifecycle_without_problem_upsert(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=1)
    async with session_factory() as session:
        incident = await upsert_open_incident(
            session,
            IncidentUpsertInput(
                rule_name="service-critical",
                group_key="service:http",
                severity=Severity.CRITICAL,
                event_time=_event_time(),
                summary="Critical http in dc1",
                affected_hosts=("web-01",),
                affected_services=("http",),
                fingerprint="problem-fp",
            ),
        )
        await session.commit()
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=AsyncIOTaskRunner(),
        plugin_registry=PluginRegistry((), "sha256:empty"),
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )
    payload = valid_icinga2_service_payload()
    payload["state"] = "OK"

    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)

    body = response.json()
    assert body["event_type"] == "RECOVERY"
    assert body["incident_id"] == str(incident.id)
    assert body["incident_effects"] == {"inserted": 0, "updated": 0}
    assert body["lifecycle_outcome"]["effect"] in {"resolved", "affected_set_shrunk"}
    assert body["lifecycle_outcome"]["reason"] == "source_recovery"
    assert body["recovery_resolution"] == "resolved"
    assert body["notification_count"] == 0
    async with session_factory() as session:
        row = await session.get(type(incident), incident.id)
    assert row is not None
    assert row.status == "RESOLVED"


async def test_recovery_response_contains_lifecycle_outcome_without_notification(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=1)
    submitted: list[dict[str, object]] = []
    task_runner = AsyncIOTaskRunner()

    async def capture_notify(payload: dict[str, object]) -> None:
        submitted.append(dict(payload))

    task_runner.register("notify", capture_notify)
    async with session_factory() as session:
        await upsert_open_incident(
            session,
            IncidentUpsertInput(
                rule_name="service-critical",
                group_key="service:http",
                severity=Severity.CRITICAL,
                event_time=_event_time(),
                summary="Critical http in dc1",
                affected_hosts=("web-01", "web-02"),
                affected_services=("http",),
                fingerprint="problem-fp",
            ),
        )
        await session.commit()
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
        plugin_registry=PluginRegistry((), "sha256:empty"),
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )
    payload = valid_icinga2_service_payload()
    payload["state"] = "OK"

    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
        await task_runner.drain()

    body = response.json()
    assert body["threshold_decision"] is None
    assert body["lifecycle_outcome"]["effect"] == "affected_set_shrunk"
    assert body["affected_object_removed"] is True
    assert body["notification_count"] == 0
    assert submitted == []


def test_recovery_branch_does_not_call_apply_problem_or_raw_state_names() -> None:
    import app.processing.ingress as ingress_module

    source = inspect.getsource(ingress_module.Icinga2DecisionProcessor.process_payload)
    recovery_start = source.index("elif event.event_type is EventType.RECOVERY:")
    recovery_end = source.index("\n\n            summary =", recovery_start)
    recovery_branch = source[recovery_start:recovery_end]

    assert "LifecycleManager(" in recovery_branch
    assert "resolve_for_event" in recovery_branch
    assert "IncidentManager(" not in recovery_branch
    # Raw Icinga2 fields must not appear in ingress.
    assert "state_type" not in source
    assert "check_output" not in source


# ING-01: POST /webhooks/icinga2 exists and returns 200


async def test_icinga2_ingest_failure_logs_only_safe_structured_fields(
    caplog: pytest.LogCaptureFixture,
) -> None:
    class ExplodingProcessor:
        async def process_payload(self, payload):
            raise RuntimeError("token-secret traceback should not be logged")

    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=ExplodingProcessor(),
        lifecycle_worker=NoopLifecycleWorker(),
    )
    caplog.set_level(logging.ERROR, logger="app.api.routers.ingress")

    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )

    assert response.status_code == 500
    events = [
        record.__dict__
        for record in caplog.records
        if record.__dict__.get("event") == "ingestion_failed"
    ]
    assert len(events) == 1
    assert events[0]["exception_type"] == "RuntimeError"
    serialized = "\n".join(
        record.getMessage() + repr(record.__dict__) for record in caplog.records
    )
    for fragment in ("token-secret", "traceback", "Traceback"):
        assert fragment not in serialized


async def test_post_webhook_icinga2_returns_200_for_hard_service(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    assert response.status_code == 200


async def test_post_webhook_icinga2_returns_200_for_hard_host(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_host_payload(),
        )
    assert response.status_code == 200


# D-06 / ING-05: decision envelope shape
async def test_response_contains_state_accepted_true_for_hard_event(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["state_accepted"] is True


async def test_response_contains_event_id_equal_to_fingerprint(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["event_id"] == body["fingerprint"]
    assert len(body["fingerprint"]) == 32


async def test_response_contains_mapped_event_type_and_severity(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["event_type"] == "PROBLEM"
    assert body["severity"] == "CRITICAL"


async def test_response_contains_mapped_recovery_event_type_and_severity(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    payload = valid_icinga2_host_payload()
    payload["state"] = "UP"
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=payload,
        )
    body = response.json()
    assert body["event_type"] == "RECOVERY"
    assert body["severity"] == "OK"


async def test_response_contains_final_tags(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert "final_tags" in body
    assert body["final_tags"]["team.name"] == "platform"


async def test_response_contains_empty_matched_rules(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """D-16: no-match events return matched_rules == [] before rule engine exists."""
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["matched_rules"] == []


async def test_response_contains_none_group_key(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["group_key"] is None


async def test_response_contains_zero_incident_effects(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["incident_effects"]["inserted"] == 0
    assert body["incident_effects"]["updated"] == 0
    assert body["closure_count"] == 0
    assert body["notification_count"] == 0


# D-01: SOFT states return non-actionable diagnostics


async def test_soft_state_returns_state_accepted_false() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = valid_icinga2_service_payload()
    payload["state_type"] = "SOFT"
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["state_accepted"] is False
    assert body["rejection"]["state_type"] == "SOFT"


# ING-02: malformed payloads fail validation with 422


async def test_extra_field_rejected_with_422() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = valid_icinga2_service_payload()
    payload["extra"] = "surprise"
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    assert response.status_code == 422


async def test_oversized_source_id_rejected_before_audit_write(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    payload = valid_icinga2_service_payload()
    payload["source_id"] = "x" * 257

    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)

    assert response.status_code == 422
    assert await _count_audit_rows(session_factory) == 0


@pytest.mark.parametrize("field", ("host", "service"))
async def test_oversized_host_or_service_rejected_before_audit_write(
    field: str,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    payload = valid_icinga2_service_payload()
    payload[field] = "x" * 257

    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)

    assert response.status_code == 422
    assert await _count_audit_rows(session_factory) == 0


async def test_host_with_service_state_rejected_with_422() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = valid_icinga2_host_payload()
    payload["state"] = "OK"
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    assert response.status_code == 422


async def test_naive_timestamp_rejected_with_422() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = valid_icinga2_service_payload()
    payload["timestamp"] = "2026-06-08T12:00:00"
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    assert response.status_code == 422


# T-02-01-I: response body must not contain secrets or raw payload


@pytest.mark.parametrize(
    "secret_fragment",
    [
        "HTTP 503",  # raw check_output should not leak
        "192.0.2.10",  # ip_address from payload should not leak
        "postgresql://",  # database url
        "token-secret",
        "password",
    ],
)
async def test_response_body_does_not_contain_secrets_or_raw_payload(
    secret_fragment: str,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    response_body = response.text
    assert secret_fragment not in response_body


# Route exposure check


def test_v1_icinga2_events_route_is_exposed_without_legacy_alias() -> None:
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
    )
    route_paths = {route.path for route in app.routes}
    assert "/v1/icinga2/events" in route_paths
    assert "/v1/health" in route_paths
    assert "/v1/readyz" in route_paths
    assert "/v1/plugins" in route_paths
    assert "/v1/rules" in route_paths
    assert "/v1/topology" in route_paths
    assert "/v1/incidents" in route_paths
    assert "/webhooks/icinga2" not in route_paths
    assert "/health" not in route_paths
    assert "/readyz" not in route_paths
    assert "/plugins" not in route_paths
    assert "/api/v1/incidents" not in route_paths


# Source assertions: processing.ingress must not import persistence


def test_processing_ingress_dependency_boundaries_for_audit() -> None:
    """Phase 7 audit-write ownership boundaries (AUD-03).

    Ingress is the only processing module that may import audit persistence
    or audit domain symbols (for the post-decision audit row insert). The
    manager, lifecycle, persistence.incidents, and lifecycle worker modules
    must NOT import audit persistence or audit ORM symbols — keeping audit
    strictly observational.
    """

    import inspect
    import app.processing.ingress as ingress_module
    import app.processing.incident_manager as incident_manager_module
    import app.processing.lifecycle as lifecycle_module
    import app.persistence.incidents as incidents_module
    import app.processing.lifecycle_worker as lifecycle_worker_module

    ingress_source = inspect.getsource(ingress_module)
    assert "from app.persistence.audit" in ingress_source
    assert "from app.domain.audit" in ingress_source
    assert "yaml.load" not in ingress_source
    assert "eval(" not in ingress_source
    assert "exec(" not in ingress_source

    forbidden = (
        "app.persistence.audit",
        "app.domain.audit",
        "IncidentEvent",
    )
    for module_name, module in (
        ("incident_manager", incident_manager_module),
        ("lifecycle", lifecycle_module),
        ("incidents", incidents_module),
        ("lifecycle_worker", lifecycle_worker_module),
    ):
        module_source = inspect.getsource(module)
        for needle in forbidden:
            assert needle not in module_source, (
                f"{module_name} must not import {needle} — audit must remain "
                "observational and excluded from decision code"
            )


# ---------------------------------------------------------------------------
# Topology enrichment integration via HTTP entrypoint
# ---------------------------------------------------------------------------
async def test_response_with_no_topology_match_and_no_ip_returns_source_tags(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    topology_path = tmp_path / "topology.yaml"
    topology_path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web"},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    processor = build_icinga2_processor(
        topology_path=topology_path, sessionmaker=session_factory
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    payload = {
        "source_id": "icinga2:service:db-01:http",
        "host": "db-01",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "HTTP 503",
        "ip_address": None,
        "tags": {"team.name": "platform"},
    }
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    body = response.json()
    assert body["state_accepted"] is True
    assert body["final_tags"] == {"team.name": "platform"}
    assert body["enrichment_diagnostics"] == []


async def test_response_with_subnet_fallback_from_http(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    topology_path = tmp_path / "topology.yaml"
    topology_path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web"},
                    }
                ],
                "subnet_rules": [
                    {
                        "id": "dc1-subnet",
                        "name": "DC1 Subnet",
                        "subnet": "192.0.2.0/24",
                        "tags": {"topology.site": "dc1"},
                    }
                ],
            }
        )
    )
    processor = build_icinga2_processor(
        topology_path=topology_path, sessionmaker=session_factory
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    payload = {
        "source_id": "icinga2:service:db-01:http",
        "host": "db-01",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "HTTP 503",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform"},
    }
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    body = response.json()
    assert body["state_accepted"] is True
    assert body["final_tags"]["topology.site"] == "dc1"
    assert body["final_tags"]["team.name"] == "platform"
    assert len(body["enrichment_diagnostics"]) == 1
    diag = body["enrichment_diagnostics"][0]
    assert diag["match_source"] == "subnet"
    assert diag["rule_id"] == "dc1-subnet"


async def test_response_conflict_diagnostic_only_includes_matched_rule(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    topology_path = tmp_path / "topology.yaml"
    topology_path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web"},
                    },
                    {
                        "id": "db-servers",
                        "name": "DB Servers",
                        "hostname_pattern": "^db-.*",
                        "tags": {"topology.role": "db"},
                    },
                ],
                "subnet_rules": [],
            }
        )
    )
    processor = build_icinga2_processor(
        topology_path=topology_path, sessionmaker=session_factory
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    payload = {
        "source_id": "icinga2:service:web-01:http",
        "host": "web-01",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "HTTP 503",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform", "topology.role": "old"},
    }
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    body = response.json()
    assert body["state_accepted"] is True
    diagnostics = body["enrichment_diagnostics"]
    assert len(diagnostics) == 1
    diag = diagnostics[0]
    assert diag["rule_id"] == "web-servers"
    assert diag["rule_name"] == "Web Servers"
    assert diag["match_source"] == "hostname"
    assert diag["tags_added"] == {}
    assert diag["tags_overridden"] == [["topology.role", "old", "web"]]
    assert diag["conflicts"] == [["topology.role", "old", "web"]]


# ---------------------------------------------------------------------------
# Rule engine integration via HTTP entrypoint
# ---------------------------------------------------------------------------
async def test_response_with_no_rule_match_returns_empty_matched_rules(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    rules_path = tmp_path / "rules.yaml"
    rules_path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "db-only",
                        "priority": 10,
                        "match": {
                            "severities": ["CRITICAL"],
                            "host_pattern": "db-.*",
                        },
                        "window": {
                            "duration_seconds": 60,
                            "group_by": ["host"],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "x",
                        "actions": [
                            {"name": "create_incident", "plugin": "default_output"}
                        ],
                    }
                ]
            }
        )
    )
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["state_accepted"] is True
    assert body["matched_rules"] == []
    assert body["group_key"] is None
    assert body["threshold_decision"] is None
    assert body["rule_decision"]["reason"] == "no matching rule"


async def test_recovery_event_returns_no_rule_match(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    rules_path = tmp_path / "rules.yaml"
    rules_path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "all",
                        "priority": 10,
                        "match": {"severities": ["OK"], "host_pattern": ".*"},
                        "window": {
                            "duration_seconds": 60,
                            "group_by": ["host"],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "x",
                        "actions": [
                            {"name": "create_incident", "plugin": "default_output"}
                        ],
                    }
                ]
            }
        )
    )
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    payload = valid_icinga2_host_payload()
    payload["state"] = "UP"
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    body = response.json()
    assert body["state_accepted"] is True
    assert body["event_type"] == "RECOVERY"
    assert body["severity"] == "OK"
    assert body["matched_rules"] == []
    assert body["group_key"] is None
    assert body["threshold_decision"] is None


async def test_response_with_rule_match_contains_group_key_and_threshold(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    rules_path = tmp_path / "rules.yaml"
    rules_path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "web-critical",
                        "priority": 10,
                        "match": {
                            "severities": ["CRITICAL"],
                            "host_pattern": "web-.*",
                            "service_pattern": "http",
                        },
                        "window": {
                            "duration_seconds": 300,
                            "group_by": ["host", "service"],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "Critical {service} on {host}",
                        "actions": [
                            {"name": "create_incident", "plugin": "default_output"}
                        ],
                    }
                ]
            }
        )
    )
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["state_accepted"] is True
    assert body["matched_rules"] == ["web-critical"]
    assert body["group_key"] == "host=web-01|service=http"
    assert body["threshold_decision"] is not None
    td = body["threshold_decision"]
    assert td["rule_name"] == "web-critical"
    assert td["group_key"] == "host=web-01|service=http"
    assert td["threshold"] == 1
    assert td["counted"] == 1
    assert td["crossed"] is True
    assert td["counted_fingerprints"] == [body["fingerprint"]]
    assert body["rule_decision"]["rule_name"] == "web-critical"
    assert body["rule_decision"]["priority"] == 10
    assert body["rule_decision"]["summary"] == "Critical http on web-01"
    assert body["incident_effects"]["inserted"] == 1
    assert body["incident_effects"]["updated"] == 0
    assert body["closure_count"] == 0
    assert body["notification_count"] == 0


# ---------------------------------------------------------------------------
# Task 3: ingress processor must not import raw Icinga2 fields
# ---------------------------------------------------------------------------
def test_processing_ingress_has_no_icinga2_raw_state_refs() -> None:
    import inspect
    import app.processing.ingress as ingress_module

    source = inspect.getsource(ingress_module)
    assert "state_type" not in source
    assert "check_output" not in source


# ---------------------------------------------------------------------------
# Phase 7 Task 2: audit-row coverage for accepted event paths
# ---------------------------------------------------------------------------
async def test_no_rule_engine_accepted_event_writes_noop_audit_row(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """An accepted event with no rule engine must still insert exactly one
    audit row with decision_kind='noop' (AUD-02 + D-12)."""

    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
    )
    assert (await _count_audit_rows(session_factory)) == 0
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=valid_icinga2_service_payload(),
        )
    assert response.status_code == 200
    assert (await _count_audit_rows(session_factory)) == 1
    async with session_factory() as session:
        row = (
            (
                await session.execute(
                    sa.text(
                        "SELECT incident_effect, incident_ids, decision_summary "
                        "FROM incident_events"
                    )
                )
            )
            .mappings()
            .one()
        )
    assert row["incident_effect"] == "none"
    assert row["incident_ids"] == []
    summary = row["decision_summary"]
    assert summary["decision_kind"] == "noop"
    assert summary["incident_effect"] == "none"
    assert summary["notification_intent"] == "no_dispatch"


async def test_accepted_event_without_sessionmaker_fails_fast_for_audit() -> None:
    """An accepted normalized event without a sessionmaker must fail fast
    with a clear audit-misconfiguration RuntimeError (AUD-02).

    The HTTP router wraps processor errors as 500, so we exercise the
    processor directly to assert the precise RuntimeError message.
    """

    from app.plugins.inputs.icinga2 import Icinga2WebhookPayload

    # Bypass the test wrapper so sessionmaker=None is actually preserved.
    processor = _real_build_icinga2_processor(
        sessionmaker=None,
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )
    payload = Icinga2WebhookPayload.model_validate(valid_icinga2_service_payload())
    with pytest.raises(RuntimeError, match="audit"):
        await processor.process_payload(payload)
