from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable, Coroutine, Mapping
from typing import Any, Protocol

logger = logging.getLogger(__name__)

TaskHandler = Callable[[Mapping[str, Any]], Coroutine[Any, Any, Any]]


class TaskSubmissionError(RuntimeError):
    """Raised when a task cannot be accepted for async execution."""


class TaskRunner(Protocol):
    def register(self, task_name: str, handler: TaskHandler) -> None: ...

    async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None: ...

    async def drain(self) -> None: ...


class AsyncIOTaskRunner:
    def __init__(self) -> None:
        self._handlers: dict[str, TaskHandler] = {}
        self._tasks: set[asyncio.Task[Any]] = set()

    @property
    def pending_count(self) -> int:
        return len(self._tasks)

    @property
    def registered_task_names(self) -> tuple[str, ...]:
        return tuple(sorted(self._handlers))

    def register(self, task_name: str, handler: TaskHandler) -> None:
        if not task_name:
            raise TaskSubmissionError("task name must not be empty")
        if task_name in self._handlers:
            raise TaskSubmissionError(f"task already registered: {task_name}")
        self._handlers[task_name] = handler

    async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None:
        handler = self._handlers.get(task_name)
        if handler is None:
            raise TaskSubmissionError(f"unknown task: {task_name}")

        payload_copy = dict(payload)
        task: asyncio.Task[Any] = asyncio.create_task(
            handler(payload_copy),
            name=f"correlia:{task_name}",
        )
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        task.add_done_callback(self._log_task_exception)

    async def drain(self) -> None:
        while self._tasks:
            tasks = tuple(self._tasks)
            await asyncio.gather(*tasks, return_exceptions=True)

    @staticmethod
    def _log_task_exception(task: asyncio.Task[Any]) -> None:
        try:
            exc = task.exception()
        except asyncio.CancelledError:
            logger.info("async task cancelled", extra={"task_name": task.get_name()})
            return
        if exc is None:
            return
        logger.error(
            "async task handler failed",
            extra={"task_name": task.get_name(), "exception_type": type(exc).__name__},
            exc_info=(type(exc), exc, exc.__traceback__),
        )
