from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import yaml

from app.config.rules import load_rules_config
from app.domain.events import EventType, NormalizedEvent, Severity
from app.domain.rules import NoOpDecision, RuleMatch
from app.processing.rule_engine import RuleEngine


def _event(
    host: str = "web-01",
    service: str | None = "http",
    severity: Severity = Severity.CRITICAL,
    event_type: EventType = EventType.PROBLEM,
    fingerprint: str = "fp1",
    tags: dict[str, str] | None = None,
    timestamp: datetime | None = None,
) -> NormalizedEvent:
    return NormalizedEvent.model_validate(
        {
            "fingerprint": fingerprint,
            "source_id": "icinga2:test",
            "host": host,
            "service": service,
            "severity": severity,
            "event_type": event_type,
            "timestamp": timestamp or datetime(2026, 6, 8, 12, 0, 0, tzinfo=UTC),
            "tags": tags or {"team.name": "platform", "topology.site": "dc1"},
            "message": "HTTP 503",
            "ip_address": "192.0.2.10",
        }
    )


def _build_engine(tmp_path: Path, rules_data: dict[str, object]) -> RuleEngine:
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(rules_data))
    config = load_rules_config(path)
    return RuleEngine(config.rules)


# ---------------------------------------------------------------------------
# RUL-03: deterministic priority order and first match wins
# ---------------------------------------------------------------------------


async def test_rules_evaluated_in_ascending_priority_order(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "low-priority",
                    "priority": 20,
                    "match": {"severities": ["CRITICAL"], "host_pattern": "web-.*"},
                    "window": {
                        "duration_seconds": 60,
                        "group_by": ["host"],
                        "trigger_threshold": 1,
                    },
                    "output_summary": "Low: {host}",
                    "actions": [{"name": "create_incident", "plugin": "low_output"}],
                },
                {
                    "name": "high-priority",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": "web-.*"},
                    "window": {
                        "duration_seconds": 60,
                        "group_by": ["host"],
                        "trigger_threshold": 1,
                    },
                    "output_summary": "High: {host}",
                    "actions": [{"name": "create_incident", "plugin": "high_output"}],
                },
            ]
        },
    )
    event = _event()
    decision = await engine.evaluate(event)
    assert isinstance(decision, RuleMatch)
    assert decision.rule_name == "high-priority"
    assert decision.priority == 10
    assert decision.summary == "High: web-01"
    assert decision.actions == ["high_output"]
    assert decision.window.duration_seconds == 60
    assert decision.window.trigger_threshold == 1
    assert decision.window.group_by == ["host"]


async def test_first_match_wins_stops_evaluation(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "first",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": "web-.*"},
                    "window": {
                        "duration_seconds": 60,
                        "group_by": ["host"],
                        "trigger_threshold": 1,
                    },
                    "output_summary": "First: {host}",
                    "actions": [
                        {"name": "create_incident", "plugin": "default_output"}
                    ],
                },
                {
                    "name": "second",
                    "priority": 20,
                    "match": {"severities": ["CRITICAL"], "host_pattern": "web-.*"},
                    "window": {
                        "duration_seconds": 60,
                        "group_by": ["host"],
                        "trigger_threshold": 1,
                    },
                    "output_summary": "Second: {host}",
                    "actions": [
                        {"name": "create_incident", "plugin": "default_output"}
                    ],
                },
            ]
        },
    )
    event = _event()
    decision = await engine.evaluate(event)
    assert isinstance(decision, RuleMatch)
    assert decision.rule_name == "first"
    assert decision.matched_rules == ["first"]


# ---------------------------------------------------------------------------
# RUL-04: matching by severity, host, service, and tags
# ---------------------------------------------------------------------------


async def test_match_by_severity(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "critical-only",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": ".*"},
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
        },
    )
    assert isinstance(
        await engine.evaluate(_event(severity=Severity.CRITICAL)), RuleMatch
    )
    assert isinstance(
        await engine.evaluate(_event(severity=Severity.WARNING)), NoOpDecision
    )


async def test_match_by_host_pattern(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "web-only",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": "web-.*"},
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
        },
    )
    assert isinstance(await engine.evaluate(_event(host="web-01")), RuleMatch)
    assert isinstance(await engine.evaluate(_event(host="db-01")), NoOpDecision)


async def test_match_by_service_pattern(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "http-only",
                    "priority": 10,
                    "match": {
                        "severities": ["CRITICAL"],
                        "host_pattern": ".*",
                        "service_pattern": "http",
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
        },
    )
    assert isinstance(await engine.evaluate(_event(service="http")), RuleMatch)
    assert isinstance(await engine.evaluate(_event(service="ssh")), NoOpDecision)
    assert isinstance(await engine.evaluate(_event(service=None)), NoOpDecision)


async def test_match_by_tag_equality(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "platform-only",
                    "priority": 10,
                    "match": {
                        "severities": ["CRITICAL"],
                        "host_pattern": ".*",
                        "tags": {"team.name": "platform"},
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
        },
    )
    assert isinstance(
        await engine.evaluate(_event(tags={"team.name": "platform"})), RuleMatch
    )
    assert isinstance(
        await engine.evaluate(_event(tags={"team.name": "sre"})), NoOpDecision
    )


async def test_match_with_empty_tags_criteria_matches_any_tags(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "any-tags",
                    "priority": 10,
                    "match": {
                        "severities": ["CRITICAL"],
                        "host_pattern": ".*",
                        "tags": {},
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
        },
    )
    assert isinstance(await engine.evaluate(_event(tags={"a": "b"})), RuleMatch)


