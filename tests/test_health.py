import logging

from pathlib import Path
from collections.abc import AsyncIterator
import pytest

from httpx import ASGITransport, AsyncClient

from app.config.settings import Settings
from app.main import create_app
from app.api.routers.health import _plugin_category_checks
from app.processing.metrics import OUTPUT_PLUGIN_CATEGORIES
from app.config.rules import CompiledRuleConfig
from app.config.topology import CompiledTopologyConfig


VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"
OPERATOR_TOKEN = "operator-token"
INGRESS_TOKEN = "ingress-token"


def _production_settings(
    *,
    rules_path: Path | None = None,
    topology_path: Path | None = None,
) -> Settings:
    return Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        environment="production",
        api_auth_enabled=True,
        expose_readyz=False,
        expose_metrics=False,
        operator_api_token=OPERATOR_TOKEN,
        ingress_api_token=INGRESS_TOKEN,
        audit_raw_payload_hmac_key="test-audit-hmac",
        rules_path=rules_path,
        topology_path=topology_path,
    )


class HealthyLifecycleWorker:
    healthy = True

    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None


class UnhealthyLifecycleWorker:
    healthy = False
    last_error_category = "RuntimeError"

    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None


class WorkerWithoutHealth:
    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None


class PluginRegistryStatus:
    def __init__(
        self,
        rows: tuple[dict[str, object], ...] = (),
        status_error: Exception | None = None,
    ) -> None:
        self._rows = rows
        self._status_error = status_error
        self.readiness_calls = 0
        self.names = tuple(str(row["name"]) for row in rows)
        self.config_hash = "safe-config-hash"

    def list_plugins(self) -> tuple[dict[str, object], ...]:
        return self._rows

    def readiness_states(self) -> dict[str, str]:
        self.readiness_calls += 1
        if self._status_error is not None:
            raise self._status_error
        ready = [row.get("ready") is True for row in self._rows]
        return {
            "email": "ready"
            if ready and all(ready)
            else "not_configured"
            if not ready
            else "not_ready"
        }


class NonDictPluginRegistryStatus:
    def readiness_states(self) -> list[str]:
        return ["ready"]


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
        self.executed_sql: list[str] = []

    async def __aenter__(self) -> "FailingSession":
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    async def execute(self, statement: object) -> None:
        self.executed_sql.append(statement.text)
        raise self.failure


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def _app(
    *,
    settings: Settings | None = None,
    sessionmaker=SuccessfulSession,
    plugin_registry: PluginRegistryStatus | None = None,
    lifecycle_worker: object | None = None,
):
    return create_app(
        settings=settings or _production_settings(),
        sessionmaker=lambda: sessionmaker(),
        plugin_registry=plugin_registry or PluginRegistryStatus(),
        icinga2_processor=object(),
        lifecycle_worker=lifecycle_worker or HealthyLifecycleWorker(),
    )


async def _assert_readyz_denials_skip_probes(
    client: AsyncClient,
    session: SuccessfulSession | FailingSession,
    registry: PluginRegistryStatus,
) -> None:
    for token in (None, "invalid-readiness-token", INGRESS_TOKEN):
        headers = {} if token is None else {"Authorization": f"Bearer {token}"}
        denied = await client.get("/v1/readyz", headers=headers)
        assert denied.status_code == 401
        assert denied.json() == {"detail": "unauthorized"}
        assert denied.headers.get("WWW-Authenticate") == "Bearer"
    assert session.executed_sql == []
    assert registry.readiness_calls == 0


