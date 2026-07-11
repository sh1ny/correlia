from pathlib import Path
import json
import asyncio
from datetime import datetime, timezone
from uuid import UUID, uuid4


from httpx import ASGITransport, AsyncClient
import pytest

from app.domain.events import EventType, NormalizedEvent, Severity
from app.domain.rules import RuleDecision, ThresholdDecision
from app.persistence.incidents import (
    IncidentAggregationWriteResult,
    LifecycleWriteResult,
)
from app.persistence.models import Incident
from app.processing.incident_manager import IncidentManager
from app.processing.ingress import Icinga2DecisionProcessor
from app.processing.lifecycle import LifecycleManager
from app.processing.lifecycle_worker import LifecycleWorker
from app.processing.notification_dispatcher import NotificationDispatcher
from app.processing.task_runner import AsyncIOTaskRunner


from app.main import create_app


FORBIDDEN_METRIC_LABELS = {
    "host",
    "service",
    "fingerprint",
    "group_key",
    "incident_id",
    "summary",
    "message",
    "raw_payload",
    "plugin_name",
}

pytestmark = pytest.mark.anyio


@pytest.fixture(autouse=True)
def _auth_env_for_metrics_tests(
    monkeypatch: pytest.MonkeyPatch, clean_settings_env: None
) -> None:
    monkeypatch.setenv(
        "DATABASE_URL", "postgresql+asyncpg://user:pass@localhost:5432/correlia"
    )
    monkeypatch.setenv("CORRELIA_OPERATOR_API_TOKEN", "operator-token")
    monkeypatch.setenv("CORRELIA_INGRESS_API_TOKEN", "ingress-token")
    monkeypatch.setenv("CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY", "test-audit-hmac")


@pytest.fixture(autouse=True)
def _reset_metrics_registry() -> None:
    """Keep assertions against the module-global Prometheus registry isolated."""
    import app.processing.metrics as metrics

    for collector in metrics.registry._collector_to_names:  # noqa: SLF001 - registry isolation
        labeled_children = getattr(collector, "_metrics", None)  # noqa: SLF001
        if labeled_children is not None:
            labeled_children.clear()
        else:
            collector._value.set(0)  # noqa: SLF001 - prometheus-client value seam
    metrics.configure_migration_report_projection(None)


class FakePlugin:
    def __init__(self, event: NormalizedEvent) -> None:
        self._event = event

    async def process_payload(self, payload: object) -> NormalizedEvent:
        return self._event


class FakeRuleEngine:
    def __init__(self, decision: RuleDecision) -> None:
        self._decision = decision

    async def evaluate(self, event: NormalizedEvent) -> RuleDecision:
        return self._decision


class FakeSession:
    async def commit(self) -> None:
        return None

    async def execute(self, statement: object) -> None:
        return None


class FakeSessionFactory:
    async def __aenter__(self) -> FakeSession:
        return FakeSession()

    async def __aexit__(self, *args: object) -> None:
        return None

    def __call__(self) -> "FakeSessionFactory":
        return self


class FakeRegistry:
    config_hash = "sha256:current"

    def get_plugin(self, name: str) -> object:
        raise KeyError(name)


def _event(event_type: EventType, *, severity: Severity) -> NormalizedEvent:
    return NormalizedEvent(
        fingerprint="fp-secret-value",
        source_id="icinga2:secret-source",
        host="db-secret-host",
        service="payments-api",
        severity=severity,
        event_type=event_type,
        timestamp=datetime(2026, 6, 9, 12, tzinfo=timezone.utc),
        tags={"team.name": "platform"},
        message="password=super-secret raw payload fragment",
    )


def _decision() -> RuleDecision:
    return RuleDecision(
        rule_name="critical-rule",
        priority=10,
        matched_rules=["critical-rule"],
        group_key="group-secret-value",
        threshold_decision=ThresholdDecision(
            rule_name="critical-rule",
            group_key="group-secret-value",
            window_start=datetime(2026, 6, 9, 11, 59, tzinfo=timezone.utc),
            window_end=datetime(2026, 6, 9, 12, tzinfo=timezone.utc),
            threshold=1,
            counted_fingerprints=["fp-secret-value"],
            counted=1,
            crossed=True,
        ),
        summary="do not expose this summary",
        actions=["email-oncall"],
    )


def _icinga2_payload_dict() -> dict[str, object]:
    return {
        "source_id": "icinga2:service:db-1:postgres",
        "host": "db-1",
        "service": "postgres",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": "2026-06-09T12:00:00+00:00",
        "check_output": "postgres is critical",
        "ip_address": "10.0.0.10",
        "tags": {"team.name": "platform"},
    }


