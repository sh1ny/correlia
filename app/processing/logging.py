from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Any

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
    }
)

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
        for key in SAFE_LOG_KEYS:
            value = record.__dict__.get(key)
            if isinstance(value, _SCALAR_TYPES):
                payload[key] = value
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
    return extra


def configure_json_logging(level: str = "INFO") -> None:
    formatter = JsonFormatter()
    root = logging.getLogger()
    if not root.handlers:
        root.addHandler(logging.StreamHandler())
    for handler in root.handlers:
        handler.setFormatter(formatter)
    root.setLevel(level)


def _timestamp(created: float) -> str:
    return datetime.fromtimestamp(created, tz=timezone.utc).isoformat(timespec="milliseconds")
