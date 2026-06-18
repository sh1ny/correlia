from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient

from app.config.settings import Settings
from app.main import create_app

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


class SuccessfulSession:
    async def __aenter__(self) -> "SuccessfulSession":
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    async def execute(self, statement: object) -> None:
        return None


def _settings(expose_readyz: bool = True, expose_metrics: bool = True) -> Settings:
    return Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        operator_api_token=OPERATOR_TOKEN,
        ingress_api_token=INGRESS_TOKEN,
        expose_readyz=expose_readyz,
        expose_metrics=expose_metrics,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )


def _app(settings: Settings) -> object:
    return create_app(
        settings=settings,
        sessionmaker=lambda: SuccessfulSession(),
        lifecycle_worker=NoopLifecycleWorker(),
    )


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def test_health_is_public_when_auth_enabled() -> None:
    app = _app(_settings())
    async for client in get_client(app):
        response = await client.get("/v1/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_readyz_is_public_by_default() -> None:
    app = _app(_settings(expose_readyz=True))
    async for client in get_client(app):
        response = await client.get("/v1/readyz")
    assert response.status_code == 200


async def test_readyz_requires_operator_token_when_not_exposed() -> None:
    app = _app(_settings(expose_readyz=False))
    async for client in get_client(app):
        public_response = await client.get("/v1/readyz")
        protected_response = await client.get(
            "/v1/readyz", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
    assert public_response.status_code == 401
    assert protected_response.status_code == 200


async def test_metrics_is_public_by_default() -> None:
    app = _app(_settings(expose_metrics=True))
    async for client in get_client(app):
        response = await client.get("/v1/metrics")
    assert response.status_code == 200


async def test_metrics_requires_operator_token_when_not_exposed() -> None:
    app = _app(_settings(expose_metrics=False))
    async for client in get_client(app):
        public_response = await client.get("/v1/metrics")
        protected_response = await client.get(
            "/v1/metrics", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
    assert public_response.status_code == 401
    assert protected_response.status_code == 200


async def test_exposure_flags_do_not_affect_health() -> None:
    app = _app(_settings(expose_readyz=False, expose_metrics=False))
    async for client in get_client(app):
        response = await client.get("/v1/health")
    assert response.status_code == 200


async def test_readyz_exposure_respects_auth_disabled() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=False,
        expose_readyz=False,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )
    app = _app(settings)
    async for client in get_client(app):
        response = await client.get("/v1/readyz")
    assert response.status_code == 200


async def test_metrics_exposure_respects_auth_disabled() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=False,
        expose_metrics=False,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )
    app = _app(settings)
    async for client in get_client(app):
        response = await client.get("/v1/metrics")
    assert response.status_code == 200