def _incident(incident_id: UUID) -> Incident:
    now = datetime(2026, 6, 9, 12, tzinfo=timezone.utc)
    return Incident(
        id=incident_id,
        rule_name="critical-rule",
        group_key="group-secret-value",
        status="RESOLVED",
        severity="CRITICAL",
        summary="do not expose this summary",
        event_count=1,
        affected_hosts=[],
        affected_services=[],
        decision_context={},
        window_state={"window_seconds": 300},
        threshold_crossed=True,
        notified_at=None,
        start_time=now,
        last_update_time=now,
        acknowledged_at=None,
        acknowledged_by=None,
        resolved_at=now,
        closed_at=None,
    )


async def test_metrics_route_returns_prometheus_text() -> None:
    app = create_app()
    transport = ASGITransport(app=app)

    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/v1/metrics")

    assert response.status_code == 200
    content_type = response.headers["content-type"]
    assert content_type.startswith("text/plain")
    assert "version=0.0.4" in content_type or "version=1.0.0" in content_type
    body = response.text
    for metric_name in (
        "correlia_events_accepted_total",
        "correlia_events_rejected_total",
        "correlia_matched_rules_total",
        "correlia_incident_effects_total",
        "correlia_plugin_loads_total",
        "correlia_notification_submissions_total",
        "correlia_notification_deliveries_total",
        "correlia_task_failures_total",
        "correlia_lifecycle_worker_healthy",
    ):
        assert metric_name in body


async def test_every_metric_label_uses_a_code_owned_finite_domain() -> None:
    import app.processing.metrics as metrics

    observed_domains = {
        collector._name: set(getattr(collector, "_labelnames", ()))  # noqa: SLF001
        for collector in metrics.registry._collector_to_names  # noqa: SLF001 - collector audit
    }
    expected_domains = {
        name: set(labels) for name, labels in metrics.COLLECTOR_LABEL_DOMAINS.items()
    }
    assert observed_domains == expected_domains

    for metric_name, label_domains in metrics.COLLECTOR_LABEL_DOMAINS.items():
        for label_name, values in label_domains.items():
            assert values
            assert set(values).isdisjoint(FORBIDDEN_METRIC_LABELS)
            assert label_name not in FORBIDDEN_METRIC_LABELS

    # Supplemental declaration audit: metrics remain centralized, but the
    # collector/domain contract above is the behavior-bearing assertion.
    app_imports = [
        path
        for path in Path("app").rglob("*.py")
        if "prometheus_client" in path.read_text()
    ]
    assert app_imports == [Path("app/processing/metrics.py")]


async def test_readiness_gauges_use_exact_finite_dependency_and_plugin_domains() -> (
    None
):
    import app.processing.metrics as metrics

    metrics.record_readiness_evaluation(
        {
            "database": "ready",
            "settings": "ready",
            "rules_config": "not_ready",
            "topology_config": "ready",
            "plugin_registry": "ready",
            "plugins": "not_ready",
            "lifecycle_worker": "ready",
        },
        {"email": "not_ready"},
    )

    assert metrics.COLLECTOR_LABEL_DOMAINS["correlia_readiness_dependencies"] == {
        "dependency": metrics.READINESS_DEPENDENCIES,
        "state": metrics.READINESS_STATES,
    }
    assert metrics.COLLECTOR_LABEL_DOMAINS["correlia_output_plugin_readiness"] == {
        "category": metrics.OUTPUT_PLUGIN_CATEGORIES,
        "state": metrics.READINESS_STATES,
    }
    body = metrics.render_metrics().decode()
    for dependency, expected_state in (
        ("database", "ready"),
        ("settings", "ready"),
        ("rules_config", "not_ready"),
        ("topology_config", "ready"),
        ("plugin_registry", "ready"),
        ("plugins", "not_ready"),
        ("lifecycle_worker", "ready"),
    ):
        for state in metrics.READINESS_STATES:
            expected = 1.0 if state == expected_state else 0.0
            assert (
                f'correlia_readiness_dependencies{{dependency="{dependency}",state="{state}"}} {expected}'
                in body
            )
    for state in metrics.READINESS_STATES:
        expected = 1.0 if state == "not_ready" else 0.0
        assert (
            f'correlia_output_plugin_readiness{{category="email",state="{state}"}} {expected}'
            in body
        )


async def test_fixed_incident_effects_remain_countable() -> None:
    import app.processing.metrics as metrics

    for effect in metrics.INCIDENT_EFFECTS:
        metrics.record_incident_effect(effect)

    body = metrics.render_metrics().decode()
    for effect in metrics.INCIDENT_EFFECTS:
        assert f'correlia_incident_effects_total{{effect="{effect}"}} 1.0' in body


