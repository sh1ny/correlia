from __future__ import annotations

import json
import os
import stat
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Literal, Mapping, TypeAlias, get_args

from prometheus_client import CONTENT_TYPE_LATEST as CONTENT_TYPE_LATEST
from prometheus_client import CollectorRegistry, Counter, Gauge, generate_latest

from app.domain.events import EventType
from app.domain.notifications import NotificationCategory

CompatibilityOperation: TypeAlias = Literal[
    "patch", "patch_acknowledge", "patch_close", "delete_close"
]
CompatibilityOutcome: TypeAlias = Literal[
    "success", "not_found", "invalid_status", "invalid_transition"
]
AuditOutcome: TypeAlias = Literal["success", "failure"]
MigrationReportStatus: TypeAlias = Literal[
    "disabled",
    "absent",
    "valid",
    "malformed",
    "oversized",
    "unsupported_version",
    "future_timestamp",
    "invalid_summary",
    "unsafe_file",
    "read_error",
]
MigrationOutcome: TypeAlias = Literal["success", "failure"]
MigrationFailureCode: TypeAlias = Literal[
    "none",
    "argument",
    "input_validation",
    "source_validation",
    "cataloged_incompatibility",
    "staged_validation",
    "promotion_failure",
]
PluginCategory: TypeAlias = Literal["email", "unknown"]
NotificationSubmissionOutcome: TypeAlias = Literal[
    "accepted",
    "missing_runner",
    "missing_plugin",
    "submit_failed",
]
NotificationDeliveryOutcome: TypeAlias = Literal["success", "failure"]
ReadinessState: TypeAlias = Literal["ready", "not_ready", "not_configured"]


ReadinessDependency: TypeAlias = Literal[
    "database",
    "settings",
    "rules_config",
    "topology_config",
    "plugin_registry",
    "plugins",
    "lifecycle_worker",
]


OutputPluginCategory: TypeAlias = Literal["email"]


READINESS_STATES = frozenset(get_args(ReadinessState))
READINESS_DEPENDENCIES = frozenset(get_args(ReadinessDependency))
OUTPUT_PLUGIN_CATEGORIES = frozenset(get_args(OutputPluginCategory))


MIGRATION_REPORT_MAX_BYTES = 65_536
MIGRATION_REPORT_VERSION = 1
MIGRATION_REPORT_MAX_ISSUE_COUNT = 1_000
MIGRATION_REPORT_MIN_COMPLETED_AT = datetime(2020, 1, 1, tzinfo=timezone.utc)

COMPATIBILITY_OPERATIONS = frozenset(get_args(CompatibilityOperation))
COMPATIBILITY_OUTCOMES = frozenset(get_args(CompatibilityOutcome))
AUDIT_OUTCOMES = frozenset(get_args(AuditOutcome))
MIGRATION_REPORT_STATUSES = frozenset(get_args(MigrationReportStatus))
MIGRATION_OUTCOMES = frozenset(get_args(MigrationOutcome))
MIGRATION_FAILURE_CODES = frozenset(get_args(MigrationFailureCode))

MIGRATION_REPORT_DOMAINS = frozenset(
    ("inputs", "rules", "topology", "plugins", "validation", "promotion")
)
MIGRATION_REPORT_ISSUE_CODES = frozenset(
    (
        "duplicate_flag",
        "invalid_input_path",
        "invalid_yaml",
        "invalid_source_document",
        "missing_top_level_wrapper",
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
        "validation_failure",
        "promotion_failure",
    )
)

EventRejectionCode: TypeAlias = Literal["rejected"]
IncidentEffect: TypeAlias = Literal[
    "acknowledged",
    "affected_set_shrunk",
    "closed",
    "expired",
    "inserted",
    "noop",
    "resolved",
    "updated",
]
TaskCategory: TypeAlias = Literal["handler"]

EVENT_REJECTION_CODE: EventRejectionCode = "rejected"
TASK_FAILURE_CATEGORY: TaskCategory = "handler"

EVENT_TYPES = frozenset(event_type.value for event_type in EventType)
EVENT_REJECTION_CODES = frozenset((EVENT_REJECTION_CODE,))
INCIDENT_EFFECTS = frozenset(get_args(IncidentEffect))
PLUGIN_CATEGORIES = frozenset(get_args(PluginCategory))
PLUGIN_LOAD_OUTCOMES = frozenset(("success",))
NOTIFICATION_SUBMISSION_OUTCOMES = frozenset(get_args(NotificationSubmissionOutcome))
NOTIFICATION_DELIVERY_OUTCOMES = frozenset(get_args(NotificationDeliveryOutcome))
NOTIFICATION_DELIVERY_CATEGORIES = frozenset(
    (
        "dispatched",
        "missing_plugin",
        "missing_incident",
        "plugin_exception",
        "dispatch_failed",
    )
)
TASK_CATEGORIES = frozenset((TASK_FAILURE_CATEGORY,))

