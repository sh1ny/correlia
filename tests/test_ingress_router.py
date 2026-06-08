from collections.abc import AsyncIterator
from pathlib import Path

import yaml

import pytest
from httpx import ASGITransport, AsyncClient

from app.config.settings import Settings
from app.domain.events import EventType, Severity
from app.main import create_app

VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


# These will fail until Task 2 creates the modules
from app.processing.ingress import (
    Icinga2DecisionProcessor,
    IngressDecisionEnvelope,
    build_icinga2_processor,
)


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def valid_icinga2_service_payload() -> dict[str, object]:
    return {
        "source_id": "icinga2:service:web-01:http",
        "host": "web-01",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "HTTP 503",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform"},
    }


def valid_icinga2_host_payload() -> dict[str, object]:
    return {
        "source_id": "icinga2:host:web-01",
        "host": "web-01",
        "service": None,
        "state": "DOWN",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "Host is unreachable",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform"},
    }


# ING-01: POST /webhooks/icinga2 exists and returns 200


async def test_post_webhook_icinga2_returns_200_for_hard_service() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    assert response.status_code == 200


async def test_post_webhook_icinga2_returns_200_for_hard_host() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_host_payload(),
        )
    assert response.status_code == 200


# D-06 / ING-05: decision envelope shape


async def test_response_contains_state_accepted_true_for_hard_event() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["state_accepted"] is True


async def test_response_contains_event_id_equal_to_fingerprint() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["event_id"] == body["fingerprint"]
    assert len(body["fingerprint"]) == 32


async def test_response_contains_mapped_event_type_and_severity() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["event_type"] == "PROBLEM"
    assert body["severity"] == "CRITICAL"


async def test_response_contains_mapped_recovery_event_type_and_severity() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_host_payload(),
        )
    body = response.json()
    assert body["event_type"] == "PROBLEM"
    assert body["severity"] == "CRITICAL"


async def test_response_contains_final_tags() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert "final_tags" in body
    assert body["final_tags"]["team.name"] == "platform"


async def test_response_contains_empty_matched_rules() -> None:
    """D-16: no-match events return matched_rules == [] before rule engine exists."""
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["matched_rules"] == []


async def test_response_contains_none_group_key() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["group_key"] is None


async def test_response_contains_zero_incident_effects() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["incident_effects"]["inserted"] == 0
    assert body["incident_effects"]["updated"] == 0
    assert body["closure_count"] == 0
    assert body["notification_count"] == 0


# D-01: SOFT states return non-actionable diagnostics


async def test_soft_state_returns_state_accepted_false() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = valid_icinga2_service_payload()
    payload["state_type"] = "SOFT"
    async for client in get_client(app):
        response = await client.post("/webhooks/icinga2", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["state_accepted"] is False
    assert body["rejection"]["state_type"] == "SOFT"


# ING-02: malformed payloads fail validation with 422


async def test_extra_field_rejected_with_422() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = valid_icinga2_service_payload()
    payload["extra"] = "surprise"
    async for client in get_client(app):
        response = await client.post("/webhooks/icinga2", json=payload)
    assert response.status_code == 422


async def test_host_with_service_state_rejected_with_422() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = valid_icinga2_host_payload()
    payload["state"] = "OK"
    async for client in get_client(app):
        response = await client.post("/webhooks/icinga2", json=payload)
    assert response.status_code == 422


async def test_naive_timestamp_rejected_with_422() -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = valid_icinga2_service_payload()
    payload["timestamp"] = "2026-06-08T12:00:00"
    async for client in get_client(app):
        response = await client.post("/webhooks/icinga2", json=payload)
    assert response.status_code == 422


# T-02-01-I: response body must not contain secrets or raw payload


@pytest.mark.parametrize(
    "secret_fragment",
    [
        "HTTP 503",  # raw check_output should not leak
        "192.0.2.10",  # ip_address from payload should not leak
        "postgresql://",  # database url
        "token-secret",
        "password",
    ],
)
async def test_response_body_does_not_contain_secrets_or_raw_payload(
    secret_fragment: str,
) -> None:
    processor = build_icinga2_processor()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    response_body = response.text
    assert secret_fragment not in response_body


# Route exposure check


def test_webhook_icinga2_route_is_exposed() -> None:
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
    )
    route_paths = {route.path for route in app.routes}
    assert "/webhooks/icinga2" in route_paths
    assert "/incidents" not in route_paths
    assert "/api/v1/incidents" not in route_paths


# Source assertions: processing.ingress must not import persistence


def test_processing_ingress_does_not_import_persistence() -> None:
    import inspect
    import app.processing.ingress as ingress_module

    source = inspect.getsource(ingress_module)
    assert "app.persistence" not in source
    assert "AsyncSession" not in source

# ---------------------------------------------------------------------------
# Topology enrichment integration via HTTP entrypoint
# ---------------------------------------------------------------------------
async def test_response_with_no_topology_match_and_no_ip_returns_source_tags(
    tmp_path: Path,
) -> None:
    topology_path = tmp_path / "topology.yaml"
    topology_path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web"},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    processor = build_icinga2_processor(topology_path=topology_path)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = {
        "source_id": "icinga2:service:db-01:http",
        "host": "db-01",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "HTTP 503",
        "ip_address": None,
        "tags": {"team.name": "platform"},
    }
    async for client in get_client(app):
        response = await client.post("/webhooks/icinga2", json=payload)
    body = response.json()
    assert body["state_accepted"] is True
    assert body["final_tags"] == {"team.name": "platform"}
    assert body["enrichment_diagnostics"] == []


