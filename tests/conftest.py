from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterator
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest
import yaml


_SMOKE = "tests/test_deployment.py::test_real_compose_smoke_proves_runtime_deployment_contract"
_RESOURCE_MARKERS = {"postgres", "deployment", "posix"}


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--verification-mode",
        choices=("full", "deployment", "portable"),
        help="Select required Linux verification or resource-free portable tests.",
    )


def _mode(config: pytest.Config) -> str | None:
    return config.getoption("--verification-mode")


def pytest_configure(config: pytest.Config) -> None:
    global _active_verification
    mode = _mode(config)
    if mode not in ("full", "deployment"):
        return
    if os.environ.get("PYTEST_ADDOPTS", "").strip():
        raise pytest.UsageError("required verification rejects PYTEST_ADDOPTS")
    if os.environ.get("PYTEST_PLUGINS", "").strip():
        raise pytest.UsageError("required verification rejects PYTEST_PLUGINS")
    if config.getini("addopts"):
        raise pytest.UsageError("required verification rejects configured addopts")
    if tuple(config.invocation_params.args) != (f"--verification-mode={mode}",):
        raise pytest.UsageError(
            "required verification accepts only --verification-mode="
            f"{mode}; selectors and pytest option overrides are forbidden"
        )
    if mode == "full":
        config.args = [str(config.rootpath)]
    else:
        config.args = [
            f"{config.rootpath / 'tests' / 'test_deployment.py'}"
            f"::{_SMOKE.split('::', 1)[1]}"
        ]
    config._verification_reports = defaultdict(dict)
    _active_verification = config
    config._verification_deselected = 0
    config._verification_collection_skips = 0
    config._verification_duplicate_reports = False


def _docker_available(*, compose: bool) -> bool:
    if shutil.which("docker") is None:
        return False
    commands = [["docker", "info", "--format", "{{.ServerVersion}}"]]
    if compose:
        commands.append(["docker", "compose", "version", "--short"])
    for command in commands:
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=15, check=False
            )
        except OSError, subprocess.TimeoutExpired:
            return False
        if result.returncode != 0 or not result.stdout.strip():
            return False
    return True


def pytest_sessionstart(session: pytest.Session) -> None:
    if _mode(session.config) in ("full", "deployment"):
        if sys.platform != "linux":
            raise pytest.UsageError("required verification needs Linux")
        if not _docker_available(compose=True):
            raise pytest.UsageError(
                "required verification needs a running Docker daemon and Docker Compose"
            )


def pytest_collectreport(report: pytest.CollectReport) -> None:
    if _active_verification is not None and report.skipped:
        _active_verification._verification_collection_skips += 1


def pytest_deselected(items: list[pytest.Item]) -> None:
    if items and _mode(items[0].config) in ("full", "deployment"):
        items[0].config._verification_deselected += len(items)


def pytest_collection_modifyitems(
    config: pytest.Config, items: list[pytest.Item]
) -> None:
    mode = _mode(config)
    for item in items:
        if "postgres_url" in item.fixturenames:
            item.add_marker(pytest.mark.postgres)
    if mode == "portable":
        excluded = [
            item
            for item in items
            if any(item.get_closest_marker(name) for name in _RESOURCE_MARKERS)
        ]
        if excluded:
            config.hook.pytest_deselected(items=excluded)
            items[:] = [item for item in items if item not in excluded]
    elif mode not in ("full", "deployment"):
        postgres_items = any(item.get_closest_marker("postgres") for item in items)
        deployment_items = any(item.get_closest_marker("deployment") for item in items)
        docker_available = not (postgres_items or deployment_items) or (
            _docker_available(compose=False)
        )
        compose_available = not deployment_items or (
            docker_available and _docker_available(compose=True)
        )
        for item in items:
            if item.get_closest_marker("posix") and os.name != "posix":
                item.add_marker(pytest.mark.skip(reason="requires POSIX"))
            if item.get_closest_marker("postgres") and not docker_available:
                item.add_marker(
                    pytest.mark.skip(reason="requires a running Docker daemon")
                )
            if item.get_closest_marker("deployment") and not compose_available:
                item.add_marker(
                    pytest.mark.skip(
                        reason="requires a running Docker daemon and Compose"
                    )
                )


def pytest_collection_finish(session: pytest.Session) -> None:
    config = session.config
    if _mode(config) not in ("full", "deployment"):
        return
    items = session.items
    nodeids = [item.nodeid for item in items]
    problems = []
    smoke_count = nodeids.count(_SMOKE)
    if smoke_count != 1:
        problems.append(f"required smoke collected {smoke_count} times (expected once)")
    if len(nodeids) != len(set(nodeids)):
        problems.append("duplicate selected node IDs")
    if _mode(config) == "deployment":
        if nodeids != [_SMOKE]:
            problems.append("deployment mode must select only the canonical smoke")
    else:
        if not any(item.get_closest_marker("postgres") for item in items):
            problems.append("no PostgreSQL tests collected")
        if not any(item.get_closest_marker("posix") for item in items):
            problems.append("no POSIX tests collected")
    config._verification_collection_problems = problems
    config._verification_selected = nodeids