# This is both the collector declaration inventory and the finite producer
# vocabulary. New collectors must declare their label domains here.
COLLECTOR_LABEL_DOMAINS: dict[str, dict[str, frozenset[str]]] = {
    "correlia_compatibility_mutations": {
        "operation": COMPATIBILITY_OPERATIONS,
        "outcome": COMPATIBILITY_OUTCOMES,
    },
    "correlia_audit_writes": {"outcome": AUDIT_OUTCOMES},
    "correlia_vigilo_migration_report_status": {"status": MIGRATION_REPORT_STATUSES},
    "correlia_vigilo_migration_report_outcome": {"outcome": MIGRATION_OUTCOMES},
    "correlia_vigilo_migration_report_failure_code": {"code": MIGRATION_FAILURE_CODES},
    "correlia_vigilo_migration_report_completed_timestamp_seconds": {},
    "correlia_events_accepted": {"event_type": EVENT_TYPES},
    "correlia_events_rejected": {"reason": EVENT_REJECTION_CODES},
    "correlia_matched_rules": {},
    "correlia_incident_effects": {"effect": INCIDENT_EFFECTS},
    "correlia_plugin_loads": {
        "category": PLUGIN_CATEGORIES,
        "outcome": PLUGIN_LOAD_OUTCOMES,
    },
    "correlia_notification_submissions": {
        "outcome": NOTIFICATION_SUBMISSION_OUTCOMES,
    },
    "correlia_notification_deliveries": {
        "category": NOTIFICATION_DELIVERY_CATEGORIES,
        "outcome": NOTIFICATION_DELIVERY_OUTCOMES,
    },
    "correlia_task_failures": {"task_category": TASK_CATEGORIES},
    "correlia_lifecycle_worker_healthy": {},
    "correlia_readiness_dependencies": {
        "dependency": READINESS_DEPENDENCIES,
        "state": READINESS_STATES,
    },
    "correlia_output_plugin_readiness": {
        "category": OUTPUT_PLUGIN_CATEGORIES,
        "state": READINESS_STATES,
    },
}

registry = CollectorRegistry()

_compatibility_mutations = Counter(
    "correlia_compatibility_mutations_total",
    "Compatibility mutation outcomes after durable commit.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_compatibility_mutations"]),
    registry=registry,
)
_audit_writes = Counter(
    "correlia_audit_writes_total",
    "Ingress-owned durable audit outcomes.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_audit_writes"]),
    registry=registry,
)
_migration_report_status = Gauge(
    "correlia_vigilo_migration_report_status",
    "Current migration report projection acquisition status.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_vigilo_migration_report_status"]),
    registry=registry,
)
_migration_report_outcome = Gauge(
    "correlia_vigilo_migration_report_outcome",
    "Last validated migration report outcome.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_vigilo_migration_report_outcome"]),
    registry=registry,
)
_migration_report_failure_code = Gauge(
    "correlia_vigilo_migration_report_failure_code",
    "Last validated migration report failure category.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_vigilo_migration_report_failure_code"]),
    registry=registry,
)
_migration_report_completed_timestamp_seconds = Gauge(
    "correlia_vigilo_migration_report_completed_timestamp_seconds",
    "Completion timestamp from the last validated migration report.",
    registry=registry,
)
_events_accepted = Counter(
    "correlia_events_accepted_total",
    "Accepted normalized events by event type.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_events_accepted"]),
    registry=registry,
)
_events_rejected = Counter(
    "correlia_events_rejected_total",
    "Rejected events by fixed rejection code.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_events_rejected"]),
    registry=registry,
)
_matched_rules = Counter(
    "correlia_matched_rules_total",
    "Rule evaluations that produced a match.",
    registry=registry,
)
_incident_effects = Counter(
    "correlia_incident_effects_total",
    "Incident durable mutation effects.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_incident_effects"]),
    registry=registry,
)
_plugin_loads = Counter(
    "correlia_plugin_loads_total",
    "Completed eager plugin registry loads by fixed output category.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_plugin_loads"]),
    registry=registry,
)
_notification_submissions = Counter(
    "correlia_notification_submissions_total",
    "Post-commit notification task submission outcomes.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_notification_submissions"]),
    registry=registry,
)
_notification_deliveries = Counter(
    "correlia_notification_deliveries_total",
    "Dispatcher-owned terminal notification delivery outcomes.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_notification_deliveries"]),
    registry=registry,
)
_task_failures = Counter(
    "correlia_task_failures_total",
    "Async task handler failures by fixed task category.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_task_failures"]),
    registry=registry,
)
_lifecycle_worker_healthy = Gauge(
    "correlia_lifecycle_worker_healthy",
    "1 when the lifecycle worker is healthy, 0 otherwise.",
    registry=registry,
)
_readiness_dependencies = Gauge(
    "correlia_readiness_dependencies",
    "Current required dependency readiness by fixed category.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_readiness_dependencies"]),
    registry=registry,
)
_output_plugin_readiness = Gauge(
    "correlia_output_plugin_readiness",
    "Current output-plugin readiness by fixed category.",
    tuple(COLLECTOR_LABEL_DOMAINS["correlia_output_plugin_readiness"]),
    registry=registry,
)


