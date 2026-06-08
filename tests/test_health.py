from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient

from app.config.settings import Settings
from app.main import create_app


VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


class SuccessfulSession:
    def __init__(self) -> None:
        self.executed_sql: list[str] = []

    async def __aenter__(self) -> "SuccessfulSession":
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    async def execute(self, statement: object) -> None:
        self.executed_sql.append(statement.text)


class FailingSession:
    def __init__(self, failure: RuntimeError) -> None:
        self.failure = failure

    async def __aenter__(self) -> "FailingSession":
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    async def execute(self, statement: object) -> None:
        raise self.failure


async def sessionmaker_with(session: object) -> AsyncIterator[object]:
    yield session


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def test_health_returns_ok_without_database_readiness() -> None:
    failure = RuntimeError("DATABASE_URL postgresql://user:password@host/token-secret")
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: FailingSession(failure),
    )

    async for client in get_client(app):
        response = await client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_readyz_returns_ready_when_database_check_succeeds() -> None:
    session = SuccessfulSession()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: session,
    )

    async for client in get_client(app):
        response = await client.get("/readyz")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
    assert session.executed_sql == ["select 1"]


async def test_readyz_returns_non_secret_503_when_database_check_fails() -> None:
    failure = RuntimeError("DATABASE_URL postgresql://user:password@host/token-secret")
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: FailingSession(failure),
    )

    async for client in get_client(app):
        response = await client.get("/readyz")

    assert response.status_code == 503
    assert response.json() == {"detail": "not ready"}
    response_body = response.text.lower()
    for secret_fragment in ("database_url", "postgresql", "password", "token", "secret"):
        assert secret_fragment not in response_body


def test_phase_one_does_not_expose_out_of_scope_routes() -> None:
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: SuccessfulSession(),
    )

    route_paths = {route.path for route in app.routes}

    assert "/health" in route_paths
    assert "/readyz" in route_paths
    assert "/metrics" not in route_paths
    assert "/config" not in route_paths
    assert "/config-summary" not in route_paths
