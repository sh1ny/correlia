from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from app.config.rules import (
    CompiledRule,
    CompiledRuleConfig,
    MatchCriteriaConfig,
    RuleActionConfig,
    RuleConfig,
    RuleWindowConfig,
    load_rules_config,
)
from app.domain.events import Severity


# ---------------------------------------------------------------------------
# RUL-01: valid rule YAML loading
# ---------------------------------------------------------------------------


def _valid_rule_yaml() -> dict[str, object]:
    return {
        "rules": [
            {
                "name": "critical-web",
                "priority": 10,
                "match": {
                    "severities": ["CRITICAL"],
                    "host_pattern": "web-.*",
                    "service_pattern": "http",
                    "tags": {"team.name": "platform"},
                },
                "window": {
                    "duration_seconds": 300,
                    "group_by": ["topology.site", "service"],
                    "trigger_threshold": 3,
                },
                "output_summary": "Critical web alert on {host} at {topology.site}",
                "actions": [
                    {"name": "create_incident", "plugin": "default_output"},
                ],
            },
            {
                "name": "warning-db",
                "priority": 20,
                "match": {
                    "severities": ["WARNING", "CRITICAL"],
                    "host_pattern": "db-.*",
                    "tags": {},
                },
                "window": {
                    "duration_seconds": 600,
                    "group_by": ["host"],
                    "trigger_threshold": 1,
                },
                "output_summary": "DB alert: {message}",
                "actions": [
                    {"name": "create_incident", "plugin": "default_output"},
                ],
            },
        ]
    }


def test_load_rules_config_accepts_valid_yaml(tmp_path: Path) -> None:
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(_valid_rule_yaml()))
    config = load_rules_config(path)
    assert len(config.rules) == 2
    assert config.rules[0].definition.name == "critical-web"
    assert config.rules[0].definition.priority == 10
    assert config.rules[1].definition.name == "warning-db"
    assert config.rules[1].definition.priority == 20
    assert config.config_hash is not None


def test_compiled_rule_has_compiled_patterns(tmp_path: Path) -> None:
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(_valid_rule_yaml()))
    config = load_rules_config(path)
    rule = config.rules[0]
    assert rule.host_pattern is not None
    assert rule.host_pattern.match("web-01")
    assert not rule.host_pattern.match("db-01")
    assert rule.service_pattern is not None
    assert rule.service_pattern.match("http")


# ---------------------------------------------------------------------------
# RUL-02: invalid YAML rejected at load time
# ---------------------------------------------------------------------------


def test_load_rules_config_rejects_duplicate_priorities(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][1]["priority"] = 10  # same as first rule
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="duplicate priority"):
        load_rules_config(path)


def test_load_rules_config_rejects_duplicate_names(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][1]["name"] = "critical-web"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="duplicate name"):
        load_rules_config(path)


