from __future__ import annotations

import re
from dataclasses import dataclass
from ipaddress import IPv4Network, IPv6Network, ip_network
from pathlib import Path

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.domain.events import TagKey


class HostnameTopologyRule(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    id: str
    name: str
    hostname_pattern: str
    tags: dict[str, str]
    tag_capture_groups: dict[TagKey, int] = Field(default_factory=dict)

    @field_validator("tags")
    @classmethod
    def _tags_must_start_with_topology(cls, value: dict[str, str]) -> dict[str, str]:
        for key in value:
            if not key.startswith("topology."):
                raise ValueError(f"tag key must start with 'topology.': {key}")
        return value

    @field_validator("tag_capture_groups")
    @classmethod
    def _capture_groups_must_be_valid(
        cls, value: dict[str, int]
    ) -> dict[str, int]:
        for key, group in value.items():
            if not key.startswith("topology."):
                raise ValueError(
                    f"capture group key must start with 'topology.': {key}"
                )
            if group < 1:
                raise ValueError(
                    f"capture group index for '{key}' must be >= 1, got {group}"
                )
        return value

class SubnetTopologyRule(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    id: str
    name: str
    subnet: str
    tags: dict[str, str]

    @field_validator("tags")
    @classmethod
    def _tags_must_start_with_topology(cls, value: dict[str, str]) -> dict[str, str]:
        for key in value:
            if not key.startswith("topology."):
                raise ValueError(f"tag key must start with 'topology.': {key}")
        return value


class TopologyConfig(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    hostname_rules: list[HostnameTopologyRule] = Field(default_factory=list)
    subnet_rules: list[SubnetTopologyRule] = Field(default_factory=list)

    @model_validator(mode="after")
    def _reject_overlapping_conflicting_subnets(self) -> "TopologyConfig":
        subnets: list[tuple[str, IPv4Network | IPv6Network, dict[str, str]]] = []
        for rule in self.subnet_rules:
            try:
                network = ip_network(rule.subnet, strict=False)
            except ValueError as exc:
                raise ValueError(
                    f"Invalid CIDR in subnet rule '{rule.id}': {rule.subnet}"
                ) from exc
            subnets.append((rule.id, network, rule.tags))

        for i, (id_a, net_a, tags_a) in enumerate(subnets):
            for id_b, net_b, tags_b in subnets[i + 1 :]:
                if net_a.version == net_b.version and net_a.overlaps(net_b):
                    if tags_a != tags_b:
                        raise ValueError(
                            f"Overlapping subnet rules '{id_a}' ({net_a}) and "
                            f"'{id_b}' ({net_b}) assign different tags"
                        )
        return self


@dataclass(frozen=True, slots=True)
class CompiledHostnameRule:
    id: str
    name: str
    pattern: re.Pattern[str]
    tags: dict[str, str]
    tag_capture_groups: dict[str, int]


@dataclass(frozen=True, slots=True)
class CompiledSubnetRule:
    id: str
    name: str
    network: IPv4Network | IPv6Network
    tags: dict[str, str]


@dataclass(frozen=True, slots=True)
class CompiledTopologyConfig:
    hostname_rules: tuple[CompiledHostnameRule, ...]
    subnet_rules: tuple[CompiledSubnetRule, ...]


def load_topology_config(path: Path) -> CompiledTopologyConfig:
    data = yaml.safe_load(path.read_text())
    if data is None:
        data = {}
    config = TopologyConfig.model_validate(data)

    compiled_hostname_rules: list[CompiledHostnameRule] = []
    for hostname_rule in config.hostname_rules:
        try:
            pattern = re.compile(hostname_rule.hostname_pattern)
        except re.error as exc:
            raise ValueError(
                f"Invalid regex in hostname rule '{hostname_rule.id}': "
                f"{hostname_rule.hostname_pattern}"
            ) from exc
        for key, group_index in hostname_rule.tag_capture_groups.items():
            if group_index > pattern.groups:
                raise ValueError(
                    f"capture group index for '{key}' in hostname rule "
                    f"'{hostname_rule.id}' is {group_index} but pattern "
                    f"'{hostname_rule.hostname_pattern}' only has "
                    f"{pattern.groups} group(s)"
                )
        compiled_hostname_rules.append(
            CompiledHostnameRule(
                id=hostname_rule.id,
                name=hostname_rule.name,
                pattern=pattern,
                tags=dict(hostname_rule.tags),
                tag_capture_groups=dict(hostname_rule.tag_capture_groups),
            )
        )

    compiled_subnet_rules: list[CompiledSubnetRule] = []
    for subnet_rule in config.subnet_rules:
        # CIDR was already validated by the model validator, but re-parse here
        # to get the network object for the compiled rule.
        network = ip_network(subnet_rule.subnet, strict=False)
        compiled_subnet_rules.append(
            CompiledSubnetRule(
                id=subnet_rule.id,
                name=subnet_rule.name,
                network=network,
                tags=dict(subnet_rule.tags),
            )
        )

    return CompiledTopologyConfig(
        hostname_rules=tuple(compiled_hostname_rules),
        subnet_rules=tuple(compiled_subnet_rules),
    )
