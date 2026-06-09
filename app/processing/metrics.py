from __future__ import annotations

from prometheus_client import CONTENT_TYPE_LATEST as CONTENT_TYPE_LATEST
from prometheus_client import CollectorRegistry, Counter, Gauge, generate_latest

registry = CollectorRegistry()

_events_accepted = Counter(
    "correlia_events_accepted_total",
    "Accepted normalized events by event type.",
    ("event_type",),
    registry=registry,
)
_events_rejected = Counter(
    "correlia_events_rejected_total",
    "Rejected events by bounded reason.",
    ("reason",),
    registry=registry,
)
_matched_rules = Counter(
    "correlia_matched_rules_total",
    "Rule evaluations that produced a match.",
    ("rule_name",),
    registry=registry,
)
_incident_effects = Counter(
    "correlia_incident_effects_total",
    "Incident durable mutation effects.",
    ("effect",),
    registry=registry,
)
_notification_attempts = Counter(
    "correlia_notification_attempts_total",
    "Notification attempts by plugin and bounded category.",
    ("plugin_name", "category"),
    registry=registry,
)
_notification_failures = Counter(
    "correlia_notification_failures_total",
    "Notification failures by plugin and bounded category.",
    ("plugin_name", "category"),
    registry=registry,
)
_task_failures = Counter(
    "correlia_task_failures_total",
    "Async task handler failures by task name.",
    ("task_name",),
    registry=registry,
)
_lifecycle_worker_healthy = Gauge(
    "correlia_lifecycle_worker_healthy",
    "1 when the lifecycle worker is healthy, 0 otherwise.",
    registry=registry,
)


def render_metrics() -> bytes:
    return generate_latest(registry)


def record_event_accepted(event_type: str) -> None:
    _events_accepted.labels(event_type=event_type).inc()


def record_event_rejected(reason: str) -> None:
    _events_rejected.labels(reason=reason).inc()


def record_rule_matched(rule_name: str) -> None:
    _matched_rules.labels(rule_name=rule_name).inc()


def record_incident_effect(effect: str) -> None:
    _incident_effects.labels(effect=effect).inc()


def record_notification_attempt(plugin_name: str, category: str) -> None:
    _notification_attempts.labels(plugin_name=plugin_name, category=category).inc()


def record_notification_failure(plugin_name: str, category: str) -> None:
    _notification_failures.labels(plugin_name=plugin_name, category=category).inc()


def record_task_failure(task_name: str) -> None:
    _task_failures.labels(task_name=task_name).inc()


def set_lifecycle_worker_healthy(healthy: bool) -> None:
    _lifecycle_worker_healthy.set(1 if healthy else 0)
