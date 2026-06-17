from __future__ import annotations

import time
from collections.abc import AsyncIterator

import pytest
from fastapi import Request
from httpx import ASGITransport, AsyncClient

from app.config.settings import Settings
from app.main import create_app
from app.middleware.rate_limit import (
    InProcessRateLimiter,
    RateLimitConfig,
    identity_for_request,
)


pytestmark = pytest.mark.anyio

VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"
OPERATOR_TOKEN = "operator-secret"
INGRESS_TOKEN = "ingress-secret"


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


def _auth_settings(
    api_auth_enabled: bool = True,
    rate_limit_enabled: bool = True,
    rate_limit_requests_operator: int = 60,
    rate_limit_window_seconds_operator: int = 60,
) -> Settings:
    return Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=api_auth_enabled,
        operator_api_token=OPERATOR_TOKEN if api_auth_enabled else None,
        ingress_api_token=INGRESS_TOKEN if api_auth_enabled else None,
        rate_limit_enabled=rate_limit_enabled,
        rate_limit_requests_operator=rate_limit_requests_operator,
        rate_limit_window_seconds_operator=rate_limit_window_seconds_operator,
    )


def _app(settings: Settings) -> object:
    return create_app(
        settings=settings,
        sessionmaker=lambda: object(),
        plugin_registry=FakePluginRegistry(),
        lifecycle_worker=NoopLifecycleWorker(),
    )


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def test_rate_limit_allows_requests_under_limit() -> None:
    app = _app(_auth_settings(rate_limit_requests_operator=2))
    app.state.rate_limiter.clear()
    async for client in get_client(app):
        response1 = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
        response2 = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
    assert response1.status_code == 200
    assert response2.status_code == 200


async def test_rate_limit_rejects_over_limit_with_429_and_retry_after() -> None:
    app = _app(_auth_settings(rate_limit_requests_operator=1))
    app.state.rate_limiter.clear()
    async for client in get_client(app):
        response1 = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
        response2 = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
    assert response1.status_code == 200
    assert response2.status_code == 429
    assert response2.json() == {"detail": "rate limit exceeded"}
    assert response2.headers.get("Retry-After") is not None
    assert int(response2.headers["Retry-After"]) > 0


async def test_invalid_token_rotation_uses_ip_bucket_on_operator_route() -> None:
    app = _app(_auth_settings(rate_limit_requests_operator=1))
    app.state.rate_limiter.clear()
    async for client in get_client(app):
        operator_response = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
        # An invalid token for an operator route falls back to the client IP bucket.
        # The first invalid token consumes the IP bucket, so a rotated invalid token
        # is rate limited before it reaches auth.
        invalid_response_1 = await client.get(
            "/v1/plugins", headers={"Authorization": "Bearer invalid-token-1"}
        )
        invalid_response_2 = await client.get(
            "/v1/plugins", headers={"Authorization": "Bearer invalid-token-2"}
        )
    assert operator_response.status_code == 200
    assert invalid_response_1.status_code == 401
    assert invalid_response_2.status_code == 429
    assert invalid_response_2.json() == {"detail": "rate limit exceeded"}


async def test_valid_operator_token_bucket_is_separate_from_ip_bucket() -> None:
    app = _app(_auth_settings(rate_limit_requests_operator=1))
    app.state.rate_limiter.clear()
    async for client in get_client(app):
        # Valid operator token uses its own token_hash bucket.
        operator_response = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
        # Same IP without a token uses the IP bucket, which is still empty,
        # so it is allowed through to auth and rejected there.
        no_auth_response = await client.get("/v1/plugins")
    assert operator_response.status_code == 200
    assert no_auth_response.status_code == 401


async def test_oversized_request_does_not_consume_rate_limit_budget() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=False,
        max_body_bytes=1_024,
        max_body_bytes_ingress=1_024,
        rate_limit_enabled=True,
        rate_limit_requests_ingress=1,
        rate_limit_window_seconds_ingress=60,
    )
    app = _app(settings)
    app.state.rate_limiter.clear()
    body = b'{"x": "' + b"a" * 2_048 + b'"}'
    async for client in get_client(app):
        oversized = await client.post(
            "/v1/icinga2/events",
            content=body,
            headers={"content-type": "application/json"},
        )
        normal = await client.post("/v1/icinga2/events", json={})
    assert oversized.status_code == 413
    # The normal request should still be allowed because the oversized request
    # was rejected by the size middleware before the rate limiter counted it.
    assert normal.status_code == 422


async def test_rate_limit_disabled_allows_unlimited_requests() -> None:
    app = _app(_auth_settings(rate_limit_enabled=False))
    app.state.rate_limiter.clear()
    async for client in get_client(app):
        response1 = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
        response2 = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
    assert response1.status_code == 200
    assert response2.status_code == 200


