from __future__ import annotations

import logging
import os
import subprocess
from collections.abc import AsyncIterator
from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from testcontainers.postgres import PostgresContainer

from app.config.settings import Settings
from app.domain.events import Severity
from app.domain.notifications import NotificationDeliveryRecord, NotificationResult
from app.domain.incidents import DecisionContext, IncidentStatus
from app.main import create_app
from app.persistence.models import Incident, IncidentEvent

pytestmark = pytest.mark.anyio

VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


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
        url = postgres.get_connection_url().replace("postgresql+psycopg2", "postgresql+asyncpg")
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


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def _settings() -> Settings:
    return Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=False,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )


def _app(session_factory: async_sessionmaker[AsyncSession]):
    return create_app(
        settings=_settings(),
        sessionmaker=session_factory,
        lifecycle_worker=NoopLifecycleWorker(),
    )


def _event_time(offset_minutes: int) -> datetime:
    return datetime(2026, 6, 9, 12, 0, tzinfo=timezone.utc) + timedelta(minutes=offset_minutes)


async def _seed_incident(
    session: AsyncSession,
    *,
    rule_name: str,
    group_key: str,
    host: str,
    service: str | None,
    severity: Severity,
    event_time: datetime,
) -> Incident:
    from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident

    incident = await upsert_open_incident(
        session,
        IncidentUpsertInput(
            rule_name=rule_name,
            group_key=group_key,
            severity=severity,
            summary=f"{severity.value} on {host}",
            event_time=event_time,
            fingerprint=f"fp-{rule_name}-{group_key}-{event_time.timestamp()}",
            affected_hosts=(host,),
            affected_services=(service,) if service is not None else (),
            window_seconds=300,
            threshold_count=1,
            decision_context=DecisionContext(
                fingerprint=f"fp-{rule_name}-{group_key}",
                source_id="icinga2",
                rule_name=rule_name,
                group_key=group_key,
                matched_rule_names=(rule_name,),
                notes={"notification.plugin": "email-oncall", "lifecycle.reason": "created"},
                action_names=("create_incident",),
                notification_delivery_results=(
                    NotificationDeliveryRecord(
                        plugin_name="email-oncall",
                        result=NotificationResult(
                            success=True,
                            category="dispatched",
                            message="notification dispatched",
                        ),
                    ),
                ),
            ),
        ),
    )
    await session.commit()
    return incident


