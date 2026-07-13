from __future__ import annotations

import ast
import traceback
from pathlib import Path

import pytest

from app.config.plugins import load_plugin_registry_config
from app.config.settings import Settings
from app.main import create_app
from app.plugins.interfaces import PluginStatus
from app.plugins.loader import PluginRegistry, load_plugin_registry
from app.plugins.outputs.email import SmtpOutputPlugin


def write_registry(path: Path, text: str) -> Path:
    path.write_text(text)
    return path


def strict_option_failure_registry(
    credential_sentinel: str, failed_plugin_name: str
) -> str:
    return f"""
outputs:
  - name: valid-email
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
  - name: {failed_plugin_name}
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
    options:
      password: {credential_sentinel}
"""


def assert_secret_free_plugin_failure(
    error: ValueError, *, position: int, forbidden_values: tuple[str, ...]
) -> None:
    assert str(error) == f"plugin registry startup failed at entry #{position}"
    rendered_failure = "\n".join(
        (str(error), repr(error), "".join(traceback.format_exception(error)))
    )
    for forbidden_value in forbidden_values:
        assert forbidden_value not in rendered_failure


def test_registry_loads_named_outputs_caches_instances_and_lists_safe_status(
    tmp_path: Path,
) -> None:
    registry_path = write_registry(
        tmp_path / "plugins.yaml",
        """
outputs:
  - name: critical-email
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
    options:
      host: localhost
      port: 1025
      from_address: correlia@example.test
      to_addresses: [ops@example.test]
      password: super-secret
      username: operator
      start_tls: true
  - name: warning-email
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
    options:
      host: localhost
      port: 1025
      to_addresses: [noc@example.test]
""",
    )

    registry = load_plugin_registry(registry_path)

    critical = registry.get_plugin("critical-email")
    assert isinstance(critical, SmtpOutputPlugin)
    assert registry.get_plugin("critical-email") is critical
    assert registry.names == ("critical-email", "warning-email")

    listed = registry.list_plugins()
    assert listed == tuple(sorted(listed, key=lambda row: str(row["name"])))
    assert {row["name"] for row in listed} == {"critical-email", "warning-email"}
    for row in listed:
        assert set(row) == {"name", "plugin_type", "status", "ready"}
        assert row["plugin_type"] == "email"
        assert row["status"] == "ready"
        assert row["ready"] is True
    assert "super-secret" not in repr(listed)
    assert "password" not in repr(listed)


