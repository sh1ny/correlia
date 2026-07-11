"""Always-run deployment artifact and controlled entrypoint contract tests."""

from __future__ import annotations

from collections.abc import Iterator
from fnmatch import fnmatchcase
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from uuid import uuid4

import pytest
import yaml

from app.config.plugins import load_plugin_registry_config
from app.config.rules import load_rules_config
from app.config.settings import Settings
from app.config.topology import load_topology_config
from app.plugins.loader import load_plugin_registry

PROJECT_ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINT_PATH = PROJECT_ROOT / "scripts" / "container-entrypoint.sh"
DOCKERFILE_PATH = PROJECT_ROOT / "Dockerfile"
DOCKERIGNORE_PATH = PROJECT_ROOT / ".dockerignore"

COMPOSE_PATH = PROJECT_ROOT / "compose.yaml"
ENV_EXAMPLE_PATH = PROJECT_ROOT / ".env.example"
CONFIG_DIRECTORY = PROJECT_ROOT / "config"

_DOCKER_UNAVAILABLE_CAPABILITIES = (
    "image user/filesystem/process/signal, network/SMTP, and runtime-secret placement"
)


def _assert_secret_absent(value: str, surface: str, secret: str) -> None:
    if secret in value:
        pytest.fail(f"secret sentinel appeared in {surface}")


