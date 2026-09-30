"""Remove only Docker resources owned by one verification project."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


_PROJECT_PATTERN = re.compile(r"correlia-verify-[a-z0-9](?:[a-z0-9-]{0,46}[a-z0-9])?")
_RESOURCES = (
    (["ps", "--all", "--quiet"], ["rm", "--force"]),
    (["volume", "ls", "--quiet"], ["volume", "rm"]),
    (["network", "ls", "--quiet"], ["network", "rm"]),
)


def _docker(arguments: list[str]) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            ["docker", *arguments],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except OSError, subprocess.TimeoutExpired:
        return None


def validate_project(project: str) -> None:
    if not isinstance(project, str) or _PROJECT_PATTERN.fullmatch(project) is None:
        raise ValueError("invalid verification project identifier")


def _validate_invocation(invocation: str) -> None:
    if (
        not isinstance(invocation, str)
        or re.fullmatch(r"[a-f0-9]{32}", invocation) is None
    ):
        raise ValueError("invalid verification invocation identifier")


def postgres_data_volume(project: str) -> str:
    validate_project(project)
    return f"{project}_postgres-data"


def acquire(project: str, invocation: str, receipt: Path) -> None:
    """Claim a fresh namespace before any resource creation, never adopt a run."""
    validate_project(project)
    _validate_invocation(invocation)
    if receipt.exists():
        raise RuntimeError("verification ownership receipt already exists")
    label = f"label=com.docker.compose.project={project}"
    for listing, _ in _RESOURCES:
        result = _docker([*listing, "--filter", label])
        if result is None or result.returncode != 0:
            raise RuntimeError("Docker verification acquisition inspection failed")
        if result.stdout.strip():
            raise RuntimeError("verification namespace is already occupied")

    # Labels alone cannot detect a foreign or unlabeled volume Compose would reuse.
    volumes = _docker(["volume", "ls", "--quiet"])
    if volumes is None or volumes.returncode != 0:
        raise RuntimeError("Docker verification acquisition inspection failed")
    if postgres_data_volume(project) in volumes.stdout.split():
        raise RuntimeError("verification database volume already exists")
    try:
        with receipt.open("x", encoding="utf-8") as ownership:
            json.dump({"project": project, "invocation": invocation}, ownership)
    except OSError as error:
        raise RuntimeError("unable to record verification ownership") from error


def has_ownership(project: str, invocation: str, receipt: Path) -> bool:
    """A project identifier by itself never authorizes automatic deletion."""
    validate_project(project)
    _validate_invocation(invocation)
    try:
        recorded = json.loads(receipt.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return False
    except (OSError, ValueError) as error:
        raise RuntimeError("unable to read verification ownership receipt") from error
    return recorded == {"project": project, "invocation": invocation}


def cleanup_owned(project: str, invocation: str, receipt: Path) -> bool:
    """Use the same ownership boundary for fixture, task and workflow finalizers."""
    if not has_ownership(project, invocation, receipt):
        return False
    cleanup(project)
    return True


def cleanup(project: str) -> None:
    """Remove labeled containers, volumes and networks; fail on any incomplete step."""
    validate_project(project)

    label = f"label=com.docker.compose.project={project}"
    failed = False
    for listing, removal in _RESOURCES:
        result = _docker([*listing, "--filter", label])
        if result is None or result.returncode != 0:
            failed = True
            continue
        for resource in result.stdout.split():
            removed = _docker([*removal, resource])
            if removed is None or removed.returncode != 0:
                failed = True

    for listing, _ in _RESOURCES:
        result = _docker([*listing, "--filter", label])
        if result is None or result.returncode != 0 or result.stdout.strip():
            failed = True
    if failed:
        raise RuntimeError("Docker verification cleanup failed")


def main() -> None:
    parser = argparse.ArgumentParser(description="Clean up one verification project")
    parser.add_argument("project", nargs="?")
    parser.add_argument(
        "--owned",
        action="store_true",
        help="require this invocation's ownership receipt",
    )
    parser.add_argument(
        "--invocation", default=os.getenv("CORRELIA_VERIFICATION_INVOCATION")
    )
    parser.add_argument("--receipt", default=os.getenv("CORRELIA_VERIFICATION_RECEIPT"))
    arguments = parser.parse_args()
    try:
        if arguments.owned:
            project = arguments.project or os.getenv("CORRELIA_VERIFICATION_PROJECT")
            if not arguments.invocation or not arguments.receipt:
                print("No verification ownership receipt; skipping automatic cleanup")
                return
            receipt = Path(arguments.receipt)
            if cleanup_owned(project, arguments.invocation, receipt):
                receipt.unlink(missing_ok=True)
            else:
                print("No matching verification ownership receipt; skipping cleanup")
        else:
            cleanup(arguments.project)
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
