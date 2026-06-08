from __future__ import annotations

import inspect
from datetime import UTC, datetime
from pathlib import Path

import pytest
import yaml

from app.config.topology import (
    CompiledHostnameRule,
    CompiledSubnetRule,
    CompiledTopologyConfig,
    HostnameTopologyRule,
    SubnetTopologyRule,
    TopologyConfig,
    load_topology_config,
)
from app.domain.events import EventType, NormalizedEvent, Severity
from app.plugins.interfaces import TopologyEnricher
from app.processing.enrichment import (
    EnrichmentDiagnostic,
    EnrichmentResult,
    StaticTopologyEnricher,
)


def _event(
    host: str = "web-01",
    ip_address: str | None = "192.0.2.10",
    tags: dict[str, str] | None = None,
) -> NormalizedEvent:
    return NormalizedEvent.model_validate(
        {
            "fingerprint": "fp123",
            "source_id": "icinga2:test",
            "host": host,
            "service": "http",
            "severity": Severity.CRITICAL,
            "event_type": EventType.PROBLEM,
            "timestamp": datetime(2026, 6, 8, 12, 0, 0, tzinfo=UTC),
            "tags": tags or {"team.name": "platform"},
            "message": "HTTP 503",
            "ip_address": ip_address,
        }
    )


# ---------------------------------------------------------------------------
# TOP-01: hostname_rules YAML loading
# ---------------------------------------------------------------------------


def test_load_topology_config_accepts_valid_hostname_rules(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web", "topology.site": "dc1"},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    assert isinstance(config, CompiledTopologyConfig)
    assert len(config.hostname_rules) == 1
    rule = config.hostname_rules[0]
    assert isinstance(rule, CompiledHostnameRule)
    assert rule.id == "web-servers"
    assert rule.name == "Web Servers"
    assert rule.pattern.match("web-01")
    assert not rule.pattern.match("db-01")
    assert rule.tags == {"topology.role": "web", "topology.site": "dc1"}


def test_load_topology_config_rejects_extra_keys_in_hostname_rule(
    tmp_path: Path,
) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "test",
                        "name": "Test",
                        "hostname_pattern": ".*",
                        "tags": {"topology.role": "test"},
                        "extra_field": "bad",
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    with pytest.raises(Exception):  # Pydantic ValidationError
        load_topology_config(path)


def test_load_topology_config_rejects_invalid_regex(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "test",
                        "name": "Test",
                        "hostname_pattern": "[invalid",
                        "tags": {"topology.role": "test"},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    with pytest.raises(Exception):
        load_topology_config(path)


# ---------------------------------------------------------------------------
# TOP-02: subnet_rules YAML loading
# ---------------------------------------------------------------------------


def test_load_topology_config_accepts_valid_subnet_rules(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [],
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
    config = load_topology_config(path)
    assert len(config.subnet_rules) == 1
    rule = config.subnet_rules[0]
    assert isinstance(rule, CompiledSubnetRule)
    assert rule.id == "dc1-subnet"
    assert rule.name == "DC1 Subnet"
    assert rule.tags == {"topology.site": "dc1"}


def test_load_topology_config_rejects_invalid_cidr(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [],
                "subnet_rules": [
                    {
                        "id": "test",
                        "name": "Test",
                        "subnet": "not-a-cidr",
                        "tags": {"topology.site": "dc1"},
                    }
                ],
            }
        )
    )
    with pytest.raises(Exception):
        load_topology_config(path)


def test_load_topology_config_rejects_overlapping_conflicting_cidrs(
    tmp_path: Path,
) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [],
                "subnet_rules": [
                    {
                        "id": "subnet-a",
                        "name": "Subnet A",
                        "subnet": "192.0.2.0/24",
                        "tags": {"topology.site": "dc1"},
                    },
                    {
                        "id": "subnet-b",
                        "name": "Subnet B",
                        "subnet": "192.0.2.0/28",
                        "tags": {"topology.site": "dc2"},
                    },
                ],
            }
        )
    )
    with pytest.raises(Exception):
        load_topology_config(path)


def test_load_topology_config_allows_overlapping_same_tags(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [],
                "subnet_rules": [
                    {
                        "id": "subnet-a",
                        "name": "Subnet A",
                        "subnet": "192.0.2.0/24",
                        "tags": {"topology.site": "dc1"},
                    },
                    {
                        "id": "subnet-b",
                        "name": "Subnet B",
                        "subnet": "192.0.2.0/28",
                        "tags": {"topology.site": "dc1"},
                    },
                ],
            }
        )
    )
    config = load_topology_config(path)
    assert len(config.subnet_rules) == 2


