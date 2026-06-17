from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient

from fastapi.security import HTTPAuthorizationCredentials

from app.api.security import _token_matches
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


class FakePluginRegistry:
    def list_plugins(self) -> tuple[dict[str, object], ...]:
        return ()

    @property
    def names(self) -> frozenset[str]:
        return frozenset()


def _auth_settings(api_auth_enabled: bool = True) -> Settings:
    return Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=api_auth_enabled,
        operator_api_token=OPERATOR_TOKEN if api_auth_enabled else None,
        ingress_api_token=INGRESS_TOKEN if api_auth_enabled else None,
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


async def test_operator_routes_accept_valid_operator_token() -> None:
    app = _app(_auth_settings())
    async for client in get_client(app):
        response = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
    assert response.status_code == 200


async def test_operator_routes_reject_missing_token() -> None:
    app = _app(_auth_settings())
    async for client in get_client(app):
        response = await client.get("/v1/plugins")
    assert response.status_code == 401
    assert response.json() == {"detail": "unauthorized"}
    assert response.headers.get("WWW-Authenticate") == "Bearer"


async def test_operator_routes_reject_invalid_token() -> None:
    app = _app(_auth_settings())
    async for client in get_client(app):
        response = await client.get(
            "/v1/plugins", headers={"Authorization": "Bearer wrong-token"}
        )
    assert response.status_code == 401
    assert response.json() == {"detail": "unauthorized"}


async def test_operator_routes_reject_ingress_token() -> None:
    app = _app(_auth_settings())
    async for client in get_client(app):
        response = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {INGRESS_TOKEN}"}
        )
    assert response.status_code == 401
    assert response.json() == {"detail": "unauthorized"}


async def test_ingress_route_accepts_valid_ingress_token() -> None:
    app = _app(_auth_settings())
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json={},
            headers={"Authorization": f"Bearer {INGRESS_TOKEN}"},
        )
    # 422 is expected because the empty body fails Icinga2 validation,
    # proving auth succeeded and the route handler was reached.
    assert response.status_code == 422


async def test_ingress_route_rejects_missing_token() -> None:
    app = _app(_auth_settings())
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json={})
    assert response.status_code == 401
    assert response.json() == {"detail": "unauthorized"}
    assert response.headers.get("WWW-Authenticate") == "Bearer"


async def test_ingress_route_rejects_invalid_token() -> None:
    app = _app(_auth_settings())
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json={},
            headers={"Authorization": "Bearer wrong-token"},
        )
    assert response.status_code == 401
    assert response.json() == {"detail": "unauthorized"}


async def test_ingress_route_rejects_operator_token() -> None:
    app = _app(_auth_settings())
    async for client in get_client(app):
        response = await client.post(
            "/v1/icinga2/events",
            json={},
            headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"},
        )
    assert response.status_code == 401
    assert response.json() == {"detail": "unauthorized"}


async def test_unauthorized_response_does_not_reveal_token_class() -> None:
    app = _app(_auth_settings())
    async for client in get_client(app):
        operator_response = await client.get(
            "/v1/plugins", headers={"Authorization": f"Bearer {INGRESS_TOKEN}"}
        )
        ingress_response = await client.post(
            "/v1/icinga2/events",
            json={},
            headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"},
        )
    assert operator_response.json() == ingress_response.json()
    assert "operator" not in operator_response.text.lower()
    assert "ingress" not in operator_response.text.lower()


async def test_auth_disabled_allows_unauthenticated_operator_access() -> None:
    app = _app(_auth_settings(api_auth_enabled=False))
    async for client in get_client(app):
        response = await client.get("/v1/plugins")
    assert response.status_code == 200


async def test_auth_disabled_allows_unauthenticated_ingress_access() -> None:
    app = _app(_auth_settings(api_auth_enabled=False))
    async for client in get_client(app):
        response = await client.post("/v1/icinga2/events", json={})
    assert response.status_code == 422


def test_token_matches_returns_false_on_malformed_bearer() -> None:
    credentials = HTTPAuthorizationCredentials(scheme="Bearer", credentials="é")
    assert _token_matches(credentials, "token") is False
