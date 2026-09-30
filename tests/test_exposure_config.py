from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Literal

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from pydantic import SecretStr
from starlette.routing import Route

from app.api import deps
from app.api.routers import metrics as metrics_router
from app.config.settings import Settings
from app.main import create_app


VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"
OPERATOR_TOKEN = "operator-secret"
INGRESS_TOKEN = "ingress-secret"
AUDIT_HMAC_KEY = "test-audit-hmac"
DOCS_PATHS = ("/docs", "/redoc", "/openapi.json", "/docs/oauth2-redirect")
EXPECTED_DOCUMENTATION_POLICY = tuple(
    (method, path, "public") for path in DOCS_PATHS for method in ("GET", "HEAD")
)
INCIDENT_ID = "b64dccf2-9a4b-4fd4-baf5-91ce12d12340"
VALID_INGRESS_BODY = {
    "source_id": "icinga2:service:web-01:http",
    "host": "web-01",
    "service": "http",
    "state": "CRITICAL",
    "state_type": "HARD",
    "timestamp": "2026-09-30T12:00:00Z",
    "check_output": "HTTP is unavailable",
    "ip_address": "192.0.2.10",
    "tags": {"team.name": "platform"},
}

# Product policy, not a projection of dependencies or OpenAPI. Operational flags
# may make readiness/metrics public only in nonproduction; other roles stay fixed.
EXPECTED_API_POLICY = (
    ("GET", "/v1/health", "public", None),
    ("GET", "/v1/readyz", "operator", None),
    ("GET", "/v1/metrics", "operator", None),
    ("POST", "/v1/icinga2/events", "ingress", VALID_INGRESS_BODY),
    ("GET", "/v1/plugins", "operator", None),
    ("GET", "/v1/rules", "operator", None),
    ("GET", "/v1/topology", "operator", None),
    ("GET", "/v1/incidents", "operator", None),
    ("GET", "/v1/incidents/{incident_id}", "operator", None),
    (
        "POST",
        "/v1/incidents/{incident_id}/ack",
        "operator",
        {"operator": "policy-operator"},
    ),
    (
        "POST",
        "/v1/incidents/{incident_id}/close",
        "operator",
        {"operator": "policy-operator", "reason": "handled manually"},
    ),
    (
        "PATCH",
        "/v1/incidents/{incident_id}",
        "operator",
        {"status": "ACKNOWLEDGED"},
    ),
    ("DELETE", "/v1/incidents/{incident_id}", "operator", None),
    ("GET", "/v1/incident-events", "operator", None),
)


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


def _settings(
    expose_readyz: bool = True,
    expose_metrics: bool = True,
    *,
    environment: Literal["local", "test", "production"] = "local",
    api_auth_enabled: bool = True,
) -> Settings:
    return Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        environment=environment,
        api_auth_enabled=api_auth_enabled,
        operator_api_token=OPERATOR_TOKEN,
        ingress_api_token=INGRESS_TOKEN,
        expose_readyz=expose_readyz,
        expose_metrics=expose_metrics,
        audit_raw_payload_hmac_key=AUDIT_HMAC_KEY,
    )


def _app(settings: Settings | None = None) -> FastAPI:
    return create_app(
        settings=settings,
        sessionmaker=lambda: SuccessfulSession(),
        lifecycle_worker=NoopLifecycleWorker(),
    )


async def get_client(app: FastAPI) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


@pytest.mark.parametrize(
    ("environment", "api_auth_enabled"),
    (
        ("local", False),
        ("local", True),
        ("test", False),
        ("test", True),
        ("production", True),
    ),
)
def test_http_route_inventory_matches_independent_policy(
    environment: Literal["local", "test", "production"],
    api_auth_enabled: bool,
) -> None:
    app = _app(
        _settings(
            environment=environment,
            api_auth_enabled=api_auth_enabled,
            expose_readyz=False,
            expose_metrics=False,
        )
    )
    expected = {(method, path) for method, path, _, _ in EXPECTED_API_POLICY}
    if environment != "production":
        expected.update(
            (method, path) for method, path, _ in EXPECTED_DOCUMENTATION_POLICY
        )
    # APIRoute is a Route subclass; FastAPI's built-in documentation routes are
    # ordinary Routes and must not disappear from the completeness check.
    registered = {
        (method, route.path)
        for route in app.routes
        if isinstance(route, Route)
        for method in route.methods or ()
    }
    assert registered == expected


