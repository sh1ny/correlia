from __future__ import annotations

import ast
from collections.abc import Mapping
from pathlib import Path
from typing import Any

import pytest

from app.processing.task_runner import AsyncIOTaskRunner, TaskSubmissionError


async def test_registered_task_names_dispatch_to_matching_handlers_with_copied_payloads() -> None:
    runner = AsyncIOTaskRunner()
    calls: list[tuple[str, Mapping[str, Any]]] = []

    async def notify(payload: Mapping[str, Any]) -> None:
        calls.append(("notify", payload))

    async def expire(payload: Mapping[str, Any]) -> None:
        calls.append(("expire", payload))

    runner.register("notify", notify)
    runner.register("expire", expire)
    payload: dict[str, Any] = {"incident_id": "inc-1", "nested": {"count": 1}}

    await runner.submit("notify", payload)
    payload["incident_id"] = "mutated"
    await runner.submit("expire", {"incident_id": "inc-2"})
    await runner.drain()

    assert runner.registered_task_names == ("expire", "notify")
    assert calls[0] == ("notify", {"incident_id": "inc-1", "nested": {"count": 1}})
    assert calls[0][1] is not payload
    assert calls[1] == ("expire", {"incident_id": "inc-2"})
    assert runner.pending_count == 0


async def test_unknown_task_submission_raises_and_creates_no_asyncio_task() -> None:
    runner = AsyncIOTaskRunner()

    with pytest.raises(TaskSubmissionError, match="unknown task"):
        await runner.submit("missing", {"incident_id": "inc-1"})

    assert runner.pending_count == 0


async def test_handler_exception_is_retrieved_and_logged(caplog: pytest.LogCaptureFixture) -> None:
    runner = AsyncIOTaskRunner()

    async def boom(payload: Mapping[str, Any]) -> None:
        raise RuntimeError(f"failed {payload['incident_id']}")

    runner.register("notify", boom)

    await runner.submit("notify", {"incident_id": "inc-1"})
    await runner.drain()

    assert runner.pending_count == 0
    assert "async task handler failed" in caplog.text
    assert "RuntimeError" in caplog.text


def test_asyncio_create_task_is_confined_to_approved_background_modules() -> None:
    root = Path(__file__).resolve().parents[1]
    approved = {
        "app/processing/task_runner.py",
        "app/processing/lifecycle_worker.py",
        "app/middleware/rate_limit.py",
    }
    offenders: list[str] = []
    for path in root.joinpath("app").rglob("*.py"):
        tree = ast.parse(path.read_text())
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            if (
                isinstance(func, ast.Attribute)
                and func.attr == "create_task"
                and isinstance(func.value, ast.Name)
                and func.value.id == "asyncio"
                and path.relative_to(root).as_posix() not in approved
            ):
                offenders.append(path.relative_to(root).as_posix())
    assert offenders == []