async def test_list_incidents_filters_and_cursor_pagination(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        first = await _seed_incident(
            session,
            rule_name="cpu-hot",
            group_key="host:app-1",
            host="app-1",
            service="cpu",
            severity=Severity.WARNING,
            event_time=_event_time(0),
        )
        second = await _seed_incident(
            session,
            rule_name="disk-full",
            group_key="host:db-1",
            host="db-1",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(2),
        )
        third = await _seed_incident(
            session,
            rule_name="host-down",
            group_key="host:cache-1",
            host="cache-1",
            service=None,
            severity=Severity.UNKNOWN,
            event_time=_event_time(2),
        )

    app = _app(session_factory)
    async for client in get_client(app):
        page1 = await client.get("/v1/incidents", params={"limit": 2})
        filtered = await client.get(
            "/v1/incidents",
            params={
                "status": "OPEN",
                "severity": "CRITICAL",
                "rule_name": "disk-full",
                "host": "db-1",
                "service": "disk",
                "updated_since": _event_time(1).isoformat(),
            },
        )
        older = await client.get(
            "/v1/incidents",
            params={"updated_since": _event_time(3).isoformat()},
        )

    assert page1.status_code == 200
    body1 = page1.json()
    ids_page1 = [item["id"] for item in body1["items"]]
    assert len(ids_page1) == 2
    assert ids_page1 == sorted([str(second.id), str(third.id)], reverse=True)
    assert body1["next_cursor"]

    async for client in get_client(app):
        page2 = await client.get(
            "/v1/incidents",
            params={"limit": 2, "cursor": body1["next_cursor"]},
        )
    assert page2.status_code == 200
    body2 = page2.json()
    assert [item["id"] for item in body2["items"]] == [str(first.id)]
    assert body2["next_cursor"] is None

    assert filtered.status_code == 200
    assert [item["id"] for item in filtered.json()["items"]] == [str(second.id)]
    assert older.status_code == 200
    assert older.json()["items"] == []


async def test_incident_detail_excludes_raw_payloads_and_secrets(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        incident = await _seed_incident(
            session,
            rule_name="safe-detail",
            group_key="host:web-1",
            host="web-1",
            service="http",
            severity=Severity.CRITICAL,
            event_time=_event_time(0),
        )

    app = _app(session_factory)
    async for client in get_client(app):
        response = await client.get(f"/v1/incidents/{incident.id}")

    assert response.status_code == 200
    body = response.json()
    assert body["id"] == str(incident.id)
    assert body["status"] == "OPEN"
    assert body["decision_context"]["notes"]["notification.plugin"] == "email-oncall"
    assert body["decision_context"]["notification_delivery_results"] == [
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
    assert body["affected_hosts"] == ["web-1"]
    assert body["affected_services"] == ["http"]
    serialized = response.text.lower()
    for fragment in (
        "raw_payload",
        "payload",
        "password",
        "token",
        "secret",
        "plugin_config",
        "smtp transcript",
        "traceback",
    ):
        assert fragment not in serialized


async def test_ack_is_idempotent_and_keeps_incident_open(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        incident = await _seed_incident(
            session,
            rule_name="ack-rule",
            group_key="host:ack-1",
            host="ack-1",
            service="cpu",
            severity=Severity.WARNING,
            event_time=_event_time(0),
        )

    app = _app(session_factory)
    payload = {"operator": "operator-a"}
    async for client in get_client(app):
        first = await client.post(f"/v1/incidents/{incident.id}/ack", json=payload)
        second = await client.post(f"/v1/incidents/{incident.id}/ack", json=payload)

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["status"] == "OPEN"
    assert second.json()["status"] == "OPEN"
    assert second.json()["acknowledgement"]["acknowledged_by"] == "operator-a"
    async with session_factory() as session:
        count = await session.scalar(
            select(func.count()).select_from(Incident).where(
                Incident.rule_name == "ack-rule",
                Incident.group_key == "host:ack-1",
                Incident.status == IncidentStatus.OPEN.value,
            )
        )
    assert count == 1

    # AUD-03: operator ACK mutations must not create audit rows.
    async with session_factory() as session:
        audit_count = await session.scalar(
            select(func.count()).select_from(IncidentEvent)
        )
    assert audit_count == 0


async def test_manual_close_is_idempotent_and_frees_open_slot(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        incident = await _seed_incident(
            session,
            rule_name="close-rule",
            group_key="host:close-1",
            host="close-1",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(0),
        )

    app = _app(session_factory)
    payload = {"operator": "operator-a", "reason": "handled manually"}
    async for client in get_client(app):
        first = await client.post(f"/v1/incidents/{incident.id}/close", json=payload)
        second = await client.post(f"/v1/incidents/{incident.id}/close", json=payload)

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["status"] == "CLOSED"
    assert second.json()["status"] == "CLOSED"
    async with session_factory() as session:
        reopened = await _seed_incident(
            session,
            rule_name="close-rule",
            group_key="host:close-1",
            host="close-1",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(5),
        )
    assert reopened.id != incident.id
    assert reopened.status == IncidentStatus.OPEN.value

    # AUD-03: operator CLOSE mutations must not create audit rows.
    async with session_factory() as session:
        audit_count = await session.scalar(
            select(func.count()).select_from(IncidentEvent)
        )
    assert audit_count == 0


async def test_operator_mutations_emit_safe_json_logs(
    session_factory: async_sessionmaker[AsyncSession],
    caplog: pytest.LogCaptureFixture,
) -> None:
    async with session_factory() as session:
        ack_incident = await _seed_incident(
            session,
            rule_name="log-ack-rule",
            group_key="host:log-ack",
            host="log-ack",
            service="cpu",
            severity=Severity.WARNING,
            event_time=_event_time(0),
        )
        close_incident = await _seed_incident(
            session,
            rule_name="log-close-rule",
            group_key="host:log-close",
            host="log-close",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(1),
        )

    app = _app(session_factory)
    caplog.set_level(logging.INFO)
    async for client in get_client(app):
        ack = await client.post(
            f"/v1/incidents/{ack_incident.id}/ack",
            json={"operator": "operator-a"},
        )
        close = await client.post(
            f"/v1/incidents/{close_incident.id}/close",
            json={"operator": "operator-a", "reason": "handled manually"},
        )

    assert ack.status_code == 200
    assert close.status_code == 200
    events = [
        record.__dict__
        for record in caplog.records
        if record.__dict__.get("event") == "operator_mutation"
    ]
    assert [event["effect"] for event in events] == ["acknowledged", "closed"]
    assert {event["incident_id"] for event in events} == {
        str(ack_incident.id),
        str(close_incident.id),
    }
    assert {event["status"] for event in events} == {"OPEN", "CLOSED"}
    assert {event["reason"] for event in events} == {"acknowledged", "manual_close"}
    serialized = "\n".join(record.getMessage() + repr(record.__dict__) for record in caplog.records)
    for fragment in ("token-secret", "raw_payload", "password", "plugin_options", "Traceback"):
        assert fragment not in serialized


async def test_incident_api_rejects_invalid_inputs_without_source_exception_text(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    app = _app(session_factory)
    async for client in get_client(app):
        bad_cursor = await client.get("/v1/incidents", params={"cursor": "not-a-cursor"})
        bad_uuid = await client.get("/v1/incidents/not-a-uuid")
        bad_body = await client.post(
            "/v1/incidents/00000000-0000-0000-0000-000000000000/ack",
            json={},
        )

        secret_ack = await client.post(
            "/v1/incidents/00000000-0000-0000-0000-000000000000/ack",
            json={"operator": "token-secret"},
        )
        secret_close = await client.post(
            "/v1/incidents/00000000-0000-0000-0000-000000000000/close",
            json={"operator": "operator-a", "reason": "password leaked"},
        )
    assert bad_cursor.status_code == 400
    assert bad_uuid.status_code == 422
    assert bad_body.status_code == 422
    assert secret_ack.status_code == 422
    assert secret_close.status_code == 422
    serialized = "\n".join(
        [
            bad_cursor.text,
            bad_uuid.text,
            bad_body.text,
            secret_ack.text,
            secret_close.text,
        ]
    ).lower()
    for fragment in (
        "traceback",
        "valueerror",
        "sqlalchemy",
        "asyncpg",
        "postgresql",
        "token-secret",
        "password leaked",
    ):
        assert fragment not in serialized




async def test_list_incidents_offset_metadata_and_cursor_coexistence(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        first = await _seed_incident(
            session,
            rule_name="offset-a",
            group_key="host:o-a",
            host="o-a",
            service="cpu",
            severity=Severity.WARNING,
            event_time=_event_time(0),
        )
        second = await _seed_incident(
            session,
            rule_name="offset-b",
            group_key="host:o-b",
            host="o-b",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(2),
        )
        third = await _seed_incident(
            session,
            rule_name="offset-c",
            group_key="host:o-c",
            host="o-c",
            service=None,
            severity=Severity.UNKNOWN,
            event_time=_event_time(4),
        )

    expected_newest_first = [str(third.id), str(second.id), str(first.id)]

    app = _app(session_factory)
    async for client in get_client(app):
        default_page = await client.get("/v1/incidents", params={"limit": 2})
        offset_page = await client.get(
            "/v1/incidents", params={"limit": 1, "offset": 1}
        )

    assert default_page.status_code == 200
    default_body = default_page.json()
    assert [item["id"] for item in default_body["items"]] == expected_newest_first[:2]
    assert default_body["next_cursor"] is not None
    assert default_body["total"] == 3
    assert default_body["limit"] == 2
    assert default_body["offset"] == 0

    assert offset_page.status_code == 200
    offset_body = offset_page.json()
    assert [item["id"] for item in offset_body["items"]] == [str(second.id)]
    assert offset_body["next_cursor"] is None
    assert offset_body["total"] == 3
    assert offset_body["limit"] == 1
    assert offset_body["offset"] == 1

    app = _app(session_factory)
    async for client in get_client(app):
        cursor_wins = await client.get(
            "/v1/incidents",
            params={"limit": 2, "cursor": default_body["next_cursor"], "offset": 0},
        )

    assert cursor_wins.status_code == 200
    cursor_body = cursor_wins.json()
    assert [item["id"] for item in cursor_body["items"]] == [str(first.id)]
    assert cursor_body["offset"] == 0
    assert cursor_body["total"] == 3


async def test_list_incidents_acknowledged_filter_is_derived_and_open_includes_acknowledged(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        acknowledged = await _seed_incident(
            session,
            rule_name="ack-filter",
            group_key="host:ack-f",
            host="ack-f",
            service="cpu",
            severity=Severity.WARNING,
            event_time=_event_time(0),
        )
        plain = await _seed_incident(
            session,
            rule_name="open-filter",
            group_key="host:open-f",
            host="open-f",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(1),
        )

    app = _app(session_factory)
    async for client in get_client(app):
        ack = await client.post(
            f"/v1/incidents/{acknowledged.id}/ack", json={"operator": "operator-a"}
        )
        acked = await client.get(
            "/v1/incidents", params={"status": "ACKNOWLEDGED"}
        )
        open_all = await client.get("/v1/incidents", params={"status": "OPEN"})

    assert ack.status_code == 200
    assert ack.json()["status"] == "OPEN"
    assert ack.json()["acknowledgement"]["acknowledged_by"] == "operator-a"

    assert acked.status_code == 200
    acked_body = acked.json()
    assert [item["id"] for item in acked_body["items"]] == [str(acknowledged.id)]
    assert acked_body["items"][0]["status"] == "OPEN"
    assert acked_body["items"][0]["acknowledgement"]["acknowledged_by"] == "operator-a"

    assert open_all.status_code == 200
    open_ids = {item["id"] for item in open_all.json()["items"]}
    assert {str(acknowledged.id), str(plain.id)} <= open_ids


async def test_incident_detail_preserves_rich_fields_for_compatibility(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        incident = await _seed_incident(
            session,
            rule_name="rich-detail",
            group_key="host:rich-1",
            host="rich-1",
            service="http",
            severity=Severity.CRITICAL,
            event_time=_event_time(0),
        )

    app = _app(session_factory)
    async for client in get_client(app):
        response = await client.get(f"/v1/incidents/{incident.id}")

    assert response.status_code == 200
    body = response.json()
    assert body["id"] == str(incident.id)
    assert body["affected_hosts"] == ["rich-1"]
    assert body["affected_services"] == ["http"]
    assert "decision_context" in body
    assert isinstance(body["decision_context"], dict)
    assert "window_state" in body
    assert isinstance(body["window_state"], dict)
    assert "acknowledgement" in body
    assert body["acknowledgement"]["acknowledged_by"] is None
    for rich_field in (
        "start_time",
        "last_update_time",
        "created_at",
        "updated_at",
    ):
        assert rich_field in body


async def test_patch_acknowledges_with_vigilo_defaults_and_is_idempotent(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        incident = await _seed_incident(
            session,
            rule_name="patch-ack",
            group_key="host:patch-ack",
            host="patch-ack",
            service="cpu",
            severity=Severity.WARNING,
            event_time=_event_time(0),
        )

    app = _app(session_factory)
    async for client in get_client(app):
        first = await client.patch(
            f"/v1/incidents/{incident.id}", json={"status": "ACKNOWLEDGED"}
        )
        second = await client.patch(
            f"/v1/incidents/{incident.id}", json={"status": "ACKNOWLEDGED"}
        )

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["status"] == "OPEN"
    assert second.json()["status"] == "OPEN"
    assert first.json()["acknowledgement"]["acknowledged_by"] == "vigilo-compat"
    assert second.json()["acknowledgement"]["acknowledged_by"] == "vigilo-compat"

    # AUD-03: PATCH compatibility ack must not create audit rows.
    async with session_factory() as session:
        audit_count = await session.scalar(
            select(func.count()).select_from(IncidentEvent)
        )
    assert audit_count == 0


async def test_patch_close_and_delete_close_with_vigilo_defaults_are_idempotent(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        patch_incident = await _seed_incident(
            session,
            rule_name="patch-close",
            group_key="host:patch-close",
            host="patch-close",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(0),
        )
        delete_incident = await _seed_incident(
            session,
            rule_name="delete-close",
            group_key="host:delete-close",
            host="delete-close",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(1),
        )

    app = _app(session_factory)
    async for client in get_client(app):
        first_close = await client.patch(
            f"/v1/incidents/{patch_incident.id}", json={"status": "CLOSED"}
        )
        repeat_close = await client.patch(
            f"/v1/incidents/{patch_incident.id}", json={"status": "CLOSED"}
        )
        first_delete = await client.delete(
            f"/v1/incidents/{delete_incident.id}"
        )
        repeat_delete = await client.delete(
            f"/v1/incidents/{delete_incident.id}"
        )

    assert first_close.status_code == 200
    assert repeat_close.status_code == 200
    assert first_close.json()["status"] == "CLOSED"
    assert repeat_close.json()["status"] == "CLOSED"
    assert first_delete.status_code == 200
    assert repeat_delete.status_code == 200
    assert first_delete.json()["status"] == "CLOSED"
    assert repeat_delete.json()["status"] == "CLOSED"

    # AUD-03: PATCH/DELETE compatibility close must not create audit rows.
    async with session_factory() as session:
        audit_count = await session.scalar(
            select(func.count()).select_from(IncidentEvent)
        )
    assert audit_count == 0


async def test_patch_rejects_summary_mutation_and_missing_status_with_compact_422(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        incident = await _seed_incident(
            session,
            rule_name="patch-reject",
            group_key="host:patch-reject",
            host="patch-reject",
            service="cpu",
            severity=Severity.WARNING,
            event_time=_event_time(0),
        )
    original_summary = incident.summary

    app = _app(session_factory)
    nil_uuid = "00000000-0000-0000-0000-000000000000"
    async for client in get_client(app):
        missing_status_cases = [
            await client.patch(f"/v1/incidents/{incident.id}", json={}),
            await client.patch(
                f"/v1/incidents/{incident.id}", content=b"[1,2,3]", headers={"content-type": "application/json"}
            ),
            await client.patch(
                f"/v1/incidents/{incident.id}", content=b"", headers={"content-type": "application/json"}
            ),
            await client.patch(
                f"/v1/incidents/{incident.id}", content=b"{", headers={"content-type": "application/json"}
            ),
            await client.patch(
                f"/v1/incidents/{incident.id}", json={"status": "OPEN"}
            ),
            await client.patch(
                f"/v1/incidents/{incident.id}", json={"status": "RESOLVED"}
            ),
            await client.patch(
                f"/v1/incidents/{incident.id}", json={"status": "UNKNOWN"}
            ),
            await client.patch(
                f"/v1/incidents/{incident.id}", json={"status": 123}
            ),
        ]
        summary_mutation_cases = [
            await client.patch(
                f"/v1/incidents/{incident.id}", json={"summary": "x"}
            ),
            await client.patch(
                f"/v1/incidents/{incident.id}",
                json={"status": "ACKNOWLEDGED", "summary": "x"},
            ),
        ]
        not_found_ack = await client.patch(
            f"/v1/incidents/{nil_uuid}", json={"status": "ACKNOWLEDGED"}
        )
        not_found_closed = await client.patch(
            f"/v1/incidents/{nil_uuid}", json={"status": "CLOSED"}
        )
        verify_get = await client.get(f"/v1/incidents/{incident.id}")

    for resp in missing_status_cases:
        assert resp.status_code == 422, resp.text
        assert resp.json() == {"detail": "status is required"}, resp.text
    for resp in summary_mutation_cases:
        assert resp.status_code == 422, resp.text
        assert resp.json() == {"detail": "summary mutation is not supported"}, resp.text
    assert not_found_ack.status_code == 404
    assert not_found_ack.json() == {"detail": "incident not found"}
    assert not_found_closed.status_code == 404
    assert not_found_closed.json() == {"detail": "incident not found"}
    assert verify_get.status_code == 200
    assert verify_get.json()["summary"] == original_summary
    assert verify_get.json()["acknowledgement"]["acknowledged_by"] is None


async def test_explicit_ack_and_close_endpoints_remain_available_alongside_aliases(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as session:
        ack_incident = await _seed_incident(
            session,
            rule_name="explicit-ack",
            group_key="host:explicit-ack",
            host="explicit-ack",
            service="cpu",
            severity=Severity.WARNING,
            event_time=_event_time(0),
        )
        close_incident = await _seed_incident(
            session,
            rule_name="explicit-close",
            group_key="host:explicit-close",
            host="explicit-close",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(1),
        )

    app = _app(session_factory)
    async for client in get_client(app):
        ack_ok = await client.post(
            f"/v1/incidents/{ack_incident.id}/ack",
            json={"operator": "operator-a"},
        )
        close_ok = await client.post(
            f"/v1/incidents/{close_incident.id}/close",
            json={"operator": "operator-a", "reason": "handled manually"},
        )
        ack_missing_body = await client.post(
            f"/v1/incidents/{ack_incident.id}/ack", json={}
        )
        close_missing_body = await client.post(
            f"/v1/incidents/{close_incident.id}/close", json={}
        )

    assert ack_ok.status_code == 200
    assert ack_ok.json()["acknowledgement"]["acknowledged_by"] == "operator-a"
    assert close_ok.status_code == 200
    assert close_ok.json()["status"] == "CLOSED"
    assert ack_missing_body.status_code == 422
    assert close_missing_body.status_code == 422


async def test_compatibility_mutations_emit_safe_json_logs(
    session_factory: async_sessionmaker[AsyncSession],
    caplog: pytest.LogCaptureFixture,
) -> None:
    async with session_factory() as session:
        ack_incident = await _seed_incident(
            session,
            rule_name="compat-log-ack",
            group_key="host:compat-log-ack",
            host="compat-log-ack",
            service="cpu",
            severity=Severity.WARNING,
            event_time=_event_time(0),
        )
        close_incident = await _seed_incident(
            session,
            rule_name="compat-log-close",
            group_key="host:compat-log-close",
            host="compat-log-close",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(1),
        )
        delete_incident = await _seed_incident(
            session,
            rule_name="compat-log-delete",
            group_key="host:compat-log-delete",
            host="compat-log-delete",
            service="disk",
            severity=Severity.CRITICAL,
            event_time=_event_time(2),
        )

    app = _app(session_factory)
    caplog.set_level(logging.INFO)
    async for client in get_client(app):
        await client.patch(
            f"/v1/incidents/{ack_incident.id}", json={"status": "ACKNOWLEDGED"}
        )
        await client.patch(
            f"/v1/incidents/{close_incident.id}", json={"status": "CLOSED"}
        )
        await client.delete(f"/v1/incidents/{delete_incident.id}")

    events = [
        record.__dict__
        for record in caplog.records
        if record.__dict__.get("event") == "operator_mutation"
    ]
    assert [event["effect"] for event in events] == [
        "acknowledged",
        "closed",
        "closed",
    ]
    assert {event["incident_id"] for event in events} == {
        str(ack_incident.id),
        str(close_incident.id),
        str(delete_incident.id),
    }
    assert {event["operator"] for event in events} == {"vigilo-compat"}
    assert {event["reason"] for event in events} == {"acknowledged", "manual_close"}
    serialized = "\n".join(
        record.getMessage() + repr(record.__dict__) for record in caplog.records
    )
    for fragment in ("raw_payload", "password", "token-secret", "summary"):
        assert fragment not in serialized
