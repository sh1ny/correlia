from pathlib import Path
import asyncio
from datetime import datetime, timezone
from uuid import UUID, uuid4


from httpx import ASGITransport, AsyncClient
import pytest

from app.domain.events import EventType, NormalizedEvent, Severity
from app.domain.rules import NotificationResult, RuleDecision, ThresholdDecision
from app.persistence.incidents import LifecycleWriteResult
from app.persistence.models import Incident
from app.processing.incident_manager import IncidentAggregationResult
from app.processing.ingress import Icinga2DecisionProcessor
from app.processing.lifecycle import LifecycleManager, LifecycleResult
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
}

pytestmark = pytest.mark.anyio


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


class InstrumentedProcessor(Icinga2DecisionProcessor):
    async def _apply_problem(
        self, event: NormalizedEvent, decision: RuleDecision
    ) -> IncidentAggregationResult:
        return IncidentAggregationResult(
            incident_id=uuid4(),
            effect="inserted",
            status="OPEN",
            replay=False,
            inside_window=True,
            counted=True,
            counted_count=1,
            threshold_crossed=True,
            first_threshold_transition=True,
            notification_triggered=False,
            notification_failed=False,
            no_dispatch_reason=None,
            notification_results=(),
        )

    async def _apply_recovery(self, event: NormalizedEvent) -> LifecycleResult:
        return LifecycleResult(
            incident_ids=(uuid4(),),
            effect="resolved",
            transitioned_to="RESOLVED",
            previous_host_count=1,
            previous_service_count=1,
            affected_object_removed=True,
        )


class FakeSession:
    async def commit(self) -> None:
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
        "correlia_notification_attempts_total",
        "correlia_notification_failures_total",
        "correlia_task_failures_total",
        "correlia_lifecycle_worker_healthy",
    ):
        assert metric_name in body


async def test_metric_declarations_exclude_high_cardinality_labels() -> None:
    import app.processing.metrics as metrics

    metrics_source = Path("app/processing/metrics.py").read_text()

    for forbidden_label in FORBIDDEN_METRIC_LABELS:
        assert f'"{forbidden_label}"' not in metrics_source
        assert f"'{forbidden_label}'" not in metrics_source

    app_imports = [
        path
        for path in Path("app").rglob("*.py")
        if "prometheus_client" in path.read_text()
    ]
    assert app_imports == [Path("app/processing/metrics.py")]

    for collector in metrics.registry._collector_to_names:  # noqa: SLF001 - declaration audit
        label_names = set(getattr(collector, "_labelnames", ()))  # noqa: SLF001
        assert label_names.isdisjoint(FORBIDDEN_METRIC_LABELS)



async def test_ingest_lifecycle_notification_and_worker_metrics_use_low_cardinality_labels(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import app.processing.lifecycle as lifecycle_module
    import app.processing.notification_dispatcher as notification_module
    import app.processing.metrics as metrics

    decision = _decision()
    problem_processor = InstrumentedProcessor(
        FakePlugin(_event(EventType.PROBLEM, severity=Severity.CRITICAL)),
        rule_engine=FakeRuleEngine(decision),
        sessionmaker=FakeSessionFactory(),
    )
    recovery_processor = InstrumentedProcessor(
        FakePlugin(_event(EventType.RECOVERY, severity=Severity.OK)),
        rule_engine=FakeRuleEngine(decision),
        sessionmaker=FakeSessionFactory(),
    )

    await problem_processor.process_payload({})
    await recovery_processor.process_payload({})

    incident_id = uuid4()

    async def fake_resolve_host_recovery(*args: object, **kwargs: object) -> tuple[LifecycleWriteResult, ...]:
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

    monkeypatch.setattr(lifecycle_module, "resolve_host_recovery", fake_resolve_host_recovery)
    await LifecycleManager(FakeSession()).resolve_for_event(
        _event(EventType.RECOVERY, severity=Severity.OK).model_copy(update={"service": None})
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

    task_runner = AsyncIOTaskRunner()

    async def fail_task(payload: object) -> None:
        raise RuntimeError("password=super-secret")

    task_runner.register("notify", fail_task)
    await task_runner.submit("notify", {})
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
        'correlia_matched_rules_total{rule_name="critical-rule"}',
        'correlia_incident_effects_total{effect="inserted"}',
        'correlia_incident_effects_total{effect="resolved"}',
        'correlia_notification_failures_total{category="dispatch_failed",plugin_name="email-oncall"}',
        'correlia_task_failures_total{task_name="correlia:notify"}',
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
    for path in (
        Path("app/processing/ingress.py"),
        Path("app/processing/incident_manager.py"),
        Path("app/processing/notification_dispatcher.py"),
        Path("app/processing/task_runner.py"),
        Path("app/processing/lifecycle.py"),
        Path("app/processing/lifecycle_worker.py"),
    ):
        for line in path.read_text().splitlines():
            if "record_" in line or "set_lifecycle_worker_healthy" in line:
                for forbidden in forbidden_source_values:
                    assert forbidden not in line