"""Remove only Docker resources owned by one verification project."""

from __future__ import annotations

import argparse
import os
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
    parser.add_argument(
        "project", nargs="?", default=os.getenv("CORRELIA_VERIFICATION_PROJECT")
    )
    arguments = parser.parse_args()
    try:
        cleanup(arguments.project)
    except (ValueError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
