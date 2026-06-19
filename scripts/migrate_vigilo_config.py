#!/usr/bin/env python3
"""Stub for Vigilo/VDE-to-Correlia migration CLI tests.

This placeholder allows the test module to import the expected helpers and
run behavior assertions.  The real implementation is added in the following
commit.
"""

from __future__ import annotations

import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Allow direct invocation as `python scripts/migrate_vigilo_config.py`.
_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))



@dataclass(frozen=True)
class MigrationIssue:
    domain: str
    location: str
    code: str
    message: str
    requirement: str


UNSUPPORTED_FIELD_CATALOG_CODES: frozenset[str] = frozenset()


def _to_correlia_tag_key(bare: str) -> str | None:
    return None


def _rewrite_match_tags(tags: dict[str, Any]) -> tuple[dict[str, str], list[MigrationIssue]]:
    return {}, []


def _rewrite_summary(summary: str, *, location: str = "output_summary") -> tuple[str, list[MigrationIssue]]:
    return "", []


def _rewrite_group_by(entries: list[str]) -> tuple[list[str], list[MigrationIssue]]:
    return [], []


def _transform_rules(raw_rules: list[Any]) -> dict[str, Any]:
    return {"rules": []}


def _transform_topology(raw_topology: dict[str, Any]) -> dict[str, Any]:
    return {"hostname_rules": [], "subnet_rules": []}


def _transform_plugins(raw_plugins: dict[str, Any]) -> dict[str, Any]:
    return {"outputs": []}


def main(argv: Sequence[str] | None = None) -> int:
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