def test_load_rules_config_rejects_extra_keys(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["extra_field"] = "nope"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_rules_config(path)


def test_load_rules_config_rejects_string_threshold(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["window"]["trigger_threshold"] = "three"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_rules_config(path)


def test_load_rules_config_rejects_zero_window_duration(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["window"]["duration_seconds"] = 0
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_rules_config(path)


def test_load_rules_config_rejects_negative_window_duration(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["window"]["duration_seconds"] = -1
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_rules_config(path)


def test_load_rules_config_rejects_invalid_host_regex(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["match"]["host_pattern"] = "[invalid"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="Invalid regex"):
        load_rules_config(path)


def test_load_rules_config_rejects_invalid_service_regex(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["match"]["service_pattern"] = "[bad"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="Invalid regex"):
        load_rules_config(path)


def test_load_rules_config_rejects_unknown_action_name(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["actions"][0]["name"] = "unknown_action"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="unknown action"):
        load_rules_config(path, known_actions=frozenset({"create_incident"}))


def test_load_rules_config_rejects_unknown_plugin_reference(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["actions"][0]["plugin"] = "unknown_plugin"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="unknown plugin"):
        load_rules_config(
            path,
            known_actions=frozenset({"create_incident"}),
            known_plugins=frozenset({"default_output"}),
        )


def test_load_rules_config_rejects_invalid_summary_variable_syntax(
    tmp_path: Path,
) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["output_summary"] = "Alert on {bad var}"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="unknown summary variable"):
        load_rules_config(path)


def test_load_rules_config_rejects_missing_group_by_field(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["window"]["group_by"] = []
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="group_by"):
        load_rules_config(path)


def test_load_rules_config_allows_empty_tags_match(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["match"]["tags"] = {}
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    config = load_rules_config(path)
    assert config.rules[0].definition.match.tags == {}


# ---------------------------------------------------------------------------
# D-13: priority uniqueness
# ---------------------------------------------------------------------------


def test_load_rules_config_rejects_multiple_rules_with_same_priority(
    tmp_path: Path,
) -> None:
    data = {
        "rules": [
            {
                "name": "rule-a",
                "priority": 5,
                "match": {"severities": ["CRITICAL"], "host_pattern": ".*"},
                "window": {
                    "duration_seconds": 60,
                    "group_by": ["host"],
                    "trigger_threshold": 1,
                },
                "output_summary": "Alert on {host}",
                "actions": [{"name": "create_incident", "plugin": "default_output"}],
            },
            {
                "name": "rule-b",
                "priority": 5,
                "match": {"severities": ["WARNING"], "host_pattern": ".*"},
                "window": {
                    "duration_seconds": 60,
                    "group_by": ["host"],
                    "trigger_threshold": 1,
                },
                "output_summary": "Alert on {host}",
                "actions": [{"name": "create_incident", "plugin": "default_output"}],
            },
        ]
    }
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="duplicate priority"):
        load_rules_config(path)


# ---------------------------------------------------------------------------
# Config model validation directly
# ---------------------------------------------------------------------------


def test_rule_config_model_rejects_empty_name() -> None:
    with pytest.raises(ValueError):
        RuleConfig.model_validate(
            {
                "rules": [
                    {
                        "name": "",
                        "priority": 1,
                        "match": {"severities": ["CRITICAL"], "host_pattern": ".*"},
                        "window": {
                            "duration_seconds": 60,
                            "group_by": ["host"],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "x",
                        "actions": [{"name": "create_incident", "plugin": "default_output"}],
                    }
                ]
            }
        )


def test_match_criteria_config_accepts_wildcard_host() -> None:
    cfg = MatchCriteriaConfig.model_validate(
        {"severities": ["CRITICAL"], "host_pattern": ".*"}
    )
    assert cfg.host_pattern == ".*"
    assert cfg.service_pattern is None


def test_rule_window_config_rejects_zero_threshold() -> None:
    with pytest.raises(ValueError):
        RuleWindowConfig.model_validate(
            {"duration_seconds": 60, "group_by": ["host"], "trigger_threshold": 0}
        )


def test_rule_action_config_rejects_empty_name() -> None:
    with pytest.raises(ValueError):
        RuleActionConfig.model_validate({"name": "", "plugin": "default_output"})

# ---------------------------------------------------------------------------
# Task 3: known_plugins acceptance and rejection
# ---------------------------------------------------------------------------
def test_load_rules_config_accepts_known_plugin_reference(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    config = load_rules_config(
        path,
        known_actions=frozenset({"create_incident"}),
        known_plugins=frozenset({"default_output"}),
    )
    assert config.rules[0].definition.actions[0].plugin == "default_output"


def test_load_rules_config_rejects_missing_plugin_reference(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["actions"][0]["plugin"] = "missing_plugin"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError, match="unknown plugin"):
        load_rules_config(
            path,
            known_actions=frozenset({"create_incident"}),
            known_plugins=frozenset({"default_output"}),
        )
