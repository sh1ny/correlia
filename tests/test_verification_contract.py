"""Exercise the real repository hooks in disposable, small pytest sessions."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import textwrap

import pytest


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
