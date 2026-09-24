"""Integration tests for ``GET /v1/incident-events`` operator API.

Covers auth, bounded projection, D-11 filters, cursor pagination,
incident correlation, and no-op inspection.  Uses Testcontainers-backed
PostgreSQL with real Alembic migrations.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
import os
import subprocess
from collections.abc import AsyncIterator
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest
import yaml
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.api.routers import audit as audit_router
from app.config.plugins import load_plugin_registry_config
from app.config.settings import Settings
from app.domain.audit import AUDIT_INCIDENT_IDS_MAX, AuditEventListFilters
from app.domain.events import Severity
from app.main import create_app
from app.persistence.audit import insert_incident_event, redact_payload
from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident
from app.persistence.models import Incident, IncidentEvent
from app.plugins.loader import PluginRegistry
from app.processing.ingress import (
    Icinga2DecisionProcessor,
    build_icinga2_processor as _real_build_icinga2_processor,
)
from app.processing.task_runner import AsyncIOTaskRunner

pytestmark = pytest.mark.anyio

VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"
OPERATOR_TOKEN = "operator-secret"
INGRESS_TOKEN = "ingress-secret"
HMAC_KEY = "test-audit-hmac"


def _run_alembic_upgrade(database_url: str) -> None:
    result = subprocess.run(
        ["uv", "run", "python", "-m", "alembic", "upgrade", "head"],
        env={
            **os.environ,
            "DATABASE_URL": database_url,
            "CORRELIA_API_AUTH_ENABLED": "false",
        },
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Alembic upgrade failed: {result.stderr}")


_migrated_url: str | None = None


@pytest.fixture(scope="module")
def postgres_url() -> str:
    global _migrated_url
    with PostgresContainer("postgres:18-alpine") as postgres:
        url = postgres.get_connection_url().replace(
            "postgresql+psycopg2", "postgresql+asyncpg"
        )
        if _migrated_url != url:
            _run_alembic_upgrade(url)
            _migrated_url = url
        yield url


@pytest.fixture
async def session_factory(postgres_url: str):
    engine = create_async_engine(postgres_url)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as conn:
        await conn.execute(Incident.__table__.delete())
        await conn.execute(IncidentEvent.__table__.delete())
    yield maker
    async with engine.begin() as cleanup:
        await cleanup.execute(Incident.__table__.delete())
        await cleanup.execute(IncidentEvent.__table__.delete())
    await engine.dispose()


class NoopLifecycleWorker:
    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None


async def get_client(app: object) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def _settings(api_auth_enabled: bool = False) -> Settings:
    return Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=api_auth_enabled,
        operator_api_token=OPERATOR_TOKEN if api_auth_enabled else None,
        ingress_api_token=INGRESS_TOKEN if api_auth_enabled else None,
        audit_raw_payload_hmac_key=HMAC_KEY,
    )


def _app(
    session_factory: async_sessionmaker[AsyncSession],
    api_auth_enabled: bool = False,
    icinga2_processor: Icinga2DecisionProcessor | None = None,
    task_runner: object | None = None,
) -> object:
    return create_app(
        settings=_settings(api_auth_enabled=api_auth_enabled),
        sessionmaker=session_factory,
        icinga2_processor=icinga2_processor,
        task_runner=task_runner or AsyncIOTaskRunner(),
        lifecycle_worker=NoopLifecycleWorker(),
    )


def _event_time(offset_minutes: int) -> datetime:
    return datetime(2026, 6, 18, 12, 0, tzinfo=timezone.utc) + timedelta(
        minutes=offset_minutes
    )


def _minimal_normalized_event(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "fingerprint": "fp-default",
        "source_id": "src-default",
        "host": "host-default",
        "service": "svc-default",
        "severity": "WARNING",
        "event_type": "PROBLEM",
        "timestamp": _event_time(0).isoformat(),
        "tags": {"env": "prod"},
        "message": "default message",
    }
    base.update(overrides)
    return base


async def _seed_audit_event(
    session: AsyncSession,
    *,
    accepted_offset: int = 0,
    event_timestamp_offset: int = 0,
    incident_ids: list[str] | None = None,
    decision_summary_incident_ids: list[str] | None = None,
    decision_summary_incident_ids_truncated: bool = False,
    incident_effect: str = "none",
    decision_kind: str = "noop",
    no_dispatch_reason: str | None = None,
    fingerprint: str = "fp-default",
    source_id: str = "src-default",
    event_type: str = "PROBLEM",
    severity: str = "WARNING",
    host: str = "host-default",
    service: str | None = "svc-default",
    normalized_event: dict[str, Any] | None = None,
    raw_payload: dict[str, Any] | None = None,
) -> IncidentEvent:
    if normalized_event is None:
        normalized_event = _minimal_normalized_event(
            fingerprint=fingerprint,
            source_id=source_id,
            event_type=event_type,
            severity=severity,
            host=host,
            service=service,
        )
    payload = {"host": host, "service": service} if raw_payload is None else raw_payload
    redacted = redact_payload(payload, max_bytes=65_536, hmac_key=HMAC_KEY)
    summary: dict[str, Any] = {
        "schema_version": 1,
        "decision_kind": decision_kind,
        "incident_effect": incident_effect,
        "notification_intent": "no_dispatch",
        "affected_incident_count": 0,
        "incident_ids_truncated": decision_summary_incident_ids_truncated,
        "incident_ids": tuple(
            decision_summary_incident_ids
            if decision_summary_incident_ids is not None
            else (incident_ids or ())
        ),
    }
    if no_dispatch_reason is not None:
        summary["no_dispatch_reason"] = no_dispatch_reason
    event = await insert_incident_event(
        session,
        event_timestamp=_event_time(event_timestamp_offset),
        source_id=source_id,
        fingerprint=fingerprint,
        event_type=event_type,
        severity=severity,
        host=host,
        service=service,
        incident_ids=incident_ids or [],
        incident_effect=incident_effect,
        decision_summary=summary,
        normalized_event=normalized_event,
        raw_payload=redacted.payload,
        raw_payload_original_byte_length=redacted.original_byte_length,
        raw_payload_stored_byte_length=redacted.stored_byte_length,
        raw_payload_truncated=redacted.truncated,
        redaction_version=redacted.redaction_version,
        redacted_path_count=redacted.redacted_path_count,
        raw_payload_hmac=redacted.payload_hmac,
    )
    # Override accepted_at for deterministic ordering in pagination tests.
    if accepted_offset != 0:
        from sqlalchemy import update

        await session.execute(
            update(IncidentEvent)
            .where(IncidentEvent.id == event.id)
            .values(accepted_at=_event_time(accepted_offset))
        )
        await session.flush()
    return event


async def test_seed_audit_event_preserves_explicit_empty_raw_payload(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        event = await _seed_audit_event(session, raw_payload={})
        await session.commit()

    assert event.raw_payload == {}


# ---------------------------------------------------------------------------
# Ingress helpers (mirror test_ingress_router.py patterns)
# ---------------------------------------------------------------------------


def _write_rules(path: Path, threshold: int = 1) -> None:
    path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "service-critical",
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
                            {"name": "create_incident", "plugin": "email-oncall"}
                        ],
                    }
                ]
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


class _RecordingTaskRunner:
    registered_task_names = ("notify",)

    def __init__(self) -> None:
        self.submissions: list[tuple[str, dict[str, object]]] = []

    def register(self, task_name: str, handler: object) -> None:
        raise AssertionError(f"unexpected registration: {task_name}")

    async def submit(self, task_name: str, payload: dict[str, object]) -> None:
        self.submissions.append((task_name, dict(payload)))

    async def drain(self) -> None:
        return None


def _build_processor(
    session_factory: async_sessionmaker[AsyncSession],
    rules_path: Path,
    plugin_registry: PluginRegistry,
    task_runner: _RecordingTaskRunner,
) -> Icinga2DecisionProcessor:
    return _real_build_icinga2_processor(
        rules_path=rules_path,
        sessionmaker=session_factory,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
        audit_raw_payload_max_bytes=65_536,
        audit_raw_payload_hmac_key=HMAC_KEY,
    )


# ---------------------------------------------------------------------------
# Auth tests
# ---------------------------------------------------------------------------


async def test_incident_events_requires_operator_token(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    app = _app(session_factory, api_auth_enabled=True)
    async for client in get_client(app):
        resp_no_auth = await client.get("/v1/incident-events")
        assert resp_no_auth.status_code == 401
        assert resp_no_auth.json() == {"detail": "unauthorized"}

        resp_ok = await client.get(
            "/v1/incident-events",
            headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"},
        )
        assert resp_ok.status_code == 200


# ---------------------------------------------------------------------------
# Empty response shape
# ---------------------------------------------------------------------------


async def test_list_incident_events_empty_with_operator_token(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    app = _app(session_factory, api_auth_enabled=True)
    async for client in get_client(app):
        resp = await client.get(
            "/v1/incident-events",
            headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["items"] == []
        assert body["total"] == 0
        assert body["limit"] == 50
        assert body["offset"] == 0
        assert body["next_cursor"] is None


# ---------------------------------------------------------------------------
# Bounded projection
# ---------------------------------------------------------------------------


async def test_list_incident_events_uses_bounded_projection(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    secret_value = "supersecretvalue12345"
    async with session_factory() as session:
        await _seed_audit_event(
            session,
            normalized_event=_minimal_normalized_event(
                message=f"connection failed with password={secret_value}",
                tags={
                    "region": "us-east-1",
                    "secret_token": secret_value,
                    "safe_key": "safe_value",
                },
            ),
            raw_payload={
                "host": "web01",
                "password": secret_value,
                "api_key": "ak_live_12345",
            },
        )
        await session.commit()

    app = _app(session_factory)
    async for client in get_client(app):
        resp = await client.get("/v1/incident-events")
        assert resp.status_code == 200
        items = resp.json()["items"]
        assert len(items) == 1
        item = items[0]

        # raw_payload and normalized_event must not appear
        assert "raw_payload" not in item
        assert "normalized_event" not in item

        # Raw payload metadata must be present
        assert item["raw_payload_original_byte_length"] is not None
        assert item["raw_payload_stored_byte_length"] is not None
        assert item["raw_payload_truncated"] is not None
        assert item["redaction_version"] is not None
        assert item["redacted_path_count"] is not None
        assert item["raw_payload_hmac"] is not None

        # Message must be redacted (contained a sensitive fragment)
        assert secret_value not in item["normalized_event_message"]
        assert item["normalized_event_message"] == "[redacted]"

        # Tags: sensitive tag keys are omitted; safe keys/values preserved
        tags = item["normalized_event_tags"]
        assert "region" in tags
        assert tags["region"] == "us-east-1"
        assert "safe_key" in tags
        assert tags["safe_key"] == "safe_value"
        # Sensitive key is omitted entirely (D-08/D-15)
        assert "secret_token" not in tags
        assert secret_value not in str(tags)


# ---------------------------------------------------------------------------
# Filter tests — incident correlation and no-op fields
# ---------------------------------------------------------------------------


async def test_list_incident_events_filters_by_incident_and_noop_fields(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    incident_a = str(uuid4())
    incident_b = str(uuid4())
    async with session_factory() as session:
        # Incident-correlated row (inserted)
        await _seed_audit_event(
            session,
            accepted_offset=1,
            incident_ids=[incident_a, incident_b],
            incident_effect="inserted",
            decision_kind="problem",
            fingerprint="fp-incident",
            source_id="src-incident",
        )
        # No-op row (no incident)
        await _seed_audit_event(
            session,
            accepted_offset=2,
            incident_ids=[],
            incident_effect="none",
            decision_kind="noop",
            fingerprint="fp-noop",
            source_id="src-noop",
        )
        # Below-threshold row (has incident, but no_dispatch_reason)
        await _seed_audit_event(
            session,
            accepted_offset=3,
            incident_ids=[incident_a],
            incident_effect="updated",
            decision_kind="problem",
            no_dispatch_reason="below_threshold",
            fingerprint="fp-below",
            source_id="src-below",
        )
        await session.commit()

    app = _app(session_factory)
    async for client in get_client(app):
        # Filter by incident_id
        resp = await client.get(
            "/v1/incident-events", params={"incident_id": incident_a}
        )
        assert resp.status_code == 200
        ids = {i["fingerprint"] for i in resp.json()["items"]}
        assert ids == {"fp-incident", "fp-below"}

        # Filter by incident_id (second incident)
        resp = await client.get(
            "/v1/incident-events", params={"incident_id": incident_b}
        )
        assert resp.status_code == 200
        ids = {i["fingerprint"] for i in resp.json()["items"]}
        assert ids == {"fp-incident"}

        # has_incident=true
        resp = await client.get("/v1/incident-events", params={"has_incident": "true"})
        assert resp.status_code == 200
        ids = {i["fingerprint"] for i in resp.json()["items"]}
        assert ids == {"fp-incident", "fp-below"}

        # has_incident=false → only incident_effect=none
        resp = await client.get("/v1/incident-events", params={"has_incident": "false"})
        assert resp.status_code == 200
        items = resp.json()["items"]
        assert len(items) == 1
        assert items[0]["fingerprint"] == "fp-noop"
        assert items[0]["incident_effect"] == "none"

        # incident_effect filter
        resp = await client.get(
            "/v1/incident-events", params={"incident_effect": "inserted"}
        )
        assert resp.status_code == 200
        ids = {i["fingerprint"] for i in resp.json()["items"]}
        assert ids == {"fp-incident"}

        # no_dispatch_reason filter
        resp = await client.get(
            "/v1/incident-events", params={"no_dispatch_reason": "below_threshold"}
        )
        assert resp.status_code == 200
        items = resp.json()["items"]
        assert len(items) == 1
        assert items[0]["fingerprint"] == "fp-below"


async def test_list_incident_events_filters_full_recovery_ids_with_bounded_response(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    incident_ids = [str(uuid4()) for _ in range(AUDIT_INCIDENT_IDS_MAX + 1)]
    async with session_factory() as session:
        await _seed_audit_event(
            session,
            accepted_offset=1,
            incident_ids=incident_ids,
            decision_summary_incident_ids=incident_ids[:AUDIT_INCIDENT_IDS_MAX],
            decision_summary_incident_ids_truncated=True,
            incident_effect="resolved",
            decision_kind="recovery",
            event_type="RECOVERY",
            fingerprint="fp-full-recovery-ids",
            source_id="src-full-recovery-ids",
        )
        await session.commit()

    app = _app(session_factory)
    async for client in get_client(app):
        response = await client.get(
            "/v1/incident-events",
            params={"incident_id": incident_ids[-1]},
        )

    assert response.status_code == 200
    payload = response.json()
    assert payload["total"] == 1
    assert len(payload["items"]) == 1
    item = payload["items"][0]
    assert item["fingerprint"] == "fp-full-recovery-ids"
    assert item["incident_ids"] == incident_ids[:AUDIT_INCIDENT_IDS_MAX]
    assert (
        item["decision_summary"]["incident_ids"]
        == incident_ids[:AUDIT_INCIDENT_IDS_MAX]
    )
    assert item["decision_summary"]["incident_ids_truncated"] is True


# ---------------------------------------------------------------------------
# Filter tests — scalar and time ranges
# ---------------------------------------------------------------------------


async def test_list_incident_events_filters_by_scalar_and_time_ranges(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        await _seed_audit_event(
            session,
            accepted_offset=1,
            fingerprint="fp-alpha",
            source_id="src-alpha",
            event_type="PROBLEM",
            severity="CRITICAL",
            host="web01",
            service="http",
        )
        await _seed_audit_event(
            session,
            accepted_offset=2,
            fingerprint="fp-beta",
            source_id="src-beta",
            event_type="RECOVERY",
            severity="OK",
            host="db01",
            service="postgres",
        )
        await session.commit()

    app = _app(session_factory)
    async for client in get_client(app):
        # fingerprint
        resp = await client.get(
            "/v1/incident-events", params={"fingerprint": "fp-alpha"}
        )
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 1
        assert resp.json()["items"][0]["fingerprint"] == "fp-alpha"

        # source_id
        resp = await client.get("/v1/incident-events", params={"source_id": "src-beta"})
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 1
        assert resp.json()["items"][0]["source_id"] == "src-beta"

        # event_type
        resp = await client.get(
            "/v1/incident-events", params={"event_type": "RECOVERY"}
        )
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 1
        assert resp.json()["items"][0]["event_type"] == "RECOVERY"

        # severity
        resp = await client.get("/v1/incident-events", params={"severity": "CRITICAL"})
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 1
        assert resp.json()["items"][0]["severity"] == "CRITICAL"

        # host
        resp = await client.get("/v1/incident-events", params={"host": "db01"})
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 1
        assert resp.json()["items"][0]["host"] == "db01"

        # service
        resp = await client.get("/v1/incident-events", params={"service": "http"})
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 1
        assert resp.json()["items"][0]["service"] == "http"

        # accepted_since — should include only beta (at +2)
        resp = await client.get(
            "/v1/incident-events",
            params={"accepted_since": _event_time(2).isoformat()},
        )
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 1
        assert resp.json()["items"][0]["fingerprint"] == "fp-beta"

        # accepted_until — should include only alpha (at +1)
        resp = await client.get(
            "/v1/incident-events",
            params={"accepted_until": _event_time(2).isoformat()},
        )
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 1
        assert resp.json()["items"][0]["fingerprint"] == "fp-alpha"

        # event_timestamp_since — both have event_timestamp at _event_time(0);
        # since > 0 means neither matches
        resp = await client.get(
            "/v1/incident-events",
            params={
                "event_timestamp_since": (
                    _event_time(0) + timedelta(seconds=1)
                ).isoformat()
            },
        )
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 0

        # event_timestamp_until — both have timestamp at _event_time(0),
        # until > 0 includes both
        resp = await client.get(
            "/v1/incident-events",
            params={
                "event_timestamp_until": (
                    _event_time(0) + timedelta(seconds=1)
                ).isoformat()
            },
        )
        assert resp.status_code == 200
        assert len(resp.json()["items"]) == 2


# ---------------------------------------------------------------------------
# Cursor pagination
# ---------------------------------------------------------------------------


async def test_list_incident_events_cursor_pagination_and_invalid_cursor(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        # Seed 5 rows with distinct accepted_at (descending order = +5 first)
        for i in range(5):
            await _seed_audit_event(
                session,
                accepted_offset=i + 1,
                fingerprint=f"fp-page-{i}",
                source_id=f"src-page-{i}",
                host=f"host-{i}",
            )
        await session.commit()

    app = _app(session_factory)
    async for client in get_client(app):
        # Page 1: limit=2, expect +5 and +4 in descending order
        resp = await client.get("/v1/incident-events", params={"limit": 2})
        assert resp.status_code == 200
        body = resp.json()
        assert len(body["items"]) == 2
        assert body["items"][0]["fingerprint"] == "fp-page-4"
        assert body["items"][1]["fingerprint"] == "fp-page-3"
        assert body["next_cursor"] is not None

        # Page 2: use cursor from page 1
        resp2 = await client.get(
            "/v1/incident-events",
            params={"limit": 2, "cursor": body["next_cursor"]},
        )
        assert resp2.status_code == 200
        body2 = resp2.json()
        assert len(body2["items"]) == 2
        assert body2["items"][0]["fingerprint"] == "fp-page-2"
        assert body2["items"][1]["fingerprint"] == "fp-page-1"

        # Page 3: one remaining
        assert body2["next_cursor"] is not None
        resp3 = await client.get(
            "/v1/incident-events",
            params={"limit": 2, "cursor": body2["next_cursor"]},
        )
        assert resp3.status_code == 200
        body3 = resp3.json()
        assert len(body3["items"]) == 1
        assert body3["items"][0]["fingerprint"] == "fp-page-0"
        assert body3["next_cursor"] is None

        # Invalid cursor → 400
        resp_bad = await client.get(
            "/v1/incident-events",
            params={"cursor": "not-a-valid-cursor!!!"},
        )
        assert resp_bad.status_code == 400
        assert resp_bad.json() == {"detail": "invalid cursor"}


async def test_list_incident_events_does_not_relabel_unrelated_value_errors(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    @asynccontextmanager
    async def session_context() -> AsyncIterator[object]:
        yield object()

    class SessionMaker:
        def __call__(self):
            return session_context()

    async def raise_unrelated_value_error(*args: object) -> object:
        raise ValueError("unexpected repository validation failure")

    monkeypatch.setattr(
        audit_router, "list_incident_events", raise_unrelated_value_error
    )

    with pytest.raises(ValueError, match="unexpected repository validation failure"):
        await audit_router.list_incident_events_endpoint(
            AuditEventListFilters(),
            SessionMaker(),  # type: ignore[arg-type]
        )


# ---------------------------------------------------------------------------
# Ingress correlation (end-to-end via ingress endpoint)
# ---------------------------------------------------------------------------


async def test_ingress_incident_and_noop_events_are_queryable(
    session_factory: async_sessionmaker[AsyncSession],
    tmp_path: Path,
) -> None:
    """Send accepted events through the ingress endpoint and verify
    they appear in the audit API with correct incident correlation.
    """
    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=1)
    plugin_registry = _write_plugins(tmp_path / "plugins.yaml")
    task_runner = _RecordingTaskRunner()
    processor = _build_processor(
        session_factory, rules_path, plugin_registry, task_runner
    )

    app = _app(
        session_factory,
        api_auth_enabled=True,
        icinga2_processor=processor,
        task_runner=task_runner,
    )

    async for client in get_client(app):
        headers = {"Authorization": f"Bearer {INGRESS_TOKEN}"}
        operator_headers = {"Authorization": f"Bearer {OPERATOR_TOKEN}"}

        # Problem event that should create an incident (threshold=1)
        problem_payload = {
            "source_id": "icinga2:service:web01:http",
            "host": "web01",
            "service": "http",
            "state": "CRITICAL",
            "state_type": "HARD",
            "timestamp": _event_time(0).isoformat(),
            "check_output": "HTTP 500 on web01",
            "ip_address": "192.0.2.10",
            "tags": {"env": "prod"},
        }
        resp_problem = await client.post(
            "/v1/icinga2/events", json=problem_payload, headers=headers
        )
        assert resp_problem.status_code == 200
        assert task_runner.submissions == [
            (
                "notify",
                {
                    "incident_id": resp_problem.json()["incident_id"],
                    "plugin_name": "email-oncall",
                    "config_hash": plugin_registry.config_hash,
                },
            )
        ]

        # Recovery event for a host with no open incident → no-op accepted
        noop_payload = {
            "source_id": "icinga2:host:orphan-host",
            "host": "orphan-host",
            "service": None,
            "state": "UP",
            "state_type": "HARD",
            "timestamp": _event_time(1).isoformat(),
            "check_output": "Host is up",
            "ip_address": "192.0.2.99",
            "tags": {"env": "prod"},
        }
        resp_noop = await client.post(
            "/v1/icinga2/events", json=noop_payload, headers=headers
        )
        assert resp_noop.status_code == 200

        # Query audit events
        resp_audit = await client.get("/v1/incident-events", headers=operator_headers)
        assert resp_audit.status_code == 200
        items = resp_audit.json()["items"]
        assert len(items) >= 2

        # Find the problem event (has incident)
        problem_items = [
            i for i in items if i["host"] == "web01" and i["event_type"] == "PROBLEM"
        ]
        assert len(problem_items) == 1
        problem_item = problem_items[0]
        assert len(problem_item["incident_ids"]) >= 1
        assert problem_item["incident_effect"] != "none"

        # Find the no-op recovery (no incident)
        noop_items = [
            i
            for i in items
            if i["host"] == "orphan-host" and i["event_type"] == "RECOVERY"
        ]
        assert len(noop_items) == 1
        noop_item = noop_items[0]
        assert noop_item["incident_ids"] == []
        assert noop_item["incident_effect"] == "none"

        # has_incident=false returns the no-op
        resp_noop_filter = await client.get(
            "/v1/incident-events",
            params={"has_incident": "false"},
            headers=operator_headers,
        )
        assert resp_noop_filter.status_code == 200
        noop_filtered = resp_noop_filter.json()["items"]
        noop_hosts = {i["host"] for i in noop_filtered}
        assert "orphan-host" in noop_hosts
        # Problem event must not appear in no-incident filter
        assert "web01" not in noop_hosts


async def test_ingress_recovery_persists_full_ids_with_bounded_summary(
    session_factory: async_sessionmaker[AsyncSession],
    tmp_path: Path,
) -> None:
    recovered_host = "shared-recovery-host"
    async with session_factory() as session:
        seeded_incidents = []
        for index in range(AUDIT_INCIDENT_IDS_MAX + 1):
            seeded_incidents.append(
                await upsert_open_incident(
                    session,
                    IncidentUpsertInput(
                        rule_name=f"recovery-rule-{index}",
                        group_key=f"recovery-group-{index}",
                        severity=Severity.CRITICAL,
                        event_time=_event_time(0),
                        summary=f"recovery problem {index}",
                        affected_hosts=(recovered_host,),
                        fingerprint=f"recovery-problem-{index}",
                    ),
                )
            )
        await session.commit()

    seeded_ids = {str(incident.id) for incident in seeded_incidents}
    rules_path = tmp_path / "rules.yaml"
    _write_rules(rules_path, threshold=1)
    plugin_registry = _write_plugins(tmp_path / "plugins.yaml")
    task_runner = _RecordingTaskRunner()
    processor = _build_processor(
        session_factory, rules_path, plugin_registry, task_runner
    )
    app = _app(
        session_factory,
        api_auth_enabled=True,
        icinga2_processor=processor,
        task_runner=task_runner,
    )

    async for client in get_client(app):
        ingress_headers = {"Authorization": f"Bearer {INGRESS_TOKEN}"}
        recovery_response = await client.post(
            "/v1/icinga2/events",
            json={
                "source_id": f"icinga2:host:{recovered_host}",
                "host": recovered_host,
                "service": None,
                "state": "UP",
                "state_type": "HARD",
                "timestamp": _event_time(1).isoformat(),
                "check_output": "Host is up",
                "ip_address": "192.0.2.99",
                "tags": {"env": "prod"},
            },
            headers=ingress_headers,
        )
        assert recovery_response.status_code == 200

        async with session_factory() as session:
            audit_event = await session.scalar(
                select(IncidentEvent).where(IncidentEvent.event_type == "RECOVERY")
            )
        assert audit_event is not None
        assert len(audit_event.incident_ids) == AUDIT_INCIDENT_IDS_MAX + 1
        assert set(audit_event.incident_ids) == seeded_ids
        assert (
            audit_event.decision_summary["incident_ids"]
            == audit_event.incident_ids[:AUDIT_INCIDENT_IDS_MAX]
        )
        assert audit_event.decision_summary["incident_ids_truncated"] is True