async def test_match_requires_all_tag_criteria(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "multi-tag",
                    "priority": 10,
                    "match": {
                        "severities": ["CRITICAL"],
                        "host_pattern": ".*",
                        "tags": {"team.name": "platform", "topology.site": "dc1"},
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
        },
    )
    assert isinstance(
        await engine.evaluate(
            _event(tags={"team.name": "platform", "topology.site": "dc1"})
        ),
        RuleMatch,
    )
    assert isinstance(
        await engine.evaluate(_event(tags={"team.name": "platform"})), NoOpDecision
    )


# ---------------------------------------------------------------------------
# RUL-05: group key generation
# ---------------------------------------------------------------------------


async def test_group_key_uses_ordered_field_segments(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "group-test",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": ".*"},
                    "window": {
                        "duration_seconds": 60,
                        "group_by": ["topology.site", "service"],
                        "trigger_threshold": 1,
                    },
                    "output_summary": "x",
                    "actions": [
                        {"name": "create_incident", "plugin": "default_output"}
                    ],
                }
            ]
        },
    )
    decision = await engine.evaluate(
        _event(service="http", tags={"topology.site": "dc1"})
    )
    assert isinstance(decision, RuleMatch)
    assert decision.group_key == "topology.site=dc1|service=http"


async def test_group_key_uses_host_when_configured(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "host-group",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": ".*"},
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
        },
    )
    decision = await engine.evaluate(_event(host="web-01"))
    assert isinstance(decision, RuleMatch)
    assert decision.group_key == "host=web-01"


async def test_missing_group_by_field_prevents_match(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "needs-site",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": ".*"},
                    "window": {
                        "duration_seconds": 60,
                        "group_by": ["topology.site"],
                        "trigger_threshold": 1,
                    },
                    "output_summary": "x",
                    "actions": [
                        {"name": "create_incident", "plugin": "default_output"}
                    ],
                }
            ]
        },
    )
    decision = await engine.evaluate(_event(tags={"other": "value"}))
    assert isinstance(decision, NoOpDecision)
    assert "missing" in decision.reason.lower()


async def test_group_key_with_none_service_omits_segment(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "host-only",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": ".*"},
                    "window": {
                        "duration_seconds": 60,
                        "group_by": ["host", "service"],
                        "trigger_threshold": 1,
                    },
                    "output_summary": "x",
                    "actions": [
                        {"name": "create_incident", "plugin": "default_output"}
                    ],
                }
            ]
        },
    )
    # service is None for host alerts
    decision = await engine.evaluate(_event(service=None))
    assert isinstance(decision, NoOpDecision)
    assert "missing" in decision.reason.lower()


async def test_summary_uses_normalized_fields_before_same_named_tags(
    tmp_path: Path,
) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "summary",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": ".*"},
                    "window": {
                        "duration_seconds": 300,
                        "group_by": ["host"],
                        "trigger_threshold": 1,
                    },
                    "output_summary": "Host {host} from {team.name}",
                    "actions": [
                        {"name": "create_incident", "plugin": "default_output"}
                    ],
                }
            ]
        },
    )
    decision = await engine.evaluate(
        _event(tags={"host": "shadow-host", "team.name": "platform"})
    )

    assert isinstance(decision, RuleMatch)
    assert decision.summary == "Host web-01 from platform"


# ---------------------------------------------------------------------------
# D-16: no-match returns explicit no-op
# ---------------------------------------------------------------------------


async def test_no_match_returns_no_op_decision(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "db-only",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": "db-.*"},
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
        },
    )
    decision = await engine.evaluate(_event(host="web-01"))
    assert isinstance(decision, NoOpDecision)
    assert decision.matched_rules == []
    assert "no matching rule" in decision.reason.lower()


# ---------------------------------------------------------------------------
# D-04: recovery events bypass rule aggregation
# ---------------------------------------------------------------------------


async def test_recovery_event_returns_no_op(tmp_path: Path) -> None:
    engine = _build_engine(
        tmp_path,
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
        },
    )
    decision = await engine.evaluate(
        _event(event_type=EventType.RECOVERY, severity=Severity.OK)
    )
    assert isinstance(decision, NoOpDecision)
    assert "recovery" in decision.reason.lower()


# ---------------------------------------------------------------------------
# Task 3: group-key collision resistance
# ---------------------------------------------------------------------------
async def test_group_keys_are_collision_resistant_for_swapped_values(
    tmp_path: Path,
) -> None:
    engine = _build_engine(
        tmp_path,
        {
            "rules": [
                {
                    "name": "group-test",
                    "priority": 10,
                    "match": {"severities": ["CRITICAL"], "host_pattern": ".*"},
                    "window": {
                        "duration_seconds": 60,
                        "group_by": ["host", "service"],
                        "trigger_threshold": 1,
                    },
                    "output_summary": "x",
                    "actions": [
                        {"name": "create_incident", "plugin": "default_output"}
                    ],
                }
            ]
        },
    )
    decision_a = await engine.evaluate(_event(host="a", service="b"))
    decision_b = await engine.evaluate(_event(host="b", service="a"))
    assert isinstance(decision_a, RuleMatch)
    assert isinstance(decision_b, RuleMatch)
    assert decision_a.group_key != decision_b.group_key
    assert decision_a.group_key == "host=a|service=b"
    assert decision_b.group_key == "host=b|service=a"