@pytest.mark.parametrize("environment", ("local", "test", "production"))
@pytest.mark.parametrize("credential", ("missing", "invalid", "wrong_role"))
@pytest.mark.parametrize(
    ("method", "path", "role", "body"),
    [row for row in EXPECTED_API_POLICY if row[2] != "public"],
    ids=[
        f"{method} {path}"
        for method, path, role, _ in EXPECTED_API_POLICY
        if role != "public"
    ],
)
async def test_protected_route_matrix_denies_before_handler_work(
    environment: Literal["local", "test", "production"],
    credential: str,
    method: str,
    path: str,
    role: str,
    body: dict[str, object] | None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Every supported request has valid identifiers/body and a fresh quota.
    app = _app(
        _settings(environment=environment, expose_readyz=False, expose_metrics=False)
    )
    protected_work: list[str] = []

    def unexpected_work() -> None:
        protected_work.append("protected collaborator")
        raise AssertionError("denied request reached protected handler work")

    for dependency in (
        deps.get_sessionmaker,
        deps.get_icinga2_processor,
        deps.get_plugin_registry,
        deps.get_rules_config,
        deps.get_topology_config,
    ):
        app.dependency_overrides[dependency] = unexpected_work
    monkeypatch.setattr(metrics_router, "render_metrics", unexpected_work)

    token = {
        "missing": None,
        "invalid": "invalid-policy-token",
        "wrong_role": INGRESS_TOKEN if role == "operator" else OPERATOR_TOKEN,
    }[credential]
    headers = {} if token is None else {"Authorization": f"Bearer {token}"}
    async for client in get_client(app):
        response = await client.request(
            method,
            path.format(incident_id=INCIDENT_ID),
            headers=headers,
            json=body,
            follow_redirects=False,
        )
    assert response.status_code == 401
    assert response.json() == {"detail": "unauthorized"}
    assert response.headers.get("WWW-Authenticate") == "Bearer"
    assert protected_work == []


@pytest.mark.parametrize("environment", ("local", "test", "production"))
async def test_health_is_public_when_auth_enabled(
    environment: Literal["local", "test", "production"],
) -> None:
    app = _app(
        _settings(environment=environment, expose_readyz=False, expose_metrics=False)
    )
    async for client in get_client(app):
        response = await client.get("/v1/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.parametrize("environment", ("local", "test"))
@pytest.mark.parametrize("api_auth_enabled", (False, True))
@pytest.mark.parametrize("expose_readyz", (False, True))
@pytest.mark.parametrize("expose_metrics", (False, True))
async def test_nonproduction_exposure_flags_are_independent(
    environment: Literal["local", "test"],
    api_auth_enabled: bool,
    expose_readyz: bool,
    expose_metrics: bool,
) -> None:
    app = _app(
        _settings(
            environment=environment,
            api_auth_enabled=api_auth_enabled,
            expose_readyz=expose_readyz,
            expose_metrics=expose_metrics,
        )
    )
    async for client in get_client(app):
        health = await client.get("/v1/health")
        assert health.status_code == 200
        assert health.json() == {"status": "ok"}
        for path, exposed in (
            ("/v1/readyz", expose_readyz),
            ("/v1/metrics", expose_metrics),
        ):
            public_response = await client.get(path)
            ingress_response = await client.get(
                path, headers={"Authorization": f"Bearer {INGRESS_TOKEN}"}
            )
            operator_response = await client.get(
                path, headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
            )
            public_status = 200 if exposed or not api_auth_enabled else 401
            assert public_response.status_code == public_status
            assert ingress_response.status_code == public_status
            assert operator_response.status_code == 200
            if path == "/v1/readyz":
                assert operator_response.json()["status"] == "ready"
            else:
                assert operator_response.headers["content-type"].startswith(
                    "text/plain"
                )


@pytest.mark.parametrize("path", DOCS_PATHS)
@pytest.mark.parametrize("suffix", ("", "/"))
@pytest.mark.parametrize("method", ("GET", "HEAD"))
@pytest.mark.parametrize("token", (None, OPERATOR_TOKEN, INGRESS_TOKEN))
async def test_production_documentation_routes_are_absent(
    path: str,
    suffix: str,
    method: str,
    token: str | None,
) -> None:
    # A new app gives every method/path/credential case independent rate-limit quota.
    app = _app(
        _settings(environment="production", expose_readyz=False, expose_metrics=False)
    )
    headers = {} if token is None else {"Authorization": f"Bearer {token}"}
    async for client in get_client(app):
        response = await client.request(
            method, path + suffix, headers=headers, follow_redirects=False
        )
    assert response.status_code == 404
    assert "location" not in response.headers
    if method == "GET":
        assert response.json() == {"detail": "Not Found"}
    else:
        assert response.content == b""


@pytest.mark.parametrize("environment", ("local", "test"))
@pytest.mark.parametrize("api_auth_enabled", (False, True))
@pytest.mark.parametrize("path", DOCS_PATHS)
@pytest.mark.parametrize("method", ("GET", "HEAD"))
async def test_nonproduction_documentation_remains_public(
    environment: Literal["local", "test"],
    api_auth_enabled: bool,
    path: str,
    method: str,
) -> None:
    app = _app(_settings(environment=environment, api_auth_enabled=api_auth_enabled))
    async for client in get_client(app):
        response = await client.request(method, path, follow_redirects=False)
    assert response.status_code == 200
    assert "location" not in response.headers
    expected_type = "application/json" if path == "/openapi.json" else "text/html"
    assert response.headers["content-type"].startswith(expected_type)
    if method == "HEAD":
        assert response.content == b""
    elif path == "/openapi.json":
        assert "/v1/health" in response.json()["paths"]
    elif path in ("/docs", "/redoc"):
        assert "/openapi.json" in response.text


def _set_environment(
    monkeypatch: pytest.MonkeyPatch,
    *,
    environment: Literal["local", "test", "production"],
    api_auth_enabled: bool,
    expose_readyz: bool,
    expose_metrics: bool,
    operator_token: str,
    ingress_token: str,
) -> None:
    for key, value in {
        "DATABASE_URL": VALID_DATABASE_URL,
        "CORRELIA_ENVIRONMENT": environment,
        "CORRELIA_API_AUTH_ENABLED": str(api_auth_enabled).lower(),
        "CORRELIA_EXPOSE_READYZ": str(expose_readyz).lower(),
        "CORRELIA_EXPOSE_METRICS": str(expose_metrics).lower(),
        "CORRELIA_OPERATOR_API_TOKEN": operator_token,
        "CORRELIA_INGRESS_API_TOKEN": ingress_token,
        "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY": AUDIT_HMAC_KEY,
    }.items():
        monkeypatch.setenv(key, value)


async def test_injected_production_settings_override_local_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _set_environment(
        monkeypatch,
        environment="local",
        api_auth_enabled=False,
        expose_readyz=True,
        expose_metrics=True,
        operator_token="environment-operator",
        ingress_token="environment-ingress",
    )
    app = _app(
        _settings(environment="production", expose_readyz=False, expose_metrics=False)
    )
    async for client in get_client(app):
        for path in DOCS_PATHS:
            response = await client.get(path, follow_redirects=False)
            assert response.status_code == 404
            assert "location" not in response.headers
        for path in ("/v1/readyz", "/v1/metrics"):
            anonymous = await client.get(path)
            environment_token = await client.get(
                path, headers={"Authorization": "Bearer environment-operator"}
            )
            operator = await client.get(
                path, headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
            )
            assert anonymous.status_code == 401
            assert environment_token.status_code == 401
            assert operator.status_code == 200


async def test_injected_local_settings_override_production_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _set_environment(
        monkeypatch,
        environment="production",
        api_auth_enabled=True,
        expose_readyz=False,
        expose_metrics=False,
        operator_token="environment-operator",
        ingress_token="environment-ingress",
    )
    app = _app(_settings(environment="local", api_auth_enabled=False))
    async for client in get_client(app):
        for path in DOCS_PATHS + ("/v1/readyz", "/v1/metrics"):
            response = await client.get(path, follow_redirects=False)
            assert response.status_code == 200
            assert "location" not in response.headers


async def test_uninjected_settings_survive_environment_changes_before_lifespan(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _set_environment(
        monkeypatch,
        environment="production",
        api_auth_enabled=True,
        expose_readyz=False,
        expose_metrics=False,
        operator_token=OPERATOR_TOKEN,
        ingress_token=INGRESS_TOKEN,
    )
    app = _app()
    _set_environment(
        monkeypatch,
        environment="local",
        api_auth_enabled=False,
        expose_readyz=True,
        expose_metrics=True,
        operator_token="changed-operator",
        ingress_token="changed-ingress",
    )

    async for client in get_client(app):
        health = await client.get("/v1/health")
        assert health.status_code == 200
        assert health.json() == {"status": "ok"}
        for path in DOCS_PATHS:
            response = await client.get(path, follow_redirects=False)
            assert response.status_code == 404
            assert "location" not in response.headers
        for path in ("/v1/readyz", "/v1/metrics"):
            for token in (None, "changed-operator", INGRESS_TOKEN):
                headers = {} if token is None else {"Authorization": f"Bearer {token}"}
                denied = await client.get(path, headers=headers)
                assert denied.status_code == 401
            operator = await client.get(
                path, headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
            )
            assert operator.status_code == 200

        # A valid SOFT event exercises the real input processor without a DB write.
        payload = {
            "source_id": "icinga2",
            "host": "production-host",
            "service": "load",
            "state": "WARNING",
            "state_type": "SOFT",
            "timestamp": "2026-09-30T12:00:00Z",
            "check_output": "Transient load warning",
        }
        for token in (None, "changed-ingress", OPERATOR_TOKEN):
            headers = {} if token is None else {"Authorization": f"Bearer {token}"}
            denied = await client.post(
                "/v1/icinga2/events", json=payload, headers=headers
            )
            assert denied.status_code == 401
        ingress = await client.post(
            "/v1/icinga2/events",
            json=payload,
            headers={"Authorization": f"Bearer {INGRESS_TOKEN}"},
        )
        assert ingress.status_code == 200
        assert ingress.json()["state_accepted"] is False
        assert ingress.json()["rejection"]["state_type"] == "SOFT"


@pytest.mark.parametrize(
    ("field", "unsafe_value"),
    (
        ("api_auth_enabled", False),
        ("expose_readyz", True),
        ("expose_metrics", True),
        ("operator_api_token", None),
        ("ingress_api_token", None),
        ("operator_api_token", SecretStr("")),
        ("ingress_api_token", SecretStr("")),
        ("operator_api_token", SecretStr(" \t\n")),
        ("ingress_api_token", SecretStr(" \t\n")),
        ("operator_api_token", SecretStr(INGRESS_TOKEN)),
        ("ingress_api_token", SecretStr(OPERATOR_TOKEN)),
        ("audit_raw_payload_hmac_key", SecretStr("")),
        ("audit_raw_payload_hmac_key", SecretStr(" \t\n")),
        ("audit_raw_payload_hmac_key", SecretStr(OPERATOR_TOKEN)),
        ("audit_raw_payload_hmac_key", SecretStr(INGRESS_TOKEN)),
    ),
)
def test_factory_rejects_unsafe_mutated_production_settings(
    field: str, unsafe_value: bool | SecretStr | None
) -> None:
    settings = _settings(
        environment="production", expose_readyz=False, expose_metrics=False
    )
    setattr(settings, field, unsafe_value)
    with pytest.raises(ValueError, match=field):
        _app(settings)


@pytest.mark.parametrize("environment", ("local", "test"))
@pytest.mark.parametrize(
    "unsafe_value",
    (
        SecretStr(""),
        SecretStr(" \t\n"),
        SecretStr(OPERATOR_TOKEN),
        SecretStr(INGRESS_TOKEN),
    ),
)
def test_factory_checks_audit_key_even_when_nonproduction_auth_is_disabled(
    environment: Literal["local", "test"], unsafe_value: SecretStr
) -> None:
    settings = _settings(environment=environment, api_auth_enabled=False)
    settings.audit_raw_payload_hmac_key = unsafe_value
    with pytest.raises(ValueError, match="audit_raw_payload_hmac_key"):
        _app(settings)