async def test_response_with_subnet_fallback_from_http(tmp_path: Path) -> None:
    topology_path = tmp_path / "topology.yaml"
    topology_path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web"},
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
    processor = build_icinga2_processor(topology_path=topology_path)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = {
        "source_id": "icinga2:service:db-01:http",
        "host": "db-01",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "HTTP 503",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform"},
    }
    async for client in get_client(app):
        response = await client.post("/webhooks/icinga2", json=payload)
    body = response.json()
    assert body["state_accepted"] is True
    assert body["final_tags"]["topology.site"] == "dc1"
    assert body["final_tags"]["team.name"] == "platform"
    assert len(body["enrichment_diagnostics"]) == 1
    diag = body["enrichment_diagnostics"][0]
    assert diag["match_source"] == "subnet"
    assert diag["rule_id"] == "dc1-subnet"


async def test_response_conflict_diagnostic_only_includes_matched_rule(
    tmp_path: Path,
) -> None:
    topology_path = tmp_path / "topology.yaml"
    topology_path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web"},
                    },
                    {
                        "id": "db-servers",
                        "name": "DB Servers",
                        "hostname_pattern": "^db-.*",
                        "tags": {"topology.role": "db"},
                    },
                ],
                "subnet_rules": [],
            }
        )
    )
    processor = build_icinga2_processor(topology_path=topology_path)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = {
        "source_id": "icinga2:service:web-01:http",
        "host": "web-01",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-08T12:00:00+00:00",
        "check_output": "HTTP 503",
        "ip_address": "192.0.2.10",
        "tags": {"team.name": "platform", "topology.role": "old"},
    }
    async for client in get_client(app):
        response = await client.post("/webhooks/icinga2", json=payload)
    body = response.json()
    assert body["state_accepted"] is True
    diagnostics = body["enrichment_diagnostics"]
    assert len(diagnostics) == 1
    diag = diagnostics[0]
    assert diag["rule_id"] == "web-servers"
    assert diag["rule_name"] == "Web Servers"
    assert diag["match_source"] == "hostname"
    assert diag["tags_added"] == {}
    assert diag["tags_overridden"] == [["topology.role", "old", "web"]]
    assert diag["conflicts"] == [["topology.role", "old", "web"]]

# ---------------------------------------------------------------------------
# Rule engine integration via HTTP entrypoint
# ---------------------------------------------------------------------------
async def test_response_with_no_rule_match_returns_empty_matched_rules(
    tmp_path: Path,
) -> None:
    rules_path = tmp_path / "rules.yaml"
    rules_path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "db-only",
                        "priority": 10,
                        "match": {
                            "severities": ["CRITICAL"],
                            "host_pattern": "db-.*",
                        },
                        "window": {
                            "duration_seconds": 60,
                            "group_by": ["host"],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "x",
                        "actions": [
                            {"name": "create_incident", "plugin": "default_output"}
                        ],
                    }
                ]
            }
        )
    )
    processor = build_icinga2_processor(rules_path=rules_path)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["state_accepted"] is True
    assert body["matched_rules"] == []
    assert body["group_key"] is None
    assert body["threshold_decision"] is None
    assert body["rule_decision"]["reason"] == "no matching rule"

async def test_recovery_event_returns_no_rule_match(tmp_path: Path) -> None:
    rules_path = tmp_path / "rules.yaml"
    rules_path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "all",
                        "priority": 10,
                        "match": {"severities": ["OK"], "host_pattern": ".*"},
                        "window": {
                            "duration_seconds": 60,
                            "group_by": ["host"],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "x",
                        "actions": [
                            {"name": "create_incident", "plugin": "default_output"}
                        ],
                    }
                ]
            }
        )
    )
    processor = build_icinga2_processor(rules_path=rules_path)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    payload = valid_icinga2_host_payload()
    payload["state"] = "UP"
    async for client in get_client(app):
        response = await client.post("/webhooks/icinga2", json=payload)
    body = response.json()
    assert body["state_accepted"] is True
    assert body["event_type"] == "RECOVERY"
    assert body["severity"] == "OK"
    assert body["matched_rules"] == []
    assert body["group_key"] is None
    assert body["threshold_decision"] is None

async def test_response_with_rule_match_contains_group_key_and_threshold(
    tmp_path: Path,
) -> None:
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
                        },
                        "window": {
                            "duration_seconds": 300,
                            "group_by": ["host", "service"],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "Critical {service} on {host}",
                        "actions": [
                            {"name": "create_incident", "plugin": "default_output"}
                        ],
                    }
                ]
            }
        )
    )
    processor = build_icinga2_processor(rules_path=rules_path)
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: object(),
        icinga2_processor=processor,
    )
    async for client in get_client(app):
        response = await client.post(
            "/webhooks/icinga2",
            json=valid_icinga2_service_payload(),
        )
    body = response.json()
    assert body["state_accepted"] is True
    assert body["matched_rules"] == ["web-critical"]
    assert body["group_key"] == "host=web-01|service=http"
    assert body["threshold_decision"] is not None
    td = body["threshold_decision"]
    assert td["rule_name"] == "web-critical"
    assert td["group_key"] == "host=web-01|service=http"
    assert td["threshold"] == 1
    assert td["counted"] == 1
    assert td["crossed"] is True
    assert td["counted_fingerprints"] == [body["fingerprint"]]
    assert body["rule_decision"]["rule_name"] == "web-critical"
    assert body["rule_decision"]["priority"] == 10
    assert body["rule_decision"]["summary"] == "Critical http on web-01"
    assert body["incident_effects"]["inserted"] == 0
    assert body["incident_effects"]["updated"] == 0
    assert body["closure_count"] == 0
    assert body["notification_count"] == 0