async def test_rate_limit_per_class_configs_are_independent() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=False,
        rate_limit_enabled=True,
        rate_limit_requests_operator=1,
        rate_limit_window_seconds_operator=60,
        rate_limit_requests_health=10,
        rate_limit_window_seconds_health=60,
    )
    app = _app(settings)
    app.state.rate_limiter.clear()
    async for client in get_client(app):
        operator1 = await client.get("/v1/plugins")
        operator2 = await client.get("/v1/plugins")
        health1 = await client.get("/v1/health")
        health2 = await client.get("/v1/health")
    assert operator1.status_code == 200
    assert operator2.status_code == 429
    assert health1.status_code == 200
    assert health2.status_code == 200


def test_identity_for_request_uses_hashed_token_when_valid_for_class() -> None:
    import hashlib

    scope = {
        "type": "http",
        "headers": [(b"authorization", b"Bearer secret-token")],
    }
    request = Request(scope)
    label, value = identity_for_request(
        request, "operator", {"operator": "secret-token"}
    )
    assert label == "token_hash"
    assert value == hashlib.sha256(b"secret-token").hexdigest()


def test_identity_for_request_uses_ingress_token_when_valid_for_ingress() -> None:
    import hashlib

    scope = {
        "type": "http",
        "headers": [(b"authorization", b"Bearer ingress-token")],
    }
    request = Request(scope)
    label, value = identity_for_request(
        request, "ingress", {"ingress": "ingress-token"}
    )
    assert label == "token_hash"
    assert value == hashlib.sha256(b"ingress-token").hexdigest()


def test_identity_for_request_falls_back_to_ip_when_token_invalid_for_class() -> None:
    scope = {
        "type": "http",
        "client": ("192.168.1.1", 12345),
        "headers": [(b"authorization", b"Bearer wrong-token")],
    }
    request = Request(scope)
    label, value = identity_for_request(
        request, "operator", {"operator": "valid-token"}
    )
    assert label == "ip"
    assert value == "192.168.1.1"


def test_identity_for_request_uses_ip_when_no_token() -> None:
    scope = {
        "type": "http",
        "client": ("192.168.1.1", 12345),
        "headers": [],
    }
    request = Request(scope)
    label, value = identity_for_request(request, "operator", {})
    assert label == "ip"
    assert value == "192.168.1.1"


def test_identity_for_request_uses_unknown_when_no_client() -> None:
    scope = {"type": "http", "headers": []}
    request = Request(scope)
    label, value = identity_for_request(request, "operator", {})
    assert label == "ip"
    assert value == "unknown"

def test_identity_for_request_falls_back_to_ip_on_malformed_bearer() -> None:
    scope = {
        "type": "http",
        "client": ("10.0.0.1", 12345),
        "headers": [(b"authorization", "Bearer é".encode())],
    }
    request = Request(scope)
    label, value = identity_for_request(request, "operator", {"operator": "token"})
    assert label == "ip"
    assert value == "10.0.0.1"


async def test_rate_limiter_retry_after_rounds_up_to_next_second(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    limiter = InProcessRateLimiter()
    monkeypatch.setattr(time, "monotonic", lambda: 100.0)
    await limiter.check("key", 1, 10)
    monkeypatch.setattr(time, "monotonic", lambda: 100.1)
    allowed, retry_after = await limiter.check("key", 1, 10)
    assert allowed is False
    assert retry_after == 10


async def test_rate_limiter_window_resets_after_interval() -> None:
    limiter = InProcessRateLimiter()
    config = RateLimitConfig(enabled=True, requests=1, window_seconds=0)
    allowed1, _ = await limiter.check("key", config.requests, config.window_seconds)
    allowed2, _ = await limiter.check("key", config.requests, config.window_seconds)
    assert allowed1 is True
    assert allowed2 is True


def test_in_process_rate_limiter_clear() -> None:
    limiter = InProcessRateLimiter()
    limiter._counters["test"] = (1, 0.0, 0)
    limiter.clear()
    assert limiter._counters == {}

async def test_in_process_rate_limiter_evicts_stale_counters() -> None:
    limiter = InProcessRateLimiter()
    await limiter.check("stale-key", 1, 0)
    assert "stale-key" in limiter._counters
    await limiter.check("fresh-key", 1, 0)
    assert "stale-key" not in limiter._counters
    assert "fresh-key" in limiter._counters


async def test_in_process_rate_limiter_evicts_using_per_key_window() -> None:
    limiter = InProcessRateLimiter()
    await limiter.check("short-window", 1, 0)
    await limiter.check("long-window", 1, 3600)
    assert "short-window" not in limiter._counters
    assert "long-window" in limiter._counters
    # A subsequent short-window check must not prematurely evict the long-window key.
    await limiter.check("short-window", 1, 0)
    assert "long-window" in limiter._counters
    assert limiter._counters["long-window"][0] == 1