def _docker_engine_available() -> bool:
    docker = shutil.which("docker")
    if docker is None:
        return False
    try:
        result = subprocess.run(
            [docker, "info"],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
    except OSError, subprocess.TimeoutExpired:
        return False
    return result.returncode == 0


def _docker(
    arguments: list[str],
    *,
    environment: dict[str, str] | None = None,
    input_data: str | None = None,
    timeout: float = 120,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", *arguments],
        cwd=PROJECT_ROOT,
        env=environment,
        input=input_data,
        capture_output=True,
        text=True,
        check=False,
        timeout=timeout,
    )


def _require_docker_success(
    arguments: list[str],
    *,
    environment: dict[str, str] | None = None,
    timeout: float = 120,
) -> subprocess.CompletedProcess[str]:
    result = _docker(arguments, environment=environment, timeout=timeout)
    if result.returncode != 0:
        pytest.fail("Docker deployment command failed without exposing its diagnostics")
    return result


def _docker_json(arguments: list[str]) -> object:
    result = _require_docker_success(arguments)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        pytest.fail("Docker inspection did not return JSON")


def _wait_until(
    description: str,
    predicate: object,
    *,
    timeout: float = 30,
) -> object:
    deadline = time.monotonic() + timeout
    last_value: object = None
    while time.monotonic() < deadline:
        last_value = predicate()  # type: ignore[operator]
        if last_value:
            return last_value
        time.sleep(0.1)
    pytest.fail(f"timed out waiting for {description}")


def _container_http_response(
    container: str,
    url: str,
    *,
    token: str | None = None,
    payload: dict[str, object] | None = None,
    method: str = "GET",
) -> tuple[int, bytes]:
    script = """
import base64
import json
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

url, method, token, payload = json.loads(sys.stdin.read())
data = json.dumps(payload).encode() if payload is not None else None
headers = {"Content-Type": "application/json"} if data is not None else {}
if token:
    headers["Authorization"] = f"Bearer {token}"
request = Request(url, data=data, headers=headers, method=method)
try:
    with urlopen(request, timeout=2) as response:
        status, body = response.status, response.read()
except HTTPError as error:
    status, body = error.code, error.read()
except URLError:
    status, body = 0, b""
print(json.dumps((status, base64.b64encode(body).decode())))
"""
    result = _docker(
        [
            "exec",
            "--interactive",
            container,
            "python",
            "-c",
            script,
        ],
        input_data=json.dumps((url, method, token, payload)),
    )
    if result.returncode != 0:
        pytest.fail("container-local HTTP probe failed without exposing diagnostics")
    try:
        status, encoded_body = json.loads(result.stdout)
        return int(status), base64.b64decode(encoded_body)
    except TypeError, ValueError:
        pytest.fail("container-local HTTP probe returned an invalid response")


def _mailpit_messages(container: str, url: str) -> list[dict[str, object]] | None:
    status, body = _container_http_response(container, url)
    if status != 200:
        return None
    try:
        response = json.loads(body)
    except json.JSONDecodeError:
        return None
    messages = response.get("messages") if isinstance(response, dict) else None
    if not isinstance(messages, list) or not all(
        isinstance(message, dict) for message in messages
    ):
        return None
    return messages


def _metric_value(
    metrics: str,
    name: str,
    labels: dict[str, str] | None = None,
    *,
    default: float | None = None,
) -> float:
    label_text = (
        ""
        if not labels
        else "{" + ",".join(f'{key}="{value}"' for key, value in labels.items()) + "}"
    )
    sample = f"{name}{label_text}"
    values = [
        line.removeprefix(sample).strip()
        for line in metrics.splitlines()
        if line.startswith(f"{sample} ")
    ]
    if not values and default is not None:
        return default
    assert len(values) == 1
    return float(values[0])


def _file_checksum(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _docker_compose_arguments(stack: dict[str, object], *arguments: str) -> list[str]:
    return [
        "compose",
        "--project-name",
        str(stack["project"]),
        "--env-file",
        str(stack["env_file"]),
        "--file",
        str(COMPOSE_PATH),
        "--file",
        str(stack["override_file"]),
        *arguments,
    ]


def _compose_cleanup(stack: dict[str, object]) -> None:
    project_label = f"com.docker.compose.project={stack['project']}"
    failures: list[str] = []

    def run(arguments: list[str], action: str) -> subprocess.CompletedProcess[str]:
        result = _docker(arguments)
        if result.returncode != 0:
            failures.append(action)
        return result

    run(
        _docker_compose_arguments(stack, "down", "--volumes", "--remove-orphans"),
        "compose down",
    )
    containers = run(
        ["ps", "--all", "--quiet", "--filter", f"label={project_label}"],
        "list containers",
    )
    container_names = containers.stdout.split() if containers.returncode == 0 else []
    if container_names:
        run(["rm", "--force", *container_names], "remove containers")
    volumes = run(
        ["volume", "ls", "--quiet", "--filter", f"label={project_label}"],
        "list volumes",
    )
    volume_names = volumes.stdout.split() if volumes.returncode == 0 else []
    if volume_names:
        run(["volume", "rm", *volume_names], "remove volumes")
    remaining_containers = run(
        ["ps", "--all", "--quiet", "--filter", f"label={project_label}"],
        "verify container cleanup",
    )
    remaining_volumes = run(
        ["volume", "ls", "--quiet", "--filter", f"label={project_label}"],
        "verify volume cleanup",
    )
    if remaining_containers.returncode == 0 and remaining_containers.stdout.strip():
        failures.append("containers remain")
    if remaining_volumes.returncode == 0 and remaining_volumes.stdout.strip():
        failures.append("volumes remain")
    if failures:
        pytest.fail("Docker cleanup failed without exposing its diagnostics")


def test_container_http_probe_sends_authentication_only_over_stdin(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    token = "probe-token-sentinel"
    calls: list[tuple[list[str], str | None]] = []

    def fake_docker(
        arguments: list[str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        input_data = kwargs.get("input_data")
        assert input_data is None or isinstance(input_data, str)
        calls.append((arguments, input_data))
        return subprocess.CompletedProcess(
            ["docker", *arguments],
            0,
            stdout=json.dumps((200, base64.b64encode(b"{}").decode())),
        )

    monkeypatch.setitem(_container_http_response.__globals__, "_docker", fake_docker)

    assert _container_http_response(
        "container-id", "http://app/v1/metrics", token=token
    ) == (200, b"{}")
    assert len(calls) == 1
    arguments, input_data = calls[0]
    assert token not in json.dumps(arguments)
    assert input_data is not None and token in input_data


def test_mailpit_messages_treats_non_success_and_malformed_json_as_retryable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    responses = iter(
        (
            (503, b"unavailable"),
            (200, b"not-json"),
            (200, json.dumps({"messages": [{"ID": "message-id"}]}).encode()),
        )
    )

    def fake_probe(*_args: object, **_kwargs: object) -> tuple[int, bytes]:
        return next(responses)

    monkeypatch.setitem(_mailpit_messages.__globals__, "_container_http_response", fake_probe)

    assert _mailpit_messages("mailpit", "http://mailpit/api/v1/messages") is None
    assert _mailpit_messages("mailpit", "http://mailpit/api/v1/messages") is None
    assert _mailpit_messages("mailpit", "http://mailpit/api/v1/messages") == [
        {"ID": "message-id"}
    ]


def test_compose_cleanup_attempts_all_resource_removal_after_down_failure(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls: list[list[str]] = []
    container_lists = iter(("orphan-one\norphan-two\n", ""))
    volume_lists = iter(("orphan-volume\n", ""))

    def fake_docker(
        arguments: list[str], **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        calls.append(arguments)
        if arguments[0] == "compose":
            return subprocess.CompletedProcess(["docker", *arguments], 1)
        if arguments[:2] == ["ps", "--all"]:
            return subprocess.CompletedProcess(
                ["docker", *arguments], 0, stdout=next(container_lists)
            )
        if arguments[:2] == ["volume", "ls"]:
            return subprocess.CompletedProcess(
                ["docker", *arguments], 0, stdout=next(volume_lists)
            )
        return subprocess.CompletedProcess(["docker", *arguments], 0)

    monkeypatch.setitem(_compose_cleanup.__globals__, "_docker", fake_docker)
    stack = {
        "project": "cleanup-test",
        "env_file": tmp_path / ".env",
        "override_file": tmp_path / "override.yaml",
    }

    with pytest.raises(pytest.fail.Exception, match="Docker cleanup failed"):
        _compose_cleanup(stack)

    assert ["rm", "--force", "orphan-one", "orphan-two"] in calls
    assert ["volume", "rm", "orphan-volume"] in calls
    assert calls[-2][:2] == ["ps", "--all"]
    assert calls[-1][:2] == ["volume", "ls"]


@pytest.fixture
def docker_compose_stack(tmp_path: Path) -> Iterator[dict[str, object]]:
    """Build the checked-in image and run one isolated Compose topology."""
    if not _docker_engine_available():
        pytest.skip(
            "Docker engine unavailable; cannot prove "
            f"{_DOCKER_UNAVAILABLE_CAPABILITIES}"
        )

    suffix = uuid4().hex[:12]
    secrets = {
        "postgres_password": f"u7-postgres-{suffix}",
        "operator_token": f"u7-operator-{suffix}",
        "ingress_token": f"u7-ingress-{suffix}",
        "audit_key": f"u7-audit-{suffix}",
    }
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
    smoke_rules_path = tmp_path / "smoke-rules.yaml"
    smoke_rules_path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "docker-smoke-threshold",
                        "priority": 1,
                        "match": {"severities": ["CRITICAL"], "host_pattern": ".+"},
                        "window": {
                            "duration_seconds": 300,
                            "group_by": ["host"],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "Critical alert on {host}",
                        "actions": [{"name": "create_incident", "plugin": "email-ops"}],
                    }
                ]
            }
        )
    )
    environment_values = {
        "POSTGRES_DB": "correlia",
        "POSTGRES_USER": "correlia",
        "POSTGRES_PASSWORD": secrets["postgres_password"],
        "DATABASE_URL": (
            "postgresql+asyncpg://correlia:"
            f"{secrets['postgres_password']}@postgres:5432/correlia"
        ),
        "CORRELIA_ENVIRONMENT": "test",
        "CORRELIA_LOG_LEVEL": "INFO",
        "CORRELIA_RULES_PATH": "/app/config/rules.yaml",
        "CORRELIA_TOPOLOGY_PATH": "/app/config/topology.yaml",
        "CORRELIA_PLUGINS_PATH": "/app/config/plugins.yaml",
        "CORRELIA_API_AUTH_ENABLED": "true",
        "CORRELIA_OPERATOR_API_TOKEN": secrets["operator_token"],
        "CORRELIA_INGRESS_API_TOKEN": secrets["ingress_token"],
        "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY": secrets["audit_key"],
        "CORRELIA_EXPOSE_READYZ": "false",
        "CORRELIA_EXPOSE_METRICS": "false",
    }
    env_file = tmp_path / ".env"
    env_file.write_text(
        "\n".join(f"{name}={value}" for name, value in environment_values.items())
        + "\n"
    )
    override_file = tmp_path / "compose.override.yaml"
    override_file.write_text(
        "\n".join(
            (
                "services:",
                "  correlia:",
                "    ports: !reset []",
                "    environment:",
                "      CORRELIA_MIGRATION_REPORT_PATH: /app/reports/migration-report.json",
                "      CORRELIA_RULES_PATH: /app/smoke/rules.yaml",
                "    volumes:",
                f"      - {report_path}:/app/reports/migration-report.json:ro",
                f"      - {smoke_rules_path}:/app/smoke/rules.yaml:ro",
                "  mailpit:",
                "    ports: !reset []",
                "",
            )
        )
    )
    stack: dict[str, object] = {
        "project": f"correlia-u7-{suffix}",
        "env_file": env_file,
        "override_file": override_file,
        "report_path": report_path,
        "secrets": secrets,
        "environment": {**os.environ, **environment_values},
    }

    try:
        _require_docker_success(
            _docker_compose_arguments(stack, "up", "--build", "--detach", "--wait"),
            environment=stack["environment"],  # type: ignore[arg-type]
            timeout=300,
        )
    except BaseException:
        _compose_cleanup(stack)
        raise
    try:
        yield stack
    finally:
        _compose_cleanup(stack)


def _load_dotenv_example(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        assert separator and key
        values[key] = value
    return values


def _secret_interpolation_paths(
    value: object,
    *,
    path: str,
    secret_names: frozenset[str],
) -> list[str]:
    if isinstance(value, dict):
        paths: list[str] = []
        for key, nested_value in value.items():
            paths.extend(
                _secret_interpolation_paths(
                    nested_value,
                    path=f"{path}.{key}",
                    secret_names=secret_names,
                )
            )
        return paths
    if isinstance(value, list):
        paths = []
        for index, nested_value in enumerate(value):
            paths.extend(
                _secret_interpolation_paths(
                    nested_value,
                    path=f"{path}[{index}]",
                    secret_names=secret_names,
                )
            )
        return paths
    if isinstance(value, str) and any(
        f"${{{secret_name}" in value for secret_name in secret_names
    ):
        return [path]
    return []


def _dockerfile_instructions(text: str) -> list[tuple[str, str]]:
    instructions: list[tuple[str, str]] = []
    logical_line = ""
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        logical_line = f"{logical_line} {line}".strip()
        if line.endswith("\\"):
            logical_line = logical_line[:-1].rstrip()
            continue
        instruction, _, arguments = logical_line.partition(" ")
        instructions.append((instruction.upper(), arguments))
        logical_line = ""
    assert not logical_line
    return instructions


def _dockerignore_patterns(text: str) -> set[str]:
    return {
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def _dockerignore_excludes(path: str, patterns: set[str]) -> bool:
    path_parts = path.split("/")
    for pattern in patterns:
        if pattern.endswith("/"):
            directory_pattern = pattern[:-1]
            if any(
                fnmatchcase("/".join(path_parts[:index]), directory_pattern)
                for index in range(1, len(path_parts) + 1)
            ):
                return True
        elif fnmatchcase(path, pattern):
            return True
    return False


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o755)


def _run_controlled_entrypoint(
    tmp_path: Path,
    *,
    database_url: str | None,
    alembic_exit: int = 0,
    alembic_output: str = "",
    web_concurrency: str | None = None,
) -> tuple[subprocess.CompletedProcess[str], list[str], str]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    event_log = tmp_path / "events.log"
    database_capture = tmp_path / "database-url.txt"

    _write_executable(
        bin_dir / "alembic",
        """#!/bin/sh
printf '%s\\n' migration >> "$EVENT_LOG"
printf '%s' "${DATABASE_URL-}" > "$DATABASE_CAPTURE"
printf '%s\\n' "$@" >> "$EVENT_LOG"
printf '%s\\n' "$ALEMBIC_OUTPUT"
printf '%s\\n' "$ALEMBIC_OUTPUT" >&2
exit "$ALEMBIC_EXIT"
""",
    )
    _write_executable(
        bin_dir / "uvicorn",
        """#!/bin/sh
printf '%s\\n' server >> "$EVENT_LOG"
printf '%s\\n' "$@" >> "$EVENT_LOG"
""",
    )

    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{bin_dir}{os.pathsep}{environment['PATH']}",
            "EVENT_LOG": str(event_log),
            "DATABASE_CAPTURE": str(database_capture),
            "ALEMBIC_EXIT": str(alembic_exit),
            "ALEMBIC_OUTPUT": alembic_output,
        }
    )
    if database_url is None:
        environment.pop("DATABASE_URL", None)
    else:
        environment["DATABASE_URL"] = database_url
    if web_concurrency is not None:
        environment["WEB_CONCURRENCY"] = web_concurrency

    result = subprocess.run(
        [str(ENTRYPOINT_PATH)],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    events = event_log.read_text().splitlines() if event_log.exists() else []
    captured_database_url = (
        database_capture.read_text() if database_capture.exists() else ""
    )
    return result, events, captured_database_url


def test_entrypoint_migrates_with_inherited_database_url_before_one_factory_server(
    tmp_path: Path,
) -> None:
    database_url = "postgresql+asyncpg://test-user:test-password@db:5432/correlia"

    result, events, captured_database_url = _run_controlled_entrypoint(
        tmp_path,
        database_url=database_url,
        web_concurrency="17",
    )

    assert result.returncode == 0
    assert (
        "exec uvicorn app.main:create_app --factory --host 0.0.0.0 "
        "--port 8000 --workers 1 --no-access-log"
    ) in ENTRYPOINT_PATH.read_text()
    assert captured_database_url == database_url
    assert events == [
        "migration",
        "upgrade",
        "head",
        "server",
        "app.main:create_app",
        "--factory",
        "--host",
        "0.0.0.0",
        "--port",
        "8000",
        "--workers",
        "1",
        "--no-access-log",
    ]
    assert database_url not in events
    assert "--reload" not in events


def test_entrypoint_propagates_migration_failure_without_server_or_secret_diagnostics(
    tmp_path: Path,
) -> None:
    database_url = "postgresql+asyncpg://test-user:credential-sentinel@db:5432/correlia"
    injected_sentinel = "migration-error-sentinel"

    result, events, _ = _run_controlled_entrypoint(
        tmp_path,
        database_url=database_url,
        alembic_exit=37,
        alembic_output=injected_sentinel,
    )

    diagnostics = f"{result.stdout}\n{result.stderr}"
    assert result.returncode == 37
    assert events == ["migration", "upgrade", "head"]
    assert "server" not in events
    assert "downgrade" not in events
    assert "Database migration failed" in diagnostics
    assert database_url not in diagnostics
    assert injected_sentinel not in diagnostics


def test_entrypoint_blocks_invalid_database_configuration_before_server(
    tmp_path: Path,
) -> None:
    invalid_database_url = "invalid-database-credential-sentinel"

    result, events, _ = _run_controlled_entrypoint(
        tmp_path,
        database_url=invalid_database_url,
        alembic_exit=2,
        alembic_output=invalid_database_url,
    )

    diagnostics = f"{result.stdout}\n{result.stderr}"
    assert result.returncode == 2
    assert events == ["migration", "upgrade", "head"]
    assert "server" not in events
    assert invalid_database_url not in diagnostics


def test_entrypoint_rejects_missing_database_url_before_migration_or_server(
    tmp_path: Path,
) -> None:
    result, events, _ = _run_controlled_entrypoint(tmp_path, database_url=None)

    assert result.returncode != 0
    assert events == []
    assert "Database configuration is required" in result.stderr


def test_dockerfile_defines_a_locked_production_only_narrow_non_root_runtime() -> None:
    dockerfile = DOCKERFILE_PATH.read_text()
    instructions = _dockerfile_instructions(dockerfile)
    copy_arguments = [
        arguments for instruction, arguments in instructions if instruction == "COPY"
    ]

    assert ("RUN", "uv sync --locked --no-dev --no-install-project") in instructions
    assert ("COPY", "pyproject.toml uv.lock ./") in instructions
    assert all(arguments != ". ." for arguments in copy_arguments)
    assert all(instruction != "ADD" for instruction, _ in instructions)
    assert ("USER", "correlia") in instructions
    assert any(
        instruction == "RUN" and "useradd" in arguments and "correlia" in arguments
        for instruction, arguments in instructions
    )
    assert ("ENTRYPOINT", '["/app/scripts/container-entrypoint.sh"]') in instructions
    assert "DATABASE_URL" not in dockerfile
    assert "WEB_CONCURRENCY" not in dockerfile


def test_dockerignore_excludes_secrets_vcs_tool_state_caches_and_local_artifacts() -> (
    None
):
    patterns = _dockerignore_patterns(DOCKERIGNORE_PATH.read_text())

    excluded_paths = (
        ".env.production",
        ".git/config",
        ".claude/settings.json",
        ".coderabbit.yaml",
        ".planning/research/.cache/cache-entry.json",
        ".planning/graphs/.last-build-snapshot.json",
        ".last-build-snapshot.json",
        ".venv/bin/python",
        "__pycache__/main.cpython-314.pyc",
        ".pytest_cache/v/cache/nodeids",
        ".mypy_cache/3.14/cache.json",
        ".ruff_cache/check.json",
        "build/wheel",
        "dist/correlia.whl",
        "correlia.egg-info/PKG-INFO",
        "developer.pem",
        "private.key",
        "certificate.p12",
        "certificate.pfx",
        "local.db",
    )

    assert all(_dockerignore_excludes(path, patterns) for path in excluded_paths)


def test_compose_topology_keeps_dependencies_private_and_uses_health_ordering() -> None:
    compose = yaml.safe_load(COMPOSE_PATH.read_text())

    assert set(compose["services"]) == {"postgres", "correlia", "mailpit"}
    assert compose["services"]["postgres"]["image"] == "postgres:16.9-alpine"
    assert compose["services"]["mailpit"]["image"] == "axllent/mailpit:v1.26.1"
    assert compose["services"]["correlia"]["build"] == "."
    assert compose["services"]["correlia"]["deploy"] == {"replicas": 1}
    assert compose["services"]["correlia"]["read_only"] is True
    assert compose["services"]["correlia"]["volumes"] == ["./config:/app/config:ro"]
    assert compose["services"]["correlia"]["depends_on"] == {
        "postgres": {"condition": "service_healthy"},
        "mailpit": {"condition": "service_healthy"},
    }

    for service_name in ("postgres", "mailpit"):
        healthcheck = compose["services"][service_name]["healthcheck"]
        assert healthcheck["interval"] == "5s"
        assert healthcheck["timeout"] == "3s"
        assert healthcheck["retries"] == 12

    app_healthcheck = compose["services"]["correlia"]["healthcheck"]["test"]
    assert "/v1/health" in " ".join(app_healthcheck)
    assert "TOKEN" not in " ".join(app_healthcheck)
    assert "DATABASE_URL" not in " ".join(app_healthcheck)

    assert compose["networks"] == {
        "database": {"internal": True},
        "smtp": {"internal": True},
    }
    assert compose["services"]["postgres"]["networks"] == ["database"]
    assert compose["services"]["mailpit"]["networks"] == ["smtp"]
    assert compose["services"]["correlia"]["networks"] == ["database", "smtp"]
    assert compose["services"]["postgres"].get("ports") is None
    assert compose["services"]["mailpit"]["ports"] == ["127.0.0.1:8025:8025"]
    assert compose["services"]["correlia"]["ports"] == ["127.0.0.1:8000:8000"]


def test_compose_secret_references_are_limited_to_service_runtime_environment() -> None:
    compose = yaml.safe_load(COMPOSE_PATH.read_text())
    secret_names = frozenset(
        {
            "DATABASE_URL",
            "POSTGRES_PASSWORD",
            "CORRELIA_OPERATOR_API_TOKEN",
            "CORRELIA_INGRESS_API_TOKEN",
            "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
        }
    )
    expected_runtime_paths = {
        "services.postgres.environment.POSTGRES_PASSWORD",
        "services.correlia.environment.DATABASE_URL",
        "services.correlia.environment.CORRELIA_OPERATOR_API_TOKEN",
        "services.correlia.environment.CORRELIA_INGRESS_API_TOKEN",
        "services.correlia.environment.CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
    }
    runtime_paths: set[str] = set()
    prohibited_paths: list[str] = []

    for service_name, service in compose["services"].items():
        runtime_paths.update(
            _secret_interpolation_paths(
                service.get("environment", {}),
                path=f"services.{service_name}.environment",
                secret_names=secret_names,
            )
        )
        for field in ("build", "command", "entrypoint", "labels", "healthcheck"):
            prohibited_paths.extend(
                _secret_interpolation_paths(
                    service.get(field, {}),
                    path=f"services.{service_name}.{field}",
                    secret_names=secret_names,
                )
            )

    assert runtime_paths == expected_runtime_paths
    assert prohibited_paths == []


def test_environment_and_config_samples_construct_strict_runtime_configuration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    example = _load_dotenv_example(ENV_EXAMPLE_PATH)
    required_settings_names = {
        "DATABASE_URL",
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
        "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
    }
    assert required_settings_names.issubset(example)
    assert all(
        example[name].startswith("replace-with-")
        for name in (
            "POSTGRES_PASSWORD",
            "CORRELIA_OPERATOR_API_TOKEN",
            "CORRELIA_INGRESS_API_TOKEN",
            "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
        )
    )

    settings_values = {
        **{
            key: value
            for key, value in example.items()
            if key == "DATABASE_URL" or key.startswith("CORRELIA_")
        },
        "DATABASE_URL": "postgresql+asyncpg://test:database-secret@postgres:5432/correlia",
        "CORRELIA_OPERATOR_API_TOKEN": "operator-secret",
        "CORRELIA_INGRESS_API_TOKEN": "ingress-secret",
        "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY": "audit-secret",
    }
    for name, value in settings_values.items():
        monkeypatch.setenv(name, value)

    settings = Settings()

    assert settings.api_auth_enabled is True
    assert settings.expose_readyz is False
    assert settings.operator_api_token is not None
    assert settings.ingress_api_token is not None
    assert settings.operator_api_token.get_secret_value() != (
        settings.ingress_api_token.get_secret_value()
    )

    plugin_config = load_plugin_registry_config(CONFIG_DIRECTORY / "plugins.yaml")
    registry = load_plugin_registry(CONFIG_DIRECTORY / "plugins.yaml")
    rules = load_rules_config(
        CONFIG_DIRECTORY / "rules.yaml",
        known_plugins=frozenset(registry.names),
    )
    topology = load_topology_config(CONFIG_DIRECTORY / "topology.yaml")

    assert registry.names == ("email-ops",)
    assert len(rules.rules) == 1
    rule = rules.rules[0].definition
    assert rule.window.trigger_threshold == 1
    assert set(rule.window.group_by) == {"host", "topology.datacenter"}
    assert "topology.datacenter" in topology.hostname_rules[0].tag_capture_groups

    entry = plugin_config.outputs[0]
    assert entry.options["host"] == "mailpit"
    assert entry.options["port"] == 1025
    assert not {"username", "password", "token", "authorization", "dsn"} & set(
        entry.options
    )


def test_real_compose_smoke_proves_runtime_deployment_contract(
    docker_compose_stack: dict[str, object],
    tmp_path: Path,
) -> None:
    """Exercise the checked-in image and topology; the fixture always removes it."""
    stack = docker_compose_stack
    project = str(stack["project"])
    secrets = stack["secrets"]
    assert isinstance(secrets, dict)
    operator_token = str(secrets["operator_token"])
    ingress_token = str(secrets["ingress_token"])
    postgres_password = str(secrets["postgres_password"])
    audit_key = str(secrets["audit_key"])
    app_container = _require_docker_success(
        _docker_compose_arguments(stack, "ps", "--quiet", "correlia")
    ).stdout.strip()
    postgres_container = _require_docker_success(
        _docker_compose_arguments(stack, "ps", "--quiet", "postgres")
    ).stdout.strip()
    mailpit_container = _require_docker_success(
        _docker_compose_arguments(stack, "ps", "--quiet", "mailpit")
    ).stdout.strip()
    if not app_container or not postgres_container or not mailpit_container:
        pytest.fail("Compose smoke did not create all required services")

    app_url = "http://127.0.0.1:8000"
    mailpit_url = "http://mailpit:8025"
    status, health_body = _wait_until(
        "public application health",
        lambda: (
            response
            if (
                response := _container_http_response(
                    app_container, f"{app_url}/v1/health"
                )
            )[0]
            == 200
            else None
        ),
    )
    assert status == 200
    assert json.loads(health_body) == {"status": "ok"}

    status, _ = _container_http_response(app_container, f"{app_url}/v1/readyz")
    assert status == 401
    status, _ = _container_http_response(
        app_container, f"{app_url}/v1/readyz", token="wrong-token"
    )
    assert status == 401
    status, ready_body = _container_http_response(
        app_container, f"{app_url}/v1/readyz", token=operator_token
    )
    assert status == 200
    assert json.loads(ready_body)["status"] == "ready"

    status, _ = _container_http_response(app_container, f"{app_url}/v1/metrics")
    assert status == 401
    status, metrics_body = _container_http_response(
        app_container, f"{app_url}/v1/metrics", token=operator_token
    )
    assert status == 200
    initial_metrics = metrics_body.decode()
    assert _metric_value(
        initial_metrics,
        "correlia_vigilo_migration_report_status",
        {"status": "valid"},
    ) == 1.0
    metric_baselines = {
        "audit_writes": _metric_value(
            initial_metrics,
            "correlia_audit_writes_total",
            {"outcome": "success"},
            default=0,
        ),
        "events_accepted": _metric_value(
            initial_metrics,
            "correlia_events_accepted_total",
            {"event_type": "PROBLEM"},
            default=0,
        ),
        "matched_rules": _metric_value(
            initial_metrics, "correlia_matched_rules_total", default=0
        ),
        "incident_inserted": _metric_value(
            initial_metrics,
            "correlia_incident_effects_total",
            {"effect": "inserted"},
            default=0,
        ),
        "notification_submissions": _metric_value(
            initial_metrics,
            "correlia_notification_submissions_total",
            {"outcome": "accepted"},
            default=0,
        ),
        "notification_deliveries": _metric_value(
            initial_metrics,
            "correlia_notification_deliveries_total",
            {"category": "dispatched", "outcome": "success"},
            default=0,
        ),
        "compatibility_acknowledgements": _metric_value(
            initial_metrics,
            "correlia_compatibility_mutations_total",
            {"operation": "patch_acknowledge", "outcome": "success"},
            default=0,
        ),
    }

    migration_revision = _require_docker_success(
        [
            "exec",
            postgres_container,
            "sh",
            "-c",
            (
                'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 '
                '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc '
                "'SELECT version_num FROM alembic_version'"
            ),
        ]
    ).stdout.strip()
    image_head = _require_docker_success(
        ["run", "--rm", "--entrypoint", "alembic", "correlia:local", "heads"]
    ).stdout.split()[0]
    assert migration_revision == image_head

    app_inspection = _docker_json(["inspect", app_container])
    assert isinstance(app_inspection, list) and len(app_inspection) == 1
    app_state = app_inspection[0]
    assert isinstance(app_state, dict)
    config = app_state["Config"]
    host_config = app_state["HostConfig"]
    assert isinstance(config, dict) and isinstance(host_config, dict)
    assert config["User"] == "correlia"
    assert host_config["ReadonlyRootfs"] is True
    runtime_environment = "\n".join(config["Env"])
    for secret in (postgres_password, operator_token, ingress_token, audit_key):
        if secret not in runtime_environment:
            pytest.fail(
                "runtime secret was not injected exclusively into service environment"
            )
    command_surface = json.dumps(
        {
            "command": config.get("Cmd"),
            "entrypoint": config.get("Entrypoint"),
            "labels": config.get("Labels"),
            "healthcheck": config.get("Healthcheck"),
        },
        sort_keys=True,
    )
    image_surface = json.dumps(_docker_json(["image", "inspect", "correlia:local"]))
    history_surface = _require_docker_success(
        ["image", "history", "--no-trunc", "correlia:local"]
    ).stdout
    for secret in (postgres_password, operator_token, ingress_token, audit_key):
        _assert_secret_absent(command_surface, "container command surface", secret)
        _assert_secret_absent(image_surface, "image configuration", secret)
        _assert_secret_absent(history_surface, "image history", secret)

    processes = _require_docker_success(
        ["top", app_container, "-eo", "pid,user,args"]
    ).stdout.splitlines()
    uvicorn_processes = [line for line in processes if "uvicorn" in line]
    assert len(uvicorn_processes) == 1
    assert "--workers 1" in uvicorn_processes[0]
    assert "--no-access-log" in uvicorn_processes[0]
    assert "--reload" not in uvicorn_processes[0]
    pid_one_command = _require_docker_success(
        [
            "exec",
            app_container,
            "python",
            "-c",
            (
                "import sys; "
                "sys.stdout.buffer.write(open('/proc/1/cmdline', 'rb').read())"
            ),
        ]
    ).stdout.replace("\x00", " ")
    assert "uvicorn" in pid_one_command
    assert "app.main:create_app" in pid_one_command
    assert "--no-access-log" in pid_one_command
    assert int(app_state["State"]["Pid"]) > 0

    for path in (
        "/app/app/main.py",
        "/app/migrations",
        "/app/alembic.ini",
        "/app/scripts/container-entrypoint.sh",
    ):
        _require_docker_success(
            ["exec", "--user", "correlia", app_container, "test", "-r", path]
        )
    assert (
        _docker(
            [
                "exec",
                "--user",
                "correlia",
                app_container,
                "sh",
                "-c",
                "touch /correlia-rootfs-probe",
            ]
        ).returncode
        != 0
    )
    for path in ("/app/config/u7-write-probe", "/app/reports/migration-report.json"):
        assert (
            _docker(
                [
                    "exec",
                    "--user",
                    "correlia",
                    app_container,
                    "sh",
                    "-c",
                    f"printf x >> {path}",
                ]
            ).returncode
            != 0
        )
    report_path = stack["report_path"]
    assert isinstance(report_path, Path)
    report_checksum_before = _file_checksum(report_path)
    config_checksums_before = {
        path: _file_checksum(path) for path in CONFIG_DIRECTORY.glob("*.yaml")
    }

    payload = {
        "source_id": "icinga2:service:dc1-app-web:http",
        "host": "dc1-app-web",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "ip_address": "192.0.2.10",
        "check_output": "HTTP 503",
        "tags": {"team.name": "platform", "topology.datacenter": "dc1"},
    }
    status, ingestion_body = _container_http_response(
        app_container,
        f"{app_url}/v1/icinga2/events",
        token=ingress_token,
        payload=payload,
        method="POST",
    )
    assert status == 200
    ingestion = json.loads(ingestion_body)
    assert ingestion["threshold_crossed"] is True
    assert ingestion["notification_triggered"] is True
    incident_id = str(ingestion["incident_id"])
    status, incidents_body = _container_http_response(
        app_container, f"{app_url}/v1/incidents", token=operator_token
    )
    assert status == 200
    assert any(
        item["id"] == incident_id for item in json.loads(incidents_body)["items"]
    )
    status, _ = _container_http_response(
        app_container,
        f"{app_url}/v1/incidents/{incident_id}",
        token=operator_token,
        payload={"status": "ACKNOWLEDGED"},
        method="PATCH",
    )
    assert status == 200

    expected_subject = (
        "[Correlia] [CRITICAL] docker-smoke-threshold: Critical alert on dc1-app-web"
    )

    def expected_smtp_message() -> tuple[dict[str, object], str] | None:
        messages = _mailpit_messages(app_container, f"{mailpit_url}/api/v1/messages")
        if messages is None:
            return None
        for message in messages:
            if (
                message.get("Subject") != expected_subject
                or message.get("To") != [{"Name": "", "Address": "ops@example.test"}]
            ):
                continue
            message_id = message.get("ID")
            if not isinstance(message_id, str):
                continue
            status, message_body = _container_http_response(
                app_container, f"{mailpit_url}/api/v1/message/{message_id}"
            )
            if status != 200:
                continue
            try:
                message_text = str(json.loads(message_body)["Text"])
            except (KeyError, TypeError, json.JSONDecodeError):
                continue
            if (
                f"Incident ID: {incident_id}" in message_text
                and "Rule: docker-smoke-threshold" in message_text
                and "Affected hosts: dc1-app-web" in message_text
            ):
                return message, message_text
        return None

    message, message_text = _wait_until(
        "expected SMTP notification after threshold crossing", expected_smtp_message
    )
    assert message["Subject"] == expected_subject
    assert message["To"] == [{"Name": "", "Address": "ops@example.test"}]
    assert f"Incident ID: {incident_id}" in message_text
    assert "Rule: docker-smoke-threshold" in message_text
    assert "Affected hosts: dc1-app-web" in message_text

    def runtime_metric_deltas() -> str | None:
        status, metrics_body = _container_http_response(
            app_container, f"{app_url}/v1/metrics", token=operator_token
        )
        if status != 200:
            return None
        candidate = metrics_body.decode()
        expected_deltas = (
            (
                "audit_writes",
                "correlia_audit_writes_total",
                {"outcome": "success"},
            ),
            (
                "events_accepted",
                "correlia_events_accepted_total",
                {"event_type": "PROBLEM"},
            ),
            ("matched_rules", "correlia_matched_rules_total", None),
            (
                "incident_inserted",
                "correlia_incident_effects_total",
                {"effect": "inserted"},
            ),
            (
                "notification_submissions",
                "correlia_notification_submissions_total",
                {"outcome": "accepted"},
            ),
            (
                "notification_deliveries",
                "correlia_notification_deliveries_total",
                {"category": "dispatched", "outcome": "success"},
            ),
            (
                "compatibility_acknowledgements",
                "correlia_compatibility_mutations_total",
                {"operation": "patch_acknowledge", "outcome": "success"},
            ),
        )
        if all(
            _metric_value(candidate, metric_name, labels, default=0)
            == metric_baselines[baseline_name] + 1
            for baseline_name, metric_name, labels in expected_deltas
        ):
            return candidate
        return None

    runtime_metrics = _wait_until("concrete operational metric deltas", runtime_metric_deltas)
    assert isinstance(runtime_metrics, str)
    assert _metric_value(
        runtime_metrics,
        "correlia_vigilo_migration_report_status",
        {"status": "valid"},
    ) == 1.0
    for forbidden in (
        postgres_password,
        operator_token,
        ingress_token,
        audit_key,
        "dc1-app-web",
        "service=http",
        "icinga2:service:dc1-app-web:http",
    ):
        _assert_secret_absent(runtime_metrics, "runtime metrics", forbidden)
    _require_docker_success(["stop", "--time", "1", postgres_container])
    try:
        status, _ = _container_http_response(app_container, f"{app_url}/v1/health")
        assert status == 200
        status, readiness_diagnostics = _wait_until(
            "readiness to report runtime database loss",
            lambda: (
                response
                if (
                    response := _container_http_response(
                        app_container, f"{app_url}/v1/readyz", token=operator_token
                    )
                )[0]
                == 503
                else None
            ),
        )
        assert status == 503
        diagnostics = readiness_diagnostics.decode()
        for secret in (postgres_password, operator_token, ingress_token, audit_key):
            _assert_secret_absent(diagnostics, "readiness diagnostics", secret)
    finally:
        _require_docker_success(["start", postgres_container])
    _wait_until(
        "readiness after database recovery",
        lambda: (
            response
            if (
                response := _container_http_response(
                    app_container, f"{app_url}/v1/readyz", token=operator_token
                )
            )[0]
            == 200
            else None
        ),
    )

    _require_docker_success(["kill", "--signal", "SIGTERM", app_container])
    stopped_app = _wait_until(
        "Uvicorn signal handoff",
        lambda: (
            (inspection if not inspection[0]["State"]["Running"] else None)
            if (inspection := _docker_json(["inspect", app_container]))
            else None
        ),
    )
    assert isinstance(stopped_app, list) and len(stopped_app) == 1
    assert stopped_app[0]["State"]["ExitCode"] == 0
    _require_docker_success(
        _docker_compose_arguments(stack, "up", "--detach", "--wait", "correlia"),
        environment=stack["environment"],  # type: ignore[arg-type]
    )
    migration_revision_after_restart = _require_docker_success(
        [
            "exec",
            postgres_container,
            "sh",
            "-c",
            (
                'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 '
                '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc '
                "'SELECT version_num FROM alembic_version'"
            ),
        ]
    ).stdout.strip()
    assert migration_revision_after_restart == migration_revision

    migration_failure_name = f"{project}-migration-failure"
    migration_failure_secret = f"migration-failure-{uuid4().hex}"
    migration_failure_dsn = (
        "postgresql+asyncpg://correlia:"
        f"{migration_failure_secret}@postgres:5432/correlia"
    )
    migration_failure_env = tmp_path / "migration-failure.env"
    migration_failure_env.write_text(f"DATABASE_URL={migration_failure_dsn}\n")
    try:
        migration_failure = _docker(
            [
                "run",
                "--name",
                migration_failure_name,
                "--network",
                f"{project}_database",
                "--env-file",
                str(migration_failure_env),
                "correlia:local",
            ],
            timeout=60,
        )
        assert migration_failure.returncode != 0
        migration_diagnostics = (
            f"{migration_failure.stdout}\n{migration_failure.stderr}"
        )
        assert "Database migration failed" in migration_diagnostics
        assert "downgrade" not in migration_diagnostics
        for secret in (
            postgres_password,
            operator_token,
            ingress_token,
            audit_key,
            migration_failure_secret,
            migration_failure_dsn,
        ):
            _assert_secret_absent(
                migration_diagnostics, "migration failure diagnostics", secret
            )
    finally:
        _require_docker_success(["rm", "--force", migration_failure_name])

    invalid_config = tmp_path / "invalid-config"
    shutil.copytree(CONFIG_DIRECTORY, invalid_config)
    invalid_plugin_sentinel = f"u7-invalid-plugin-{uuid4().hex}"
    invalid_plugins = yaml.safe_load((invalid_config / "plugins.yaml").read_text())
    invalid_plugins["outputs"][0]["class_path"] = (
        f"app.plugins.outputs.{invalid_plugin_sentinel}.MissingPlugin"
    )
    (invalid_config / "plugins.yaml").write_text(yaml.safe_dump(invalid_plugins))
    invalid_plugin_name = f"{project}-invalid-plugin"
    env_file = stack["env_file"]
    assert isinstance(env_file, Path)
    try:
        invalid_plugin = _docker(
            [
                "run",
                "--name",
                invalid_plugin_name,
                "--network",
                f"{project}_database",
                "--volume",
                f"{invalid_config}:/app/config:ro",
                "--env-file",
                str(env_file),
                "correlia:local",
            ],
            timeout=90,
        )
        assert invalid_plugin.returncode != 0
        invalid_diagnostics = f"{invalid_plugin.stdout}\n{invalid_plugin.stderr}"
        invalid_logs = _require_docker_success(["logs", invalid_plugin_name])
        for surface in (invalid_diagnostics, invalid_logs.stdout, invalid_logs.stderr):
            _assert_secret_absent(
                surface,
                "invalid plugin startup diagnostics",
                invalid_plugin_sentinel,
            )
            for secret in (postgres_password, operator_token, ingress_token, audit_key):
                _assert_secret_absent(
                    surface, "invalid plugin startup diagnostics", secret
                )
        plugin_events = [
            json.loads(line)
            for line in f"{invalid_logs.stdout}\n{invalid_logs.stderr}".splitlines()
            if line.startswith("{")
        ]
        expected_plugin_event = {
            "event": "plugin_load",
            "outcome": "failure",
            "category": "email",
            "failure_code": "module_or_class",
            "entry_position": 1,
        }
        assert any(
            expected_plugin_event.items() <= event.items() for event in plugin_events
        )
        invalid_inspection = _docker_json(["inspect", invalid_plugin_name])
        assert isinstance(invalid_inspection, list) and len(invalid_inspection) == 1
        assert invalid_inspection[0]["State"]["ExitCode"] != 0
    finally:
        _require_docker_success(["rm", "--force", invalid_plugin_name])

    assert _file_checksum(report_path) == report_checksum_before
    assert {
        path: _file_checksum(path) for path in CONFIG_DIRECTORY.glob("*.yaml")
    } == config_checksums_before
