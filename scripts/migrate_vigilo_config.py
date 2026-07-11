#!/usr/bin/env python3
"""Standalone Vigilo/VDE-to-Correlia configuration migration CLI.

Translates supported Vigilo YAML shapes into strict Correlia `rules.yaml`,
`topology.yaml`, and `plugins.yaml`.  Fails closed on unsupported fields,
plaintext SMTP credentials, and un-mappable plugin types, producing a
structured JSON report and never promoting partial output.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import sys
import tempfile
from collections.abc import Iterator, Sequence
from datetime import datetime, timezone
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

# Allow direct invocation as `python scripts/migrate_vigilo_config.py`.
_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import yaml  # noqa: E402

from app.config.plugins import load_plugin_registry_config  # noqa: E402
from app.config.rules import _KNOWN_NORMALIZED_FIELDS, load_rules_config  # noqa: E402
from app.config.topology import load_topology_config  # noqa: E402
from app.domain.events import TagValue  # noqa: E402
from pydantic import TypeAdapter, ValidationError  # noqa: E402
from app.plugins.loader import load_plugin_registry  # noqa: E402


# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

_ALLOWED_EMAIL_CONFIG_KEYS = frozenset(
    {
        "smtp_host",
        "smtp_port",
        "from_address",
        "to_addresses",
        "subject_prefix",
        "use_tls",
    }
)
_CREDENTIAL_KEYS = frozenset({"smtp_username", "smtp_password", "username", "password"})
_EMAIL_MODULE = "app.plugins.outputs.email"
_EMAIL_SOURCE_CLASS = "EmailPlugin"
_EMAIL_TARGET_CLASS = "app.plugins.outputs.email.SmtpOutputPlugin"
_GLOB_METACHARS = frozenset({"*", "?", "[", "]"})
_TAG_KEY_RE = re.compile(r"^[a-z][a-z0-9_.-]*$")
_PLACEHOLDER_RE = re.compile(r"\{[^{}]*\}")
_VALID_PLACEHOLDER_RE = re.compile(r"^\{([a-zA-Z0-9_.-]+)\}$")
_ENV_VAR_PLACEHOLDER_RE = re.compile(r"\$\{[^}]*\}")
_ENV_KEY_PLACEHOLDER_RE = re.compile(r"\{env:[^}]*\}")
_TAG_VALUE_ADAPTER = TypeAdapter(TagValue)


def _is_valid_tag_value(value: str) -> bool:
    try:
        _TAG_VALUE_ADAPTER.validate_python(value)
    except ValidationError:
        return False
    return True


# -----------------------------------------------------------------------------
# Issue model
# -----------------------------------------------------------------------------


@dataclass(frozen=True)
class MigrationIssue:
    domain: str
    location: str
    code: str
    message: str
    requirement: str

    def to_json(self) -> dict[str, str]:
        return asdict(self)


UNSUPPORTED_FIELD_CATALOG_CODES: frozenset[str] = frozenset(
    {
        "unsupported_rule_min_hosts",
        "unsupported_rule_is_dc_level",
        "invalid_rule_severity",
        "invalid_rule_priority",
        "invalid_rule_tags",
        "invalid_rule_matcher",
        "duplicate_rule_priority",
        "empty_actions",
        "invalid_action_entry",
        "unsupported_tag_wildcard",
        "invalid_topology_tag_key",
        "unsupported_group_by",
        "unsupported_summary_placeholder",
        "missing_topology_target_tag",
        "unsupported_hostname_topology",
        "invalid_topology_section",
        "invalid_topology_value",
        "missing_subnet_field",
        "unsupported_plugin_section",
        "unsupported_plugin_type",
        "unsupported_plugin_class",
        "plaintext_smtp_credentials",
        "unsupported_plugin_option",
        "unknown_action_plugin",
        "invalid_input_path",
        "invalid_yaml",
        "invalid_source_document",
        "missing_top_level_wrapper",
    }
)


# -----------------------------------------------------------------------------
# CLI parsing
# -----------------------------------------------------------------------------


class DuplicateFlagError(Exception):
    """Raised when a single-path CLI flag is specified more than once."""

    def __init__(self, option_string: str) -> None:
        self.option_string = option_string


class ArgumentParseError(Exception):
    """Raised instead of printing unbounded argparse diagnostics."""


class _MigrationArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ArgumentParseError(message)


class _SingleUseAction(argparse.Action):
    """argparse action that rejects repeated occurrences of a single-path flag."""

    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: str | Sequence[Any] | None,
        option_string: str | None = None,
    ) -> None:
        if getattr(namespace, self.dest) is not self.default:
            raise DuplicateFlagError(option_string or self.dest)
        if option_string == "--report-path" and (
            not isinstance(values, str) or not values or values.startswith("-")
        ):
            parser.error("--report-path requires a non-option path value")
        setattr(namespace, self.dest, values)


def _build_parser() -> argparse.ArgumentParser:
    parser = _MigrationArgumentParser(
        description=(
            "Translate supported Vigilo/VDE YAML into strict Correlia config. "
            "Vigilo priorities are inverted to Correlia ascending ranks. "
            "Plaintext SMTP credentials are rejected."
        ),
    )
    parser.add_argument(
        "--rules",
        required=True,
        action=_SingleUseAction,
        help="Path to the Vigilo rules YAML file.",
    )
    parser.add_argument(
        "--topology",
        required=True,
        action=_SingleUseAction,
        help="Path to the Vigilo topology YAML file.",
    )
    parser.add_argument(
        "--plugins",
        required=True,
        action=_SingleUseAction,
        help="Path to the Vigilo plugins YAML file.",
    )
    parser.add_argument(
        "--out-dir",
        required=True,
        action=_SingleUseAction,
        help="Directory where generated YAML files will be written.",
    )
    parser.add_argument(
        "--report-path",
        action=_SingleUseAction,
        help="Optional path to write a JSON migration report.",
    )
    return parser


# -----------------------------------------------------------------------------
# Utility helpers
# -----------------------------------------------------------------------------


def _load_yaml(path: Path) -> Any:
    text = path.read_text()
    data = yaml.safe_load(text)
    if data is None:
        return {}
    return data


def _to_slug(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    if not slug:
        slug = "rule"
    return slug


def _unique_slugs(names: list[str]) -> list[str]:
    seen: dict[str, int] = {}
    result: list[str] = []
    for name in names:
        slug = _to_slug(name)
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        if count:
            slug = f"{slug}-{count}"
        result.append(slug)
    return result


def _to_correlia_tag_key(bare: str) -> str | None:
    if not bare:
        return None
    prefixed = f"topology.{bare}" if not bare.startswith("topology.") else bare
    if _TAG_KEY_RE.match(prefixed):
        return prefixed
    return None


def _has_glob_metachar(value: str) -> bool:
    return any(ch in _GLOB_METACHARS for ch in value)


def _extract_report_path(argv: Sequence[str] | None) -> Path | None:
    """Return a safe report destination only when pre-parse syntax is unambiguous."""
    if argv is None:
        argv = sys.argv[1:]
    for index, argument in enumerate(argv):
        if argument == "--report-path":
            if index + 1 == len(argv) or argv[index + 1].startswith("-"):
                return None
            return Path(argv[index + 1])
        if argument.startswith("--report-path="):
            value = argument.removeprefix("--report-path=")
            if not value or value.startswith("-"):
                return None
            return Path(value)
    return None


# -----------------------------------------------------------------------------
# Rule transforms
# -----------------------------------------------------------------------------


def _rewrite_match_tags(
    tags: dict[str, Any],
) -> tuple[dict[str, str], list[MigrationIssue]]:
    issues: list[MigrationIssue] = []
    rewritten: dict[str, str] = {}
    for key, value in tags.items():
        if not isinstance(key, str):
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"match.tags[{key}]",
                    code="invalid_topology_tag_key",
                    message=f"tag key '{key}' must be a string",
                    requirement="CFG-06",
                )
            )
            continue
        if not isinstance(value, str):
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"match.tags[{key}]",
                    code="unsupported_tag_wildcard",
                    message=f"tag value for '{key}' must be a string",
                    requirement="CFG-06",
                )
            )
            continue
        if _has_glob_metachar(value):
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"match.tags[{key}]",
                    code="unsupported_tag_wildcard",
                    message=f"tag value for '{key}' contains unsupported fnmatch metacharacters",
                    requirement="CFG-06",
                )
            )
            continue
        new_key = _to_correlia_tag_key(key)
        if new_key is None:
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"match.tags[{key}]",
                    code="invalid_topology_tag_key",
                    message=f"tag key '{key}' cannot be converted to a valid topology.* key",
                    requirement="CFG-06",
                )
            )
            continue
        rewritten[new_key] = value
    return rewritten, issues


def _rewrite_summary(
    summary: str, *, location: str = "output_summary"
) -> tuple[str, list[MigrationIssue]]:
    issues: list[MigrationIssue] = []

    def replacer(match: re.Match[str]) -> str:
        placeholder = match.group(0)
        valid = _VALID_PLACEHOLDER_RE.match(placeholder)
        if not valid:
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=location,
                    code="unsupported_summary_placeholder",
                    message=f"summary placeholder '{placeholder}' is not a valid identifier",
                    requirement="CFG-06",
                )
            )
            return placeholder
        name = valid.group(1)
        if name in _KNOWN_NORMALIZED_FIELDS:
            return placeholder
        prefixed = _to_correlia_tag_key(name)
        if prefixed is None:
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=location,
                    code="unsupported_summary_placeholder",
                    message=f"summary placeholder '{name}' is not a normalized field or valid topology key",
                    requirement="CFG-06",
                )
            )
            return placeholder
        return f"{{{prefixed}}}"

    rewritten = _PLACEHOLDER_RE.sub(replacer, summary)
    return rewritten, issues


def _rewrite_group_by(entries: list[Any]) -> tuple[list[str], list[MigrationIssue]]:
    issues: list[MigrationIssue] = []
    rewritten: list[str] = []
    for idx, entry in enumerate(entries):
        if not isinstance(entry, str):
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"window.group_by[{idx}]",
                    code="unsupported_group_by",
                    message="window.group_by entries must be strings",
                    requirement="CFG-06",
                )
            )
            continue
        if entry in _KNOWN_NORMALIZED_FIELDS:
            rewritten.append(entry)
            continue
        if entry == "rule_name":
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"window.group_by[{entry}]",
                    code="unsupported_group_by",
                    message="window.group_by value 'rule_name' is not supported",
                    requirement="CFG-06",
                )
            )
            continue
        prefixed = _to_correlia_tag_key(entry)
        if prefixed is None:
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"window.group_by[{entry}]",
                    code="unsupported_group_by",
                    message=f"window.group_by value '{entry}' is not a normalized field or valid topology key",
                    requirement="CFG-06",
                )
            )
            continue
        rewritten.append(prefixed)
    return rewritten, issues


def _preflight_rules(raw_rules: list[Any]) -> list[MigrationIssue]:
    issues: list[MigrationIssue] = []
    if not isinstance(raw_rules, list):
        issues.append(
            MigrationIssue(
                domain="rules",
                location="rules",
                code="invalid_rule_severity",
                message="rules must be a list",
                requirement="CFG-06",
            )
        )
        return issues

    priorities: list[int] = []
    for idx, rule in enumerate(raw_rules):
        loc = f"rules[{idx}]"
        if not isinstance(rule, dict):
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=loc,
                    code="invalid_rule_priority",
                    message="rule entry must be a mapping",
                    requirement="CFG-06",
                )
            )
            continue

        window = rule.get("window", {})
        if not isinstance(window, dict):
            window = {}
        if "min_hosts" in window:
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"{loc}.window.min_hosts",
                    code="unsupported_rule_min_hosts",
                    message="window.min_hosts is not supported",
                    requirement="CFG-06",
                )
            )
        if "is_dc_level" in rule:
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"{loc}.is_dc_level",
                    code="unsupported_rule_is_dc_level",
                    message="is_dc_level is not supported",
                    requirement="CFG-06",
                )
            )

        match_block = rule.get("match", {})
        if not isinstance(match_block, dict):
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"{loc}.match",
                    code="invalid_rule_severity",
                    message="match block must be a mapping",
                    requirement="CFG-06",
                )
            )
        else:
            severity = match_block.get("severity")
            if not isinstance(severity, list) or not severity:
                issues.append(
                    MigrationIssue(
                        domain="rules",
                        location=f"{loc}.match.severity",
                        code="invalid_rule_severity",
                        message="match.severity must be a non-empty list",
                        requirement="CFG-06",
                    )
                )

            if "host" in match_block and not isinstance(match_block["host"], str):
                issues.append(
                    MigrationIssue(
                        domain="rules",
                        location=f"{loc}.match.host",
                        code="invalid_rule_matcher",
                        message="match.host must be a string when present",
                        requirement="CFG-06",
                    )
                )

            service = match_block.get("service")
            if service is not None and not isinstance(service, str):
                issues.append(
                    MigrationIssue(
                        domain="rules",
                        location=f"{loc}.match.service",
                        code="invalid_rule_matcher",
                        message="match.service must be a string or null when present",
                        requirement="CFG-06",
                    )
                )

            tags = match_block.get("tags", {})
            if not isinstance(tags, dict):
                issues.append(
                    MigrationIssue(
                        domain="rules",
                        location=f"{loc}.match.tags",
                        code="invalid_rule_tags",
                        message="match.tags must be a mapping",
                        requirement="CFG-06",
                    )
                )
            else:
                _, tag_issues = _rewrite_match_tags(tags)
                for issue in tag_issues:
                    issues.append(
                        MigrationIssue(
                            domain=issue.domain,
                            location=f"{loc}.{issue.location}",
                            code=issue.code,
                            message=issue.message,
                            requirement=issue.requirement,
                        )
                    )

        priority = rule.get("priority")
        if priority is None:
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"{loc}.priority",
                    code="invalid_rule_priority",
                    message="priority is required and must be an integer",
                    requirement="CFG-06",
                )
            )
        elif isinstance(priority, bool) or not isinstance(priority, int):
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"{loc}.priority",
                    code="invalid_rule_priority",
                    message="priority must be an integer",
                    requirement="CFG-06",
                )
            )
        else:
            priorities.append(priority)

        raw_group_by = window.get("group_by", [])
        if isinstance(raw_group_by, list):
            _, group_issues = _rewrite_group_by(raw_group_by)
            for issue in group_issues:
                issues.append(
                    MigrationIssue(
                        domain=issue.domain,
                        location=f"{loc}.{issue.location}",
                        code=issue.code,
                        message=issue.message,
                        requirement=issue.requirement,
                    )
                )

        summary = rule.get("output_summary", "")
        if isinstance(summary, str):
            _, summary_issues = _rewrite_summary(
                summary, location=f"{loc}.output_summary"
            )
            issues.extend(summary_issues)

        actions = rule.get("actions", [])
        if actions == []:
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"{loc}.actions",
                    code="empty_actions",
                    message="empty actions are not supported",
                    requirement="CFG-06",
                )
            )
        elif isinstance(actions, list):
            for a_idx, action in enumerate(actions):
                if not isinstance(action, str):
                    issues.append(
                        MigrationIssue(
                            domain="rules",
                            location=f"{loc}.actions[{a_idx}]",
                            code="invalid_action_entry",
                            message="action entries must be strings",
                            requirement="CFG-06",
                        )
                    )
        else:
            issues.append(
                MigrationIssue(
                    domain="rules",
                    location=f"{loc}.actions",
                    code="invalid_action_entry",
                    message="actions must be a list of strings",
                    requirement="CFG-06",
                )
            )

    if len(priorities) != len(set(priorities)):
        seen = set()
        for p in priorities:
            if p in seen:
                issues.append(
                    MigrationIssue(
                        domain="rules",
                        location="rules",
                        code="duplicate_rule_priority",
                        message=f"duplicate priority: {p}",
                        requirement="CFG-06",
                    )
                )
                break
            seen.add(p)

    return issues


def _transform_rules(raw_rules: list[Any]) -> dict[str, Any]:
    sorted_rules = sorted(
        [r for r in raw_rules if isinstance(r, dict)],
        key=lambda r: int(r.get("priority", 0)),
        reverse=True,
    )
    output_rules: list[dict[str, Any]] = []
    for new_priority, rule in enumerate(sorted_rules, start=1):
        match_block = rule.get("match", {})
        if not isinstance(match_block, dict):
            match_block = {}

        if "host" in match_block and not isinstance(match_block["host"], str):
            raise ValueError("match.host must be a string when present")
        host_pattern = match_block.get("host", "*")
        service_pattern = match_block.get("service")
        if service_pattern is not None and not isinstance(service_pattern, str):
            raise ValueError("match.service must be a string or null when present")

        tags = match_block.get("tags", {})
        if not isinstance(tags, dict):
            raise ValueError("match.tags must be a mapping")
        rewritten_tags, _ = _rewrite_match_tags(tags)

        raw_window = rule.get("window", {})
        if not isinstance(raw_window, dict):
            raw_window = {}
        raw_group_by = raw_window.get("group_by", [])
        if not isinstance(raw_group_by, list):
            raw_group_by = []
        if any(not isinstance(entry, str) for entry in raw_group_by):
            raise ValueError("window.group_by entries must be strings")
        rewritten_group_by, _ = _rewrite_group_by(raw_group_by)

        summary = rule.get("output_summary", "")
        if not isinstance(summary, str):
            summary = ""
        rewritten_summary, _ = _rewrite_summary(summary)

        actions = rule.get("actions", [])
        if not isinstance(actions, list):
            actions = []
        action_objects = [
            {"name": "create_incident", "plugin": action}
            for action in actions
            if isinstance(action, str)
        ]

        output_rules.append(
            {
                "name": rule.get("name", f"rule-{new_priority}"),
                "priority": new_priority,
                "match": {
                    "severities": match_block.get("severity", []),
                    "host_pattern": fnmatch.translate(host_pattern),
                    "service_pattern": (
                        fnmatch.translate(service_pattern)
                        if service_pattern is not None
                        else None
                    ),
                    "tags": rewritten_tags,
                },
                "window": {
                    "duration_seconds": raw_window.get("duration_seconds", 60),
                    "group_by": rewritten_group_by,
                    "trigger_threshold": raw_window.get("trigger_threshold", 1),
                },
                "output_summary": rewritten_summary,
                "actions": action_objects,
            }
        )
    return {"rules": output_rules}


# -----------------------------------------------------------------------------
# Topology transforms
# -----------------------------------------------------------------------------


def _preflight_topology(raw_topology: dict[str, Any]) -> list[MigrationIssue]:
    issues: list[MigrationIssue] = []
    if not isinstance(raw_topology, dict):
        issues.append(
            MigrationIssue(
                domain="topology",
                location="topology_rules",
                code="unsupported_hostname_topology",
                message="topology_rules must be a mapping",
                requirement="CFG-06",
            )
        )
        return issues

    hostname_patterns = raw_topology.get("hostname_patterns", [])
    if not isinstance(hostname_patterns, list):
        issues.append(
            MigrationIssue(
                domain="topology",
                location="topology_rules.hostname_patterns",
                code="invalid_topology_section",
                message="topology_rules.hostname_patterns must be a list",
                requirement="CFG-06",
            )
        )
        hostname_patterns = []
    for idx, entry in enumerate(hostname_patterns):
        loc = f"topology_rules.hostname_patterns[{idx}]"
        if not isinstance(entry, dict):
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=loc,
                    code="unsupported_hostname_topology",
                    message="hostname pattern entry must be a mapping",
                    requirement="CFG-06",
                )
            )
            continue
        regex = entry.get("regex", "")
        if not isinstance(regex, str):
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=f"{loc}.regex",
                    code="invalid_topology_value",
                    message="hostname pattern regex must be a string",
                    requirement="CFG-06",
                )
            )
            continue
        if not regex:
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=f"{loc}.regex",
                    code="invalid_topology_value",
                    message="hostname pattern regex must be a non-empty string",
                    requirement="CFG-06",
                )
            )
            continue
        has_capture = False
        try:
            pattern = re.compile(regex)
            has_capture = pattern.groups > 0
        except re.error:
            pass

        tags = entry.get("tags", {})
        if not isinstance(tags, dict):
            if "tags" in entry:
                issues.append(
                    MigrationIssue(
                        domain="topology",
                        location=f"{loc}.tags",
                        code="invalid_topology_value",
                        message="hostname pattern tags must be a mapping",
                        requirement="CFG-06",
                    )
                )
            tags = {}
        has_literal_tags = bool(tags)

        if has_capture and "target_tag" not in entry:
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=loc,
                    code="missing_topology_target_tag",
                    message="hostname pattern with capture groups requires target_tag",
                    requirement="CFG-06",
                )
            )
        if not has_capture and not has_literal_tags:
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=loc,
                    code="unsupported_hostname_topology",
                    message="hostname pattern without capture groups must have literal tags",
                    requirement="CFG-06",
                )
            )

        target_tag = entry.get("target_tag")
        if has_capture and "target_tag" in entry and not isinstance(target_tag, str):
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=f"{loc}.target_tag",
                    code="invalid_topology_value",
                    message="hostname pattern target_tag must be a string",
                    requirement="CFG-06",
                )
            )
        elif isinstance(target_tag, str) and _to_correlia_tag_key(target_tag) is None:
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=f"{loc}.target_tag",
                    code="invalid_topology_tag_key",
                    message=f"target_tag '{target_tag}' cannot be converted to a valid topology.* key",
                    requirement="CFG-06",
                )
            )

        for tag_name, tag_value in tags.items():
            tag_location = f"{loc}.tags[{tag_name}]"
            if not isinstance(tag_name, str):
                issues.append(
                    MigrationIssue(
                        domain="topology",
                        location=tag_location,
                        code="invalid_topology_tag_key",
                        message="hostname pattern literal tag names must be strings",
                        requirement="CFG-06",
                    )
                )
                continue
            if not isinstance(tag_value, str):
                issues.append(
                    MigrationIssue(
                        domain="topology",
                        location=tag_location,
                        code="invalid_topology_value",
                        message="hostname pattern literal tag values must be strings",
                        requirement="CFG-06",
                    )
                )
            elif not _is_valid_tag_value(tag_value):
                issues.append(
                    MigrationIssue(
                        domain="topology",
                        location=tag_location,
                        code="invalid_topology_value",
                        message=(
                            "hostname pattern literal tag values must be non-empty strings "
                            "no longer than 256 characters"
                        ),
                        requirement="CFG-06",
                    )
                )
            if _to_correlia_tag_key(tag_name) is None:
                issues.append(
                    MigrationIssue(
                        domain="topology",
                        location=tag_location,
                        code="invalid_topology_tag_key",
                        message=f"tag name '{tag_name}' cannot be converted to a valid topology.* key",
                        requirement="CFG-06",
                    )
                )
    ip_subnets = raw_topology.get("ip_subnets", [])
    if not isinstance(ip_subnets, list):
        issues.append(
            MigrationIssue(
                domain="topology",
                location="topology_rules.ip_subnets",
                code="invalid_topology_section",
                message="topology_rules.ip_subnets must be a list",
                requirement="CFG-06",
            )
        )
        ip_subnets = []
    for idx, entry in enumerate(ip_subnets):
        loc = f"topology_rules.ip_subnets[{idx}]"
        if not isinstance(entry, dict):
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=loc,
                    code="missing_subnet_field",
                    message="subnet entry must be a mapping",
                    requirement="CFG-06",
                )
            )
            continue
        for field in ("cidr", "value", "target_tag"):
            if field not in entry:
                issues.append(
                    MigrationIssue(
                        domain="topology",
                        location=f"{loc}.{field}",
                        code="missing_subnet_field",
                        message=f"subnet entry missing required field '{field}'",
                        requirement="CFG-06",
                    )
                )
        target_tag = entry.get("target_tag")
        if "target_tag" in entry and not isinstance(target_tag, str):
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=f"{loc}.target_tag",
                    code="invalid_topology_value",
                    message="subnet target_tag must be a string",
                    requirement="CFG-06",
                )
            )
        elif isinstance(target_tag, str) and _to_correlia_tag_key(target_tag) is None:
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=f"{loc}.target_tag",
                    code="invalid_topology_tag_key",
                    message=f"target_tag '{target_tag}' cannot be converted to a valid topology.* key",
                    requirement="CFG-06",
                )
            )

        if "value" in entry and not isinstance(entry["value"], str):
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=f"{loc}.value",
                    code="invalid_topology_value",
                    message="subnet value must be a string",
                    requirement="CFG-06",
                )
            )
        elif "value" in entry and not _is_valid_tag_value(entry["value"]):
            issues.append(
                MigrationIssue(
                    domain="topology",
                    location=f"{loc}.value",
                    code="invalid_topology_value",
                    message="subnet values must be non-empty strings no longer than 256 characters",
                    requirement="CFG-06",
                )
            )
    return issues


def _transform_topology(raw_topology: dict[str, Any]) -> dict[str, Any]:
    hostname_patterns = raw_topology.get("hostname_patterns", [])
    if not isinstance(hostname_patterns, list):
        raise ValueError("topology_rules.hostname_patterns must be a list")
    ip_subnets = raw_topology.get("ip_subnets", [])
    if not isinstance(ip_subnets, list):
        raise ValueError("topology_rules.ip_subnets must be a list")

    hostname_names = [
        str(entry.get("name", f"hostname-{idx}"))
        for idx, entry in enumerate(hostname_patterns)
        if isinstance(entry, dict)
    ]
    hostname_ids = _unique_slugs(hostname_names)

    hostname_rules: list[dict[str, Any]] = []
    for idx, entry in enumerate(hostname_patterns):
        if not isinstance(entry, dict):
            continue
        regex = str(entry.get("regex", ""))
        rule_id = hostname_ids[idx]
        target_tag = entry.get("target_tag")
        tags = entry.get("tags", {})
        if not isinstance(tags, dict):
            tags = {}

        rewritten_tags = {}
        for key, value in tags.items():
            new_key = _to_correlia_tag_key(str(key))
            if new_key is not None:
                rewritten_tags[new_key] = str(value)

        try:
            pattern = re.compile(regex)
            has_capture = pattern.groups > 0
        except re.error:
            has_capture = False

        capture_groups: dict[str, int] = {}
        if has_capture and target_tag is not None:
            prefixed = _to_correlia_tag_key(str(target_tag))
            if prefixed is not None:
                capture_groups[prefixed] = 1

        rule: dict[str, Any] = {
            "id": rule_id,
            "name": entry.get("name", rule_id),
            "hostname_pattern": regex,
            "tags": rewritten_tags,
        }
        if capture_groups:
            rule["tag_capture_groups"] = capture_groups
        hostname_rules.append(rule)

    subnet_names = [
        str(entry.get("target_tag", f"subnet-{idx}"))
        for idx, entry in enumerate(ip_subnets)
        if isinstance(entry, dict)
    ]
    subnet_ids = _unique_slugs(subnet_names)

    subnet_rules: list[dict[str, Any]] = []
    for idx, entry in enumerate(ip_subnets):
        if not isinstance(entry, dict):
            continue
        rule_id = subnet_ids[idx]
        target_tag = str(entry.get("target_tag", ""))
        value = str(entry.get("value", ""))
        prefixed = _to_correlia_tag_key(target_tag)
        tags = {prefixed: value} if prefixed is not None else {}
        subnet_rules.append(
            {
                "id": rule_id,
                "name": entry.get("name", rule_id),
                "subnet": str(entry.get("cidr", "")),
                "tags": tags,
            }
        )

    return {"hostname_rules": hostname_rules, "subnet_rules": subnet_rules}


# -----------------------------------------------------------------------------
# Plugin transforms
# -----------------------------------------------------------------------------
def _iter_unsupported_placeholders(
    value: Any, location: str
) -> Iterator[tuple[str, str]]:
    """Yield (location, description) for unsupported ${...} or {env: ...} forms.

    Recurses through lists and mappings only under allowed email option values.
    """
    if isinstance(value, str):
        if _ENV_VAR_PLACEHOLDER_RE.search(value):
            yield location, f"unsupported ${{...}} placeholder in value '{value}'"
        elif _ENV_KEY_PLACEHOLDER_RE.search(value):
            yield location, f"unsupported {{env: ...}} placeholder in value '{value}'"
    elif isinstance(value, dict):
        if "env" in value:
            yield f"{location}.env", "unsupported {env: ...} placeholder"
        else:
            for key, val in value.items():
                yield from _iter_unsupported_placeholders(val, f"{location}.{key}")
    elif isinstance(value, list):
        for idx, item in enumerate(value):
            yield from _iter_unsupported_placeholders(item, f"{location}[{idx}]")


def _preflight_plugins(raw_plugins: dict[str, Any]) -> list[MigrationIssue]:
    issues: list[MigrationIssue] = []
    if not isinstance(raw_plugins, dict):
        issues.append(
            MigrationIssue(
                domain="plugins",
                location="plugins",
                code="unsupported_plugin_section",
                message="plugins configuration must be a mapping",
                requirement="CFG-06",
            )
        )
        return issues

    for section in raw_plugins:
        if section != "outputs":
            issues.append(
                MigrationIssue(
                    domain="plugins",
                    location=f"plugins.{section}",
                    code="unsupported_plugin_section",
                    message=f"unsupported top-level plugin section '{section}'",
                    requirement="CFG-06",
                )
            )

    outputs = raw_plugins.get("outputs", {})
    if not isinstance(outputs, dict):
        issues.append(
            MigrationIssue(
                domain="plugins",
                location="plugins.outputs",
                code="unsupported_plugin_section",
                message="plugins.outputs must be a mapping",
                requirement="CFG-06",
            )
        )
        return issues

    for name, output in outputs.items():
        loc = f"plugins.outputs.{name}"
        # Reject placeholder syntax in the source output name so generated
        # plugins.yaml cannot carry ${...} or {env: ...} anywhere.
        for subloc, description in _iter_unsupported_placeholders(name, loc):
            issues.append(
                MigrationIssue(
                    domain="plugins",
                    location=subloc,
                    code="unsupported_plugin_option",
                    message=description,
                    requirement="CFG-06",
                )
            )
        if not isinstance(output, dict):
            issues.append(
                MigrationIssue(
                    domain="plugins",
                    location=loc,
                    code="unsupported_plugin_class",
                    message="output entry must be a mapping",
                    requirement="CFG-06",
                )
            )
            continue
        module = output.get("module", "")
        class_name = output.get("class", "")

        if module != _EMAIL_MODULE:
            if isinstance(module, str) and module.startswith("app.plugins.outputs."):
                issues.append(
                    MigrationIssue(
                        domain="plugins",
                        location=f"{loc}.module",
                        code="unsupported_plugin_type",
                        message=f"output type '{module}' is not supported; only email outputs are supported",
                        requirement="CFG-06",
                    )
                )
            else:
                issues.append(
                    MigrationIssue(
                        domain="plugins",
                        location=f"{loc}.module",
                        code="unsupported_plugin_class",
                        message=f"source module '{module}' cannot be mapped to {_EMAIL_TARGET_CLASS}",
                        requirement="CFG-06",
                    )
                )
            continue

        if class_name != _EMAIL_SOURCE_CLASS:
            issues.append(
                MigrationIssue(
                    domain="plugins",
                    location=f"{loc}.class",
                    code="unsupported_plugin_class",
                    message=f"source class '{class_name}' cannot be mapped to {_EMAIL_TARGET_CLASS}",
                    requirement="CFG-06",
                )
            )
            continue

        config = output.get("config", {})
        if not isinstance(config, dict):
            issues.append(
                MigrationIssue(
                    domain="plugins",
                    location=f"{loc}.config",
                    code="unsupported_plugin_option",
                    message="email output config must be a mapping",
                    requirement="CFG-06",
                )
            )
            continue
        for key in config:
            if key in _CREDENTIAL_KEYS:
                issues.append(
                    MigrationIssue(
                        domain="plugins",
                        location=f"{loc}.config.{key}",
                        code="plaintext_smtp_credentials",
                        message=f"plaintext SMTP credential key '{key}' is not allowed",
                        requirement="CFG-06",
                    )
                )
            elif key not in _ALLOWED_EMAIL_CONFIG_KEYS:
                issues.append(
                    MigrationIssue(
                        domain="plugins",
                        location=f"{loc}.config.{key}",
                        code="unsupported_plugin_option",
                        message=f"unsupported email plugin option '{key}'",
                        requirement="CFG-06",
                    )
                )
            else:
                if key == "use_tls" and not isinstance(config[key], bool):
                    issues.append(
                        MigrationIssue(
                            domain="plugins",
                            location=f"{loc}.config.use_tls",
                            code="unsupported_plugin_option",
                            message="use_tls must be a boolean",
                            requirement="CFG-06",
                        )
                    )
                else:
                    for subloc, description in _iter_unsupported_placeholders(
                        config[key], f"{loc}.config.{key}"
                    ):
                        issues.append(
                            MigrationIssue(
                                domain="plugins",
                                location=subloc,
                                code="unsupported_plugin_option",
                                message=description,
                                requirement="CFG-06",
                            )
                        )

    return issues


def _transform_plugins(raw_plugins: dict[str, Any]) -> dict[str, Any]:
    outputs = raw_plugins.get("outputs", {})
    if not isinstance(outputs, dict):
        raise ValueError("plugins.outputs must be a mapping")

    output_list: list[dict[str, Any]] = []
    for name, output in outputs.items():
        if not isinstance(output, dict):
            continue
        # Fail closed for direct callers even if preflight was bypassed.
        if list(_iter_unsupported_placeholders(name, "name")):
            raise ValueError(
                f"unsupported placeholder syntax in generated output name '{name}'"
            )

        config = output.get("config", {})
        if not isinstance(config, dict):
            raise ValueError(f"plugins.outputs.{name}.config must be a mapping")
        for key in config:
            if key in _ALLOWED_EMAIL_CONFIG_KEYS:
                if list(_iter_unsupported_placeholders(config[key], f"config.{key}")):
                    raise ValueError(
                        f"unsupported placeholder syntax in generated options for output '{name}'"
                    )

        options: dict[str, Any] = {
            "host": config.get("smtp_host", "localhost"),
            "port": config.get("smtp_port", 587),
            "from_address": config.get("from_address", "correlia@localhost"),
            "to_addresses": config.get("to_addresses", ["ops@localhost"]),
        }
        if "subject_prefix" in config:
            options["subject_prefix"] = config["subject_prefix"]
        if "use_tls" in config:
            use_tls = config["use_tls"]
            if not isinstance(use_tls, bool):
                raise ValueError("use_tls must be a boolean")
            options["start_tls"] = use_tls
        else:
            options["start_tls"] = True

        output_list.append(
            {
                "name": name,
                "plugin_type": "email",
                "class_path": _EMAIL_TARGET_CLASS,
                "options": options,
            }
        )

    return {"outputs": output_list}


def _extract_output_names(raw_plugins: dict[str, Any]) -> set[str]:
    if not isinstance(raw_plugins, dict):
        return set()
    outputs = raw_plugins.get("outputs", {})
    if not isinstance(outputs, dict):
        return set()
    return {name for name, output in outputs.items() if isinstance(output, dict)}


def _check_action_plugins_exist(
    raw_rules: list[Any], output_names: set[str]
) -> list[MigrationIssue]:
    issues: list[MigrationIssue] = []
    if not isinstance(raw_rules, list):
        return issues
    for idx, rule in enumerate(raw_rules):
        if not isinstance(rule, dict):
            continue
        actions = rule.get("actions", [])
        if not isinstance(actions, list):
            continue
        for a_idx, action in enumerate(actions):
            if not isinstance(action, str):
                continue
            if action not in output_names:
                issues.append(
                    MigrationIssue(
                        domain="rules",
                        location=f"rules[{idx}].actions[{a_idx}]",
                        code="unknown_action_plugin",
                        message=f"action plugin '{action}' is not defined in plugins.outputs",
                        requirement="CFG-06",
                    )
                )
    return issues


# -----------------------------------------------------------------------------
# Input path validation
# -----------------------------------------------------------------------------


def _validate_input_path(path: Path, flag: str) -> list[MigrationIssue]:
    issues: list[MigrationIssue] = []
    if any(ch in str(path) for ch in _GLOB_METACHARS):
        issues.append(
            MigrationIssue(
                domain="inputs",
                location=f"{flag}={path}",
                code="invalid_input_path",
                message=f"{flag} path contains glob metacharacters",
                requirement="CFG-06",
            )
        )
        return issues

    if path.suffix.lower() not in {".yaml", ".yml"}:
        issues.append(
            MigrationIssue(
                domain="inputs",
                location=f"{flag}={path}",
                code="invalid_input_path",
                message=f"{flag} path must end in .yaml or .yml",
                requirement="CFG-06",
            )
        )
        return issues

    if not path.exists():
        issues.append(
            MigrationIssue(
                domain="inputs",
                location=f"{flag}={path}",
                code="invalid_input_path",
                message=f"{flag} path does not exist",
                requirement="CFG-06",
            )
        )
    elif not path.is_file():
        issues.append(
            MigrationIssue(
                domain="inputs",
                location=f"{flag}={path}",
                code="invalid_input_path",
                message=f"{flag} path is not a regular file",
                requirement="CFG-06",
            )
        )

    return issues


def _nearest_existing_directory(path: Path) -> Path:
    """Return an existing ancestor so staging never creates output paths."""
    existing = path
    while not existing.exists():
        existing = existing.parent
    if not existing.is_dir():
        raise NotADirectoryError(f"staging parent is not a directory: {existing}")
    return existing


# -----------------------------------------------------------------------------
# Staging, validation, and promotion
# -----------------------------------------------------------------------------


def _write_yaml(path: Path, data: dict[str, Any]) -> None:
    path.write_text(yaml.safe_dump(data, sort_keys=True))


def _validate_staged(staging: Path) -> None:
    plugins_path = staging / "plugins.yaml"
    rules_path = staging / "rules.yaml"
    topology_path = staging / "topology.yaml"

    load_plugin_registry_config(plugins_path)
    # Instantiate the generated email plugin to catch option validation the
    # config loader alone does not enforce (e.g. TLS/credential rules).
    plugin_registry = load_plugin_registry(plugins_path)
    load_rules_config(rules_path, known_plugins=frozenset(plugin_registry.names))
    load_topology_config(topology_path)


def _promote(staging: Path, out_dir: Path) -> None:
    created_out_dir = not out_dir.exists()
    target_files = {
        "rules.yaml": staging / "rules.yaml",
        "topology.yaml": staging / "topology.yaml",
        "plugins.yaml": staging / "plugins.yaml",
    }

    backup_dir: str | None = None
    backed_up: dict[str, Path] = {}
    promoted: list[str] = []
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        backup_dir = tempfile.mkdtemp(prefix="migrate_backup_", dir=out_dir.parent)
        for name in target_files:
            target = out_dir / name
            if target.exists():
                backup = Path(backup_dir) / name
                shutil.copy2(str(target), str(backup))
                backed_up[name] = backup

        for name, source in target_files.items():
            os.replace(str(source), str(out_dir / name))
            promoted.append(name)
    except Exception:
        # Best-effort restore of any pre-existing files before re-raising.
        for name, backup in backed_up.items():
            shutil.copy2(str(backup), str(out_dir / name))
        # Remove newly-promoted files that had no pre-existing backup so the
        # out-dir is returned to its pre-promotion state.
        for name in promoted:
            if name not in backed_up:
                (out_dir / name).unlink(missing_ok=True)
        # Remove the output directory if we created it and it is now empty.
        if created_out_dir and out_dir.exists() and not any(out_dir.iterdir()):
            out_dir.rmdir()
        raise
    finally:
        if backup_dir is not None:
            shutil.rmtree(backup_dir, ignore_errors=True)


# -----------------------------------------------------------------------------
# Main entrypoint
# -----------------------------------------------------------------------------


_MIGRATION_SUMMARY_MAX_ISSUES = 1_000
_MIGRATION_SUMMARY_VERSION = 1


def _build_report(
    ok: bool,
    issues: list[MigrationIssue],
    out_dir: Path | None,
    *,
    failure_code: str,
) -> dict[str, Any]:
    issue_count = min(len(issues), _MIGRATION_SUMMARY_MAX_ISSUES)
    return {
        "ok": ok,
        "errors": [issue.to_json() for issue in issues],
        "generated": (
            {
                "rules": str(out_dir / "rules.yaml"),
                "topology": str(out_dir / "topology.yaml"),
                "plugins": str(out_dir / "plugins.yaml"),
            }
            if ok and out_dir is not None
            else None
        ),
        "metrics_summary": {
            "version": _MIGRATION_SUMMARY_VERSION,
            "outcome": "success" if ok else "failure",
            "failure_code": failure_code,
            "issue_count": issue_count,
            "issues_truncated": len(issues) > issue_count,
            "completed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        },
    }


def _write_report_atomically(report_path: Path, report: dict[str, Any]) -> None:
    """Publish one complete report or preserve the previously published file."""
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=report_path.parent,
            prefix=f".{report_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(report, temporary, sort_keys=True, separators=(",", ":"))
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, report_path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def _print_terminal(
    *,
    ok: bool,
    failure_code: str,
    issue_count: int,
    issues_truncated: bool,
) -> None:
    payload = {
        "event": "migration_terminal",
        "outcome": "success" if ok else "failure",
        "failure_code": failure_code,
        "issue_count": min(issue_count, _MIGRATION_SUMMARY_MAX_ISSUES),
        "issues_truncated": issues_truncated
        or issue_count > _MIGRATION_SUMMARY_MAX_ISSUES,
    }
    print(
        json.dumps(payload, sort_keys=True, separators=(",", ":")),
        file=sys.stdout if ok else sys.stderr,
    )


def _finish(
    *,
    report_path: Path | None,
    ok: bool,
    issues: list[MigrationIssue],
    out_dir: Path | None,
    failure_code: str,
    exit_code: int,
) -> int:
    report = _build_report(ok, issues, out_dir, failure_code=failure_code)
    if report_path is not None:
        try:
            _write_report_atomically(report_path, report)
        except OSError:
            _print_terminal(
                ok=False,
                failure_code="report_emission",
                issue_count=0,
                issues_truncated=False,
            )
            return 1
    _print_terminal(
        ok=ok,
        failure_code=failure_code,
        issue_count=len(issues),
        issues_truncated=len(issues) > _MIGRATION_SUMMARY_MAX_ISSUES,
    )
    return exit_code


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    pre_parsed_report_path = _extract_report_path(argv)
    try:
        args = parser.parse_args(argv)
    except ArgumentParseError:
        return _finish(
            report_path=pre_parsed_report_path,
            ok=False,
            issues=[],
            out_dir=None,
            failure_code="argument",
            exit_code=2,
        )
    except DuplicateFlagError as exc:
        return _finish(
            report_path=pre_parsed_report_path,
            ok=False,
            issues=[
                MigrationIssue(
                    domain="inputs",
                    location=f"flag={exc.option_string}",
                    code="duplicate_flag",
                    message=f"flag {exc.option_string!r} may only be specified once",
                    requirement="CFG-06",
                )
            ],
            out_dir=None,
            failure_code="argument",
            exit_code=1,
        )

    report_path = Path(args.report_path) if args.report_path is not None else None

    rules_path = Path(args.rules)
    topology_path = Path(args.topology)
    plugins_path = Path(args.plugins)
    out_dir = Path(args.out_dir)

    issues: list[MigrationIssue] = []
    issues.extend(_validate_input_path(rules_path, "--rules"))
    issues.extend(_validate_input_path(topology_path, "--topology"))
    issues.extend(_validate_input_path(plugins_path, "--plugins"))
    if issues:
        return _finish(
            report_path=report_path,
            ok=False,
            issues=issues,
            out_dir=None,
            failure_code="input_validation",
            exit_code=1,
        )

    raw_documents: dict[str, Any] = {}
    for domain, path in (
        ("rules", rules_path),
        ("topology", topology_path),
        ("plugins", plugins_path),
    ):
        try:
            raw_documents[domain] = _load_yaml(path)
        except OSError, yaml.YAMLError:
            issues.append(
                MigrationIssue(
                    domain=domain,
                    location=str(path),
                    code="invalid_yaml",
                    message="could not read or parse YAML",
                    requirement="CFG-06",
                )
            )
    if issues:
        return _finish(
            report_path=report_path,
            ok=False,
            issues=issues,
            out_dir=None,
            failure_code="source_validation",
            exit_code=1,
        )

    raw_rules = raw_documents["rules"]
    raw_topology = raw_documents["topology"]
    raw_plugins = raw_documents["plugins"]
    rules_list: Any = []
    topology_rules: Any = {}
    for domain, raw_document, wrapper in (
        ("rules", raw_rules, "rules"),
        ("topology", raw_topology, "topology_rules"),
    ):
        if not isinstance(raw_document, dict):
            issues.append(
                MigrationIssue(
                    domain=domain,
                    location=domain,
                    code="invalid_source_document",
                    message=f"{domain} source document must be a mapping",
                    requirement="CFG-06",
                )
            )
        elif wrapper not in raw_document:
            issues.append(
                MigrationIssue(
                    domain=domain,
                    location=wrapper,
                    code="missing_top_level_wrapper",
                    message=f"{domain} source document is missing top-level '{wrapper}'",
                    requirement="CFG-06",
                )
            )
        elif domain == "rules":
            rules_list = raw_document[wrapper]
        else:
            topology_rules = raw_document[wrapper]

    issues.extend(_preflight_rules(rules_list))
    issues.extend(_preflight_topology(topology_rules))
    issues.extend(_preflight_plugins(raw_plugins))
    issues.extend(
        _check_action_plugins_exist(rules_list, _extract_output_names(raw_plugins))
    )
    if issues:
        return _finish(
            report_path=report_path,
            ok=False,
            issues=issues,
            out_dir=None,
            failure_code="cataloged_incompatibility",
            exit_code=1,
        )

    transformed_rules = _transform_rules(rules_list)
    transformed_topology = _transform_topology(topology_rules)
    transformed_plugins = _transform_plugins(raw_plugins)
    staging = tempfile.mkdtemp(
        prefix="migrate_staging_",
        dir=_nearest_existing_directory(out_dir.parent),
    )
    try:
        staging_path = Path(staging)
        _write_yaml(staging_path / "rules.yaml", transformed_rules)
        _write_yaml(staging_path / "topology.yaml", transformed_topology)
        _write_yaml(staging_path / "plugins.yaml", transformed_plugins)
        try:
            _validate_staged(staging_path)
        except Exception:
            return _finish(
                report_path=report_path,
                ok=False,
                issues=[
                    MigrationIssue(
                        domain="validation",
                        location="staging",
                        code="validation_failure",
                        message="generated config failed validation",
                        requirement="CFG-07",
                    )
                ],
                out_dir=None,
                failure_code="staged_validation",
                exit_code=1,
            )
        try:
            _promote(staging_path, out_dir)
        except Exception:
            return _finish(
                report_path=report_path,
                ok=False,
                issues=[
                    MigrationIssue(
                        domain="promotion",
                        location="output",
                        code="promotion_failure",
                        message="generated config could not be promoted",
                        requirement="CFG-07",
                    )
                ],
                out_dir=None,
                failure_code="promotion_failure",
                exit_code=1,
            )
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    return _finish(
        report_path=report_path,
        ok=True,
        issues=[],
        out_dir=out_dir,
        failure_code="none",
        exit_code=0,
    )


if __name__ == "__main__":
    raise SystemExit(main())
