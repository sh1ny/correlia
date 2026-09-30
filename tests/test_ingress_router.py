from collections import Counter
from collections.abc import AsyncIterator, Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import UUID
import asyncio
import json
import logging
import subprocess
import os
import sys

import yaml

import pytest
import sqlalchemy as sa
from httpx import ASGITransport, AsyncClient, Response
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.config.plugins import load_plugin_registry_config
from app.config.settings import Settings
from app.domain.events import EVENT_TAG_MAX_BYTES, Severity
from app.domain.rules import RuleMatch, RuleWindow
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


class CommittedStateRunner:
    """Capture what a separate connection can see at notification submission."""

    registered_task_names = ("notify",)

    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self.session_factory = session_factory
        self.observations: list[
            tuple[dict[str, Any], dict[str, Any] | None, list[dict[str, Any]]]
        ] = []

    async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None:
        assert task_name == "notify"
        async with self.session_factory() as session:
            incident = (
                (
                    await session.execute(
                        sa.text(
                            "SELECT event_count, threshold_crossed, window_state "
                            "FROM incidents WHERE id = CAST(:id AS uuid)"
                        ),
                        {"id": payload["incident_id"]},
                    )
                )
                .mappings()
                .one_or_none()
            )
            crossing_audits = (
                (
                    await session.execute(
                        sa.text(
                            "SELECT source_id, fingerprint, decision_summary "
                            "FROM incident_events WHERE "
                            "decision_summary->>'first_threshold_transition' = 'true'"
                        )
                    )
                )
                .mappings()
                .all()
            )
        self.observations.append(
            (
                dict(payload),
                dict(incident) if incident is not None else None,
                [dict(row) for row in crossing_audits],
            )
        )

    async def drain(self) -> None:
        return None


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
    duration_seconds: int = 300,
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
                            "duration_seconds": duration_seconds,
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


async def _race_http_events_at_incident_insert(
    client: AsyncClient,
    session_factory: async_sessionmaker[AsyncSession],
    first_payload: dict[str, object],
    second_payload: dict[str, object],
) -> tuple[Response, Response]:
    # SHARE conflicts with both INSERTs' ROW EXCLUSIVE table locks. Observe
    # two separate PostgreSQL backends waiting on incidents before releasing
    # either; merely scheduling two asyncio tasks would not prove a DB race.
    async with session_factory() as blocker:
        await blocker.execute(sa.text("LOCK TABLE incidents IN SHARE MODE"))
        requests = (
            asyncio.create_task(client.post("/v1/icinga2/events", json=first_payload)),
            asyncio.create_task(client.post("/v1/icinga2/events", json=second_payload)),
        )
        try:
            async with session_factory() as observer:

                async def both_waiting() -> None:
                    while True:
                        waiting = await observer.scalar(
                            sa.text(
                                "SELECT count(DISTINCT locks.pid) FROM pg_locks AS locks "
                                "JOIN pg_class AS relation ON relation.oid = locks.relation "
                                "WHERE relation.relname = 'incidents' "
                                "AND locks.mode = 'RowExclusiveLock' "
                                "AND NOT locks.granted"
                            )
                        )
                        if waiting == 2:
                            return
                        if any(request.done() for request in requests):
                            raise AssertionError(
                                "request finished before both inserts waited"
                            )

                await asyncio.wait_for(both_waiting(), timeout=15)
        finally:
            # Always unblock the HTTP tasks, even on timeout or assertion
            # failure, so the module-scoped PostgreSQL fixture can clean up.
            await blocker.rollback()
            try:
                await asyncio.wait_for(
                    asyncio.gather(*requests, return_exceptions=True), timeout=15
                )
            finally:
                for request in requests:
                    if not request.done():
                        request.cancel()
    return requests[0].result(), requests[1].result()


def _http_threshold_facts(body: dict[str, Any]) -> tuple[Any, ...]:
    threshold = body["threshold_decision"]
    assert threshold == body["rule_decision"]["threshold_decision"]
    return (
        threshold["counted"],
        threshold["crossed"],
        body["threshold_crossed"],
        body["no_dispatch_reason"] == "replay",
        body["notification_triggered"],
        body["no_dispatch_reason"],
        "dispatch_planned" if body["notification_triggered"] else "no_dispatch",
    )


def _audit_threshold_facts(summary: dict[str, Any]) -> tuple[Any, ...]:
    assert summary["decision_kind"] == "problem"
    assert summary["threshold_count"] == 2
    return (
        summary["counted_count"],
        summary["counted_count"] >= summary["threshold_count"],
        summary["threshold_crossed"],
        summary["replay"],
        summary["first_threshold_transition"],
        summary["no_dispatch_reason"],
        summary["notification_intent"],
    )


