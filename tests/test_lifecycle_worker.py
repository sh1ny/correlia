from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

from app.config.settings import Settings
from app.main import create_app
from app.plugins.loader import PluginRegistry
from app.processing.task_runner import AsyncIOTaskRunner


VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


async def test_lifecycle_worker_runs_sweep_and_updates_health() -> None:
    from app.processing.lifecycle_worker import LifecycleWorker

    calls: list[int] = []

    async def sweep(sessionmaker: object, limit: int) -> int:
        calls.append(limit)
        return 2

    worker = LifecycleWorker(
        sessionmaker=object(),
        interval_seconds=60,
        batch_size=25,
        sweep=sweep,
    )

    await worker.start()
    for _ in range(50):
        if worker.expired_total == 2:
            break
        await asyncio.sleep(0.01)

    assert calls == [25]
    assert worker.healthy is True
    assert worker.last_sweep_at is not None
    assert worker.last_error_category is None
    assert worker.expired_total == 2

    await worker.stop()


async def test_lifecycle_worker_records_safe_failure_and_continues() -> None:
    from app.processing.lifecycle_worker import LifecycleWorker

    first_failure = asyncio.Event()
    second_success = asyncio.Event()
    calls = 0

    async def sweep(sessionmaker: object, limit: int) -> int:
        nonlocal calls
        calls += 1
        if calls == 1:
            first_failure.set()
            raise RuntimeError("DATABASE_URL postgresql://user:password@host/token-secret")
        second_success.set()
        return 3

    worker = LifecycleWorker(
        sessionmaker=object(),
        interval_seconds=0.01,
        batch_size=10,
        sweep=sweep,
    )

    await worker.start()
    await asyncio.wait_for(first_failure.wait(), timeout=1)
    await asyncio.sleep(0)

    assert worker.healthy is False
    assert worker.last_error_category == "RuntimeError"
    error_state = str(worker.last_error_category)
    for secret_fragment in ("DATABASE_URL", "password", "token-secret", "Traceback"):
        assert secret_fragment not in error_state

    await asyncio.wait_for(second_success.wait(), timeout=1)
    for _ in range(50):
        if worker.expired_total == 3:
            break
        await asyncio.sleep(0.01)
    assert worker.healthy is True
    assert worker.expired_total == 3

    await worker.stop()


class RecordingLifecycleWorker:
    def __init__(self) -> None:
        self.started = 0
        self.stopped = 0
        self.healthy = False
        self.last_sweep_at = None
        self.last_error_category = None
        self.expired_total = 0

    async def start(self) -> None:
        self.started += 1
        self.healthy = True

    async def stop(self) -> None:
        self.stopped += 1
        self.healthy = False


class SuccessfulSession:
    async def __aenter__(self) -> "SuccessfulSession":
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    async def execute(self, statement: object) -> None:
        return None


def sessionmaker() -> AsyncIterator[SuccessfulSession]:
    return SuccessfulSession()


async def test_lifespan_starts_and_stops_lifecycle_worker() -> None:
    from app.api.deps import get_lifecycle_worker

    worker = RecordingLifecycleWorker()
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=sessionmaker,  # type: ignore[arg-type]
        icinga2_processor=object(),  # type: ignore[arg-type]
        task_runner=AsyncIOTaskRunner(),
        plugin_registry=PluginRegistry((), ""),
        lifecycle_worker=worker,  # type: ignore[arg-type]
    )

    async with app.router.lifespan_context(app):
        assert worker.started == 1
        assert worker.stopped == 0
        assert get_lifecycle_worker(type("Request", (), {"app": app})()) is worker

    assert worker.started == 1
    assert worker.stopped == 1


def test_lifecycle_worker_does_not_reuse_task_runner_or_external_schedulers() -> None:
    root = __import__("pathlib").Path(__file__).resolve().parents[1]
    sources = {
        path.relative_to(root).as_posix(): path.read_text()
        for path in root.joinpath("app").rglob("*.py")
    }
    joined = "\n".join(sources.values())
    assert "TaskRunner.register(\"expire" not in joined
    assert "TaskRunner.register('expire" not in joined
    for forbidden in ("celery", "redis", "apscheduler"):
        assert forbidden not in sources["app/processing/lifecycle_worker.py"].lower()
    assert not root.joinpath("frontend").exists()
