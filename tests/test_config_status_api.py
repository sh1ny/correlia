from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest
import yaml
from httpx import ASGITransport, AsyncClient

from app.config.plugins import load_plugin_registry_config
from app.config.settings import Settings
from app.main import create_app
from app.plugins.loader import PluginRegistry

pytestmark = pytest.mark.anyio

VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


class NoopLifecycleWorker:
    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def _write_plugins(path: Path) -> PluginRegistry:
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


def _write_rules(path: Path) -> None:
    path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "web-critical",
                        "priority": 10,
                        "match": {
                            "severities": ["CRITICAL"],
                            "host_pattern": "web-.*",
                            "service_pattern": "http",
                            "tags": {"team.name": "platform"},
                        },
                        "window": {
                            "duration_seconds": 300,
                            "group_by": ["host", "service"],
                            "trigger_threshold": 2,
                        },
                        "output_summary": "Critical {service} on {host}",
                        "actions": [
                            {"name": "create_incident", "plugin": "email-oncall"}
                        ],
                    }
                ]
            }
        )
    )


def _write_topology(path: Path) -> None:
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-hosts",
                        "name": "Web Hosts",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web", "topology.site": "dc1"},
                    }
                ],
                "subnet_rules": [
                    {
                        "id": "dc1-subnet",
                        "name": "DC1 Subnet",
                        "subnet": "192.0.2.0/24",
                        "tags": {"topology.site": "dc1"},
                    }
                ],
            }
        )
    )


async def test_rules_summary_exposes_allowlisted_fields_and_hash(tmp_path: Path) -> None:
    plugins_path = tmp_path / "plugins.yaml"
    rules_path = tmp_path / "rules.yaml"
    topology_path = tmp_path / "topology.yaml"
    registry = _write_plugins(plugins_path)
    _write_rules(rules_path)
    _write_topology(topology_path)
    app = create_app(
        settings=Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            rules_path=rules_path,
            topology_path=topology_path,
            plugins_path=plugins_path,
        ),
        sessionmaker=lambda: object(),
        plugin_registry=registry,
        lifecycle_worker=NoopLifecycleWorker(),
    )

    async for client in get_client(app):
        response = await client.get("/v1/rules")

    assert response.status_code == 200
    body = response.json()
    assert body["config_hash"]
    assert body["rules"] == [
        {
            "name": "web-critical",
            "priority": 10,
            "group_by": ["host", "service"],
            "actions": [{"name": "create_incident", "plugin": "email-oncall"}],
        }
    ]
    serialized = response.text.lower()
    for forbidden in (
        "password",
        "secret",
        "token",
        "plugin_config",
        "critical {service}",
        "host_pattern",
        "service_pattern",
        "ops@example.test",
        "smtpoutputplugin",
    ):
        assert forbidden not in serialized


async def test_topology_summary_exposes_match_types_tag_keys_and_hash(tmp_path: Path) -> None:
    plugins_path = tmp_path / "plugins.yaml"
    rules_path = tmp_path / "rules.yaml"
    topology_path = tmp_path / "topology.yaml"
    registry = _write_plugins(plugins_path)
    _write_rules(rules_path)
    _write_topology(topology_path)
    app = create_app(
        settings=Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            rules_path=rules_path,
            topology_path=topology_path,
            plugins_path=plugins_path,
        ),
        sessionmaker=lambda: object(),
        plugin_registry=registry,
        lifecycle_worker=NoopLifecycleWorker(),
    )

    async for client in get_client(app):
        response = await client.get("/v1/topology")

    assert response.status_code == 200
    body = response.json()
    assert body["config_hash"]
    assert body["rules"] == [
        {
            "id": "web-hosts",
            "name": "Web Hosts",
            "match_type": "hostname",
            "tag_keys": ["topology.role", "topology.site"],
        },
        {
            "id": "dc1-subnet",
            "name": "DC1 Subnet",
            "match_type": "subnet",
            "tag_keys": ["topology.site"],
        },
    ]
    serialized = response.text.lower()
    for forbidden in (
        "password",
        "secret",
        "token",
        "plugin_config",
        "^web-",
        "192.0.2.0/24",
        "dc1\"",
        "ops@example.test",
    ):
        assert forbidden not in serialized