async def test_submit_notifications_without_task_runner_reports_failed_result_per_action(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    submissions: list[str] = []
    monkeypatch.setattr(
        "app.processing.ingress.record_notification_submission",
        submissions.append,
    )
    decision = RuleMatch(
        rule_name="critical-rule",
        priority=10,
        matched_rules=["critical-rule"],
        group_key="service=http",
        window=RuleWindow(
            duration_seconds=60,
            group_by=["service"],
            trigger_threshold=1,
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
    operator_token = "production-operator-token"
    ingress_token = "production-ingress-token"
    app = create_app(
        settings=Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            environment="production",
            api_auth_enabled=True,
            expose_readyz=False,
            expose_metrics=False,
            operator_api_token=operator_token,
            ingress_api_token=ingress_token,
            audit_raw_payload_hmac_key="test-audit-hmac",
        ),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
        # Background expiry must not contaminate request-only SQL recording.
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )
    first_payload = _payload(
        host="web-01", source_id="icinga2:service:web-01:http"
    )
    ingress_headers = {"Authorization": f"Bearer {ingress_token}"}

    async def persisted_rows() -> list[list[dict[str, Any]]]:
        async with session_factory() as session:
            return [
                [
                    dict(row)
                    for row in (await session.execute(statement)).mappings().all()
                ]
                for statement in (
                    sa.text("SELECT * FROM incidents ORDER BY id"),
                    sa.text("SELECT * FROM incident_events ORDER BY id"),
                )
            ]

    processor_calls: list[object] = []
    process_payload = processor.process_payload

    async def record_process_payload(payload: Any) -> Any:
        processor_calls.append(payload)
        return await process_payload(payload)

    sql_statements: list[str] = []

    def record_sql(
        connection: Any,
        cursor: Any,
        statement: str,
        parameters: Any,
        context: Any,
        executemany: bool,
    ) -> None:
        sql_statements.append(statement)

    engine = session_factory.kw["bind"]
    async for client in get_client(app):
        before_denials = await persisted_rows()
        assert before_denials == [[], []]
        # Both recording seams exist only for denied requests. Authorized
        # processing below uses the unwrapped real processor and PostgreSQL.
        with monkeypatch.context() as denied_patch:
            denied_patch.setattr(processor, "process_payload", record_process_payload)
            for headers in (
                {},
                {"Authorization": "Bearer invalid-token"},
                {"Authorization": f"Bearer {operator_token}"},
            ):
                sa.event.listen(
                    engine.sync_engine, "before_cursor_execute", record_sql
                )
                try:
                    denied = await client.post(
                        "/v1/icinga2/events",
                        json=first_payload,
                        headers=headers,
                    )
                    await task_runner.drain()
                finally:
                    sa.event.remove(
                        engine.sync_engine, "before_cursor_execute", record_sql
                    )
                assert denied.status_code == 401
                assert denied.json() == {"detail": "unauthorized"}
                assert denied.headers["WWW-Authenticate"] == "Bearer"
                assert processor_calls == []
                assert sql_statements == []
                assert await persisted_rows() == before_denials
                assert submitted == []
                assert submissions == []

        first = await client.post(
            "/v1/icinga2/events",
            json=first_payload,
            headers=ingress_headers,
        )
        assert first.status_code == 200
        second = await client.post(
            "/v1/icinga2/events",
            json=_payload(
                host="web-02",
                source_id="icinga2:service:web-02:http",
                timestamp="2026-06-08T12:01:00+00:00",
            ),
            headers=ingress_headers,
        )
        assert second.status_code == 200
        replay = await client.post(
            "/v1/icinga2/events",
            json=_payload(
                host="web-02",
                source_id="icinga2:service:web-02:http",
                timestamp="2026-06-08T12:01:00+00:00",
            ),
            headers=ingress_headers,
        )
        assert replay.status_code == 200
        already = await client.post(
            "/v1/icinga2/events",
            json=_payload(
                host="web-03",
                source_id="icinga2:service:web-03:http",
                timestamp="2026-06-08T12:02:00+00:00",
            ),
            headers=ingress_headers,
        )
        assert already.status_code == 200
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

    persisted_incidents, _ = await persisted_rows()
    assert len(persisted_incidents) == 1
    incident = persisted_incidents[0]
    assert str(incident["id"]) == first_body["incident_id"]
    assert incident["status"] == "OPEN"
    assert incident["rule_name"] == "service-critical"
    assert incident["severity"] == "CRITICAL"
    assert incident["summary"] == "Critical http in dc1"
    assert incident["event_count"] == 3
    assert incident["affected_hosts"] == ["web-01", "web-02", "web-03"]
    assert incident["affected_services"] == ["http"]
    assert incident["start_time"] == _event_time()
    assert incident["last_update_time"] == datetime(
        2026, 6, 8, 12, 2, tzinfo=timezone.utc
    )
    assert incident["threshold_crossed"] is True
    assert incident["window_state"]["counted_count"] == 3
    assert set(incident["window_state"]["counted_fingerprint_timestamps"]) == {
        first_body["fingerprint"],
        second_body["fingerprint"],
        already_body["fingerprint"],
    }


async def test_http_replay_and_late_events_project_committed_window_to_response_and_audit(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
    postgres_url: str,
) -> None:
    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=2, duration_seconds=60)
    task_runner = AsyncIOTaskRunner()
    submitted: list[dict[str, object]] = []

    async def capture_notify(payload: dict[str, object]) -> None:
        submitted.append(dict(payload))

    task_runner.register("notify", capture_notify)
    output_plugin = GateOutputPlugin()
    output_plugin.release.set()
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
        plugin_registry=SynchronizedOutputRegistry({"email-oncall": output_plugin}),
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )
    event_specs = (
        ("web-01", "2026-06-08T12:01:40+00:00"),
        ("web-02", "2026-06-08T12:01:20+00:00"),
        ("web-01", "2026-06-08T12:01:40+00:00"),
        ("web-03", "2026-06-08T12:00:39+00:00"),
        ("web-04", "2026-06-08T12:03:40+00:00"),
    )
    responses = []
    async for client in get_client(app):
        first = await client.post(
            "/v1/icinga2/events",
            json=_payload(
                host=event_specs[0][0],
                source_id=f"icinga2:service:{event_specs[0][0]}:http",
                timestamp=event_specs[0][1],
            ),
        )
        assert first.status_code == 200
        responses.append(first.json())
    assert submitted == []
    async with session_factory() as session:
        persisted_first = (
            (
                await session.execute(
                    sa.text(
                        "SELECT event_count, threshold_crossed, window_state "
                        "FROM incidents WHERE id = CAST(:id AS uuid)"
                    ),
                    {"id": responses[0]["incident_id"]},
                )
            )
            .mappings()
            .one()
        )
    assert persisted_first["event_count"] == 1
    assert persisted_first["threshold_crossed"] is False
    assert persisted_first["window_state"]["counted_count"] == 1

    # Stop the first app and rebuild its processor, rule engine, runner, and
    # SQLAlchemy engine; the new runtime reads only committed threshold state.
    fresh_engine = create_async_engine(postgres_url)
    fresh_factory = async_sessionmaker(fresh_engine, expire_on_commit=False)
    fresh_runner = AsyncIOTaskRunner()
    fresh_runner.register("notify", capture_notify)
    fresh_output_plugin = GateOutputPlugin()
    fresh_output_plugin.release.set()
    fresh_processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=fresh_factory,
        task_runner=fresh_runner,
        plugin_registry=SynchronizedOutputRegistry(
            {"email-oncall": fresh_output_plugin}
        ),
    )
    fresh_app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=fresh_factory,
        icinga2_processor=fresh_processor,
        task_runner=fresh_runner,
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )
    try:
        async for client in get_client(fresh_app):
            for host, timestamp in event_specs[1:]:
                response = await client.post(
                    "/v1/icinga2/events",
                    json=_payload(
                        host=host,
                        source_id=f"icinga2:service:{host}:http",
                        timestamp=timestamp,
                    ),
                )
                assert response.status_code == 200
                responses.append(response.json())
            detail_response = await client.get(
                f"/v1/incidents/{responses[0]['incident_id']}"
            )
            await fresh_runner.drain()
    finally:
        await fresh_engine.dispose()

    assert detail_response.status_code == 200
    fingerprints = [body["fingerprint"] for body in responses]
    assert fingerprints[0] == fingerprints[2]
    expected_windows = (
        ("2026-06-08T12:00:40+00:00", "2026-06-08T12:01:40+00:00"),
        ("2026-06-08T12:00:40+00:00", "2026-06-08T12:01:40+00:00"),
        ("2026-06-08T12:00:40+00:00", "2026-06-08T12:01:40+00:00"),
        ("2026-06-08T12:00:40+00:00", "2026-06-08T12:01:40+00:00"),
        ("2026-06-08T12:02:40+00:00", "2026-06-08T12:03:40+00:00"),
    )
    expected_fingerprints = (
        {fingerprints[0]},
        {fingerprints[0], fingerprints[1]},
        {fingerprints[0], fingerprints[1]},
        {fingerprints[0], fingerprints[1]},
        {fingerprints[4]},
    )
    expected_counts = (1, 2, 2, 2, 1)
    expected_current_crossings = (False, True, True, True, False)
    expected_monotone_crossings = (False, True, True, True, True)
    expected_first_transitions = (False, True, False, False, False)
    for index, body in enumerate(responses):
        threshold = body["threshold_decision"]
        assert threshold == body["rule_decision"]["threshold_decision"]
        assert threshold["threshold"] == 2
        assert datetime.fromisoformat(
            threshold["window_start"]
        ) == datetime.fromisoformat(expected_windows[index][0])
        assert datetime.fromisoformat(
            threshold["window_end"]
        ) == datetime.fromisoformat(expected_windows[index][1])
        assert set(threshold["counted_fingerprints"]) == expected_fingerprints[index]
        assert threshold["counted"] == expected_counts[index]
        assert threshold["crossed"] is expected_current_crossings[index]
        assert body["threshold_crossed"] is expected_monotone_crossings[index]
        assert body["incident_id"] == responses[0]["incident_id"]
    assert "replay" in responses[2]["threshold_decision"]["replay_or_skip_reasons"][0]
    assert "outside" in responses[3]["threshold_decision"]["replay_or_skip_reasons"][0]
    assert [body["no_dispatch_reason"] for body in responses] == [
        "below_threshold",
        None,
        "replay",
        "already_notified",
        "already_notified",
    ]
    assert [body["notification_triggered"] for body in responses] == list(
        expected_first_transitions
    )
    assert len(submitted) == 1
    assert submitted[0]["incident_id"] == responses[0]["incident_id"]
    assert task_runner.pending_count == 0
    detail = detail_response.json()
    assert detail["threshold_crossed"] is True
    assert detail["window_state"]["counted_count"] == 1

    async with session_factory() as session:
        audit_rows = (
            (
                await session.execute(
                    sa.text(
                        "SELECT source_id, fingerprint, decision_summary "
                        "FROM incident_events"
                    )
                )
            )
            .mappings()
            .all()
        )
    assert len(audit_rows) == len(responses)
    responses_by_request: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for body in responses:
        responses_by_request.setdefault(
            (body["source_id"], body["fingerprint"]), []
        ).append(body)
    audits_by_request: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for row in audit_rows:
        audits_by_request.setdefault((row["source_id"], row["fingerprint"]), []).append(
            row["decision_summary"]
        )
    assert responses_by_request.keys() == audits_by_request.keys()
    for request_key, response_group in responses_by_request.items():
        assert Counter(_http_threshold_facts(body) for body in response_group) == (
            Counter(
                _audit_threshold_facts(summary)
                for summary in audits_by_request[request_key]
            )
        )