async def test_health_returns_ok_without_database_readiness() -> None:
    failure = RuntimeError("DATABASE_URL postgresql://user:password@host/token-secret")
    session = FailingSession(failure)
    registry = PluginRegistryStatus()
    app = _app(sessionmaker=lambda: session, plugin_registry=registry)

    async for client in get_client(app):
        before = await client.get("/v1/health")
        assert before.status_code == 200
        assert before.json() == {"status": "ok"}
        assert session.executed_sql == []
        assert registry.readiness_calls == 0

        not_ready = await client.get(
            "/v1/readyz", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
        assert not_ready.status_code == 503
        assert not_ready.json()["checks"]["database"] == "not_ready"
        assert session.executed_sql == ["select 1"]
        assert registry.readiness_calls == 1

        after = await client.get("/v1/health")
        assert after.status_code == 200
        assert after.json() == {"status": "ok"}
        assert session.executed_sql == ["select 1"]
        assert registry.readiness_calls == 1


async def test_readyz_returns_ready_when_database_check_succeeds() -> None:
    session = SuccessfulSession()
    registry = PluginRegistryStatus()
    app = _app(sessionmaker=lambda: session, plugin_registry=registry)

    async for client in get_client(app):
        await _assert_readyz_denials_skip_probes(client, session, registry)
        response = await client.get(
            "/v1/readyz", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )

    assert response.status_code == 200
    assert response.json() == {
        "status": "ready",
        "checks": {
            "database": "ready",
            "settings": "ready",
            "rules_config": "ready",
            "topology_config": "ready",
            "plugin_registry": "ready",
            "plugins": "ready",
            "lifecycle_worker": "ready",
            "email": "not_configured",
        },
    }
    assert session.executed_sql == ["select 1"]
    assert registry.readiness_calls == 1
    from app.processing.metrics import render_metrics

    metrics = render_metrics().decode()
    for state in ("ready", "not_ready", "not_configured"):
        expected = 1.0 if state == "not_configured" else 0.0
        assert (
            f'correlia_output_plugin_readiness{{category="email",state="{state}"}} {expected}'
            in metrics
        )


async def test_readyz_returns_non_secret_503_when_database_check_fails() -> None:
    failure = RuntimeError("DATABASE_URL postgresql://user:password@host/token-secret")
    session = FailingSession(failure)
    registry = PluginRegistryStatus()
    app = _app(sessionmaker=lambda: session, plugin_registry=registry)

    async for client in get_client(app):
        await _assert_readyz_denials_skip_probes(client, session, registry)
        response = await client.get(
            "/v1/readyz", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )

    assert response.status_code == 503
    assert response.json()["detail"] == "not ready"
    assert response.json()["checks"]["database"] == "not_ready"
    assert session.executed_sql == ["select 1"]
    assert registry.readiness_calls == 1
    response_body = response.text.lower()
    for secret_fragment in (
        "database_url",
        "postgresql",
        "password",
        "token",
        "secret",
    ):
        assert secret_fragment not in response_body


@pytest.mark.parametrize(
    ("case", "expected_check"),
    (
        ("database", "database"),
        ("rules", "rules_config"),
        ("topology", "topology_config"),
        ("plugin_registry", "plugin_registry"),
        ("plugin_not_ready", "plugins"),
    ),
)
async def test_readyz_reports_dependency_failures_without_secrets(
    case: str,
    expected_check: str,
    tmp_path: Path,
) -> None:
    settings = _production_settings()
    sessionmaker = SuccessfulSession
    plugin_registry: PluginRegistryStatus | None = PluginRegistryStatus()
    if case == "database":
        failure = RuntimeError(
            "DATABASE_URL postgresql://user:password@host/token-secret"
        )

        def sessionmaker() -> FailingSession:
            return FailingSession(failure)
    elif case == "rules":
        settings = _production_settings(
            rules_path=tmp_path / "rules-password-token-secret.yaml"
        )
    elif case == "topology":
        settings = _production_settings(
            topology_path=tmp_path / "topology-password-token-secret.yaml"
        )
        plugin_registry = None
    elif case == "plugin_not_ready":
        plugin_registry = PluginRegistryStatus(
            (
                {
                    "name": "email-oncall",
                    "plugin_type": "email",
                    "status": "not_ready",
                    "ready": False,
                    "options": {"password": "token-secret"},
                },
            )
        )

    app = _app(
        settings=settings, sessionmaker=sessionmaker, plugin_registry=plugin_registry
    )
    if case == "rules":
        app.state.rules_config = None
    else:
        app.state.rules_config = CompiledRuleConfig((), "safe-rules-hash")
    if case == "topology":
        app.state.topology_config = None
    else:
        app.state.topology_config = CompiledTopologyConfig((), ())
    if case == "plugin_registry":
        app.state.plugin_registry = None

    async for client in get_client(app):
        response = await client.get(
            "/v1/readyz", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )

    assert response.status_code == 503
    payload = response.json()
    assert payload["detail"] == "not ready"
    assert payload["checks"][expected_check] == "not_ready"
    response_body = response.text.lower()
    for secret_fragment in (
        "database_url",
        "postgresql",
        "password",
        "token",
        "secret",
        "options",
        "traceback",
    ):
        assert secret_fragment not in response_body


async def test_readyz_requires_lifecycle_worker_health() -> None:
    for worker in (WorkerWithoutHealth(), UnhealthyLifecycleWorker()):
        app = _app(lifecycle_worker=worker)
        async for client in get_client(app):
            response = await client.get(
                "/v1/readyz", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
            )
        assert response.status_code == 503
        assert response.json()["checks"]["lifecycle_worker"] == "not_ready"

    app = _app(lifecycle_worker=HealthyLifecycleWorker())
    async for client in get_client(app):
        response = await client.get(
            "/v1/readyz", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )
    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["checks"]["lifecycle_worker"] == "ready"


async def test_readyz_aggregates_plugin_categories_without_plugin_details() -> None:
    app = _app(
        plugin_registry=PluginRegistryStatus(
            (
                {
                    "name": "ready-email-secret",
                    "plugin_type": "email",
                    "status": "ready",
                    "ready": True,
                },
                {
                    "name": "failed-email-secret",
                    "plugin_type": "email",
                    "status": "password=token-secret",
                    "ready": False,
                    "options": {"password": "token-secret"},
                },
            )
        )
    )

    async for client in get_client(app):
        response = await client.get(
            "/v1/readyz", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )

    assert response.status_code == 503
    payload = response.json()
    assert payload["checks"]["email"] == "not_ready"
    assert payload["checks"]["plugins"] == "not_ready"
    assert set(payload["checks"]) == {
        "database",
        "settings",
        "rules_config",
        "topology_config",
        "plugin_registry",
        "plugins",
        "lifecycle_worker",
        "email",
    }
    serialized = response.text.lower()
    for forbidden in (
        "ready-email-secret",
        "failed-email-secret",
        "password",
        "token",
        "options",
    ):
        assert forbidden not in serialized


def test_plugin_category_checks_fail_closed_for_non_dict_result() -> None:
    assert _plugin_category_checks(NonDictPluginRegistryStatus()) == {
        category: "not_ready" for category in OUTPUT_PLUGIN_CATEGORIES
    }


async def test_readyz_fails_closed_when_plugin_status_evaluation_raises(
    caplog: pytest.LogCaptureFixture,
) -> None:
    app = _app(
        plugin_registry=PluginRegistryStatus(
            status_error=RuntimeError("smtp://user:password@secret-host/token-secret")
        )
    )
    caplog.set_level(logging.INFO, logger="app.api.routers.health")

    async for client in get_client(app):
        response = await client.get(
            "/v1/readyz", headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        )

    assert response.status_code == 503
    assert response.json()["checks"]["email"] == "not_ready"
    assert "smtp" not in response.text.lower()
    events = [
        record.__dict__
        for record in caplog.records
        if record.__dict__.get("event") == "readiness"
    ]
    assert [(event["category"], event["state"]) for event in events] == [
        ("plugins", "not_ready"),
        ("email", "not_ready"),
    ]
    assert "smtp" not in repr(events).lower()


async def test_readyz_logs_only_meaningful_state_transitions(
    caplog: pytest.LogCaptureFixture,
) -> None:
    worker = HealthyLifecycleWorker()
    app = _app(lifecycle_worker=worker)
    caplog.set_level(logging.INFO, logger="app.api.routers.health")

    async for client in get_client(app):
        headers = {"Authorization": f"Bearer {OPERATOR_TOKEN}"}
        first = await client.get("/v1/readyz", headers=headers)
        second = await client.get("/v1/readyz", headers=headers)
        worker.healthy = False
        third = await client.get("/v1/readyz", headers=headers)

    assert [response.status_code for response in (first, second, third)] == [
        200,
        200,
        503,
    ]
    events = [
        (record.__dict__["category"], record.__dict__["state"])
        for record in caplog.records
        if record.__dict__.get("event") == "readiness"
    ]
    assert events == [("aggregate", "ready"), ("lifecycle_worker", "not_ready")]