_migration_report_lock = Lock()
_migration_report_path: Path | None = None
_migration_report_status_value: MigrationReportStatus = "disabled"
_migration_report_summary: (
    tuple[MigrationOutcome, MigrationFailureCode, float] | None
) = None


def render_metrics() -> bytes:
    """Refresh the bounded migration projection and render one consistent scrape."""
    with _migration_report_lock:
        _refresh_migration_report_projection_locked()
        return generate_latest(registry)


def record_compatibility_mutation(
    operation: CompatibilityOperation,
    outcome: CompatibilityOutcome,
) -> None:
    _compatibility_mutations.labels(operation=operation, outcome=outcome).inc()


def record_audit_write(outcome: AuditOutcome) -> None:
    _audit_writes.labels(outcome=outcome).inc()


def configure_migration_report_projection(report_path: Path | None) -> None:
    """Set the read-only report source and clear any prior projection."""
    global \
        _migration_report_path, \
        _migration_report_status_value, \
        _migration_report_summary
    with _migration_report_lock:
        _migration_report_path = report_path
        _migration_report_status_value = "disabled" if report_path is None else "absent"
        _migration_report_summary = None
        _apply_migration_report_gauges()


def refresh_migration_report_projection() -> None:
    """Acquire one bounded migration-report snapshot for non-scrape callers."""
    with _migration_report_lock:
        _refresh_migration_report_projection_locked()


def _refresh_migration_report_projection_locked() -> None:
    """Acquire and publish one report snapshot while holding the projection lock."""
    global _migration_report_status_value, _migration_report_summary
    path = _migration_report_path
    if path is None:
        _migration_report_status_value = "disabled"
        _apply_migration_report_gauges()
        return
    status_value, summary = _read_migration_report_snapshot(path)
    _migration_report_status_value = status_value
    if summary is not None:
        _migration_report_summary = summary
    _apply_migration_report_gauges()


def _read_migration_report_snapshot(
    path: Path,
) -> tuple[
    MigrationReportStatus, tuple[MigrationOutcome, MigrationFailureCode, float] | None
]:
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        return "absent", None
    except OSError:
        return "unsafe_file", None
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            return "unsafe_file", None
        if metadata.st_size > MIGRATION_REPORT_MAX_BYTES:
            return "oversized", None
        data = os.read(descriptor, MIGRATION_REPORT_MAX_BYTES + 1)
    except OSError:
        return "read_error", None
    finally:
        os.close(descriptor)
    if len(data) > MIGRATION_REPORT_MAX_BYTES:
        return "oversized", None
    try:
        report = json.loads(data.decode("utf-8"))
    except UnicodeDecodeError, json.JSONDecodeError, RecursionError:
        return "malformed", None
    return _validate_migration_report(report)


