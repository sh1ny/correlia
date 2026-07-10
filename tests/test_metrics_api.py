from pathlib import Path
import asyncio
from datetime import datetime, timezone
from uuid import UUID, uuid4


from httpx import ASGITransport, AsyncClient
import pytest

from app.domain.events import EventType, NormalizedEvent, Severity
from app.domain.rules import RuleDecision, ThresholdDecision
from app.persistence.incidents import IncidentAggregationWriteResult, LifecycleWriteResult
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
}

pytestmark = pytest.mark.anyio

@pytest.fixture(autouse=True)
def _auth_env_for_metrics_tests(monkeypatch: pytest.MonkeyPatch, clean_settings_env: None) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://user:pass@localhost:5432/correlia")
    monkeypatch.setenv("CORRELIA_OPERATOR_API_TOKEN", "operator-token")
    monkeypatch.setenv("CORRELIA_INGRESS_API_TOKEN", "ingress-token")
    monkeypatch.setenv("CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY", "test-audit-hmac")



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
    async def _fake_record_problem_incident(session: object, inp: object) -> IncidentAggregationWriteResult:
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

    monkeypatch.setattr(im_module, "record_problem_incident", _fake_record_problem_incident)
    monkeypatch.setattr(lm_module, "resolve_host_recovery", _fake_resolve_host_recovery)
    monkeypatch.setattr(lm_module, "resolve_service_recovery", _fake_resolve_service_recovery)

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

    async def fake_record_problem_incident(*args: object, **kwargs: object) -> IncidentAggregationWriteResult:
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
    metric_call_names = (
        "record_event_accepted",
        "record_event_rejected",
        "record_rule_matched",
        "record_incident_effect",
        "record_notification_attempt",
        "record_notification_failure",
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