# ---------------------------------------------------------------------------
# D-07: reserved topology.* namespace
# ---------------------------------------------------------------------------


def test_load_topology_config_rejects_non_topology_tags(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "test",
                        "name": "Test",
                        "hostname_pattern": ".*",
                        "tags": {"team.name": "bad"},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    with pytest.raises(Exception):
        load_topology_config(path)


# ---------------------------------------------------------------------------
# TOP-03: hostname precedence over subnet fallback
# ---------------------------------------------------------------------------


async def test_hostname_match_prevents_subnet_fallback(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
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
                        "tags": {"topology.site": "dc1", "topology.role": "unknown"},
                    }
                ],
            }
        )
    )
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="web-01", ip_address="192.0.2.10")
    result = await enricher.enrich(event)

    assert result.event.tags["topology.role"] == "web"
    assert "topology.site" not in result.event.tags
    assert len(result.diagnostics) == 1
    assert result.diagnostics[0].match_source == "hostname"


async def test_subnet_fallback_when_no_hostname_match(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
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
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="db-01", ip_address="192.0.2.10")
    result = await enricher.enrich(event)

    assert result.event.tags["topology.site"] == "dc1"
    assert "topology.role" not in result.event.tags
    assert len(result.diagnostics) == 1
    assert result.diagnostics[0].match_source == "subnet"


async def test_no_match_returns_original_event(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="unknown-01")
    result = await enricher.enrich(event)

    assert result.event is event
    assert result.diagnostics == []


# ---------------------------------------------------------------------------
# TOP-04: topology wins conflicts, D-08 diagnostics
# ---------------------------------------------------------------------------


async def test_topology_wins_on_conflicting_source_tags(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
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
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="web-01", tags={"team.name": "platform", "topology.role": "old-value"})
    result = await enricher.enrich(event)

    assert result.event.tags["topology.role"] == "web"
    assert result.event.tags["team.name"] == "platform"
    assert len(result.diagnostics) == 1
    diag = result.diagnostics[0]
    assert diag.tags_overridden == [("topology.role", "old-value", "web")]
    assert diag.conflicts == [("topology.role", "old-value", "web")]


async def test_no_conflict_when_source_tag_same_value(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
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
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="web-01", tags={"team.name": "platform", "topology.role": "web"})
    result = await enricher.enrich(event)

    assert result.event.tags["topology.role"] == "web"
    assert len(result.diagnostics) == 1
    diag = result.diagnostics[0]
    assert diag.tags_added == {}
    assert diag.tags_overridden == []
    assert diag.conflicts == []


# ---------------------------------------------------------------------------
# TOP-05: enrichment diagnostics shape
# ---------------------------------------------------------------------------


async def test_diagnostics_contain_matched_rule_info(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web", "topology.site": "dc1"},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="web-01")
    result = await enricher.enrich(event)

    assert len(result.diagnostics) == 1
    diag = result.diagnostics[0]
    assert diag.rule_id == "web-servers"
    assert diag.rule_name == "Web Servers"
    assert diag.match_source == "hostname"
    assert diag.tags_added == {"topology.role": "web", "topology.site": "dc1"}


# ---------------------------------------------------------------------------
# TOP-06: plugin boundary / protocol isolation
# ---------------------------------------------------------------------------


def test_static_topology_enricher_implements_protocol() -> None:
    path = Path("/dev/null")  # dummy; we only check structural typing
    # Structural typing means any object with an `enrich` method matching
    # the signature satisfies TopologyEnricher.
    assert hasattr(StaticTopologyEnricher, "enrich")


def test_enrichment_has_no_persistence_import() -> None:
    import app.processing.enrichment as enrichment_module

    source = inspect.getsource(enrichment_module)
    assert "app.persistence" not in source
    assert "AsyncSession" not in source


def test_enrichment_has_no_rule_engine_import() -> None:
    import app.processing.enrichment as enrichment_module

    source = inspect.getsource(enrichment_module)
    assert "RuleEngine" not in source
    assert "rule_engine" not in source


# ---------------------------------------------------------------------------
# D-10: diagnostics bounded to matched rules only
# ---------------------------------------------------------------------------


async def test_diagnostics_only_include_matched_rule(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
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
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="web-01")
    result = await enricher.enrich(event)

    assert len(result.diagnostics) == 1
    assert result.diagnostics[0].rule_id == "web-servers"
