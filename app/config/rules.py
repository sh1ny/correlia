from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.domain.events import Severity
from app.domain.rules import MatchCriteria, RuleAction, RuleDefinition, RuleWindow


class MatchCriteriaConfig(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    severities: list[str]
    host_pattern: str = Field(min_length=1)
    service_pattern: str | None = None
    tags: dict[str, str] = Field(default_factory=dict)

    @field_validator("severities", mode="after")
    @classmethod
    def _validate_severities(cls, value: list[str]) -> list[str]:
        for s in value:
            if s not in {e.value for e in Severity}:
                raise ValueError(f"invalid severity: {s}")
        return value


class RuleActionConfig(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    name: str = Field(min_length=1)
    plugin: str = Field(min_length=1)


class RuleWindowConfig(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    duration_seconds: int = Field(ge=1)
    group_by: list[str] = Field(min_length=1)
    trigger_threshold: int = Field(ge=1)


class RuleDefinitionConfig(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    name: str = Field(min_length=1)
    priority: int
    match: MatchCriteriaConfig
    window: RuleWindowConfig
    output_summary: str = Field(min_length=1)
    actions: list[RuleActionConfig] = Field(default_factory=list)

    @field_validator("actions", mode="after")
    @classmethod
    def _actions_not_empty(cls, value: list[RuleActionConfig]) -> list[RuleActionConfig]:
        if not value:
            raise ValueError("actions must not be empty")
        return value


class RuleConfig(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    rules: list[RuleDefinitionConfig] = Field(default_factory=list)


@dataclass(frozen=True, slots=True)
class CompiledRule:
    definition: RuleDefinition
    host_pattern: re.Pattern[str]
    service_pattern: re.Pattern[str] | None


@dataclass(frozen=True, slots=True)
class CompiledRuleConfig:
    rules: tuple[CompiledRule, ...]
    config_hash: str


_KNOWN_NORMALIZED_FIELDS: frozenset[str] = frozenset(
    {
        "host",
        "service",
        "message",
        "severity",
        "event_type",
        "fingerprint",
        "source_id",
        "timestamp",
        "ip_address",
    }
)

_TAG_KEY_RE = re.compile(r"^[a-z][a-z0-9_.-]*$")
_SUMMARY_VAR_RE = re.compile(r"\{([a-zA-Z0-9_.-]+)\}")
_INVALID_VAR_RE = re.compile(r"\{[^}]*\}")

def _validate_summary_variables(summary: str) -> None:
    for match in _INVALID_VAR_RE.finditer(summary):
        var = match.group(0)
        inner = var[1:-1]
        if not _SUMMARY_VAR_RE.match(var):
            raise ValueError(f"unknown summary variable: {var}")
        if inner not in _KNOWN_NORMALIZED_FIELDS and not _TAG_KEY_RE.match(inner):
            raise ValueError(f"unknown summary variable: {{{inner}}}")


def _compile_rule_config(rule_cfg: RuleDefinitionConfig) -> CompiledRule:
    try:
        host_pattern = re.compile(rule_cfg.match.host_pattern)
    except re.error as exc:
        raise ValueError(
            f"Invalid regex in rule '{rule_cfg.name}' host_pattern: "
            f"{rule_cfg.match.host_pattern}"
        ) from exc

    service_pattern: re.Pattern[str] | None = None
    if rule_cfg.match.service_pattern is not None:
        try:
            service_pattern = re.compile(rule_cfg.match.service_pattern)
        except re.error as exc:
            raise ValueError(
                f"Invalid regex in rule '{rule_cfg.name}' service_pattern: "
                f"{rule_cfg.match.service_pattern}"
            ) from exc

    match = MatchCriteria(
        severities=[Severity(s) for s in rule_cfg.match.severities],
        host_pattern=rule_cfg.match.host_pattern,
        service_pattern=rule_cfg.match.service_pattern,
        tags=rule_cfg.match.tags,
    )
    window = RuleWindow(
        duration_seconds=rule_cfg.window.duration_seconds,
        group_by=rule_cfg.window.group_by,
        trigger_threshold=rule_cfg.window.trigger_threshold,
    )
    actions = [RuleAction(name=a.name, plugin=a.plugin) for a in rule_cfg.actions]
    definition = RuleDefinition(
        name=rule_cfg.name,
        priority=rule_cfg.priority,
        match=match,
        window=window,
        output_summary=rule_cfg.output_summary,
        actions=actions,
    )
    return CompiledRule(
        definition=definition,
        host_pattern=host_pattern,
        service_pattern=service_pattern,
    )


def load_rules_config(
    path: Path,
    *,
    known_actions: frozenset[str] = frozenset({"create_incident"}),
    known_plugins: frozenset[str] = frozenset(),
) -> CompiledRuleConfig:
    data = yaml.safe_load(path.read_text())
    if data is None:
        data = {"rules": []}
    config = RuleConfig.model_validate(data)

    # Semantic validations
    priorities = set()
    names = set()
    for rule in config.rules:
        if rule.priority in priorities:
            raise ValueError(
                f"duplicate priority {rule.priority} in rule '{rule.name}'"
            )
        priorities.add(rule.priority)
        if rule.name in names:
            raise ValueError(f"duplicate name: {rule.name}")
        names.add(rule.name)

        for action in rule.actions:
            if action.name not in known_actions:
                raise ValueError(
                    f"unknown action '{action.name}' in rule '{rule.name}'"
                )
            if known_plugins and action.plugin not in known_plugins:
                raise ValueError(
                    f"unknown plugin '{action.plugin}' in rule '{rule.name}'"
                )

        _validate_summary_variables(rule.output_summary)

    compiled_rules: list[CompiledRule] = []
    for rule_cfg in config.rules:
        compiled_rules.append(_compile_rule_config(rule_cfg))

    # Deterministic hash for observability
    config_text = yaml.safe_dump(
        {"rules": [r.model_dump(mode="json") for r in config.rules]}
    )
    config_hash = hashlib.sha256(config_text.encode()).hexdigest()

    return CompiledRuleConfig(
        rules=tuple(compiled_rules),
        config_hash=config_hash,
    )
