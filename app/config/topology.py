from __future__ import annotations

import re
from dataclasses import dataclass
from ipaddress import ip_network
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class HostnameTopologyRule(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    id: str
    name: str
    hostname_pattern: str
    tags: dict[str, str]

    @field_validator("tags")
    @classmethod
    def _tags_must_start_with_topology(cls, value: dict[str, str]) -> dict[str, str]:
        for key in value:
            if not key.startswith("topology."):
                raise ValueError(f"tag key must start with 'topology.': {key}")
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
        subnets: list[tuple[str, Any, dict[str, str]]] = []
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
                if net_a.overlaps(net_b):
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


@dataclass(frozen=True, slots=True)
class CompiledSubnetRule:
    id: str
    name: str
    network: Any  # ipaddress.IPv4Network | IPv6Network
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
    for rule in config.hostname_rules:
        try:
            pattern = re.compile(rule.hostname_pattern)
        except re.error as exc:
            raise ValueError(
                f"Invalid regex in hostname rule '{rule.id}': "
                f"{rule.hostname_pattern}"
            ) from exc
        compiled_hostname_rules.append(
            CompiledHostnameRule(
                id=rule.id,
                name=rule.name,
                pattern=pattern,
                tags=dict(rule.tags),
            )
        )

    compiled_subnet_rules: list[CompiledSubnetRule] = []
    for rule in config.subnet_rules:
        # CIDR was already validated by the model validator, but re-parse here
        # to get the network object for the compiled rule.
        network = ip_network(rule.subnet, strict=False)
        compiled_subnet_rules.append(
            CompiledSubnetRule(
                id=rule.id,
                name=rule.name,
                network=network,
                tags=dict(rule.tags),
            )
        )

    return CompiledTopologyConfig(
        hostname_rules=tuple(compiled_hostname_rules),
        subnet_rules=tuple(compiled_subnet_rules),
    )