def pytest_runtest_logreport(report: pytest.TestReport) -> None:
    if report.when not in ("setup", "call", "teardown"):
        return
    # Reports do not expose Config; the selected session is stored at collection.
    if _active_verification is not None:
        phases = _active_verification._verification_reports[report.nodeid]
        if report.when in phases:
            _active_verification._verification_duplicate_reports = True
        phases[report.when] = report.outcome == "passed" and not hasattr(
            report, "wasxfail"
        )


_active_verification: pytest.Config | None = None


def pytest_sessionfinish(
    session: pytest.Session, exitstatus: int | pytest.ExitCode
) -> None:
    global _active_verification
    config = session.config
    _active_verification = None
    if _mode(config) not in ("full", "deployment"):
        return
    problems = list(
        getattr(
            config, "_verification_collection_problems", ["collection did not finish"]
        )
    )
    if config._verification_deselected:
        problems.append(f"{config._verification_deselected} tests deselected")
    if config._verification_collection_skips:
        problems.append(f"{config._verification_collection_skips} collection skips")
    if config._verification_duplicate_reports:
        problems.append("duplicate execution reports")
    selected = getattr(config, "_verification_selected", [])
    if not selected:
        problems.append("no tests selected")
    for nodeid in selected:
        reports = config._verification_reports[nodeid]
        if set(reports) != {"setup", "call", "teardown"}:
            problems.append(f"{nodeid}: incomplete setup/call/teardown")
        elif not all(reports.values()):
            problems.append(f"{nodeid}: non-passing or xfail result")
    if problems:
        terminal = config.pluginmanager.get_plugin("terminalreporter")
        if terminal is not None:
            for problem in problems:
                terminal.write_line(f"verification incomplete: {problem}", red=True)
        if exitstatus == pytest.ExitCode.OK:
            session.exitstatus = pytest.ExitCode.TESTS_FAILED


@pytest.fixture(scope="session")
def postgres_image() -> str:
    compose = yaml.safe_load(
        (Path(__file__).resolve().parents[1] / "compose.yaml").read_text()
    )
    image = compose["services"]["postgres"]["image"]
    if not isinstance(image, str) or not image.strip():
        raise ValueError("compose.yaml must define a nonempty PostgreSQL image")
    return image


_SETTINGS_ENV_KEYS = (
    "DATABASE_URL",
    "CORRELIA_DATABASE_URL",
    "CORRELIA_ENVIRONMENT",
    "CORRELIA_LOG_LEVEL",
    "CORRELIA_RULES_PATH",
    "CORRELIA_TOPOLOGY_PATH",
    "CORRELIA_PLUGINS_PATH",
    "CORRELIA_API_AUTH_ENABLED",
    "CORRELIA_OPERATOR_API_TOKEN",
    "CORRELIA_INGRESS_API_TOKEN",
    "CORRELIA_EXPOSE_READYZ",
    "CORRELIA_EXPOSE_METRICS",
    "CORRELIA_MIGRATION_REPORT_PATH",
    "CORRELIA_MAX_BODY_BYTES",
    "CORRELIA_MAX_BODY_BYTES_OPERATOR",
    "CORRELIA_MAX_BODY_BYTES_INGRESS",
    "CORRELIA_MAX_BODY_BYTES_METRICS",
    "CORRELIA_MAX_BODY_BYTES_READYZ",
    "CORRELIA_MAX_BODY_BYTES_HEALTH",
    "CORRELIA_RATE_LIMIT_ENABLED",
    "CORRELIA_RATE_LIMIT_REQUESTS_OPERATOR",
    "CORRELIA_RATE_LIMIT_WINDOW_SECONDS_OPERATOR",
    "CORRELIA_RATE_LIMIT_REQUESTS_INGRESS",
    "CORRELIA_RATE_LIMIT_WINDOW_SECONDS_INGRESS",
    "CORRELIA_RATE_LIMIT_REQUESTS_METRICS",
    "CORRELIA_RATE_LIMIT_WINDOW_SECONDS_METRICS",
    "CORRELIA_RATE_LIMIT_REQUESTS_READYZ",
    "CORRELIA_RATE_LIMIT_WINDOW_SECONDS_READYZ",
    "CORRELIA_RATE_LIMIT_REQUESTS_HEALTH",
    "CORRELIA_RATE_LIMIT_WINDOW_SECONDS_HEALTH",
    "CORRELIA_RATE_LIMIT_SWEEP_INTERVAL_SECONDS",
    "CORRELIA_AUDIT_RAW_PAYLOAD_MAX_BYTES",
    "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
)


@pytest.fixture(autouse=True)
def clean_settings_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    for key in _SETTINGS_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    yield
