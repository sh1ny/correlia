from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path
from typing import Literal

import pytest
import yaml
from fastapi import FastAPI
from fastapi.security import HTTPAuthorizationCredentials
from httpx import ASGITransport, AsyncClient

from app.api.security import _token_matches
from app.config.settings import Settings
from app.main import create_app


VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"
OPERATOR_TOKEN = "operator-secret"
INGRESS_TOKEN = "ingress-secret"


class NoopLifecycleWorker:
    healthy = True

    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None


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
async def test_config_routes_preserve_safe_results_for_operator_or_nonproduction_bypass(
    environment: Literal["local", "test", "production"],
    api_auth_enabled: bool,
    tmp_path: Path,
) -> None:
    plugins_path = tmp_path / "plugins.yaml"
    plugins_path.write_text(
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
                            "password": "configuration-password-sentinel",
                            "start_tls": True,
                            "to_addresses": ["ops@example.test"],
                        },
                    }
                ]
            }
        )
    )
    rules_path = tmp_path / "rules.yaml"
    rules_path.write_text(
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
    topology_path = tmp_path / "topology.yaml"
    topology_path.write_text(
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
    app = create_app(
        settings=Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            environment=environment,
            api_auth_enabled=api_auth_enabled,
            operator_api_token=OPERATOR_TOKEN if api_auth_enabled else None,
            ingress_api_token=INGRESS_TOKEN if api_auth_enabled else None,
            audit_raw_payload_hmac_key="test-audit-hmac",
            expose_readyz=False,
            expose_metrics=False,
            plugins_path=plugins_path,
            rules_path=rules_path,
            topology_path=topology_path,
        ),
        sessionmaker=lambda: object(),
        lifecycle_worker=NoopLifecycleWorker(),
    )
    headers = (
        {"Authorization": f"Bearer {OPERATOR_TOKEN}"} if api_auth_enabled else {}
    )
    async for client in get_client(app):
        plugins = await client.get("/v1/plugins", headers=headers)
        rules = await client.get("/v1/rules", headers=headers)
        topology = await client.get("/v1/topology", headers=headers)

    assert plugins.status_code == 200
    assert plugins.json() == [
        {
            "name": "email-oncall",
            "plugin_type": "email",
            "status": "ready",
            "ready": True,
        }
    ]
    assert rules.status_code == 200
    assert set(rules.json()) == {"config_hash", "rules"}
    assert rules.json()["rules"] == [
        {
            "name": "web-critical",
            "priority": 10,
            "group_by": ["host", "service"],
            "actions": [{"name": "create_incident", "plugin": "email-oncall"}],
        }
    ]
    assert topology.status_code == 200
    assert set(topology.json()) == {"config_hash", "rules"}
    assert topology.json()["rules"] == [
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
    for response in (plugins, rules, topology):
        serialized = response.text.lower()
        for forbidden in (
            "configuration-password-sentinel",
            "password",
            "options",
            "class_path",
            "smtpoutputplugin",
            "ops@example.test",
            "host_pattern",
            "service_pattern",
            "critical {service}",
            "^web-",
            "192.0.2.0/24",
            OPERATOR_TOKEN,
            INGRESS_TOKEN,
        ):
            assert forbidden not in serialized


def test_token_matches_returns_false_on_malformed_bearer() -> None:
    credentials = HTTPAuthorizationCredentials(scheme="Bearer", credentials="é")
    assert _token_matches(credentials, "token") is False
