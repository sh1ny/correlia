from __future__ import annotations

import inspect
from datetime import UTC, datetime
from pathlib import Path

import pytest
from pydantic import ValidationError
import yaml

from app.config.topology import (
    CompiledHostnameRule,
    CompiledSubnetRule,
    CompiledTopologyConfig,
    load_topology_config,
)
from app.domain.events import EventType, NormalizedEvent, Severity
from app.processing.enrichment import (
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
    with pytest.raises(ValidationError):
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
    with pytest.raises(ValueError, match="Invalid regex"):
        load_topology_config(path)

# ---------------------------------------------------------------------------
# CFG-04: hostname tag capture groups (D-07, D-09, D-11)
# ---------------------------------------------------------------------------


def test_load_topology_config_accepts_hostname_tag_capture_groups(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "datacenter-hosts",
                        "name": "Datacenter Hosts",
                        "hostname_pattern": "^([a-z0-9]+)-prd-.*",
                        "tags": {"topology.env": "production"},
                        "tag_capture_groups": {"topology.datacenter": 1},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    assert len(config.hostname_rules) == 1
    rule = config.hostname_rules[0]
    assert rule.tags == {"topology.env": "production"}
    assert rule.tag_capture_groups == {"topology.datacenter": 1}
    match = rule.pattern.match("prm1-prd-web01")
    assert match is not None
    assert match.group(1) == "prm1"

def test_load_topology_config_rejects_capture_group_key_outside_tag_key_contract(
    tmp_path: Path,
) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "bad-key",
                        "name": "Bad Key",
                        "hostname_pattern": "^([a-z0-9]+)-prd-.*",
                        "tags": {},
                        "tag_capture_groups": {"topology.Datacenter": 1},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    with pytest.raises(ValidationError):
        load_topology_config(path)


@pytest.mark.parametrize(
    ("group_index", "expected_snippet"),
    [
        (0, "must be >= 1"),
        (-1, "must be >= 1"),
        (2, "is 2 but pattern"),
    ],
)
def test_load_topology_config_rejects_invalid_capture_group_index(
    tmp_path: Path,
    group_index: int,
    expected_snippet: str,
) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "bad-group",
                        "name": "Bad Group",
                        "hostname_pattern": "^([a-z0-9]+)-prd-.*",
                        "tags": {},
                        "tag_capture_groups": {"topology.datacenter": group_index},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    with pytest.raises(ValueError, match=expected_snippet):
        load_topology_config(path)


def test_load_topology_config_rejects_capture_group_key_without_topology_prefix(
    tmp_path: Path,
) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "bad-key",
                        "name": "Bad Key",
                        "hostname_pattern": "^([a-z0-9]+)-prd-.*",
                        "tags": {},
                        "tag_capture_groups": {"datacenter": 1},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    with pytest.raises(ValidationError):
        load_topology_config(path)


def test_load_topology_config_rejects_subnet_tag_capture_groups(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [],
                "subnet_rules": [
                    {
                        "id": "subnet-capture",
                        "name": "Subnet Capture",
                        "subnet": "192.0.2.0/24",
                        "tags": {"topology.site": "dc1"},
                        "tag_capture_groups": {"topology.foo": 1},
                    }
                ],
            }
        )
    )
    with pytest.raises(ValidationError):
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



def test_load_topology_config_allows_mixed_ipv4_ipv6_subnets(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [],
                "subnet_rules": [
                    {
                        "id": "ipv4",
                        "name": "IPv4",
                        "subnet": "192.0.2.0/24",
                        "tags": {"topology.site": "v4"},
                    },
                    {
                        "id": "ipv6",
                        "name": "IPv6",
                        "subnet": "2001:db8::/32",
                        "tags": {"topology.site": "v6"},
                    },
                ],
            }
        )
    )

    config = load_topology_config(path)

    assert len(config.subnet_rules) == 2

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
    with pytest.raises(ValidationError):
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
    with pytest.raises(ValidationError):
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
    with pytest.raises(ValidationError):
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


