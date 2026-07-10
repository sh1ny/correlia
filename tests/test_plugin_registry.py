from __future__ import annotations

import ast
import traceback
from pathlib import Path

import pytest

from app.config.plugins import load_plugin_registry_config
from app.config.settings import Settings
from app.main import create_app
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
    assert str(error) == f"unable to construct output plugin #{position}"
    rendered_failure = "\n".join(
        (str(error), repr(error), "".join(traceback.format_exception(error)))
    )
    for forbidden_value in forbidden_values:
        assert forbidden_value not in rendered_failure


def test_registry_loads_named_outputs_caches_instances_and_lists_safe_status(tmp_path: Path) -> None:
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
    "yaml_text, match",
    [
        (
            """
outputs:
  - name: email
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
  - name: email
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
""",
            "duplicate output plugin name",
        ),
        (
            """
outputs:
  - name: pager
    plugin_type: pagerduty
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
""",
            "plugin_type",
        ),
        (
            """
outputs:
  - name: unsafe
    plugin_type: email
    class_path: os.system
""",
            "app.plugins.outputs",
        ),
    ],
)
def test_registry_config_rejects_invalid_declarations(tmp_path: Path, yaml_text: str, match: str) -> None:
    with pytest.raises(ValueError, match=match):
        load_plugin_registry_config(write_registry(tmp_path / "plugins.yaml", yaml_text))


@pytest.mark.parametrize(
    "class_path, match",
    [
        ("app.plugins.outputs.email.MissingPlugin", "missing output plugin class"),
        ("app.plugins.outputs.email.SmtpOutputOptions", "does not implement OutputPlugin"),
    ],
)
def test_registry_loader_rejects_missing_or_non_output_classes(
    tmp_path: Path, class_path: str, match: str
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

    with pytest.raises(ValueError, match=match):
        load_plugin_registry(registry_path)



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