def _validate_migration_report(
    report: object,
) -> tuple[
    MigrationReportStatus, tuple[MigrationOutcome, MigrationFailureCode, float] | None
]:
    if not isinstance(report, dict) or set(report) != {
        "ok",
        "errors",
        "generated",
        "metrics_summary",
    }:
        return "malformed", None
    if not isinstance(report["ok"], bool) or not isinstance(report["errors"], list):
        return "malformed", None
    generated = report["generated"]
    if generated is not None and (
        not isinstance(generated, dict)
        or set(generated) != {"rules", "topology", "plugins"}
        or not all(isinstance(value, str) for value in generated.values())
    ):
        return "malformed", None
    for issue in report["errors"]:
        if (
            not isinstance(issue, dict)
            or set(issue) != {"domain", "location", "code", "message", "requirement"}
            or issue.get("domain") not in MIGRATION_REPORT_DOMAINS
            or issue.get("code") not in MIGRATION_REPORT_ISSUE_CODES
            or not all(isinstance(value, str) for value in issue.values())
        ):
            return "invalid_summary", None
    if (report["ok"] and (generated is None or report["errors"])) or (
        not report["ok"] and generated is not None
    ):
        return "malformed", None
    summary = report["metrics_summary"]
    if not isinstance(summary, dict) or set(summary) != {
        "version",
        "outcome",
        "failure_code",
        "issue_count",
        "issues_truncated",
        "completed_at",
    }:
        return "invalid_summary", None
    if summary["version"] != MIGRATION_REPORT_VERSION:
        return "unsupported_version", None
    outcome = summary["outcome"]
    failure_code = summary["failure_code"]
    issue_count = summary["issue_count"]
    emitted_issue_count = len(report["errors"])
    if (
        outcome not in MIGRATION_OUTCOMES
        or failure_code not in MIGRATION_FAILURE_CODES
        or not isinstance(issue_count, int)
        or isinstance(issue_count, bool)
        or not 0 <= issue_count <= MIGRATION_REPORT_MAX_ISSUE_COUNT
        or not isinstance(summary["issues_truncated"], bool)
        or not isinstance(summary["completed_at"], str)
        or (outcome == "success") != report["ok"]
        or (outcome == "success" and failure_code != "none")
        or (outcome == "failure" and failure_code == "none")
        or emitted_issue_count > issue_count
        or (
            summary["issues_truncated"]
            and issue_count < MIGRATION_REPORT_MAX_ISSUE_COUNT
            and emitted_issue_count == issue_count
        )
        or (
            not summary["issues_truncated"]
            and issue_count != emitted_issue_count
        )
    ):
        return "invalid_summary", None
    try:
        completed_at = datetime.fromisoformat(
            summary["completed_at"].replace("Z", "+00:00")
        )
    except ValueError:
        return "invalid_summary", None
    if (
        completed_at.tzinfo is None
        or completed_at < MIGRATION_REPORT_MIN_COMPLETED_AT
        or completed_at > datetime.now(timezone.utc)
    ):
        return "future_timestamp", None
    return "valid", (outcome, failure_code, completed_at.timestamp())


def _apply_migration_report_gauges() -> None:
    for status_value in MIGRATION_REPORT_STATUSES:
        _migration_report_status.labels(status=status_value).set(
            1 if status_value == _migration_report_status_value else 0
        )
    if _migration_report_summary is None:
        for outcome in MIGRATION_OUTCOMES:
            _migration_report_outcome.labels(outcome=outcome).set(0)
        for failure_code in MIGRATION_FAILURE_CODES:
            _migration_report_failure_code.labels(code=failure_code).set(0)
        _migration_report_completed_timestamp_seconds.set(0)
        return
    outcome, failure_code, completed_at = _migration_report_summary
    for candidate in MIGRATION_OUTCOMES:
        _migration_report_outcome.labels(outcome=candidate).set(
            1 if candidate == outcome else 0
        )
    for candidate in MIGRATION_FAILURE_CODES:
        _migration_report_failure_code.labels(code=candidate).set(
            1 if candidate == failure_code else 0
        )
    _migration_report_completed_timestamp_seconds.set(completed_at)


_apply_migration_report_gauges()


def record_event_accepted(event_type: EventType) -> None:
    _events_accepted.labels(event_type=event_type.value).inc()


def record_event_rejected() -> None:
    _events_rejected.labels(reason=EVENT_REJECTION_CODE).inc()


def record_rule_matched() -> None:
    _matched_rules.inc()


def record_incident_effect(effect: IncidentEffect) -> None:
    _incident_effects.labels(effect=effect).inc()


def record_plugin_load(category: PluginCategory) -> None:
    _plugin_loads.labels(category=category, outcome="success").inc()


def record_notification_submission(outcome: NotificationSubmissionOutcome) -> None:
    _notification_submissions.labels(outcome=outcome).inc()


def record_notification_delivery(
    outcome: NotificationDeliveryOutcome, category: NotificationCategory
) -> None:
    _notification_deliveries.labels(category=category, outcome=outcome).inc()


def record_task_failure() -> None:
    _task_failures.labels(task_category=TASK_FAILURE_CATEGORY).inc()


def set_lifecycle_worker_healthy(healthy: bool) -> None:
    _lifecycle_worker_healthy.set(1 if healthy else 0)


def record_readiness_evaluation(
    dependencies: Mapping[str, str],
    output_plugins: Mapping[str, str],
) -> None:
    """Project one readiness evaluation onto closed dependency/category gauges."""
    for dependency in READINESS_DEPENDENCIES:
        state = dependencies.get(dependency)
        normalized_state = state if state in READINESS_STATES else "not_ready"
        for candidate in READINESS_STATES:
            _readiness_dependencies.labels(dependency=dependency, state=candidate).set(
                1 if candidate == normalized_state else 0
            )
    for category in OUTPUT_PLUGIN_CATEGORIES:
        state = output_plugins.get(category)
        normalized_state = state if state in READINESS_STATES else "not_ready"
        for candidate in READINESS_STATES:
            _output_plugin_readiness.labels(category=category, state=candidate).set(
                1 if candidate == normalized_state else 0
            )
