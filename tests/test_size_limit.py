from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import datetime, timezone
from starlette.types import Message, Receive, Scope, Send

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
        audit_raw_payload_hmac_key="test-audit-hmac",
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
            audit_raw_payload_hmac_key="test-audit-hmac",
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

async def test_disconnect_during_body_read_returns_without_app() -> None:
    from app.middleware.size_limit import RequestSizeLimiterMiddleware

    calls: list[tuple[Scope, Message]] = []

    async def app(scope: Scope, receive: Receive, send: Send) -> None:
        calls.append((scope, await receive()))

    async def receive() -> Message:
        if not hasattr(receive, "called"):
            receive.called = True
            return {"type": "http.request", "body": b"chunk", "more_body": True}
        return {"type": "http.disconnect"}

    middleware = RequestSizeLimiterMiddleware(app, default_limit=100, class_limits={})
    scope: Scope = {"type": "http", "path": "/v1/rules", "headers": []}
    sent: list[Message] = []

    async def send(msg: Message) -> None:
        sent.append(msg)

    await middleware(scope, receive, send)
    assert calls == []
    assert sent == []


async def test_replay_receive_returns_terminal_message_after_body() -> None:
    from app.middleware.size_limit import RequestSizeLimiterMiddleware

    calls: list[Message] = []

    async def app(scope: Scope, receive: Receive, send: Send) -> None:
        calls.append(await receive())
        calls.append(await receive())

    async def receive() -> Message:
        if not hasattr(receive, "called"):
            receive.called = True
            return {"type": "http.request", "body": b"hello", "more_body": False}
        raise AssertionError("middleware delegated after body replay")

    middleware = RequestSizeLimiterMiddleware(app, default_limit=100, class_limits={})
    scope: Scope = {"type": "http", "path": "/v1/rules", "headers": []}

    await middleware(scope, receive, lambda msg: None)
    assert calls == [
        {"type": "http.request", "body": b"hello", "more_body": False},
        {"type": "http.request", "body": b"", "more_body": False},
    ]


async def test_empty_progress_messages_do_not_inflate_replay_count() -> None:
    from app.middleware.size_limit import RequestSizeLimiterMiddleware

    calls: list[Message] = []

    async def app(scope: Scope, receive: Receive, send: Send) -> None:
        calls.append(await receive())
        calls.append(await receive())

    empty_messages = 100

    async def receive() -> Message:
        if not hasattr(receive, "idx"):
            receive.idx = 0
        idx = receive.idx
        receive.idx += 1
        if idx < empty_messages:
            return {"type": "http.request", "body": b"", "more_body": True}
        if idx == empty_messages:
            return {"type": "http.request", "body": b"payload", "more_body": False}
        raise AssertionError("middleware delegated after body replay")

    middleware = RequestSizeLimiterMiddleware(app, default_limit=100, class_limits={})
    scope: Scope = {"type": "http", "path": "/v1/rules", "headers": []}

    await middleware(scope, receive, lambda msg: None)
    assert calls == [
        {"type": "http.request", "body": b"payload", "more_body": False},
        {"type": "http.request", "body": b"", "more_body": False},
    ]


async def test_oversized_streamed_body_rejects_413_without_draining() -> None:
    from app.middleware.size_limit import RequestSizeLimiterMiddleware

    received_chunks: list[bytes] = []

    async def app(scope: Scope, receive: Receive, send: Send) -> None:
        pass

    async def receive() -> Message:
        if len(received_chunks) == 0:
            received_chunks.append(b"chunk1")
            return {"type": "http.request", "body": b"chunk1", "more_body": True}
        if len(received_chunks) == 1:
            received_chunks.append(b"chunk2")
            return {"type": "http.request", "body": b"chunk2", "more_body": True}
        raise AssertionError("middleware drained body after overflow")

    middleware = RequestSizeLimiterMiddleware(app, default_limit=10, class_limits={})
    scope: Scope = {"type": "http", "path": "/v1/rules", "headers": []}
    sent: list[Message] = []

    async def send(msg: Message) -> None:
        sent.append(msg)

    await middleware(scope, receive, send)
    assert len(received_chunks) == 2
    assert sent[0] == {
        "type": "http.response.start",
        "status": 413,
        "headers": [(b"content-type", b"application/json")],
    }
    assert sent[1] == {
        "type": "http.response.body",
        "body": b'{"detail":"request body too large"}',
    }