@pytest.mark.parametrize(
    "scenario",
    ("fresh-inserts", "existing-distinct", "existing-identical"),
)
async def test_concurrent_http_threshold_two_serializes_each_request_and_submits_once(
    scenario: str,
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=2)
    runner = CommittedStateRunner(session_factory)
    plugin_registry = SynchronizedOutputRegistry({"email-oncall": GateOutputPlugin()})
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=runner,
        plugin_registry=plugin_registry,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=runner,  # type: ignore[arg-type]
        plugin_registry=plugin_registry,  # type: ignore[arg-type]
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )
    seed = None
    async for client in get_client(app):
        if scenario != "fresh-inserts":
            seed_response = await client.post(
                "/v1/icinga2/events",
                json=_payload(host="web-01", source_id="icinga2:service:web-01:http"),
            )
            assert seed_response.status_code == 200
            seed = seed_response.json()
            assert seed["threshold_decision"]["counted"] == 1
            assert runner.observations == []

        first_payload = _payload(
            host="web-02" if seed is not None else "web-01",
            source_id=(
                "icinga2:service:web-02:http"
                if seed is not None
                else "icinga2:service:web-01:http"
            ),
            timestamp="2026-06-08T12:01:00+00:00",
        )
        second_payload = (
            dict(first_payload)
            if scenario == "existing-identical"
            else _payload(
                host="web-03" if seed is not None else "web-02",
                source_id=(
                    "icinga2:service:web-03:http"
                    if seed is not None
                    else "icinga2:service:web-02:http"
                ),
                timestamp="2026-06-08T12:01:00+00:00",
            )
        )
        http_responses = await _race_http_events_at_incident_insert(
            client, session_factory, first_payload, second_payload
        )
        assert all(response.status_code == 200 for response in http_responses)
        responses = [response.json() for response in http_responses]

    incident_id = responses[0]["incident_id"]
    assert all(body["incident_id"] == incident_id for body in responses)
    assert seed is None or seed["incident_id"] == incident_id
    expected_count = 2 if scenario != "existing-distinct" else 3
    expected_fingerprints = {body["fingerprint"] for body in responses} | (
        {seed["fingerprint"]} if seed is not None else set()
    )
    assert len(expected_fingerprints) == expected_count
    assert (
        Counter(body["threshold_decision"]["counted"] for body in responses)
        == {
            "fresh-inserts": Counter({1: 1, 2: 1}),
            "existing-distinct": Counter({2: 1, 3: 1}),
            "existing-identical": Counter({2: 2}),
        }[scenario]
    )
    assert sum(body["notification_triggered"] for body in responses) == 1
    assert sum(body["no_dispatch_reason"] == "replay" for body in responses) == (
        1 if scenario == "existing-identical" else 0
    )
    for body in responses:
        threshold = body["threshold_decision"]
        assert threshold["threshold"] == 2
        assert datetime.fromisoformat(threshold["window_start"]) == datetime(
            2026, 6, 8, 11, 56, tzinfo=timezone.utc
        )
        assert datetime.fromisoformat(threshold["window_end"]) == datetime(
            2026, 6, 8, 12, 1, tzinfo=timezone.utc
        )
        assert len(threshold["counted_fingerprints"]) == threshold["counted"]
        assert body["threshold_crossed"] is (threshold["counted"] >= 2)
        assert body["notification_count"] == int(body["notification_triggered"])
        assert body["notification_failed"] is False
        assert body["fingerprint"] in threshold["counted_fingerprints"]
        assert set(threshold["counted_fingerprints"]) <= expected_fingerprints

    async with session_factory() as session:
        incidents = (
            (
                await session.execute(
                    sa.text(
                        "SELECT id, status, event_count, threshold_crossed, window_state "
                        "FROM incidents WHERE rule_name = 'service-critical'"
                    )
                )
            )
            .mappings()
            .all()
        )
        audits = (
            (
                await session.execute(
                    sa.text(
                        "SELECT source_id, fingerprint, incident_ids, decision_summary "
                        "FROM incident_events"
                    )
                )
            )
            .mappings()
            .all()
        )
    assert len(incidents) == 1
    row = incidents[0]
    assert str(row["id"]) == incident_id
    assert row["status"] == "OPEN"
    assert row["event_count"] == expected_count
    assert row["threshold_crossed"] is True
    assert row["window_state"]["counted_count"] == expected_count
    assert set(row["window_state"]["counted_fingerprint_timestamps"]) == (
        expected_fingerprints
    )
    assert len(audits) == len(responses) + int(seed is not None)
    assert all(audit["incident_ids"] == [incident_id] for audit in audits)
    assert (
        sum(audit["decision_summary"]["first_threshold_transition"] for audit in audits)
        == 1
    )
    race_audits = [
        audit
        for audit in audits
        if seed is None or audit["fingerprint"] != seed["fingerprint"]
    ]
    assert len(race_audits) == 2
    if scenario == "existing-identical":
        # Both requests have the same fingerprint AND source_id. Their
        # transaction outcomes (new vs replay), not audit row ordering,
        # identify the two matching audit facts.
        assert all(
            (audit["source_id"], audit["fingerprint"])
            == (responses[0]["source_id"], responses[0]["fingerprint"])
            for audit in race_audits
        )
        assert Counter(_http_threshold_facts(body) for body in responses) == Counter(
            _audit_threshold_facts(audit["decision_summary"]) for audit in race_audits
        )
    else:
        audits_by_request = {
            (audit["source_id"], audit["fingerprint"]): audit["decision_summary"]
            for audit in race_audits
        }
        assert len(audits_by_request) == 2
        for body in responses:
            assert _http_threshold_facts(body) == _audit_threshold_facts(
                audits_by_request[(body["source_id"], body["fingerprint"])]
            )

    # The runner queries through its own AsyncSession at submit time; a
    # staged-but-uncommitted crossing would be invisible to this callback.
    assert len(runner.observations) == 1
    submitted, visible_incident, visible_audits = runner.observations[0]
    assert submitted["incident_id"] == incident_id
    assert submitted["plugin_name"] == "email-oncall"
    assert visible_incident is not None
    assert visible_incident["threshold_crossed"] is True
    assert visible_incident["window_state"]["counted_count"] >= 2
    assert len(visible_audits) == 1
    winner = next(body for body in responses if body["notification_triggered"])
    assert visible_audits[0]["source_id"] == winner["source_id"]
    assert visible_audits[0]["fingerprint"] == winner["fingerprint"]
    assert visible_audits[0]["decision_summary"]["incident_ids"] == [incident_id]
    assert visible_audits[0]["decision_summary"]["counted_count"] == 2
    assert visible_audits[0]["decision_summary"]["first_threshold_transition"] is True


