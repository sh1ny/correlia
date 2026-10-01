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


def _claim_name(project: str) -> str:
    return f"{project}-verification-owner"


def _claim_image() -> str:
    # Task wrappers also run before uv sync, so require no Python dependencies.
    result = _docker(
        [
            "compose",
            "--file",
            str(Path(__file__).resolve().parents[1] / "compose.yaml"),
            "config",
            "--no-interpolate",
            "--format",
            "json",
        ]
    )
    if result is None or result.returncode != 0:
        raise RuntimeError("unable to read verification ownership image")
    try:
        image = json.loads(result.stdout)["services"]["postgres"]["image"]
    except (ValueError, KeyError, TypeError) as error:
        raise RuntimeError("unable to read verification ownership image") from error
    if not isinstance(image, str) or not image.strip():
        raise RuntimeError("compose.yaml must define a nonempty PostgreSQL image")
    return image


def _claim_identity(project: str) -> tuple[str, str] | None:
    result = _docker(
        ["container", "inspect", "--format", "{{json .}}", _claim_name(project)]
    )
    if result is None:
        raise RuntimeError("Docker verification ownership inspection failed")
    if result.returncode != 0:
        return None
    try:
        recorded = json.loads(result.stdout)
    except ValueError as error:
        raise RuntimeError("Docker verification ownership inspection failed") from error
    if not isinstance(recorded, dict):
        return None
    identifier = recorded.get("Id")
    config = recorded.get("Config")
    if (
        not isinstance(identifier, str)
        or re.fullmatch(r"[a-f0-9]{64}", identifier) is None
        or recorded.get("Name") != f"/{_claim_name(project)}"
        or not isinstance(config, dict)
    ):
        return None
    labels = config.get("Labels")
    if not isinstance(labels, dict):
        return None
    invocation = labels.get("correlia.verification.invocation")
    if (
        labels.get("correlia.verification.project") != project
        or not isinstance(invocation, str)
        or re.fullmatch(r"[a-f0-9]{32}", invocation) is None
    ):
        return None
    return identifier, invocation


def _release_claim(identifier: str) -> None:
    # Never remove by name: a replacement can belong to another invocation.
    result = _docker(["rm", "--force", identifier])
    if result is None or result.returncode != 0:
        raise RuntimeError("Docker verification ownership release failed")


def acquire(project: str, invocation: str, receipt: Path) -> None:
    """Exclusively claim the daemon namespace before inspecting or creating data."""
    validate_project(project)
    _validate_invocation(invocation)
    if receipt.exists():
        raise RuntimeError("verification ownership receipt already exists")
    claim = _docker(
        [
            "create",
            "--quiet",
            "--name",
            _claim_name(project),
            "--label",
            f"correlia.verification.project={project}",
            "--label",
            f"correlia.verification.invocation={invocation}",
            "--network",
            "none",
            "--read-only",
            # Override the PG16 image VOLUME so the stopped marker creates no data.
            "--tmpfs",
            "/var/lib/postgresql/data",
            "--entrypoint",
            "/bin/true",
            _claim_image(),
        ]
    )
    if claim is None or claim.returncode != 0:
        # A failed/ambiguous create never authorizes removing the named container.
        raise RuntimeError("Docker verification namespace claim failed")
    identifier = claim.stdout.strip()
    if re.fullmatch(r"[a-f0-9]{64}", identifier) is None:
        raise RuntimeError("Docker verification namespace claim failed")
    try:
        label = f"label=com.docker.compose.project={project}"
        for listing, _ in _RESOURCES:
            result = _docker([*listing, "--filter", label])
            if result is None or result.returncode != 0:
                raise RuntimeError("Docker verification acquisition inspection failed")
            if result.stdout.strip():
                raise RuntimeError("verification namespace is already occupied")

        # Labels cannot detect a foreign or unlabeled volume Compose would reuse.
        volumes = _docker(["volume", "ls", "--quiet"])
        if volumes is None or volumes.returncode != 0:
            raise RuntimeError("Docker verification acquisition inspection failed")
        if postgres_data_volume(project) in volumes.stdout.split():
            raise RuntimeError("verification database volume already exists")
        if _claim_identity(project) != (identifier, invocation):
            raise RuntimeError("verification ownership claim does not match")
        try:
            with receipt.open("x", encoding="utf-8") as ownership:
                json.dump(
                    {
                        "project": project,
                        "invocation": invocation,
                        "claim": identifier,
                    },
                    ownership,
                )
        except OSError as error:
            raise RuntimeError("unable to record verification ownership") from error
    except RuntimeError:
        # Rejected acquisition may remove only the marker it actually created.
        _release_claim(identifier)
        raise


def _owned_claim(project: str, invocation: str, receipt: Path) -> str | None:
    validate_project(project)
    _validate_invocation(invocation)
    try:
        recorded = json.loads(receipt.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        raise RuntimeError("unable to read verification ownership receipt") from error
    if (
        not isinstance(recorded, dict)
        or recorded.get("project") != project
        or recorded.get("invocation") != invocation
    ):
        return None
    identifier = recorded.get("claim")
    if (
        not isinstance(identifier, str)
        or re.fullmatch(r"[a-f0-9]{64}", identifier) is None
        or _claim_identity(project) != (identifier, invocation)
    ):
        return None
    return identifier


def has_ownership(project: str, invocation: str, receipt: Path) -> bool:
    """Require both a local receipt and its exact daemon-visible invocation claim."""
    return _owned_claim(project, invocation, receipt) is not None


def cleanup_owned(
    project: str, invocation: str, receipt: Path, *, release: bool = True
) -> bool:
    """Keep the claim on failure, or while a nested fixture still needs the project."""
    identifier = _owned_claim(project, invocation, receipt)
    if identifier is None:
        return False
    _cleanup_resources(project)
    if _claim_identity(project) != (identifier, invocation):
        raise RuntimeError("verification ownership claim does not match")
    if release:
        _release_claim(identifier)
        receipt.unlink(missing_ok=True)
    return True


def cleanup(project: str) -> None:
    """Deliberately remove a project's resources, releasing its claim only on success."""
    validate_project(project)
    claim = _claim_identity(project)
    _cleanup_resources(project)
    if claim is not None:
        _release_claim(claim[0])


def _cleanup_resources(project: str) -> None:
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
        help="require this invocation's receipt and Docker ownership claim",
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
            if not cleanup_owned(project, arguments.invocation, receipt):
                print("No matching verification ownership; skipping cleanup")
        else:
            cleanup(arguments.project)
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
