from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from datetime import datetime, timezone
from typing import Any

from app.processing.metrics import set_lifecycle_worker_healthy

logger = logging.getLogger(__name__)

LifecycleSweep = Callable[[Any, int], Awaitable[int]]


class LifecycleWorker:
    def __init__(
        self,
        *,
        sessionmaker: Any,
        interval_seconds: float,
        batch_size: int,
        sweep: LifecycleSweep,
    ) -> None:
        if interval_seconds <= 0:
            raise ValueError("interval_seconds must be positive")
        if batch_size < 1:
            raise ValueError("batch_size must be positive")
        self._sessionmaker = sessionmaker
        self._interval_seconds = interval_seconds
        self._batch_size = batch_size
        self._sweep = sweep
        self._stop_event: asyncio.Event | None = None
        self._task: asyncio.Task[None] | None = None
        self._healthy = False
        self._last_sweep_at: datetime | None = None
        self._last_error_category: str | None = None
        self._expired_total = 0

    @property
    def healthy(self) -> bool:
        return self._healthy

    @property
    def last_sweep_at(self) -> datetime | None:
        return self._last_sweep_at

    @property
    def last_error_category(self) -> str | None:
        return self._last_error_category

    @property
    def expired_total(self) -> int:
        return self._expired_total

    async def start(self) -> None:
        if self._task is not None and not self._task.done():
            return
        self._stop_event = asyncio.Event()
        self._task = asyncio.create_task(
            self._run(),
            name="correlia:lifecycle-worker",
        )
        self._task.add_done_callback(self._retrieve_task_exception)

    async def stop(self) -> None:
        task = self._task
        stop_event = self._stop_event
        if task is None or stop_event is None:
            return
        stop_event.set()
        try:
            await asyncio.wait_for(task, timeout=max(1.0, self._interval_seconds + 1.0))
        except asyncio.TimeoutError:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        finally:
            self._task = None
            self._stop_event = None
            set_lifecycle_worker_healthy(False)

    async def _run(self) -> None:
        stop_event = self._stop_event
        if stop_event is None:
            return
        while not stop_event.is_set():
            await self._run_sweep()
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=self._interval_seconds)
            except asyncio.TimeoutError:
                continue

    async def _run_sweep(self) -> None:
        try:
            expired_count = await self._sweep(self._sessionmaker, self._batch_size)
        except Exception as exc:  # noqa: BLE001 - worker must keep running after sweep failures.
            self._healthy = False
            set_lifecycle_worker_healthy(False)
            self._last_error_category = type(exc).__name__
            logger.error(
                "lifecycle worker sweep failed",
                extra={"exception_type": self._last_error_category},
            )
            return
        self._expired_total += expired_count
        self._last_sweep_at = datetime.now(timezone.utc)
        self._last_error_category = None
        self._healthy = True
        set_lifecycle_worker_healthy(True)

    @staticmethod
    def _retrieve_task_exception(task: asyncio.Task[None]) -> None:
        try:
            task.exception()
        except asyncio.CancelledError:
            return
