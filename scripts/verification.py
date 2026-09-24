"""Run a fixed verification command with lock and environment safeguards."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
from uuid import uuid4

from cleanup_verification import cleanup


ROOT = Path(__file__).resolve().parents[1]


def _lock_digest(path: Path) -> bytes:
    with path.open("rb") as lock:
        return hashlib.file_digest(lock, "sha256").digest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required")
    if args.task == "audit" and command != [
        "uv",
        "--no-config",
        "--preview-features",
        "audit",
        "audit",
        "--locked",
    ]:
        parser.error(
            "audit must use the complete locked dependency scope without exceptions"
        )

    lock_path = ROOT / "uv.lock"
    if not lock_path.is_file():
        parser.error("uv.lock is required; verification never creates it")
    before = _lock_digest(lock_path)
    # User-level uv settings must not narrow setup or the advisory scan. Keep only
    # interpreter selection and download-cache placement from the mise environment.
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("UV_")
        or key in {"UV_PYTHON", "UV_PYTHON_DOWNLOADS", "UV_CACHE_DIR"}
    }
    environment.pop("VIRTUAL_ENV", None)
    environment.pop("PYTEST_ADDOPTS", None)
    environment.pop("PYTEST_PLUGINS", None)
    project = None
    if args.task in {"test", "test:deployment"}:
        project = environment.setdefault(
            "CORRELIA_VERIFICATION_PROJECT", f"correlia-verify-{uuid4().hex}"
        )
        print(f"Verification project: {project}", flush=True)
    result = 1
    try:
        result = subprocess.run(
            command, cwd=ROOT, env=environment, check=False
        ).returncode
    except KeyboardInterrupt:
        result = 130
    except OSError:
        print(f"{args.task}: unable to launch required command", file=sys.stderr)
    finally:
        if project is not None:
            try:
                cleanup(project)
            except OSError, RuntimeError, ValueError, subprocess.SubprocessError:
                print("Verification resource cleanup failed", file=sys.stderr)
                result = result or 1
        if not lock_path.is_file() or _lock_digest(lock_path) != before:
            print("Verification changed uv.lock", file=sys.stderr)
            result = result or 1
        print(
            f"{args.task}: {'passed' if result == 0 else 'failed'} (exit {result})",
            flush=True,
        )
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with Path(summary).open("a", encoding="utf-8") as report:
                report.write(
                    f"- `{args.task}`: {'passed' if result == 0 else 'failed'} (exit {result})\n"
                )
    return result


if __name__ == "__main__":
    raise SystemExit(main())