async def test_ingest_lifecycle_notification_and_worker_metrics_use_low_cardinality_labels(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import app.processing.ingress as ingress_module
    import app.processing.lifecycle as lifecycle_module
    import app.processing.notification_dispatcher as notification_module
    import app.processing.metrics as metrics
    import app.processing.incident_manager as incident_manager_module

    # The ingress now writes an audit row inside its own transaction and
    # builds the IncidentManager/LifecycleManager directly; the fake
    # session in this test cannot satisfy that path. Replace the audit
    # insert with a no-op so the metric-label assertions remain the focus.
    async def _noop_insert(*args: object, **kwargs: object) -> object:
        return None

    monkeypatch.setattr(ingress_module, "insert_incident_event", _noop_insert)

    from app.plugins.inputs.icinga2 import Icinga2Rejection
    from app.plugins.inputs.icinga2 import Icinga2WebhookPayload

    from app.persistence.incidents import (
        IncidentAggregationWriteResult,
        LifecycleWriteResult,
    )
    from app.processing import incident_manager as im_module
    from app.processing import lifecycle as lm_module

    class _NoopDbSession:
        def __init__(self) -> None:
            self.commits = 0
            self.flushes = 0

        async def commit(self) -> None:
            self.commits += 1

        async def flush(self) -> None:
            self.flushes += 1

        async def execute(self, *args: object, **kwargs: object) -> object:
            return _NoopResult()

        def add(self, obj: object) -> None:
            return None

        async def __aenter__(self) -> "_NoopDbSession":
            return self

        async def __aexit__(self, *args: object) -> None:
            return None

    class _NoopResult:
        def scalars(self) -> "_NoopScalars":
            return _NoopScalars()

        def all(self) -> tuple[object, ...]:
            return ()

        def first(self) -> object | None:
            return None

        def one(self) -> object:
            raise RuntimeError("no row")

        def mappings(self) -> object:
            return self

    class _NoopScalars:
        def all(self) -> tuple[object, ...]:
            return ()

        def __iter__(self) -> object:
            return iter(())

        async def __aiter__(self) -> "_NoopScalars":
            return self

        async def __anext__(self) -> object:
            raise StopAsyncIteration

    class _NoopSessionFactory:
        def __call__(self) -> "_NoopSessionFactory":
            return self

        async def __aenter__(self) -> _NoopDbSession:
            return _NoopDbSession()

        async def __aexit__(self, *args: object) -> None:
            return None

    # Monkeypatch the persistence-layer functions so the fake session
    # can satisfy the manager code paths.
    async def _fake_record_problem_incident(
        session: object, inp: object
    ) -> IncidentAggregationWriteResult:
        return IncidentAggregationWriteResult(
            incident=_incident(uuid4()),
            effect="inserted",
            replay=False,
            inside_window=True,
            counted=True,
            threshold_crossed=True,
            first_threshold_transition=True,
            counted_count=1,
            counted_fingerprints=("fp-secret-value",),
        )

    async def _fake_resolve_host_recovery(
        session: object,
        *,
        host: str,
        recovery_time: object,
        fingerprint: str,
        source_id: str,
    ) -> tuple[LifecycleWriteResult, ...]:
        inc = _incident(uuid4())
        inc.status = "RESOLVED"
        return (
            LifecycleWriteResult(
                incident=inc,
                effect="resolved",
                transitioned_to="RESOLVED",
                previous_host_count=1,
                previous_service_count=0,
                affected_object_removed=True,
            ),
        )

    async def _fake_resolve_service_recovery(
        session: object,
        *,
        host: str,
        service: str,
        recovery_time: object,
        fingerprint: str,
        source_id: str,
    ) -> tuple[LifecycleWriteResult, ...]:
        return ()

    async def _fake_record_notification_result(*args: object, **kwargs: object) -> bool:
        return True

    monkeypatch.setattr(
        ingress_module, "record_notification_result", _fake_record_notification_result
    )

    monkeypatch.setattr(
        im_module, "record_problem_incident", _fake_record_problem_incident
    )
    monkeypatch.setattr(lm_module, "resolve_host_recovery", _fake_resolve_host_recovery)
    monkeypatch.setattr(
        lm_module, "resolve_service_recovery", _fake_resolve_service_recovery
    )

    decision = _decision()
    problem_processor = Icinga2DecisionProcessor(
        FakePlugin(_event(EventType.PROBLEM, severity=Severity.CRITICAL)),
        rule_engine=FakeRuleEngine(decision),
        sessionmaker=_NoopSessionFactory(),
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )
    recovery_processor = Icinga2DecisionProcessor(
        FakePlugin(_event(EventType.RECOVERY, severity=Severity.OK)),
        rule_engine=FakeRuleEngine(decision),
        sessionmaker=_NoopSessionFactory(),
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )

    problem_payload = Icinga2WebhookPayload.model_validate(_icinga2_payload_dict())
    recovery_payload = Icinga2WebhookPayload.model_validate(_icinga2_payload_dict())
    await problem_processor.process_payload(problem_payload)
    await recovery_processor.process_payload(recovery_payload)

    class HostileRuleEngine:
        def __init__(self) -> None:
            self._index = 0

        async def evaluate(self, event: NormalizedEvent) -> RuleDecision:
            rule_name = f"hostile-rule-{self._index}-secret"
            self._index += 1
            return decision.model_copy(
                update={"matched_rules": [rule_name], "actions": []}
            )

    hostile_rule_processor = Icinga2DecisionProcessor(
        FakePlugin(_event(EventType.PROBLEM, severity=Severity.CRITICAL)),
        rule_engine=HostileRuleEngine(),
        sessionmaker=_NoopSessionFactory(),
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )
    for _ in range(200):
        await hostile_rule_processor.process_payload(problem_payload)

    class RejectedPlugin:
        async def process_payload(self, payload: object) -> Icinga2Rejection:
            return Icinga2Rejection(
                reason="hostile rejection: password=super-secret",
                source_id="hostile-source",
                host="hostile-host",
                service="hostile-service",
                state="CRITICAL",
                state_type="HARD",
            )

    rejected_processor = Icinga2DecisionProcessor(
        RejectedPlugin(),
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )
    await rejected_processor.process_payload(problem_payload)

    async def fake_record_problem_incident(
        *args: object, **kwargs: object
    ) -> IncidentAggregationWriteResult:
        return IncidentAggregationWriteResult(
            incident=_incident(uuid4()),
            effect="inserted",
            replay=False,
            inside_window=True,
            counted=True,
            threshold_crossed=True,
            first_threshold_transition=True,
            counted_count=1,
            counted_fingerprints=("fp-secret-value",),
        )

    monkeypatch.setattr(
        incident_manager_module,
        "record_problem_incident",
        fake_record_problem_incident,
    )
    await IncidentManager(FakeSession()).apply_problem(
        _event(EventType.PROBLEM, severity=Severity.CRITICAL),
        decision.model_copy(update={"actions": []}),
    )

    incident_id = uuid4()

    async def fake_resolve_host_recovery(
        *args: object, **kwargs: object
    ) -> tuple[LifecycleWriteResult, ...]:
        return (
            LifecycleWriteResult(
                incident=_incident(incident_id),
                effect="resolved",
                transitioned_to="RESOLVED",
                previous_host_count=1,
                previous_service_count=0,
                affected_object_removed=True,
            ),
        )

    monkeypatch.setattr(
        lifecycle_module, "resolve_host_recovery", fake_resolve_host_recovery
    )
    await LifecycleManager(FakeSession()).resolve_for_event(
        _event(EventType.RECOVERY, severity=Severity.OK).model_copy(
            update={"service": None}
        )
    )

    async def fake_record_notification_result(*args: object, **kwargs: object) -> bool:
        return False

    monkeypatch.setattr(
        notification_module,
        "record_notification_result",
        fake_record_notification_result,
    )
    dispatcher = NotificationDispatcher(FakeSessionFactory(), FakeRegistry())
    await dispatcher.process(
        {
            "incident_id": str(uuid4()),
            "plugin_name": "email-oncall",
            "config_hash": "sha256:stale",
        }
    )

    empty_registry_processor = Icinga2DecisionProcessor(
        FakePlugin(_event(EventType.PROBLEM, severity=Severity.CRITICAL)),
        task_runner=AsyncIOTaskRunner(),
        plugin_registry=object(),
        audit_raw_payload_max_bytes=1024,
        audit_raw_payload_hmac_key="test-audit-hmac",
    )
    await empty_registry_processor._submit_notifications(  # noqa: SLF001 - owning-path metric audit
        uuid4(),
        decision.model_copy(
            update={
                "actions": [f"hostile-plugin-{index}-secret" for index in range(200)]
            }
        ),
    )

    task_runner = AsyncIOTaskRunner()

    async def fail_task(payload: object) -> None:
        raise RuntimeError("password=super-secret")

    for task_name in (
        "notify",
        *(f"hostile-task-{index}-secret" for index in range(100)),
    ):
        task_runner.register(task_name, fail_task)
        await task_runner.submit(task_name, {})
    await task_runner.drain()
    await asyncio.sleep(0)

    async def successful_sweep(sessionmaker: object, limit: int) -> int:
        return 0

    worker = LifecycleWorker(
        sessionmaker=object(),
        interval_seconds=1,
        batch_size=1,
        sweep=successful_sweep,
    )
    await worker._run_sweep()  # noqa: SLF001 - worker health seam audit
    healthy_body = metrics.render_metrics().decode()
    assert "correlia_lifecycle_worker_healthy 1.0" in healthy_body

    async def failing_sweep(sessionmaker: object, limit: int) -> int:
        raise RuntimeError("token=super-secret")

    failing_worker = LifecycleWorker(
        sessionmaker=object(),
        interval_seconds=1,
        batch_size=1,
        sweep=failing_sweep,
    )
    await failing_worker._run_sweep()  # noqa: SLF001 - worker health seam audit

    body = metrics.render_metrics().decode()
    for expected in (
        'correlia_events_accepted_total{event_type="PROBLEM"}',
        'correlia_events_accepted_total{event_type="RECOVERY"}',
        'correlia_events_rejected_total{reason="rejected"} 1.0',
        "correlia_matched_rules_total 202.0",
        'correlia_incident_effects_total{effect="inserted"}',
        'correlia_incident_effects_total{effect="resolved"}',
        'correlia_notification_deliveries_total{category="dispatch_failed",outcome="failure"}',
        'correlia_notification_submissions_total{outcome="missing_plugin"} 200.0',
        'correlia_task_failures_total{task_category="handler"} 101.0',
        "correlia_lifecycle_worker_healthy 0.0",
    ):
        assert expected in body

    for secret_fragment in (
        "db-secret-host",
        "payments-api",
        "fp-secret-value",
        "group-secret-value",
        str(incident_id),
        "raw payload fragment",
        "super-secret",
        "hostile rejection",
        "hostile-rule-0-secret",
        "hostile-plugin-0-secret",
        "hostile-task-0-secret",
    ):
        assert secret_fragment not in body

    forbidden_source_values = (
        "event.host",
        "event.service",
        "event.fingerprint",
        "decision.group_key",
        "incident_id",
        "payload",
        "summary",
    )
    metric_call_names = (
        "record_event_accepted",
        "record_event_rejected",
        "record_rule_matched",
        "record_incident_effect",
        "record_notification_submission",
        "record_notification_delivery",
        "record_task_failure",
        "set_lifecycle_worker_healthy",
    )
    for path in (
        Path("app/processing/ingress.py"),
        Path("app/processing/incident_manager.py"),
        Path("app/processing/notification_dispatcher.py"),
        Path("app/processing/task_runner.py"),
        Path("app/processing/lifecycle.py"),
        Path("app/processing/lifecycle_worker.py"),
    ):
        for line in path.read_text().splitlines():
            if any(metric_call_name in line for metric_call_name in metric_call_names):
                for forbidden in forbidden_source_values:
                    assert forbidden not in line


async def test_migration_report_projection_is_bounded_and_retains_last_good(
    tmp_path: Path,
) -> None:
    import app.processing.metrics as metrics

    report_path = tmp_path / "migration-report.json"
    valid_report = {
        "ok": True,
        "errors": [],
        "generated": {
            "rules": "/private/rules.yaml",
            "topology": "/private/topology.yaml",
            "plugins": "/private/plugins.yaml",
        },
        "metrics_summary": {
            "version": 1,
            "outcome": "success",
            "failure_code": "none",
            "issue_count": 0,
            "issues_truncated": False,
            "completed_at": "2026-07-10T12:00:00+00:00",
        },
    }

    metrics.configure_migration_report_projection(None)
    metrics.refresh_migration_report_projection()
    assert 'correlia_vigilo_migration_report_status{status="disabled"} 1.0' in (
        metrics.render_metrics().decode()
    )

    report_path.write_text(json.dumps(valid_report))
    metrics.configure_migration_report_projection(report_path)
    metrics.refresh_migration_report_projection()
    body = metrics.render_metrics().decode()
    assert 'correlia_vigilo_migration_report_status{status="valid"} 1.0' in body
    assert 'correlia_vigilo_migration_report_outcome{outcome="success"} 1.0' in body
    assert 'correlia_vigilo_migration_report_failure_code{code="none"} 1.0' in body
    assert (
        "correlia_vigilo_migration_report_completed_timestamp_seconds 1.7836848e+09"
        in body
    )
    assert "/private/" not in body

    report_path.write_text('{"ok":true')
    metrics.refresh_migration_report_projection()
    body = metrics.render_metrics().decode()
    assert 'correlia_vigilo_migration_report_status{status="malformed"} 1.0' in body
    assert 'correlia_vigilo_migration_report_outcome{outcome="success"} 1.0' in body
    assert "/private/" not in body

async def test_migration_report_projection_refreshes_at_metrics_render_boundary(
    tmp_path: Path,
) -> None:
    import os

    import app.processing.metrics as metrics

    report_path = tmp_path / "migration-report.json"
    report = {
        "ok": True,
        "errors": [],
        "generated": {
            "rules": "/private/rules.yaml",
            "topology": "/private/topology.yaml",
            "plugins": "/private/plugins.yaml",
        },
        "metrics_summary": {
            "version": 1,
            "outcome": "success",
            "failure_code": "none",
            "issue_count": 0,
            "issues_truncated": False,
            "completed_at": "2026-07-10T12:00:00+00:00",
        },
    }
    report_path.write_text(json.dumps(report))
    metrics.configure_migration_report_projection(report_path)
    assert 'correlia_vigilo_migration_report_outcome{outcome="success"} 1.0' in (
        metrics.render_metrics().decode()
    )

    report["ok"] = False
    report["generated"] = None
    report["metrics_summary"]["outcome"] = "failure"
    report["metrics_summary"]["failure_code"] = "cataloged_incompatibility"
    replacement = tmp_path / "replacement.json"
    replacement.write_text(json.dumps(report))
    os.replace(replacement, report_path)

    body = metrics.render_metrics().decode()
    assert 'correlia_vigilo_migration_report_outcome{outcome="failure"} 1.0' in body
    assert (
        'correlia_vigilo_migration_report_failure_code{code="cataloged_incompatibility"} 1.0'
        in body
    )


async def test_migration_report_renders_are_consistent_during_atomic_replacement(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import os
    import threading
    from concurrent.futures import ThreadPoolExecutor

    import app.processing.metrics as metrics

    report_path = tmp_path / "migration-report.json"
    report_path.write_text(
        json.dumps(
            {
                "ok": True,
                "errors": [],
                "generated": {
                    "rules": "/private/rules.yaml",
                    "topology": "/private/topology.yaml",
                    "plugins": "/private/plugins.yaml",
                },
                "metrics_summary": {
                    "version": 1,
                    "outcome": "success",
                    "failure_code": "none",
                    "issue_count": 0,
                    "issues_truncated": False,
                    "completed_at": "2026-07-10T12:00:00+00:00",
                },
            }
        )
    )
    metrics.configure_migration_report_projection(report_path)

    first_snapshot_read = threading.Event()
    release_first_render = threading.Event()
    call_count = 0
    call_count_lock = threading.Lock()
    read_snapshot = metrics._read_migration_report_snapshot  # noqa: SLF001

    def pause_first_snapshot(path: Path) -> tuple[str, object]:
        nonlocal call_count
        snapshot = read_snapshot(path)
        with call_count_lock:
            call_count += 1
            pause = call_count == 1
        if pause:
            first_snapshot_read.set()
            assert release_first_render.wait(timeout=1)
        return snapshot

    monkeypatch.setattr(metrics, "_read_migration_report_snapshot", pause_first_snapshot)
    with ThreadPoolExecutor(max_workers=2) as executor:
        first_render = executor.submit(metrics.render_metrics)
        assert first_snapshot_read.wait(timeout=1)

        replacement = tmp_path / "replacement.json"
        replacement.write_text(
            json.dumps(
                {
                    "ok": False,
                    "errors": [],
                    "generated": None,
                    "metrics_summary": {
                        "version": 1,
                        "outcome": "failure",
                        "failure_code": "cataloged_incompatibility",
                        "issue_count": 0,
                        "issues_truncated": False,
                        "completed_at": "2026-07-10T12:00:00+00:00",
                    },
                }
            )
        )
        os.replace(replacement, report_path)
        second_render = executor.submit(metrics.render_metrics)
        release_first_render.set()
        first_body = first_render.result(timeout=1).decode()
        second_body = second_render.result(timeout=1).decode()

    assert 'correlia_vigilo_migration_report_outcome{outcome="success"} 1.0' in (
        first_body
    )
    assert 'correlia_vigilo_migration_report_failure_code{code="none"} 1.0' in (
        first_body
    )
    assert 'correlia_vigilo_migration_report_outcome{outcome="failure"} 0.0' in (
        first_body
    )
    assert (
        'correlia_vigilo_migration_report_failure_code{code="cataloged_incompatibility"} 0.0'
        in first_body
    )
    assert 'correlia_vigilo_migration_report_outcome{outcome="failure"} 1.0' in (
        second_body
    )
    assert (
        'correlia_vigilo_migration_report_failure_code{code="cataloged_incompatibility"} 1.0'
        in second_body
    )
    assert 'correlia_vigilo_migration_report_failure_code{code="none"} 0.0' in (
        second_body
    )
    assert 'correlia_vigilo_migration_report_outcome{outcome="success"} 0.0' in (
        second_body
    )


async def test_migration_report_projection_rejects_fifo_without_blocking(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import os
    import threading
    from concurrent.futures import ThreadPoolExecutor

    import app.processing.metrics as metrics

    report_path = tmp_path / "migration-report.fifo"
    os.mkfifo(report_path)
    original_open = os.open
    observed_flags: list[int] = []

    def capture_open(path: Path, flags: int) -> int:
        observed_flags.append(flags)
        return original_open(path, flags)

    def unblock_blocking_reader() -> None:
        descriptor = original_open(report_path, os.O_WRONLY | os.O_NONBLOCK)
        os.close(descriptor)

    monkeypatch.setattr(metrics.os, "open", capture_open)
    timer = threading.Timer(0.2, unblock_blocking_reader)
    timer.start()
    try:
        with ThreadPoolExecutor(max_workers=1) as executor:
            snapshot = executor.submit(metrics._read_migration_report_snapshot, report_path)
            status, summary = snapshot.result(timeout=0.1)
    finally:
        timer.cancel()
    assert (status, summary) == ("unsafe_file", None)
    assert observed_flags[0] & os.O_NONBLOCK


async def test_migration_report_projection_contains_deep_json_recursion(
    tmp_path: Path,
) -> None:
    import app.processing.metrics as metrics

    report_path = tmp_path / "migration-report.json"
    report_path.write_text("[" * 1_000 + "]" * 1_000)
    metrics.configure_migration_report_projection(report_path)

    body = metrics.render_metrics().decode()

    assert 'correlia_vigilo_migration_report_status{status="malformed"} 1.0' in body


async def test_migration_report_projection_catches_decoder_recursion(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import app.processing.metrics as metrics

    report_path = tmp_path / "migration-report.json"
    report_path.write_text("{}")

    def raise_recursion(_document: str) -> None:
        raise RecursionError

    monkeypatch.setattr(metrics.json, "loads", raise_recursion)
    metrics.configure_migration_report_projection(report_path)

    body = metrics.render_metrics().decode()

    assert 'correlia_vigilo_migration_report_status{status="malformed"} 1.0' in body


async def test_migration_report_projection_clears_summary_gauges(
    tmp_path: Path,
) -> None:
    import app.processing.metrics as metrics

    report_path = tmp_path / "migration-report.json"
    report_path.write_text(
        json.dumps(
            {
                "ok": True,
                "errors": [],
                "generated": {
                    "rules": "/private/rules.yaml",
                    "topology": "/private/topology.yaml",
                    "plugins": "/private/plugins.yaml",
                },
                "metrics_summary": {
                    "version": 1,
                    "outcome": "success",
                    "failure_code": "none",
                    "issue_count": 0,
                    "issues_truncated": False,
                    "completed_at": "2026-07-10T12:00:00+00:00",
                },
            }
        )
    )
    metrics.configure_migration_report_projection(report_path)
    metrics.render_metrics()
    def assert_summary_gauges_are_zero(body: str) -> None:
        for outcome in metrics.MIGRATION_OUTCOMES:
            assert (
                f'correlia_vigilo_migration_report_outcome{{outcome="{outcome}"}} 0.0'
                in body
            )
        for failure_code in metrics.MIGRATION_FAILURE_CODES:
            assert (
                f'correlia_vigilo_migration_report_failure_code{{code="{failure_code}"}} 0.0'
                in body
            )

    metrics.configure_migration_report_projection(None)
    assert_summary_gauges_are_zero(metrics.render_metrics().decode())

    metrics.configure_migration_report_projection(tmp_path / "replacement-report.json")
    assert_summary_gauges_are_zero(metrics.render_metrics().decode())


async def test_migration_report_projection_rejects_unsafe_and_future_snapshots(
    tmp_path: Path,
) -> None:
    import app.processing.metrics as metrics

    report_path = tmp_path / "migration-report.json"
    report_path.write_text("x" * (metrics.MIGRATION_REPORT_MAX_BYTES + 1))
    metrics.configure_migration_report_projection(report_path)
    metrics.refresh_migration_report_projection()
    assert 'correlia_vigilo_migration_report_status{status="oversized"} 1.0' in (
        metrics.render_metrics().decode()
    )

    if hasattr(__import__("os"), "symlink"):
        target = tmp_path / "target.json"
        target.write_text("{}")
        report_path.unlink()
        report_path.symlink_to(target)
        metrics.refresh_migration_report_projection()
        assert 'correlia_vigilo_migration_report_status{status="unsafe_file"} 1.0' in (
            metrics.render_metrics().decode()
        )


async def test_migration_report_projection_validates_versions_domains_and_file_kind(
    tmp_path: Path,
) -> None:
    import os

    import app.processing.metrics as metrics

    report_path = tmp_path / "migration-report.json"
    report = {
        "ok": False,
        "errors": [],
        "generated": None,
        "metrics_summary": {
            "version": 1,
            "outcome": "failure",
            "failure_code": "cataloged_incompatibility",
            "issue_count": 0,
            "issues_truncated": False,
            "completed_at": "2026-07-10T12:00:00+00:00",
        },
    }
    report_path.write_text(json.dumps(report))
    metrics.configure_migration_report_projection(report_path)
    metrics.refresh_migration_report_projection()
    body = metrics.render_metrics().decode()
    assert 'correlia_vigilo_migration_report_outcome{outcome="failure"} 1.0' in body
    assert (
        'correlia_vigilo_migration_report_failure_code{code="cataloged_incompatibility"} 1.0'
        in body
    )

    replacement = tmp_path / "replacement.json"
    report["metrics_summary"]["version"] = 2
    replacement.write_text(json.dumps(report))
    os.replace(replacement, report_path)
    metrics.refresh_migration_report_projection()
    assert (
        'correlia_vigilo_migration_report_status{status="unsupported_version"} 1.0'
        in (metrics.render_metrics().decode())
    )

    report["metrics_summary"]["version"] = 1
    report["metrics_summary"]["completed_at"] = "2999-01-01T00:00:00+00:00"
    report_path.write_text(json.dumps(report))
    metrics.refresh_migration_report_projection()
    assert 'correlia_vigilo_migration_report_status{status="future_timestamp"} 1.0' in (
        metrics.render_metrics().decode()
    )

    report["metrics_summary"]["completed_at"] = "2026-07-10T12:00:00+00:00"
    report["metrics_summary"]["failure_code"] = "secret-code"
    report_path.write_text(json.dumps(report))
    metrics.refresh_migration_report_projection()
    assert 'correlia_vigilo_migration_report_status{status="invalid_summary"} 1.0' in (
        metrics.render_metrics().decode()
    )

    report["metrics_summary"]["failure_code"] = "cataloged_incompatibility"
    report["errors"] = [
        {
            "domain": "hostile-domain",
            "location": "/secret/path",
            "code": "hostile-code",
            "message": "secret",
            "requirement": "CFG-06",
        }
    ]
    report_path.write_text(json.dumps(report))
    metrics.refresh_migration_report_projection()
    assert 'correlia_vigilo_migration_report_status{status="invalid_summary"} 1.0' in (
        metrics.render_metrics().decode()
    )

    metrics.configure_migration_report_projection(tmp_path)
    metrics.refresh_migration_report_projection()
    assert 'correlia_vigilo_migration_report_status{status="unsafe_file"} 1.0' in (
        metrics.render_metrics().decode()
    )


async def test_audit_metric_is_emitted_only_after_commit_and_once_on_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import app.processing.ingress as ingress

    order: list[str] = []
    monkeypatch.setattr(
        ingress, "_record_audit_outcome", lambda outcome: order.append(outcome)
    )

    class SuccessfulSession:
        async def commit(self) -> None:
            order.append("commit")

    await ingress._commit_audit_transaction(SuccessfulSession())  # noqa: SLF001
    assert order == ["commit", "success"]

    class FailingSession:
        async def commit(self) -> None:
            order.append("failed_commit")
            raise RuntimeError("secret commit failure")

    with pytest.raises(RuntimeError, match="secret commit failure"):
        await ingress._commit_audit_transaction(FailingSession())  # noqa: SLF001
    assert order == ["commit", "success", "failed_commit", "failure"]

    async def failing_insert(*args: object, **kwargs: object) -> None:
        raise RuntimeError("secret insert failure")

    monkeypatch.setattr(ingress, "insert_incident_event", failing_insert)
    with pytest.raises(RuntimeError, match="secret insert failure"):
        await ingress._insert_incident_event_with_audit_metric(object())  # noqa: SLF001
    assert order == [
        "commit",
        "success",
        "failed_commit",
        "failure",
        "failure",
    ]


def test_plugin_lifecycle_metrics_are_distinct_and_finite() -> None:
    import app.processing.metrics as metrics

    metrics.record_plugin_load("email")
    metrics.record_notification_submission("accepted")
    metrics.record_notification_submission("missing_runner")
    metrics.record_notification_delivery("success", "dispatched")
    metrics.record_notification_delivery("failure", "plugin_exception")

    body = metrics.render_metrics().decode()
    assert 'correlia_plugin_loads_total{category="email",outcome="success"} 1.0' in body
    assert 'correlia_notification_submissions_total{outcome="accepted"} 1.0' in body
    assert (
        'correlia_notification_submissions_total{outcome="missing_runner"} 1.0' in body
    )
    assert (
        'correlia_notification_deliveries_total{category="dispatched",outcome="success"} 1.0'
        in body
    )
    assert (
        'correlia_notification_deliveries_total{category="plugin_exception",outcome="failure"} 1.0'
        in body
    )
    assert "correlia_notification_attempts_total" not in body
    assert "correlia_notification_failures_total" not in body
