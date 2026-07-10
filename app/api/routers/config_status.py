from __future__ import annotations

import hashlib
import json
from typing import Annotated

from fastapi import APIRouter, Depends, Security

from app.api.security import require_operator_token

from app.api.deps import get_rules_config, get_topology_config
from app.config.rules import CompiledRuleConfig
from app.config.topology import CompiledTopologyConfig

router = APIRouter(prefix="/v1", dependencies=[Security(require_operator_token)])


def _hash_payload(payload: object) -> str:
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    return hashlib.sha256(encoded).hexdigest()


@router.get("/rules")
async def list_rules_summary(
    rules_config: Annotated[CompiledRuleConfig, Depends(get_rules_config)],
) -> dict[str, object]:
    rules = []
    for compiled in rules_config.rules:
        definition = compiled.definition
        rules.append(
            {
                "name": definition.name,
                "priority": definition.priority,
                "group_by": list(definition.window.group_by),
                "actions": [
                    {"name": action.name, "plugin": action.plugin}
                    for action in definition.actions
                ],
            }
        )
    return {"config_hash": rules_config.config_hash, "rules": rules}


@router.get("/topology")
async def list_topology_summary(
    topology_config: Annotated[CompiledTopologyConfig, Depends(get_topology_config)],
) -> dict[str, object]:
    rules: list[dict[str, object]] = []
    for rule in topology_config.hostname_rules:
        rules.append(
            {
                "id": rule.id,
                "name": rule.name,
                "match_type": "hostname",
                "tag_keys": sorted(rule.tags.keys() | rule.tag_capture_groups.keys()),
            }
        )
    for subnet_rule in topology_config.subnet_rules:
        rules.append(
            {
                "id": subnet_rule.id,
                "name": subnet_rule.name,
                "match_type": "subnet",
                "tag_keys": sorted(subnet_rule.tags),
            }
        )
    return {"config_hash": _hash_payload(rules), "rules": rules}
