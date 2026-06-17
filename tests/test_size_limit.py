from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import datetime, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from app.config.settings import Settings
from app.domain.rules import IngressDecisionEnvelope
from app.main import create_app


pytestmark = pytest.mark.anyio

VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


class NoopLifecycleWorker:
    healthy = True

    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None


class FakePluginRegistry:
    def list_plugins(self) -> tuple[dict[str, object], ...]:
        return ()

    @property
    def names(self) -> frozenset[str]:
        return frozenset()


class RecordingProcessor:
    def __init__(self) -> None:
        self.calls: list[object] = []

    async def process_payload(self, payload: object) -> IngressDecisionEnvelope:
        self.calls.append(payload)
        return IngressDecisionEnvelope(state_accepted=True)


def _settings(max_body_bytes_ingress: int | None = None) -> Settings:
    return Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=False,
        max_body_bytes=2_048,
        max_body_bytes_ingress=max_body_bytes_ingress,
    )


def _app(settings: Settings, processor: RecordingProcessor | None = None) -> object:
    return create_app(
        settings=settings,
        sessionmaker=lambda: object(),
        plugin_registry=FakePluginRegistry(),
        lifecycle_worker=NoopLifecycleWorker(),
        icinga2_processor=processor,
    )


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        ("/v1/icinga2/events", "ingress"),
        ("/v1/incidents", "operator"),
        ("/v1/incidents/123", "operator"),
        ("/v1/rules", "operator"),
        ("/v1/topology", "operator"),
        ("/v1/plugins", "operator"),
        ("/v1/metrics", "metrics"),
        ("/v1/readyz", "readyz"),
        ("/v1/health", "health"),
        ("/v1/unknown", "operator"),
    ],
)
def test_classify_path_maps_routes(path: str, expected: str) -> None:
    from app.middleware.classification import classify_path

    assert classify_path(path) == expected


async def test_oversized_content_length_returns_413_and_skips_handler() -> None:
    processor = RecordingProcessor()
    app = _app(_settings(max_body_bytes_ingress=1_024), processor=processor)
    body = b'{"x": "' + b"a" * 2_048 + b'"}'
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            content=body,
            headers={"content-type": "application/json"},
        )
    assert response.status_code == 413
    assert response.json() == {"detail": "request body too large"}
    assert processor.calls == []


async def test_chunked_body_over_cap_returns_413_and_skips_handler() -> None:
    processor = RecordingProcessor()
    app = _app(_settings(max_body_bytes_ingress=1_024), processor=processor)
    body = b'{"x": "' + b"a" * 2_048 + b'"}'
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            content=body,
            headers={
                "content-type": "application/json",
                "transfer-encoding": "chunked",
            },
        )
    assert response.status_code == 413
    assert response.json() == {"detail": "request body too large"}
    assert processor.calls == []


def _valid_host_payload() -> dict[str, object]:
    return {
        "source_id": "icinga2",
        "host": "host1",
        "service": None,
        "state": "UP",
        "state_type": "HARD",
        "timestamp": datetime(2026, 6, 8, 12, 0, tzinfo=timezone.utc).isoformat(),
        "check_output": "ok",
    }


async def test_under_cap_body_replays_to_handler() -> None:
    processor = RecordingProcessor()
    app = _app(_settings(max_body_bytes_ingress=4_096), processor=processor)
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json=_valid_host_payload(),
            headers={"content-type": "application/json"},
        )
    assert response.status_code == 200
    assert len(processor.calls) == 1


async def test_default_cap_applies_when_class_override_is_none() -> None:
    processor = RecordingProcessor()
    app = _app(
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            api_auth_enabled=False,
            max_body_bytes=1_024,
            max_body_bytes_ingress=None,
        ),
        processor=processor,
    )
    body = b'{"x": "' + b"a" * 2_048 + b'"}'
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            content=body,
            headers={"content-type": "application/json"},
        )
    assert response.status_code == 413
    assert processor.calls == []
