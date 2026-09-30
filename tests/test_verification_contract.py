"""Exercise the real repository hooks in disposable, small pytest sessions."""

from __future__ import annotations

from collections.abc import Iterator
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import textwrap
from types import ModuleType
from uuid import uuid4

import pytest

from scripts import cleanup_verification


_SMOKE = """
import pytest

@pytest.mark.deployment
def test_real_compose_smoke_proves_runtime_deployment_contract():
    assert True
"""
_POSTGRES = """
import pytest

@pytest.fixture
def postgres_url():
    return "unused-by-the-fixture"

def test_postgres(postgres_url):
    assert postgres_url
"""
_POSIX = """
import pytest

@pytest.mark.posix
def test_posix():
    assert True
"""


@pytest.fixture
def child_suite(tmp_path: Path) -> tuple[Path, Path]:
    root = tmp_path / "isolated"
    tests = root / "tests"
    tests.mkdir(parents=True)
    # Load the production hook definitions, not a second model of their logic.
    (root / "conftest.py").write_text(
        Path(__file__).with_name("conftest.py").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    (tests / "test_deployment.py").write_text(_SMOKE, encoding="utf-8")
    (tests / "test_database.py").write_text(_POSTGRES, encoding="utf-8")
    (tests / "test_posix.py").write_text(_POSIX, encoding="utf-8")
    return root, tests


def _run(
    root: Path,
    mode: str | None,
    *,
    args: tuple[str, ...] = (),
    env: dict[str, str] | None = None,
    fake_prerequisites: bool = True,
    docker_available: bool = True,
) -> subprocess.CompletedProcess[str]:
    plugin = f"""
import pytest
from types import SimpleNamespace

class FixturePrerequisites:
    @pytest.hookimpl(tryfirst=True)
    def pytest_sessionstart(self, session):
        for module in session.config.pluginmanager.get_plugins():
            if (
                getattr(module, "__file__", "").endswith("conftest.py")
                and hasattr(module, "_docker_available")
            ):
                module.sys = SimpleNamespace(platform="linux")
                module._docker_available = lambda **kwargs: {docker_available!r}
                return
        raise RuntimeError("production conftest was not loaded")
"""
    runner = f"""
import pytest
{plugin if fake_prerequisites else ""}
pytest_args = {([f"--verification-mode={mode}"] if mode else []) + list(args)!r}
raise SystemExit(pytest.main(pytest_args, plugins={"[FixturePrerequisites()]" if fake_prerequisites else "[]"}))
"""
    child_env = os.environ.copy()
    child_env.pop("PYTEST_ADDOPTS", None)
    child_env.pop("PYTEST_PLUGINS", None)
    child_env["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    if env:
        child_env.update(env)
    return subprocess.run(
        [sys.executable, "-c", runner],
        cwd=root,
        env=child_env,
        capture_output=True,
        text=True,
        timeout=45,
        check=False,
    )


def _output(result: subprocess.CompletedProcess[str]) -> str:
    return result.stdout + result.stderr


def test_complete_full_and_exact_deployment_pass(
    child_suite: tuple[Path, Path],
) -> None:
    root, _ = child_suite
    for mode in ("full", "deployment"):
        result = _run(root, mode)
        assert result.returncode == 0, _output(result)


@pytest.mark.parametrize(
    ("phase", "file", "body"),
    [
        (
            "collection",
            "test_collected_skip.py",
            "import pytest\npytest.skip('no', allow_module_level=True)",
        ),
        (
            "setup",
            "test_database.py",
            "import pytest\n@pytest.fixture\ndef postgres_url():\n"
            "    pytest.skip('no')\ndef test_postgres(postgres_url):\n    pass",
        ),
        (
            "call",
            "test_posix.py",
            "import pytest\n@pytest.mark.posix\ndef test_posix():\n"
            "    pytest.skip('no')",
        ),
        (
            "teardown",
            "test_posix.py",
            "import pytest\n@pytest.fixture\ndef cleanup():\n    yield\n"
            "    pytest.skip('no')\n@pytest.mark.posix\ndef test_posix(cleanup):\n"
            "    pass",
        ),
    ],
)
def test_full_rejects_skips_in_every_phase(
    child_suite: tuple[Path, Path], phase: str, file: str, body: str
) -> None:
    root, tests = child_suite
    (tests / file).write_text(body, encoding="utf-8")
    result = _run(root, "full")
    assert result.returncode != 0, _output(result)
    assert "verification incomplete" in _output(result)
    diagnostic = {
        "collection": "collection skips",
        "setup": "incomplete setup/call/teardown",
        "call": "non-passing or xfail result",
        "teardown": "non-passing or xfail result",
    }[phase]
    assert diagnostic in _output(result)


@pytest.mark.parametrize(
    "body",
    [
        "import pytest\n@pytest.mark.posix\ndef test_posix():\n    pytest.xfail('known')",
        "import pytest\n@pytest.mark.posix\n@pytest.mark.xfail(reason='known')\ndef test_posix():\n    pass",
    ],
)
def test_full_rejects_xfail_and_unexpected_pass(
    child_suite: tuple[Path, Path], body: str
) -> None:
    root, tests = child_suite
    (tests / "test_posix.py").write_text(body, encoding="utf-8")
    result = _run(root, "full")
    assert result.returncode != 0, _output(result)
    assert "non-passing or xfail result" in _output(result)


@pytest.mark.parametrize(
    ("removed", "diagnostic"),
    [
        ("test_deployment.py", "required smoke collected 0 times"),
        ("test_database.py", "no PostgreSQL tests collected"),
        ("test_posix.py", "no POSIX tests collected"),
    ],
)
def test_full_rejects_missing_required_participation(
    child_suite: tuple[Path, Path], removed: str, diagnostic: str
) -> None:
    root, tests = child_suite
    (tests / removed).unlink()
    result = _run(root, "full")
    assert result.returncode != 0, _output(result)
    assert diagnostic in _output(result)


@pytest.mark.parametrize(
    "args",
    [
        ("-k", "test_posix"),
        ("--collect-only",),
        ("tests/test_posix.py",),
        ("-o", "addopts="),
        ("-x",),
    ],
)
def test_required_modes_reject_narrowing_and_nonexecution(
    child_suite: tuple[Path, Path], args: tuple[str, ...]
) -> None:
    root, _ = child_suite
    result = _run(root, "full", args=args)
    assert result.returncode != 0, _output(result)
    assert "selectors and pytest option overrides are forbidden" in _output(result)


def test_required_mode_rejects_inherited_pytest_addopts(
    child_suite: tuple[Path, Path],
) -> None:
    root, _ = child_suite
    result = _run(root, "deployment", env={"PYTEST_ADDOPTS": "-k test_posix"})
    assert result.returncode != 0, _output(result)
    assert "rejects PYTEST_ADDOPTS" in _output(result)


def test_full_rejects_empty_collection(
    child_suite: tuple[Path, Path],
) -> None:
    root, tests = child_suite
    for test_file in tests.glob("test_*.py"):
        test_file.unlink()
    result = _run(root, "full")
    assert result.returncode != 0, _output(result)
    assert "no tests selected" in _output(result)


def test_required_modes_fail_before_collection_without_docker(
    child_suite: tuple[Path, Path],
) -> None:
    root, _ = child_suite
    for mode in ("full", "deployment"):
        result = _run(root, mode, docker_available=False)
        assert result.returncode != 0, _output(result)
        assert "needs a running Docker daemon and Docker Compose" in _output(result)


def test_ordinary_mode_skips_unavailable_resource_cases(
    child_suite: tuple[Path, Path],
) -> None:
    root, _ = child_suite
    result = _run(root, None, args=("-rs",), docker_available=False)
    assert result.returncode == 0, _output(result)
    assert "requires a running Docker daemon" in _output(result)


def test_collection_error_preserves_pytest_exit_status(
    child_suite: tuple[Path, Path],
) -> None:
    root, tests = child_suite
    (tests / "test_broken.py").write_text("def test_broken(\n", encoding="utf-8")
    result = _run(root, "full")
    assert result.returncode == pytest.ExitCode.INTERRUPTED, _output(result)


def test_deployment_rejects_skipped_smoke(
    child_suite: tuple[Path, Path],
) -> None:
    root, tests = child_suite
    (tests / "test_deployment.py").write_text(
        "import pytest\n@pytest.mark.deployment\n"
        "def test_real_compose_smoke_proves_runtime_deployment_contract():\n"
        "    pytest.skip('service unavailable')\n",
        encoding="utf-8",
    )
    result = _run(root, "deployment")
    assert result.returncode != 0, _output(result)
    assert "non-passing or xfail result" in _output(result)


def test_full_rejects_duplicate_smoke(
    child_suite: tuple[Path, Path],
) -> None:
    root, tests = child_suite
    (tests / "test_deployment.py").write_text(
        "import pytest\n@pytest.mark.deployment\n"
        "@pytest.mark.parametrize('value', [1, 2])\n"
        "def test_real_compose_smoke_proves_runtime_deployment_contract(value):\n"
        "    assert value\n",
        encoding="utf-8",
    )
    result = _run(root, "full")
    assert result.returncode != 0, _output(result)
    assert "required smoke collected 0 times" in _output(result)


def test_full_rejects_interrupted_execution(
    child_suite: tuple[Path, Path],
) -> None:
    root, tests = child_suite
    (tests / "test_posix.py").write_text(
        "import pytest\n@pytest.mark.posix\ndef test_posix():\n"
        "    raise KeyboardInterrupt\n",
        encoding="utf-8",
    )
    result = _run(root, "full")
    assert result.returncode != 0, _output(result)
    assert "incomplete setup/call/teardown" in _output(result)


def test_existing_pytest_failure_remains_nonzero(
    child_suite: tuple[Path, Path],
) -> None:
    root, tests = child_suite
    (tests / "test_posix.py").write_text(
        "import pytest\n@pytest.mark.posix\ndef test_posix():\n    assert False\n",
        encoding="utf-8",
    )
    result = _run(root, "full")
    assert result.returncode == pytest.ExitCode.TESTS_FAILED, _output(result)


def test_portable_keeps_database_free_cases_in_mixed_modules(
    child_suite: tuple[Path, Path],
) -> None:
    root, tests = child_suite
    (tests / "test_database.py").write_text(
        textwrap.dedent("""
            import pytest
            @pytest.fixture
            def postgres_url():
                raise RuntimeError('database fixture must not start')
            def test_database(postgres_url):
                pass
            def test_portable(tmp_path):
                (tmp_path / 'visited').write_text('portable ran')
                assert (tmp_path / 'visited').read_text() == 'portable ran'
        """),
        encoding="utf-8",
    )
    result = _run(root, "portable", fake_prerequisites=False)
    assert result.returncode == 0, _output(result)
    assert "1 passed" in _output(result)
    assert "3 deselected" in _output(result)


class _OwnershipDocker:
    """Keep resource identity/state at the Docker boundary, not a cleanup mock."""

    def __init__(self) -> None:
        self.resources = {
            "container": {"developer-container": "developer-project"},
            "volume": {"developer-volume": "developer-project"},
            "network": {"developer-network": "developer-project"},
        }
        self.failed_inspection: tuple[str, ...] | None = None

    def run(self, arguments: list[str]) -> subprocess.CompletedProcess[str]:
        if tuple(arguments) == self.failed_inspection:
            return subprocess.CompletedProcess(["docker", *arguments], 1, stdout="")
        kind = {
            ("ps", "--all"): "container",
            ("volume", "ls"): "volume",
            ("network", "ls"): "network",
        }.get(tuple(arguments[:2]))
        if kind:
            resources = self.resources[kind]
            if "--filter" in arguments:
                project = arguments[-1].removeprefix(
                    "label=com.docker.compose.project="
                )
                names = [name for name, owner in resources.items() if owner == project]
            else:
                names = list(resources)
            return subprocess.CompletedProcess(
                ["docker", *arguments], 0, stdout="\n".join(sorted(names))
            )
        kind = {
            ("rm", "--force"): "container",
            ("volume", "rm"): "volume",
            ("network", "rm"): "network",
        }[tuple(arguments[:2])]
        del self.resources[kind][arguments[-1]]
        return subprocess.CompletedProcess(["docker", *arguments], 0, stdout="")

    def create_project(self, project: str) -> None:
        self.resources["container"][f"{project}-postgres"] = project
        self.resources["volume"][f"{project}_postgres-data"] = project
        self.resources["network"][f"{project}_database"] = project

    def snapshot(self) -> dict[str, dict[str, str]]:
        return {kind: dict(resources) for kind, resources in self.resources.items()}


@pytest.fixture
def ownership_boundary(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> tuple[ModuleType, _OwnershipDocker, Path]:
    script = Path(__file__).resolve().parents[1] / "scripts" / "verification.py"
    monkeypatch.setitem(sys.modules, "cleanup_verification", cleanup_verification)
    spec = importlib.util.spec_from_file_location("verification_under_test", script)
    assert spec is not None and spec.loader is not None
    wrapper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wrapper)
    (tmp_path / "uv.lock").write_text("unchanged-lock", encoding="utf-8")
    monkeypatch.setattr(wrapper, "ROOT", tmp_path)
    monkeypatch.setattr(wrapper, "gettempdir", lambda: str(tmp_path))
    monkeypatch.setattr(sys, "argv", [str(script), "test:deployment", "--", "child"])
    monkeypatch.setenv("CORRELIA_VERIFICATION_PROJECT", "correlia-verify-boundary")
    for name in (
        "CORRELIA_VERIFICATION_INVOCATION",
        "CORRELIA_VERIFICATION_RECEIPT",
        "GITHUB_ENV",
        "GITHUB_STEP_SUMMARY",
    ):
        monkeypatch.delenv(name, raising=False)
    docker = _OwnershipDocker()
    monkeypatch.setattr(cleanup_verification, "_docker", docker.run)
    started = tmp_path / "child-started"

    def child(
        command: list[str], *, env: dict[str, str], **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        started.write_text("started", encoding="utf-8")
        docker.create_project(env["CORRELIA_VERIFICATION_PROJECT"])
        return subprocess.CompletedProcess(command, 7)

    monkeypatch.setattr(wrapper.subprocess, "run", child)
    return wrapper, docker, started


@pytest.mark.parametrize("kind", ["container", "volume", "network"])
def test_outer_finalizer_never_deletes_a_rejected_namespace(
    ownership_boundary: tuple[ModuleType, _OwnershipDocker, Path], kind: str
) -> None:
    wrapper, docker, started = ownership_boundary
    docker.resources[kind]["preexisting-resource"] = "correlia-verify-boundary"
    before = docker.snapshot()

    assert wrapper.main() != 0
    assert not started.exists()
    assert docker.resources == before


@pytest.mark.parametrize("owner", ["", "correlia-verify-foreign"])
def test_outer_finalizer_rejects_exact_database_volume_without_matching_labels(
    ownership_boundary: tuple[ModuleType, _OwnershipDocker, Path], owner: str
) -> None:
    wrapper, docker, started = ownership_boundary
    docker.resources["volume"]["correlia-verify-boundary_postgres-data"] = owner
    before = docker.snapshot()

    assert wrapper.main() != 0
    assert not started.exists()
    assert docker.resources == before


@pytest.mark.parametrize(
    "inspection",
    [
        (
            "ps",
            "--all",
            "--quiet",
            "--filter",
            "label=com.docker.compose.project=correlia-verify-boundary",
        ),
        (
            "volume",
            "ls",
            "--quiet",
            "--filter",
            "label=com.docker.compose.project=correlia-verify-boundary",
        ),
        (
            "network",
            "ls",
            "--quiet",
            "--filter",
            "label=com.docker.compose.project=correlia-verify-boundary",
        ),
        ("volume", "ls", "--quiet"),
    ],
)
def test_outer_finalizer_fails_closed_when_freshness_cannot_be_inspected(
    ownership_boundary: tuple[ModuleType, _OwnershipDocker, Path],
    inspection: tuple[str, ...],
) -> None:
    wrapper, docker, started = ownership_boundary
    docker.failed_inspection = inspection
    before = docker.snapshot()

    assert wrapper.main() != 0
    assert not started.exists()
    assert docker.resources == before


def test_outer_finalizer_removes_only_owned_resources_after_child_failure(
    ownership_boundary: tuple[ModuleType, _OwnershipDocker, Path],
) -> None:
    wrapper, docker, started = ownership_boundary
    before = docker.snapshot()

    assert wrapper.main() == 7
    assert started.exists()
    assert docker.resources == before


def test_outer_finalizer_honors_receipt_after_interrupted_creation(
    ownership_boundary: tuple[ModuleType, _OwnershipDocker, Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    wrapper, docker, started = ownership_boundary
    before = docker.snapshot()

    def interrupted_child(
        _command: list[str], *, env: dict[str, str], **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        started.write_text("interrupted", encoding="utf-8")
        docker.create_project(env["CORRELIA_VERIFICATION_PROJECT"])
        raise KeyboardInterrupt

    monkeypatch.setattr(wrapper.subprocess, "run", interrupted_child)

    assert wrapper.main() == 130
    assert started.exists()
    assert docker.resources == before


@pytest.mark.parametrize("receipt_state", ["missing", "mismatch"])
def test_outer_finalizer_rejects_invalid_receipt_after_successful_child(
    ownership_boundary: tuple[ModuleType, _OwnershipDocker, Path],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    receipt_state: str,
) -> None:
    wrapper, docker, started = ownership_boundary
    sentinel = "correlia-verify-boundary-sentinel"
    docker.resources["volume"][sentinel] = "developer-project"
    after_creation: dict[str, dict[str, str]] = {}

    def successful_child(
        command: list[str], *, env: dict[str, str], **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        project = env["CORRELIA_VERIFICATION_PROJECT"]
        receipt = Path(env["CORRELIA_VERIFICATION_RECEIPT"])
        assert cleanup_verification.has_ownership(
            project, env["CORRELIA_VERIFICATION_INVOCATION"], receipt
        )
        started.write_text("successful", encoding="utf-8")
        docker.create_project(project)
        after_creation.update(docker.snapshot())
        if receipt_state == "missing":
            receipt.unlink()
        else:
            recorded = json.loads(receipt.read_text(encoding="utf-8"))
            recorded["invocation"] = "foreign-invocation"
            receipt.write_text(json.dumps(recorded), encoding="utf-8")
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(wrapper.subprocess, "run", successful_child)

    assert wrapper.main() != 0
    assert started.read_text(encoding="utf-8") == "successful"
    assert "Verification resource cleanup failed" in capsys.readouterr().err
    assert docker.resources == after_creation
    assert docker.resources["volume"][sentinel] == "developer-project"


@pytest.mark.parametrize("receipt_state", ["missing", "project", "invocation"])
def test_automatic_cleanup_gate_refuses_missing_or_mismatched_receipt(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, receipt_state: str
) -> None:
    docker = _OwnershipDocker()
    monkeypatch.setattr(cleanup_verification, "_docker", docker.run)
    project = "correlia-verify-gate"
    invocation = uuid4().hex
    receipt = tmp_path / "ownership.json"
    if receipt_state != "missing":
        receipt.write_text(
            json.dumps(
                {
                    "project": (
                        project
                        if receipt_state != "project"
                        else "correlia-verify-other"
                    ),
                    "invocation": (
                        invocation if receipt_state != "invocation" else uuid4().hex
                    ),
                }
            ),
            encoding="utf-8",
        )
    docker.create_project(project)
    before = docker.snapshot()
    monkeypatch.setenv("CORRELIA_VERIFICATION_PROJECT", project)
    monkeypatch.setenv("CORRELIA_VERIFICATION_INVOCATION", invocation)
    monkeypatch.setenv("CORRELIA_VERIFICATION_RECEIPT", str(receipt))
    monkeypatch.setattr(sys, "argv", ["cleanup_verification.py", "--owned"])

    cleanup_verification.main()

    assert docker.resources == before


def test_automatic_cleanup_gate_recovers_a_valid_interrupted_receipt(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    docker = _OwnershipDocker()
    monkeypatch.setattr(cleanup_verification, "_docker", docker.run)
    project = "correlia-verify-interrupted"
    invocation = uuid4().hex
    receipt = tmp_path / "ownership.json"
    cleanup_verification.acquire(project, invocation, receipt)
    before = docker.snapshot()
    docker.create_project(project)
    monkeypatch.setenv("CORRELIA_VERIFICATION_PROJECT", project)
    monkeypatch.setenv("CORRELIA_VERIFICATION_INVOCATION", invocation)
    monkeypatch.setenv("CORRELIA_VERIFICATION_RECEIPT", str(receipt))
    monkeypatch.setattr(sys, "argv", ["cleanup_verification.py", "--owned"])

    cleanup_verification.main()

    assert docker.resources == before


def _ownership_docker(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["docker", *arguments],
        capture_output=True,
        text=True,
        check=False,
        timeout=90,
    )
    assert result.returncode == 0, "ownership qualification Docker operation failed"
    return result


@pytest.fixture
def live_ownership_namespace(tmp_path: Path) -> Iterator[dict[str, object]]:
    project = f"correlia-verify-{uuid4().hex}"
    invocation = uuid4().hex
    receipt = tmp_path / "ownership.json"
    cleanup_verification.acquire(project, invocation, receipt)
    # Exact-name foreign/unlabeled sentinels must be removed by their creator,
    # never by project cleanup. Record only successful creations below.
    created_volumes: list[str] = []
    namespace: dict[str, object] = {
        "project": project,
        "invocation": invocation,
        "receipt": receipt,
        "created_volumes": created_volumes,
    }
    try:
        yield namespace
    finally:
        cleanup_verification.cleanup_owned(project, invocation, receipt)
        remaining = _ownership_docker(["volume", "ls", "--quiet"]).stdout.split()
        for volume in created_volumes:
            if volume in remaining:
                _ownership_docker(["volume", "rm", volume])


def _create_ownership_volume(
    namespace: dict[str, object], name: str, *, owner: str | None
) -> None:
    existing = _ownership_docker(["volume", "ls", "--quiet"]).stdout.split()
    assert name not in existing, "ownership rehearsal volume already exists"
    arguments = ["volume", "create"]
    if owner is not None:
        arguments.extend(["--label", f"com.docker.compose.project={owner}"])
    _ownership_docker([*arguments, name])
    created_volumes = namespace["created_volumes"]
    assert isinstance(created_volumes, list)
    created_volumes.append(name)


def _ownership_environment(
    namespace: dict[str, object], *, receipt: Path | None = None
) -> dict[str, str]:
    environment = os.environ.copy()
    for name in ("GITHUB_ENV", "GITHUB_STEP_SUMMARY"):
        environment.pop(name, None)
    environment.update(
        {
            "CORRELIA_VERIFICATION_PROJECT": str(namespace["project"]),
            "CORRELIA_VERIFICATION_INVOCATION": str(namespace["invocation"]),
            "CORRELIA_VERIFICATION_RECEIPT": str(
                receipt if receipt is not None else namespace["receipt"]
            ),
        }
    )
    return environment


@pytest.mark.deployment
@pytest.mark.parametrize("collision", ["project-network", "unlabeled", "foreign"])
def test_live_outer_finalizer_preserves_preoccupied_namespace_and_database_bytes(
    live_ownership_namespace: dict[str, object],
    postgres_image: str,
    tmp_path: Path,
    collision: str,
) -> None:
    namespace = live_ownership_namespace
    project = str(namespace["project"])
    volume = f"{project}_postgres-data"
    network = f"{project}-preexisting"
    if collision == "project-network":
        _ownership_docker(
            [
                "network",
                "create",
                "--label",
                f"com.docker.compose.project={project}",
                network,
            ]
        )
    else:
        _create_ownership_volume(
            namespace,
            volume,
            owner=(
                None if collision == "unlabeled" else f"correlia-verify-{uuid4().hex}"
            ),
        )
        _ownership_docker(
            [
                "run",
                "--rm",
                "--network",
                "none",
                "--volume",
                f"{volume}:/sentinel",
                "--entrypoint",
                "sh",
                postgres_image,
                "-c",
                "printf preserved-database-bytes > /sentinel/ownership-marker",
            ]
        )
    marker = tmp_path / "child-started"
    exports = tmp_path / "workflow-environment"
    exports.write_text("", encoding="utf-8")
    environment = _ownership_environment(namespace)
    environment.pop("CORRELIA_VERIFICATION_INVOCATION")
    environment.pop("CORRELIA_VERIFICATION_RECEIPT")
    environment["GITHUB_ENV"] = str(exports)
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(
        [
            sys.executable,
            str(root / "scripts" / "verification.py"),
            "test:deployment",
            "--",
            sys.executable,
            "-c",
            f"from pathlib import Path; Path({str(marker)!r}).write_text('started')",
        ],
        cwd=root,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=90,
    )

    assert result.returncode != 0, _output(result)
    assert not marker.exists()
    # Exercise the workflow's next-step environment and cleanup entrypoint,
    # including the rejected acquisition's absence of a published ownership gate.
    for line in exports.read_text(encoding="utf-8").splitlines():
        name, value = line.split("=", 1)
        environment[name] = value
    fallback = subprocess.run(
        [
            sys.executable,
            str(root / "scripts" / "cleanup_verification.py"),
            "--owned",
        ],
        cwd=root,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=90,
    )
    assert fallback.returncode == 0, _output(fallback)
    if collision == "project-network":
        labels = json.loads(
            _ownership_docker(
                ["network", "inspect", "--format", "{{json .Labels}}", network]
            ).stdout
        )
        assert labels["com.docker.compose.project"] == project
    else:
        assert volume in _ownership_docker(["volume", "ls", "--quiet"]).stdout.split()
        marker_bytes = _ownership_docker(
            [
                "run",
                "--rm",
                "--network",
                "none",
                "--volume",
                f"{volume}:/sentinel:ro",
                "--entrypoint",
                "sh",
                postgres_image,
                "-c",
                "cat /sentinel/ownership-marker",
            ]
        ).stdout
        assert marker_bytes == "preserved-database-bytes"


@pytest.mark.deployment
def test_live_outer_finalizer_removes_only_this_failed_invocations_resources(
    live_ownership_namespace: dict[str, object],
) -> None:
    namespace = live_ownership_namespace
    project = str(namespace["project"])
    volume = f"{project}_postgres-data"
    sentinel = f"{project}-sentinel"
    _create_ownership_volume(namespace, sentinel, owner="developer-project")
    child = (
        "import os, subprocess; "
        "project = os.environ['CORRELIA_VERIFICATION_PROJECT']; "
        "subprocess.run(['docker', 'volume', 'create', '--label', "
        "f'com.docker.compose.project={project}', "
        "f'{project}_postgres-data'], check=True); "
        "raise SystemExit(7)"
    )
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(
        [
            sys.executable,
            str(root / "scripts" / "verification.py"),
            "test:deployment",
            "--",
            sys.executable,
            "-c",
            child,
        ],
        cwd=root,
        env=_ownership_environment(namespace),
        capture_output=True,
        text=True,
        check=False,
        timeout=90,
    )

    assert result.returncode == 7, _output(result)
    remaining = _ownership_docker(["volume", "ls", "--quiet"]).stdout.split()
    assert volume not in remaining
    assert sentinel in remaining


@pytest.mark.deployment
@pytest.mark.parametrize("receipt_state", ["valid", "missing", "project", "invocation"])
def test_live_workflow_gate_cleans_only_a_matching_interrupted_invocation(
    live_ownership_namespace: dict[str, object], tmp_path: Path, receipt_state: str
) -> None:
    namespace = live_ownership_namespace
    project = str(namespace["project"])
    owned_volume = f"{project}_postgres-data"
    foreign_volume = f"{project}-sentinel"
    _create_ownership_volume(namespace, owned_volume, owner=project)
    _create_ownership_volume(namespace, foreign_volume, owner="developer-project")
    receipt = Path(str(namespace["receipt"]))
    if receipt_state == "missing":
        receipt = tmp_path / "missing-receipt.json"
    elif receipt_state != "valid":
        receipt = tmp_path / "mismatched-receipt.json"
        receipt.write_text(
            json.dumps(
                {
                    "project": (
                        project
                        if receipt_state != "project"
                        else "correlia-verify-other"
                    ),
                    "invocation": (
                        str(namespace["invocation"])
                        if receipt_state != "invocation"
                        else uuid4().hex
                    ),
                }
            ),
            encoding="utf-8",
        )
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(
        [
            sys.executable,
            str(root / "scripts" / "cleanup_verification.py"),
            "--owned",
        ],
        cwd=root,
        env=_ownership_environment(namespace, receipt=receipt),
        capture_output=True,
        text=True,
        check=False,
        timeout=90,
    )

    assert result.returncode == 0, _output(result)
    remaining = _ownership_docker(["volume", "ls", "--quiet"]).stdout.split()
    assert (owned_volume in remaining) is (receipt_state != "valid")
    assert foreign_volume in remaining