async def test_subnet_matching_skips_different_ip_families(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [],
                "subnet_rules": [
                    {
                        "id": "ipv6",
                        "name": "IPv6",
                        "subnet": "2001:db8::/32",
                        "tags": {"topology.site": "v6"},
                    },
                    {
                        "id": "ipv4",
                        "name": "IPv4",
                        "subnet": "192.0.2.0/24",
                        "tags": {"topology.site": "v4"},
                    },
                ],
            }
        )
    )
    enricher = StaticTopologyEnricher(load_topology_config(path))
    event = _event(host="unknown", ip_address="192.0.2.10")

    result = await enricher.enrich(event)

    assert result.event.tags["topology.site"] == "v4"
    assert result.diagnostics[0].rule_id == "ipv4"

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
# CFG-04: derived hostname tag enrichment (D-08, D-09)
# ---------------------------------------------------------------------------


async def test_hostname_capture_group_adds_derived_tag(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "datacenter-hosts",
                        "name": "Datacenter Hosts",
                        "hostname_pattern": "^([a-z0-9]+)-prd-.*",
                        "tags": {},
                        "tag_capture_groups": {"topology.datacenter": 1},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="prm1-prd-web01")
    result = await enricher.enrich(event)

    assert result.event.tags["topology.datacenter"] == "prm1"
    diag = result.diagnostics[0]
    assert diag.tags_added == {"topology.datacenter": "prm1"}
    assert diag.tags_overridden == []
    assert diag.conflicts == []


async def test_hostname_capture_group_overrides_literal_or_event_tag(
    tmp_path: Path,
) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "datacenter-hosts",
                        "name": "Datacenter Hosts",
                        "hostname_pattern": "^([a-z0-9]+)-prd-.*",
                        "tags": {
                            "topology.datacenter": "literal-dc",
                            "topology.role": "web",
                        },
                        "tag_capture_groups": {"topology.datacenter": 1},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="prm1-prd-web01", tags={"topology.datacenter": "event-dc"})
    result = await enricher.enrich(event)

    assert result.event.tags["topology.datacenter"] == "prm1"
    assert result.event.tags["topology.role"] == "web"
    diag = result.diagnostics[0]
    assert diag.tags_added == {"topology.role": "web"}
    assert diag.tags_overridden == [
        ("topology.datacenter", "event-dc", "literal-dc"),
        ("topology.datacenter", "literal-dc", "prm1"),
    ]
    assert diag.conflicts == [
        ("topology.datacenter", "event-dc", "literal-dc"),
        ("topology.datacenter", "literal-dc", "prm1"),
    ]


@pytest.mark.parametrize(
    ("hostname_pattern", "host", "group_index"),
    [
        ("^web(-?[0-9]*).*", "web", 1),  # empty string group
        ("^(web)(?:-(\\d+))?.*", "web", 2),  # unmatched optional group (None)
    ],
)
async def test_hostname_capture_group_skips_empty_capture(
    tmp_path: Path,
    hostname_pattern: str,
    host: str,
    group_index: int,
) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "optional-suffix",
                        "name": "Optional Suffix",
                        "hostname_pattern": hostname_pattern,
                        "tags": {},
                        "tag_capture_groups": {"topology.suffix": group_index},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host=host)
    result = await enricher.enrich(event)

    assert "topology.suffix" not in result.event.tags
    diag = result.diagnostics[0]
    assert diag.tags_added == {}
    assert diag.tags_overridden == []
    assert diag.conflicts == []

async def test_hostname_capture_group_rejects_overlong_capture(
    tmp_path: Path,
) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "overlong-capture",
                        "name": "Overlong Capture",
                        "hostname_pattern": "^(.*)$",
                        "tags": {},
                        "tag_capture_groups": {"topology.big": 1},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    enricher = StaticTopologyEnricher(config)
    event = _event(host="x" * 257)
    with pytest.raises(ValueError, match="exceeds 256 characters"):
        await enricher.enrich(event)


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

def test_enrich_method_has_no_persistence_or_rule_engine_refs() -> None:
    source = inspect.getsource(StaticTopologyEnricher.enrich)
    assert "app.persistence" not in source
    assert "AsyncSession" not in source
    assert "RuleEngine" not in source