async def test_failed_audit_insert_rolls_back_crossing_and_retry_submits_once(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.processing import ingress as ingress_module

    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=2)
    runner = CommittedStateRunner(session_factory)
    plugin_registry = SynchronizedOutputRegistry({"email-oncall": GateOutputPlugin()})
    processor = build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=runner,
        plugin_registry=plugin_registry,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=runner,  # type: ignore[arg-type]
        plugin_registry=plugin_registry,  # type: ignore[arg-type]
        lifecycle_worker=NoopLifecycleWorker(),  # type: ignore[arg-type]
    )
    crossing_payload = _payload(
        host="web-02",
        source_id="icinga2:service:web-02:http",
        timestamp="2026-06-08T12:01:00+00:00",
    )
    trigger_name = "u4_reject_crossing_audit"
    async for client in get_client(app):
        first = await client.post(
            "/v1/icinga2/events",
            json=_payload(host="web-01", source_id="icinga2:service:web-01:http"),
        )
        assert first.status_code == 200
        incident_id = first.json()["incident_id"]
        async with session_factory() as session:
            before = (
                (
                    await session.execute(
                        sa.text(
                            "SELECT event_count, last_update_time, window_state, "
                            "threshold_crossed, decision_context FROM incidents "
                            "WHERE id = CAST(:id AS uuid)"
                        ),
                        {"id": incident_id},
                    )
                )
                .mappings()
                .one()
            )
            before_snapshot = dict(before)

        # A real PostgreSQL trigger checks the crossing is already visible
        # inside this transaction before rejecting its audit INSERT. Failure
        # before aggregation would raise a different error and fail the test.
        async with session_factory() as ddl:
            await ddl.execute(
                sa.text(
                    "CREATE FUNCTION u4_reject_crossing_audit() RETURNS trigger "
                    "LANGUAGE plpgsql AS $$ "
                    "BEGIN "
                    "IF NOT EXISTS ("
                    "SELECT 1 FROM incidents "
                    "WHERE id = (NEW.incident_ids->>0)::uuid "
                    "AND threshold_crossed "
                    "AND (window_state->>'counted_count')::integer = 2"
                    ") THEN "
                    "RAISE EXCEPTION 'audit reached before incident crossing'; "
                    "END IF; "
                    "RAISE EXCEPTION 'u4_reject_crossing_audit' USING ERRCODE = '23514'; "
                    "END; $$"
                )
            )
            await ddl.execute(
                sa.text(
                    "CREATE TRIGGER u4_reject_crossing_audit "
                    "BEFORE INSERT ON incident_events FOR EACH ROW "
                    "WHEN (NEW.source_id = 'icinga2:service:web-02:http') "
                    "EXECUTE FUNCTION u4_reject_crossing_audit()"
                )
            )
            await ddl.commit()

        actual_insert = ingress_module.insert_incident_event
        audit_errors: list[tuple[str | None, str]] = []

        async def observe_real_audit_insert(*args: Any, **kwargs: Any) -> Any:
            try:
                return await actual_insert(*args, **kwargs)
            except sa.exc.IntegrityError as error:
                audit_errors.append(
                    (getattr(error.orig, "sqlstate", None), str(error.orig))
                )
                raise

        monkeypatch.setattr(
            ingress_module, "insert_incident_event", observe_real_audit_insert
        )
        try:
            failed = await client.post("/v1/icinga2/events", json=crossing_payload)
            assert failed.status_code == 500
            assert failed.json() == {"detail": "ingest failed"}
            assert len(audit_errors) == 1
            assert audit_errors[0][0] == "23514"
            assert trigger_name in audit_errors[0][1]

            async with session_factory() as inspection:
                unchanged = (
                    (
                        await inspection.execute(
                            sa.text(
                                "SELECT event_count, last_update_time, window_state, "
                                "threshold_crossed, decision_context FROM incidents "
                                "WHERE id = CAST(:id AS uuid)"
                            ),
                            {"id": incident_id},
                        )
                    )
                    .mappings()
                    .one()
                )
                audit_rows = (
                    (
                        await inspection.execute(
                            sa.text(
                                "SELECT source_id FROM incident_events "
                                "WHERE incident_ids @> jsonb_build_array(CAST(:id AS text))"
                            ),
                            {"id": incident_id},
                        )
                    )
                    .scalars()
                    .all()
                )
            assert dict(unchanged) == before_snapshot
            assert audit_rows == ["icinga2:service:web-01:http"]
            assert runner.observations == []
        finally:
            async with session_factory() as ddl:
                await ddl.execute(
                    sa.text("DROP TRIGGER u4_reject_crossing_audit ON incident_events")
                )
                await ddl.execute(sa.text("DROP FUNCTION u4_reject_crossing_audit()"))
                await ddl.commit()

        retry = await client.post("/v1/icinga2/events", json=crossing_payload)
        assert retry.status_code == 200
        body = retry.json()
        assert body["incident_id"] == incident_id
        assert body["threshold_decision"]["counted"] == 2
        assert body["threshold_decision"]["crossed"] is True
        assert body["threshold_crossed"] is True
        assert body["notification_triggered"] is True
        assert body["notification_count"] == 1

    async with session_factory() as inspection:
        final = (
            (
                await inspection.execute(
                    sa.text(
                        "SELECT event_count, threshold_crossed, window_state "
                        "FROM incidents WHERE id = CAST(:id AS uuid)"
                    ),
                    {"id": incident_id},
                )
            )
            .mappings()
            .one()
        )
        audit_rows = (
            (
                await inspection.execute(
                    sa.text(
                        "SELECT source_id, fingerprint, decision_summary "
                        "FROM incident_events"
                    )
                )
            )
            .mappings()
            .all()
        )
    assert final["event_count"] == 2
    assert final["threshold_crossed"] is True
    assert final["window_state"]["counted_count"] == 2
    assert len(audit_rows) == 2
    retried_audits = [
        audit
        for audit in audit_rows
        if audit["source_id"] == crossing_payload["source_id"]
    ]
    assert len(retried_audits) == 1
    assert retried_audits[0]["fingerprint"] == body["fingerprint"]
    assert retried_audits[0]["decision_summary"]["first_threshold_transition"] is True
    assert retried_audits[0]["decision_summary"]["counted_count"] == 2
    assert len(runner.observations) == 1
    submitted, visible_incident, visible_audits = runner.observations[0]
    assert submitted["incident_id"] == incident_id
    assert visible_incident is not None
    assert visible_incident["threshold_crossed"] is True
    assert visible_incident["window_state"]["counted_count"] == 2
    assert len(visible_audits) == 1
    assert visible_audits[0]["source_id"] == crossing_payload["source_id"]
    assert visible_audits[0]["fingerprint"] == body["fingerprint"]
    assert visible_audits[0]["decision_summary"]["incident_ids"] == [incident_id]


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
            replay = await fresh_client.post(
                "/v1/icinga2/events",
                json=_payload(
                    host="web-01",
                    source_id="icinga2:service:web-01:http",
                ),
            )
            after_replay = await fresh_client.get(f"/v1/incidents/{incident_id}")
    finally:
        await fresh_engine.dispose()

    assert reopened.status_code == 200
    reopened_context = reopened.json()["decision_context"]
    assert reopened_context["notes"] == aggregated_context["notes"]
    assert (
        reopened_context["notification_delivery_results"]
        == aggregated_context["notification_delivery_results"]
    )
    assert replay.status_code == 200
    assert replay.json()["incident_id"] == incident_id
    assert replay.json()["threshold_decision"]["counted"] == 2
    assert replay.json()["no_dispatch_reason"] == "replay"
    assert replay.json()["notification_results"] == []
    assert fresh_runner.pending_count == 0
    assert (
        after_replay.json()["decision_context"]["notification_delivery_results"]
        == (aggregated_context["notification_delivery_results"])
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
    assert body["rule_decision"]["reason"] == "recovery events bypass rule aggregation"
    assert body["lifecycle_outcome"]["effect"] == "affected_set_shrunk"
    assert body["affected_object_removed"] is True
    assert body["notification_count"] == 0
    assert submitted == []
    async with session_factory() as session:
        summary = (
            await session.execute(
                sa.text("SELECT decision_summary FROM incident_events")
            )
        ).scalar_one()
    assert summary["decision_kind"] == "recovery"
    assert summary["threshold_count"] is None
    assert summary["counted_count"] is None
    assert summary["threshold_crossed"] is None


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
    assert response.json()["detail"][0]["loc"] == ["body", "extra"]


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


# ---------------------------------------------------------------------------
# Topology enrichment integration via HTTP entrypoint
# ---------------------------------------------------------------------------


def _tags_near_byte_limit(count: int = 128) -> dict[str, str]:
    return {f"k{i:03}": "x" * 118 for i in range(count)}


@pytest.mark.parametrize(
    ("kind", "state_type"),
    [
        ("source_count", "HARD"),
        ("source_count", "SOFT"),
        ("source_bytes", "HARD"),
        ("literal_count", "HARD"),
        ("literal_bytes", "HARD"),
        ("capture_count", "HARD"),
        ("capture_bytes", "HARD"),
        ("capture_nul", "HARD"),
        ("collision_growth", "HARD"),
    ],
)
async def test_tag_overflow_has_sanitized_422_and_no_state_changes(
    kind: str,
    state_type: str,
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
    caplog: pytest.LogCaptureFixture,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    topology_path = tmp_path / "topology.yaml"
    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=3)
    rule_data = yaml.safe_load(rules_path.read_text())
    rule_data["rules"][0]["output_summary"] = "Rule matched"
    rules_path.write_text(yaml.safe_dump(rule_data))

    captured = kind.startswith("capture")
    literal_value = (
        "x" * 256
        if kind == "collision_growth"
        else "x" * 118
        if kind == "literal_bytes"
        else "dc1"
    )
    topology_path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "source-and-topology",
                        "name": "Source and Topology",
                        "hostname_pattern": "^(.*)$",
                        "tags": {} if captured else {"topology.site": literal_value},
                        "tag_capture_groups": {"topology.site": 1} if captured else {},
                    }
                ],
            }
        )
    )
    submitted: list[str] = []
    monkeypatch.setattr(
        "app.processing.ingress.record_notification_submission", submitted.append
    )
    task_runner = AsyncIOTaskRunner()
    processor = build_icinga2_processor(
        topology_path=topology_path,
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        task_runner=task_runner,
        lifecycle_worker=NoopLifecycleWorker(),
    )
    seed = valid_icinga2_service_payload()
    seed["host"] = "seed"
    seed["source_id"] = "icinga2:service:seed:http"
    seed["tags"] = {"team.name": "platform"}
    payload = valid_icinga2_service_payload()
    payload["source_id"] = "icinga2:service:rejected:http"
    payload["host"] = "web-rejected"
    payload["state_type"] = state_type
    if kind == "source_count":
        payload["tags"] = {f"k{i:03}": "secret" for i in range(129)}
    elif kind == "source_bytes":
        tags = _tags_near_byte_limit()
        tags["k127"] = "x" * 118
        payload["tags"] = tags  # 16,385 bytes, source count exactly 128
    elif kind in ("literal_count", "capture_count"):
        payload["tags"] = {f"k{i:03}": "x" for i in range(128)}
    elif kind in ("literal_bytes", "capture_bytes"):
        payload["tags"] = _tags_near_byte_limit(127)
        if kind == "capture_bytes":
            payload["host"] = "web-" + "x" * 115
    elif kind == "collision_growth":
        payload["tags"] = {**_tags_near_byte_limit(127), "topology.site": "x"}
    else:
        payload["host"] = "web-\x00rejected"
        payload["tags"] = {"team.name": "platform"}

    if kind in ("literal_bytes", "capture_bytes", "collision_growth"):
        source_bytes = len(
            json.dumps(
                payload["tags"],
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            ).encode("utf-8")
        )
        assert source_bytes <= EVENT_TAG_MAX_BYTES

    caplog.set_level(logging.INFO, logger="app.processing.ingress")
    async for client in get_client(app):
        accepted = await client.post("/v1/icinga2/events", json=seed)
        assert accepted.status_code == 200
        assert accepted.json()["threshold_decision"]["counted"] == 1
        async with session_factory() as session:
            before_window = (
                await session.execute(
                    sa.text("SELECT window_state FROM incidents WHERE id = :id"),
                    {"id": UUID(accepted.json()["incident_id"])},
                )
            ).scalar_one()
            before_audits = (
                await session.execute(sa.text("SELECT COUNT(*) FROM incident_events"))
            ).scalar_one()
            before_incidents = (
                await session.execute(sa.text("SELECT COUNT(*) FROM incidents"))
            ).scalar_one()
        response = await client.post("/v1/icinga2/events", json=payload)
        await task_runner.drain()

    assert response.status_code == 422
    assert response.json() == {
        "detail": [
            {
                "loc": ["body", "tags"],
                "msg": "invalid event tags",
                "type": "value_error.event_tags",
            }
        ]
    }
    assert submitted == []
    async with session_factory() as session:
        assert (
            await session.execute(
                sa.text("SELECT window_state FROM incidents WHERE id = :id"),
                {"id": UUID(accepted.json()["incident_id"])},
            )
        ).scalar_one() == before_window
        assert (
            await session.execute(sa.text("SELECT COUNT(*) FROM incident_events"))
        ).scalar_one() == before_audits
        assert (
            await session.execute(sa.text("SELECT COUNT(*) FROM incidents"))
        ).scalar_one() == before_incidents
    safe_logs = "\n".join(
        record.getMessage() + repr(record.__dict__)
        for record in caplog.records
        if record.name.startswith(("app.processing.ingress", "app.api.routers.ingress"))
    )
    assert "web-\x00rejected" not in safe_logs
    assert "secret" not in safe_logs


