from __future__ import annotations

import io
import json
import logging
from collections.abc import Mapping
from pathlib import Path
from typing import Any


from app.processing.logging import JsonFormatter, safe_log_extra
from app.processing.task_runner import AsyncIOTaskRunner


FORBIDDEN_FRAGMENTS = (
    "raw_payload",
    "plugin_options",
    "password",
    "token-secret",
    "smtp transcript",
    "Traceback",
    "secret exception",
)


def _format_record(**extra: object) -> dict[str, object]:
    formatter = JsonFormatter()
    record = logging.LogRecord(
        name="correlia.test",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg="synthetic event",
        args=(),
        exc_info=None,
    )
    for key, value in extra.items():
        setattr(record, key, value)
    return json.loads(formatter.format(record))


def test_json_formatter_outputs_only_safe_keys() -> None:
    payload = _format_record(
        **safe_log_extra(
            event="incident_upserted",
            incident_id="01890f7a-0000-4000-8000-000000000001",
            rule_name="service-critical",
            group_key="service:http",
            status="OPEN",
            severity="CRITICAL",
            reason="threshold_crossed",
            category="dispatched",
            plugin_name="email-oncall",
            task_name="correlia:notify",
            count=2,
            exception_type="RuntimeError",
        ),
        raw_payload={"password": "token-secret"},
        plugin_options={"password": "token-secret"},
        password="token-secret",
    )

    assert payload["msg"] == "synthetic event"
    assert payload["event"] == "incident_upserted"
    assert payload["incident_id"] == "01890f7a-0000-4000-8000-000000000001"
    assert payload["rule_name"] == "service-critical"
    assert payload["group_key"] == "service:http"
    assert payload["count"] == 2
    for forbidden_key in ("raw_payload", "plugin_options", "password"):
        assert forbidden_key not in payload
    serialized = json.dumps(payload)
    for fragment in FORBIDDEN_FRAGMENTS:
        assert fragment not in serialized


async def test_task_failure_log_omits_stack_trace_and_secret_message() -> None:
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(JsonFormatter())
    logger = logging.getLogger("app.processing.task_runner")
    previous_handlers = list(logger.handlers)
    previous_propagate = logger.propagate
    logger.handlers = [handler]
    logger.propagate = False
    logger.setLevel(logging.INFO)

    runner = AsyncIOTaskRunner()

    async def boom(payload: Mapping[str, Any]) -> None:
        raise RuntimeError(f"secret exception {payload['secret']}")

    try:
        runner.register("notify", boom)
        await runner.submit("notify", {"secret": "token-secret"})
        await runner.drain()
    finally:
        logger.handlers = previous_handlers
        logger.propagate = previous_propagate

    lines = [line for line in stream.getvalue().splitlines() if line.strip()]
    assert lines
    payload = json.loads(lines[-1])
    assert payload["event"] == "task_failed"
    assert payload["task_name"] == "correlia:notify"
    assert payload["exception_type"] == "RuntimeError"
    serialized = json.dumps(payload)
    for fragment in FORBIDDEN_FRAGMENTS:
        assert fragment not in serialized


def test_phase_four_touched_sources_do_not_use_exception_logging() -> None:
    root = Path(__file__).resolve().parents[1]
    paths = [
        "app/processing/ingress.py",
        "app/processing/incident_manager.py",
        "app/processing/notification_dispatcher.py",
        "app/processing/task_runner.py",
        "app/processing/lifecycle.py",
        "app/processing/lifecycle_worker.py",
        "app/api/routers/incidents.py",
        "app/api/routers/ingress.py",
        "app/api/routers/health.py",
    ]
    offenders: dict[str, str] = {}
    for relative in paths:
        source = root.joinpath(relative).read_text()
        if "logger.exception(" in source or "exc_info=True" in source or "exc_info=(" in source:
            offenders[relative] = source
    assert offenders == {}


def test_rate_limit_log_omits_raw_token_and_authorization_header() -> None:
    payload = _format_record(
        **safe_log_extra(
            event="rate_limit_exceeded",
            route_class="operator",
            identity_hash="token_hash:abc123",
            limit=60,
            window_seconds=60,
            retry_after=30,
        ),
        authorization="Bearer secret-token",
    )
    assert payload["event"] == "rate_limit_exceeded"
    assert payload["route_class"] == "operator"
    assert payload["identity_hash"] == "token_hash:abc123"
    assert payload["limit"] == 60
    assert payload["retry_after"] == 30
    serialized = json.dumps(payload)
    assert "secret-token" not in serialized
    assert "authorization" not in serialized.lower()


def test_size_limit_log_omits_raw_body_and_authorization_header() -> None:
    payload = _format_record(
        **safe_log_extra(
            event="request_body_too_large",
            route_class="ingress",
            content_length=2048,
            limit=1024,
        ),
        authorization="Bearer secret-token",
        raw_body=b"secret payload",
    )
    assert payload["event"] == "request_body_too_large"
    assert payload["route_class"] == "ingress"
    assert payload["content_length"] == 2048
    assert payload["limit"] == 1024
    serialized = json.dumps(payload)
    assert "secret-token" not in serialized
    assert "secret payload" not in serialized
    assert "authorization" not in serialized.lower()
