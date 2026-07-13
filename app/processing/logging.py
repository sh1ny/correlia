from __future__ import annotations

import json
import logging
from collections.abc import Mapping
from datetime import datetime, timezone

SAFE_LOG_KEYS = frozenset(
    {
        "event",
        "event_type",
        "incident_id",
        "rule_name",
        "group_key",
        "status",
        "severity",
        "reason",
        "category",
        "plugin_name",
        "task_name",
        "exception_type",
        "effect",
        "operator",
        "count",
        "matched_rule_count",
        "notification_count",
        "closure_count",
        "expired_count",
        "previous_host_count",
        "previous_service_count",
        "affected_object_removed",
        "healthy",
        "ready",
        "route_class",
        "identity_hash",
        "content_length",
        "retry_after",
        "limit",
        "window_seconds",
        "operation",
        "outcome",
        "failure_code",
        "issue_count",
        "issues_truncated",
        "entry_position",
        "state",
    }
)

_OPERATIONAL_EVENT_SCHEMAS: dict[str, dict[str, frozenset[object] | None]] = {
    "compatibility_mutation": {
        "event": frozenset(("compatibility_mutation",)),
        "operation": frozenset(
            ("patch", "patch_acknowledge", "patch_close", "delete_close")
        ),
        "outcome": frozenset(
            ("success", "not_found", "invalid_status", "invalid_transition")
        ),
    },
    "audit_write": {
        "event": frozenset(("audit_write",)),
        "outcome": frozenset(("success", "failure")),
    },
    "migration_terminal": {
        "event": frozenset(("migration_terminal",)),
        "outcome": frozenset(("success", "failure")),
        "failure_code": frozenset(
            (
                "none",
                "argument",
                "input_validation",
                "source_validation",
                "cataloged_incompatibility",
                "staged_validation",
                "promotion_failure",
                "report_emission",
            )
        ),
        "issue_count": None,
        "issues_truncated": frozenset((True, False)),
    },
    "plugin_load": {
        "event": frozenset(("plugin_load",)),
        "outcome": frozenset(("success", "failure")),
        "category": frozenset(("email", "unknown")),
        "failure_code": frozenset(
            (
                "none",
                "registry_entry",
                "module_or_class",
                "interface",
                "constructor",
                "status",
            )
        ),
        "entry_position": None,
    },
    "notification_submission": {
        "event": frozenset(("notification_submission",)),
        "outcome": frozenset(
            ("accepted", "missing_runner", "missing_plugin", "submit_failed")
        ),
    },
    "notification_delivery": {
        "event": frozenset(("notification_delivery",)),
        "outcome": frozenset(("success", "failure")),
        "category": frozenset(
            (
                "dispatched",
                "missing_plugin",
                "missing_incident",
                "plugin_exception",
                "dispatch_failed",
            )
        ),
    },
    "readiness": {
        "event": frozenset(("readiness",)),
        "category": frozenset(
            (
                "aggregate",
                "database",
                "settings",
                "rules_config",
                "topology_config",
                "plugin_registry",
                "plugins",
                "lifecycle_worker",
                "email",
            )
        ),
        "state": frozenset(("ready", "not_ready", "not_configured")),
    },
}

_RESERVED_LOG_KEYS = frozenset(logging.LogRecord("", 0, "", 0, "", (), None).__dict__)
_SCALAR_TYPES = (str, int, float, bool, type(None))


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "ts": _timestamp(record.created),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        payload.update(_filter_operational_event_fields(record.__dict__))
        return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def safe_log_extra(**fields: object) -> dict[str, object]:
    extra: dict[str, object] = {}
    for key, value in fields.items():
        if key not in SAFE_LOG_KEYS or key in _RESERVED_LOG_KEYS:
            continue
        if isinstance(value, _SCALAR_TYPES):
            extra[key] = value
        elif value is not None:
            extra[key] = str(value)
    return _filter_operational_event_fields(extra)


def operational_log_extra(**fields: object) -> dict[str, object]:
    """Return an exact, finite event payload for required operational events."""
    return _filter_operational_event_fields(fields)


def _filter_operational_event_fields(fields: Mapping[str, object]) -> dict[str, object]:
    event = fields.get("event")
    schema = _OPERATIONAL_EVENT_SCHEMAS.get(event) if isinstance(event, str) else None
    if schema is None:
        return {
            key: value
            for key, value in fields.items()
            if key in SAFE_LOG_KEYS
            and key not in _RESERVED_LOG_KEYS
            and isinstance(value, _SCALAR_TYPES)
        }
    filtered: dict[str, object] = {}
    for key, allowed_values in schema.items():
        value = fields.get(key)
        if allowed_values is None:
            max_value = 1_000 if key == "issue_count" else 100
            if (
                isinstance(value, int)
                and not isinstance(value, bool)
                and 0 <= value <= max_value
            ):
                filtered[key] = value
        elif value in allowed_values:
            filtered[key] = value
    return filtered


def configure_json_logging(level: str = "INFO") -> None:
    formatter = JsonFormatter()
    root = logging.getLogger()
    if not root.handlers:
        root.addHandler(logging.StreamHandler())
    for handler in root.handlers:
        handler.setFormatter(formatter)
    root.setLevel(level)


def _timestamp(created: float) -> str:
    return datetime.fromtimestamp(created, tz=timezone.utc).isoformat(
        timespec="milliseconds"
    )