def test_registry_aggregates_plugin_status_by_fixed_category(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    class MutableStatusPlugin:
        def __init__(self, ready: bool) -> None:
            self.ready = ready

        def plugin_status(self) -> PluginStatus:
            return PluginStatus(plugin_type="email", ready=self.ready, status="ready")

        async def send_notification(self, envelope: object) -> None:
            return None

    plugins = {
        1: MutableStatusPlugin(True),
        2: MutableStatusPlugin(True),
    }
    monkeypatch.setattr(
        "app.plugins.loader._instantiate_plugin",
        lambda _entry, position: plugins[position],
    )
    registry = load_plugin_registry(
        write_registry(
            tmp_path / "plugins.yaml",
            """
outputs:
  - name: first-hostile-plugin
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
  - name: second-hostile-plugin
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
""",
        )
    )

    assert registry.readiness_states() == {"email": "ready"}
    plugins[2].ready = False
    assert registry.readiness_states() == {"email": "not_ready"}

    def status_failure() -> PluginStatus:
        raise RuntimeError("smtp://user:password@secret-host/token-secret")

    monkeypatch.setattr(plugins[2], "plugin_status", status_failure)
    assert registry.readiness_states() == {"email": "not_ready"}
    assert PluginRegistry((), "").readiness_states() == {"email": "not_configured"}


def test_config_hash_is_deterministic_for_same_yaml(tmp_path: Path) -> None:
    text = """
outputs:
  - name: email
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
    options:
      host: localhost
      port: 1025
"""
    first = load_plugin_registry_config(write_registry(tmp_path / "a.yaml", text))
    second = load_plugin_registry_config(write_registry(tmp_path / "b.yaml", text))

    assert first.config_hash == second.config_hash


@pytest.mark.parametrize(
    ("class_path", "failure_code"),
    [
        ("app.plugins.outputs.email.MissingPlugin", "module_or_class"),
        ("app.plugins.outputs.email.SmtpOutputOptions", "interface"),
    ],
)
def test_registry_loader_normalizes_missing_or_non_output_classes(
    tmp_path: Path, class_path: str, failure_code: str
) -> None:
    registry_path = write_registry(
        tmp_path / "plugins.yaml",
        f"""
outputs:
  - name: bad
    plugin_type: email
    class_path: {class_path}
""",
    )

    with pytest.raises(ValueError) as failure:
        load_plugin_registry(registry_path)

    assert_secret_free_plugin_failure(
        failure.value, position=1, forbidden_values=(class_path,)
    )
    assert getattr(failure.value, "failure_code") == failure_code


def test_registry_redacts_later_plugin_strict_option_failure(tmp_path: Path) -> None:
    credential_sentinel = "smtp-credential-sentinel"
    failed_plugin_name = "hostile-plugin-name-sentinel"
    registry_path = write_registry(
        tmp_path / "plugins.yaml",
        strict_option_failure_registry(credential_sentinel, failed_plugin_name),
    )

    with pytest.raises(ValueError) as failure:
        load_plugin_registry(registry_path)

    assert_secret_free_plugin_failure(
        failure.value,
        position=2,
        forbidden_values=(credential_sentinel, failed_plugin_name),
    )


async def test_lifespan_aborts_before_runtime_startup_for_redacted_plugin_failure(
    tmp_path: Path,
    caplog: pytest.LogCaptureFixture,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class RecordingLifecycleWorker:
        started = False

        async def start(self) -> None:
            self.started = True

        async def stop(self) -> None:
            return None

    credential_sentinel = "smtp-credential-sentinel"
    failed_plugin_name = "hostile-plugin-name-sentinel"
    registry_path = write_registry(
        tmp_path / "plugins.yaml",
        strict_option_failure_registry(credential_sentinel, failed_plugin_name),
    )
    recorded_categories: list[str] = []
    monkeypatch.setattr("app.main.record_plugin_load", recorded_categories.append)
    lifecycle_worker = RecordingLifecycleWorker()
    app = create_app(
        settings=Settings(
            DATABASE_URL="postgresql+asyncpg://user:pass@localhost:5432/correlia",
            operator_api_token="operator-token",
            ingress_api_token="ingress-token",
            audit_raw_payload_hmac_key="test-audit-hmac",
            plugins_path=registry_path,
        ),
        sessionmaker=lambda: object(),
        icinga2_processor=object(),
        lifecycle_worker=lifecycle_worker,
    )

    with pytest.raises(ValueError) as failure:
        async with app.router.lifespan_context(app):
            pytest.fail("plugin validation failure must prevent lifespan yield")

    assert_secret_free_plugin_failure(
        failure.value,
        position=2,
        forbidden_values=(credential_sentinel, failed_plugin_name),
    )
    assert not hasattr(app.state, "plugin_registry")
    assert not hasattr(app.state, "task_runner")
    assert lifecycle_worker.started is False
    events = [
        record.__dict__
        for record in caplog.records
        if record.__dict__.get("event") == "plugin_load"
    ]
    assert len(events) == 1
    assert {
        key: events[0][key]
        for key in ("event", "outcome", "category", "failure_code", "entry_position")
    } == {
        "event": "plugin_load",
        "outcome": "failure",
        "category": "email",
        "failure_code": "constructor",
        "entry_position": 2,
    }
    assert set(events[0]).isdisjoint({"plugin_name", "class_path", "exception_type"})
    assert credential_sentinel not in repr(events[0])
    assert failed_plugin_name not in repr(events[0])
    assert recorded_categories == []


async def test_lifespan_normalizes_plugin_status_failure_without_starting_workers(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    class StatusFailurePlugin:
        def plugin_status(self) -> object:
            raise RuntimeError("status failure with password=secret")

    class NoopLifecycleWorker:
        started = False

        async def start(self) -> None:
            self.started = True

        async def stop(self) -> None:
            return None

    monkeypatch.setattr(
        "app.plugins.loader._instantiate_plugin",
        lambda entry, position: StatusFailurePlugin(),
    )
    lifecycle_worker = NoopLifecycleWorker()
    app = create_app(
        settings=Settings(
            DATABASE_URL="postgresql+asyncpg://user:pass@localhost:5432/correlia",
            operator_api_token="operator-token",
            ingress_api_token="ingress-token",
            audit_raw_payload_hmac_key="test-audit-hmac",
            plugins_path=write_registry(
                tmp_path / "plugins.yaml",
                """
outputs:
  - name: hostile-plugin
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
""",
            ),
        ),
        sessionmaker=lambda: object(),
        icinga2_processor=object(),
        lifecycle_worker=lifecycle_worker,
    )

    with pytest.raises(ValueError, match="plugin registry startup failed at entry #1"):
        async with app.router.lifespan_context(app):
            pytest.fail("plugin status failure must prevent lifespan yield")

    events = [
        record.__dict__
        for record in caplog.records
        if record.__dict__.get("event") == "plugin_load"
    ]
    assert len(events) == 1
    assert events[0]["failure_code"] == "status"
    assert events[0]["category"] == "email"
    assert "password=secret" not in repr(events[0])
    assert lifecycle_worker.started is False


@pytest.mark.parametrize(
    ("registry_text", "expected_categories"),
    (
        (
            """
outputs:
  - name: hostile-plugin-name
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
""",
            ["email"],
        ),
        ("outputs: []", []),
    ),
)
async def test_lifespan_records_only_completed_plugin_load_categories(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    registry_text: str,
    expected_categories: list[str],
) -> None:
    class NoopLifecycleWorker:
        async def start(self) -> None:
            return None

        async def stop(self) -> None:
            return None

    recorded_categories: list[str] = []
    monkeypatch.setattr("app.main.record_plugin_load", recorded_categories.append)
    app = create_app(
        settings=Settings(
            DATABASE_URL="postgresql+asyncpg://user:pass@localhost:5432/correlia",
            operator_api_token="operator-token",
            ingress_api_token="ingress-token",
            audit_raw_payload_hmac_key="test-audit-hmac",
            plugins_path=write_registry(tmp_path / "plugins.yaml", registry_text),
        ),
        sessionmaker=lambda: object(),
        icinga2_processor=object(),
        lifecycle_worker=NoopLifecycleWorker(),
    )

    async with app.router.lifespan_context(app):
        assert app.state.plugin_registry.names == (
            ("hostile-plugin-name",) if expected_categories else ()
        )
        assert recorded_categories == expected_categories


def test_unknown_plugin_name_raises_key_error() -> None:
    registry = PluginRegistry((), "0" * 64)

    with pytest.raises(KeyError, match="unknown output plugin"):
        registry.get_plugin("missing")


def test_registry_source_uses_only_safe_loading_and_trusted_import_patterns() -> None:
    root = Path(__file__).resolve().parents[1]
    source_paths = [root / "app/config/plugins.py", root / "app/plugins/loader.py"]
    forbidden_calls: list[str] = []
    for path in source_paths:
        tree = ast.parse(path.read_text())
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            if isinstance(func, ast.Name) and func.id in {"eval", "exec", "__import__"}:
                forbidden_calls.append(func.id)
            if (
                isinstance(func, ast.Attribute)
                and func.attr == "load"
                and isinstance(func.value, ast.Name)
                and func.value.id == "yaml"
            ):
                forbidden_calls.append("yaml.load")
    assert forbidden_calls == []

    config_source = (root / "app/config/plugins.py").read_text()
    loader_source = (root / "app/plugins/loader.py").read_text()
    assert "yaml.safe_load" in config_source
    assert "app.plugins.outputs." in config_source
    assert "app.plugins.outputs." in loader_source
