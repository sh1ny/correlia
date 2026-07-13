from __future__ import annotations

import io
import json
import logging
from collections.abc import Mapping
from pathlib import Path
from typing import Any
import pytest


from app.processing.logging import JsonFormatter, operational_log_extra, safe_log_extra
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
    assert set(payload) == {"ts", "level", "logger", "msg", "event"}
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
        if (
            "logger.exception(" in source
            or "exc_info=True" in source
            or "exc_info=(" in source
        ):
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


def test_operational_event_schema_drops_hostile_compatibility_values() -> None:
    payload = _format_record(
        **operational_log_extra(
            event="compatibility_mutation",
            operation="patch_acknowledge",
            outcome="success",
            incident_id="incident-secret",
            route="/v1/incidents/incident-secret",
            reason="password=secret",
            count="not-an-int",
        )
    )

    assert payload["event"] == "compatibility_mutation"
    assert payload["operation"] == "patch_acknowledge"
    assert payload["outcome"] == "success"
    assert set(payload) == {
        "ts",
        "level",
        "logger",
        "msg",
        "event",
        "operation",
        "outcome",
    }
    assert "incident-secret" not in json.dumps(payload)
    assert "password=secret" not in json.dumps(payload)


def test_compatibility_outcomes_use_fixed_metrics_and_identifier_free_events(
    caplog: pytest.LogCaptureFixture,
) -> None:
    from app.api.routers.incidents import _record_compatibility_outcome
    from app.processing.metrics import render_metrics

    caplog.set_level(logging.INFO)
    _record_compatibility_outcome("patch_acknowledge", "success")
    _record_compatibility_outcome("patch_close", "invalid_transition")
    _record_compatibility_outcome("delete_close", "not_found")

    events = [
        record.__dict__
        for record in caplog.records
        if record.__dict__.get("event") == "compatibility_mutation"
    ]
    assert [(event["operation"], event["outcome"]) for event in events] == [
        ("patch_acknowledge", "success"),
        ("patch_close", "invalid_transition"),
        ("delete_close", "not_found"),
    ]
    assert all(
        set(event).isdisjoint({"incident_id", "operator", "reason", "route"})
        for event in events
    )
    metrics = render_metrics().decode()
    assert (
        'correlia_compatibility_mutations_total{operation="patch_acknowledge",outcome="success"} 1.0'
        in metrics
    )


def test_plugin_lifecycle_operational_events_drop_identifier_and_exception_fields() -> (
    None
):
    plugin_load = _format_record(
        **operational_log_extra(
            event="plugin_load",
            outcome="failure",
            category="email",
            failure_code="constructor",
            entry_position=2,
            plugin_name="hostile-plugin",
            class_path="app.plugins.outputs.secret.Plugin",
            exception_type="SecretFailure",
            endpoint="smtp://secret",
        )
    )
    submission = _format_record(
        **operational_log_extra(
            event="notification_submission",
            outcome="accepted",
            plugin_name="hostile-plugin",
        )
    )
    delivery = _format_record(
        **operational_log_extra(
            event="notification_delivery",
            outcome="failure",
            category="plugin_exception",
            incident_id="incident-secret",
            plugin_name="hostile-plugin",
            exception_type="SecretFailure",
        )
    )

    assert set(plugin_load) == {
        "ts",
        "level",
        "logger",
        "msg",
        "event",
        "outcome",
        "category",
        "failure_code",
        "entry_position",
    }
    assert set(submission) == {"ts", "level", "logger", "msg", "event", "outcome"}
    assert set(delivery) == {
        "ts",
        "level",
        "logger",
        "msg",
        "event",
        "outcome",
        "category",
    }
    serialized = json.dumps((plugin_load, submission, delivery))
    for forbidden in (
        "hostile-plugin",
        "secret.Plugin",
        "SecretFailure",
        "smtp://secret",
    ):
        assert forbidden not in serialized


def test_readiness_event_schema_is_finite_and_drops_hostile_details() -> None:
    payload = _format_record(
        **operational_log_extra(
            event="readiness",
            category="email",
            state="not_ready",
            plugin_name="hostile-plugin",
            status="smtp://user:password@secret-host/token-secret",
            exception_type="SecretFailure",
            endpoint="smtp://secret",
        )
    )

    assert set(payload) == {
        "ts",
        "level",
        "logger",
        "msg",
        "event",
        "category",
        "state",
    }
    assert payload["event"] == "readiness"
    assert payload["category"] == "email"
    assert payload["state"] == "not_ready"
    serialized = json.dumps(payload)
    for forbidden in (
        "hostile-plugin",
        "password",
        "token-secret",
        "SecretFailure",
        "smtp://",
    ):
        assert forbidden not in serialized