@pytest.mark.parametrize(
    "tags",
    [
        {},
        {**_tags_near_byte_limit(), "k127": "x" * 117},
    ],
)
async def test_ingress_accepts_empty_and_exact_byte_limit_source_maps(
    tags: dict[str, str],
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        lifecycle_worker=NoopLifecycleWorker(),
    )
    payload = valid_icinga2_service_payload()
    payload["tags"] = tags
    assert (
        len(
            json.dumps(
                tags, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
        )
        <= EVENT_TAG_MAX_BYTES
    )
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    assert response.status_code == 200
    assert response.json()["final_tags"] == tags
    async with session_factory() as session:
        stored = (
            await session.execute(
                sa.text("SELECT normalized_event->>'tags' FROM incident_events")
            )
        ).scalar_one()
    assert json.loads(stored) == tags


async def test_tag_validation_errors_redact_hostile_key_and_value(
    caplog: pytest.LogCaptureFixture,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    processor = build_icinga2_processor(sessionmaker=session_factory)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        lifecycle_worker=NoopLifecycleWorker(),
    )
    payload = valid_icinga2_service_payload()
    payload["tags"] = {
        "secret-token-" + "x" * 60: "secret-value",
        "a": "x" * 257,
    }
    caplog.set_level(logging.INFO)
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)
    assert response.status_code == 422
    assert response.json() == {
        "detail": [
            {
                "loc": ["body", "tags"],
                "msg": "invalid event tags",
                "type": "value_error.event_tags",
            }
        ]
    }
    assert "secret-token-" not in response.text
    assert "secret-value" not in response.text
    assert "secret-token-" not in "\n".join(r.getMessage() for r in caplog.records)
    assert await _count_audit_rows(session_factory) == 0


