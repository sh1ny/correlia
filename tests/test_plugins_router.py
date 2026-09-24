from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest
import yaml
from httpx import ASGITransport, AsyncClient

from app.config.plugins import load_plugin_registry_config
from app.plugins.loader import PluginRegistry

pytestmark = pytest.mark.anyio


@pytest.fixture(autouse=True)
def _disable_auth_for_plugins_tests(
    monkeypatch: pytest.MonkeyPatch, clean_settings_env: None
) -> None:
    monkeypatch.setenv("CORRELIA_API_AUTH_ENABLED", "false")
    monkeypatch.setenv("CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY", "test-audit-hmac")


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def _registry(tmp_path: Path) -> PluginRegistry:
    path = tmp_path / "plugins.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "outputs": [
                    {
                        "name": "email-oncall",
                        "plugin_type": "email",
                        "class_path": "app.plugins.outputs.email.SmtpOutputPlugin",
                        "options": {
                            "host": "localhost",
                            "port": 1025,
                            "username": "operator",
                            "password": "super-secret",
                            "start_tls": True,
                            "to_addresses": ["ops@example.test"],
                        },
                    }
                ]
            }
        )
    )
    config = load_plugin_registry_config(path)
    return PluginRegistry(config.outputs, config.config_hash)


async def test_v1_plugins_route_lists_safe_output_status_only(tmp_path: Path) -> None:
    from app.config.settings import Settings
    from app.main import create_app

    registry = _registry(tmp_path)
    app = create_app(
        settings=Settings(
            DATABASE_URL="postgresql+asyncpg://user:pass@localhost:5432/correlia"
        ),
        sessionmaker=lambda: object(),
        plugin_registry=registry,
    )

    async for client in get_client(app):
        response = await client.get("/v1/plugins")

    assert response.status_code == 200
    body = response.json()
    assert body == [
        {
            "name": "email-oncall",
            "plugin_type": "email",
            "status": "ready",
            "ready": True,
        }
    ]
    serialized = response.text.lower()
    assert "options" not in serialized
    assert "password" not in serialized
    assert "super-secret" not in serialized
    assert "ops@example.test" not in serialized
    assert "smtpoutputplugin" not in serialized
    assert "rendered" not in serialized


def test_v1_plugins_route_is_exposed_without_legacy_alias() -> None:
    from app.config.settings import Settings
    from app.main import create_app

    app = create_app(
        settings=Settings(
            DATABASE_URL="postgresql+asyncpg://user:pass@localhost:5432/correlia"
        ),
        sessionmaker=lambda: object(),
    )
    route_paths = {route.path for route in app.routes}
    assert "/v1/plugins" in route_paths
    assert "/plugins" not in route_paths
    assert "/api/v1/incidents" not in route_paths
