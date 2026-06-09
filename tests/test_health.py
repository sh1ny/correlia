from pathlib import Path
from collections.abc import AsyncIterator
import pytest

from httpx import ASGITransport, AsyncClient

from app.config.settings import Settings
from app.main import create_app
from app.config.rules import CompiledRuleConfig
from app.config.topology import CompiledTopologyConfig



VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"
PHASE_FOUR_TARGETED_VERIFICATION_COMMAND = (
    "uv run pytest tests/test_domain_incidents.py tests/test_settings.py "
    "tests/test_icinga2_input.py tests/test_ingress_router.py "
    "tests/test_topology_enrichment.py tests/test_rule_topology_yaml.py "
    "tests/test_rule_engine.py tests/test_notification_dispatch.py "
    "tests/test_incident_manager.py tests/test_lifecycle_repository.py "
    "tests/test_lifecycle_expiration.py tests/test_lifecycle_worker.py "
    "tests/test_incidents_api.py tests/test_config_status_api.py "
    "tests/test_metrics_api.py tests/test_structured_logging.py tests/test_health.py -x"
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
    def __init__(self, rows: tuple[dict[str, object], ...] = ()) -> None:
        self._rows = rows
        self.names = tuple(str(row["name"]) for row in rows)
        self.config_hash = "safe-config-hash"

    def list_plugins(self) -> tuple[dict[str, object], ...]:
        return self._rows


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
        settings=settings or Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: sessionmaker(),
        plugin_registry=plugin_registry or PluginRegistryStatus(),
        icinga2_processor=object(),
        lifecycle_worker=lifecycle_worker or HealthyLifecycleWorker(),
    )


async def test_health_returns_ok_without_database_readiness() -> None:
    failure = RuntimeError("DATABASE_URL postgresql://user:password@host/token-secret")
    app = _app(sessionmaker=lambda: FailingSession(failure))

    async for client in get_client(app):
        response = await client.get("/v1/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_readyz_returns_ready_when_database_check_succeeds() -> None:
    session = SuccessfulSession()
    app = _app(sessionmaker=lambda: session)

    async for client in get_client(app):
        response = await client.get("/v1/readyz")

    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["checks"]["database"] == "ready"
    assert session.executed_sql == ["select 1"]


async def test_readyz_returns_non_secret_503_when_database_check_fails() -> None:
    failure = RuntimeError("DATABASE_URL postgresql://user:password@host/token-secret")
    app = _app(sessionmaker=lambda: FailingSession(failure))

    async for client in get_client(app):
        response = await client.get("/v1/readyz")

    assert response.status_code == 503
    assert response.json()["detail"] == "not ready"
    response_body = response.text.lower()
    for secret_fragment in ("database_url", "postgresql", "password", "token", "secret"):
        assert secret_fragment not in response_body


def test_v1_health_and_readyz_routes_replace_legacy_paths() -> None:
    app = _app()

    route_paths = {route.path for route in app.routes}

    assert "/v1/health" in route_paths
    assert "/v1/readyz" in route_paths
    assert "/health" not in route_paths
    assert "/readyz" not in route_paths
    assert "/metrics" not in route_paths
    assert "/config" not in route_paths
    assert "/config-summary" not in route_paths



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
    settings = Settings(DATABASE_URL=VALID_DATABASE_URL)
    sessionmaker = SuccessfulSession
    plugin_registry: PluginRegistryStatus | None = PluginRegistryStatus()
    if case == "database":
        failure = RuntimeError("DATABASE_URL postgresql://user:password@host/token-secret")

        def sessionmaker() -> FailingSession:
            return FailingSession(failure)
    elif case == "rules":
        settings = Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            rules_path=tmp_path / "rules-password-token-secret.yaml",
        )
    elif case == "topology":
        settings = Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            topology_path=tmp_path / "topology-password-token-secret.yaml",
        )
    elif case == "plugin_registry":
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

    app = _app(settings=settings, sessionmaker=sessionmaker, plugin_registry=plugin_registry)
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
        response = await client.get("/v1/readyz")

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
            response = await client.get("/v1/readyz")
        assert response.status_code == 503
        assert response.json()["checks"]["lifecycle_worker"] == "not_ready"

    app = _app(lifecycle_worker=HealthyLifecycleWorker())
    async for client in get_client(app):
        response = await client.get("/v1/readyz")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["checks"]["lifecycle_worker"] == "ready"


def test_phase_four_targeted_verification_commands_are_documented() -> None:
    command = PHASE_FOUR_TARGETED_VERIFICATION_COMMAND

    assert command == (
        "uv run pytest tests/test_domain_incidents.py tests/test_settings.py "
        "tests/test_icinga2_input.py tests/test_ingress_router.py "
        "tests/test_topology_enrichment.py tests/test_rule_topology_yaml.py "
        "tests/test_rule_engine.py tests/test_notification_dispatch.py "
        "tests/test_incident_manager.py tests/test_lifecycle_repository.py "
        "tests/test_lifecycle_expiration.py tests/test_lifecycle_worker.py "
        "tests/test_incidents_api.py tests/test_config_status_api.py "
        "tests/test_metrics_api.py tests/test_structured_logging.py tests/test_health.py -x"
    )
    assert "sqlite" not in command.lower()


def test_readyz_source_keeps_failure_details_safe() -> None:
    source = Path("app/api/routers/health.py").read_text().lower()

    assert "database_url" not in source
    assert "str(exc)" not in source
    assert "repr(exc)" not in source
    assert "exc.args" not in source