async def test_accepted_full_tags_reach_rules_and_postgres_snapshot_unchanged(
    tmp_path: Path,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    topology_path = tmp_path / "topology.yaml"
    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=3)
    rules = yaml.safe_load(rules_path.read_text())
    rules["rules"][0]["match"]["tags"] = {"topology.site": "dc1"}
    rules["rules"][0]["window"]["group_by"] = ["topology.site"]
    rules_path.write_text(yaml.safe_dump(rules))
    topology_path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "host",
                        "name": "Host",
                        "hostname_pattern": "^(dc1)-.*",
                        "tags": {"topology.site": "literal"},
                        "tag_capture_groups": {"topology.site": 1},
                    }
                ],
                "subnet_rules": [
                    {
                        "id": "subnet",
                        "name": "Subnet",
                        "subnet": "192.0.2.0/24",
                        "tags": {"topology.site": "dc2"},
                    }
                ],
            }
        )
    )
    processor = build_icinga2_processor(
        topology_path=topology_path,
        rules_path=rules_path,
        sessionmaker=session_factory,
    )
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=session_factory,
        icinga2_processor=processor,
        lifecycle_worker=NoopLifecycleWorker(),
    )
    tags = {**_tags_near_byte_limit(127), "topology.site": "from-source"}
    payload = valid_icinga2_service_payload()
    payload["host"] = "dc1-web"
    payload["tags"] = tags
    expected = {**tags, "topology.site": "dc1"}
    assert len(expected) == 128
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json=payload)

    assert response.status_code == 200
    body = response.json()
    assert body["final_tags"] == expected
    assert body["matched_rules"] == ["service-critical"]
    assert body["group_key"] == "topology.site=dc1"
    assert body["rule_decision"]["summary"] == "Critical http in dc1"
    assert body["enrichment_diagnostics"][0]["match_source"] == "hostname"
    assert body["enrichment_diagnostics"][0]["tags_overridden"] == [
        ["topology.site", "from-source", "literal"],
        ["topology.site", "literal", "dc1"],
    ]
    async with session_factory() as session:
        stored = (
            await session.execute(
                sa.text("SELECT normalized_event->>'tags' FROM incident_events")
            )
        ).scalar_one()
    assert json.loads(stored) == expected


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
    async with session_factory() as session:
        summary = (
            await session.execute(
                sa.text("SELECT decision_summary FROM incident_events")
            )
        ).scalar_one()
    assert summary["decision_kind"] == "noop"
    assert summary["threshold_count"] is None
    assert summary["counted_count"] is None


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
    assert body["rule_decision"]["threshold_decision"] == td
    assert body["rule_decision"]["rule_name"] == "web-critical"
    assert body["rule_decision"]["priority"] == 10
    assert body["rule_decision"]["summary"] == "Critical http on web-01"
    assert body["incident_effects"]["inserted"] == 1
    assert body["incident_effects"]["updated"] == 0
    assert body["closure_count"] == 0
    assert body["notification_count"] == 0


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
