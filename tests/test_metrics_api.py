from pathlib import Path

from httpx import ASGITransport, AsyncClient

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


async def test_metrics_route_returns_prometheus_text() -> None:
    app = create_app()
    transport = ASGITransport(app=app)

    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/v1/metrics")

    assert response.status_code == 200
    content_type = response.headers["content-type"]
    assert content_type.startswith("text/plain")
    assert "version=0.0.4" in content_type
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
