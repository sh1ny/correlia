from __future__ import annotations

import asyncio
import hashlib
import logging
import math
import secrets
import time
from dataclasses import dataclass
from typing import Any

from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp

from app.middleware.classification import classify_path
from app.processing.logging import safe_log_extra

_DETAIL = "rate limit exceeded"
_TOKEN_PREFIX = "token_hash"
_IP_PREFIX = "ip"

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class RateLimitConfig:
    enabled: bool
    requests: int
    window_seconds: int


class InProcessRateLimiter:
    def __init__(self) -> None:
        self._counters: dict[str, tuple[int, float, int]] = {}
        self._lock = asyncio.Lock()

    async def check(
        self, key: str, limit: int, window_seconds: int
    ) -> tuple[bool, int | None]:
        now = time.monotonic()
        async with self._lock:
            count, window_start, _ = self._counters.get(key, (0, now, window_seconds))
            if now - window_start >= window_seconds:
                count = 0
                window_start = now
            if count >= limit:
                self._counters[key] = (count, window_start, window_seconds)
                reset_at = window_start + window_seconds
                retry_after = max(1, math.ceil(reset_at - now))
                return False, retry_after
            self._counters[key] = (count + 1, window_start, window_seconds)
            return True, None

    async def sweep_expired(self) -> int:
        now = time.monotonic()
        async with self._lock:
            expired = [
                k
                for k, (_, window_start, window_seconds) in self._counters.items()
                if now - window_start >= window_seconds
            ]
            for k in expired:
                del self._counters[k]
            return len(expired)

    def clear(self) -> None:
        self._counters.clear()


class RateLimitSweepWorker:
    def __init__(self, limiter: InProcessRateLimiter, interval_seconds: float) -> None:
        if interval_seconds <= 0:
            raise ValueError("interval_seconds must be positive")
        self._limiter = limiter
        self._interval_seconds = interval_seconds
        self._stop_event: asyncio.Event | None = None
        self._task: asyncio.Task[None] | None = None

    async def start(self) -> None:
        if self._task is not None and not self._task.done():
            return
        self._stop_event = asyncio.Event()
        self._task = asyncio.create_task(
            self._run(),
            name="correlia:rate-limit-sweep-worker",
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

    async def _run(self) -> None:
        stop_event = self._stop_event
        if stop_event is None:
            return
        while not stop_event.is_set():
            try:
                removed_count = await self._limiter.sweep_expired()
            except Exception as exc:  # noqa: BLE001 - worker must keep running after sweep failures.
                logger.warning(
                    "rate limit sweep failed",
                    extra=safe_log_extra(
                        event="rate_limit_sweep_failed",
                        exception_type=type(exc).__name__,
                    ),
                )
            else:
                logger.info(
                    "rate limit sweep completed",
                    extra=safe_log_extra(
                        event="rate_limit_sweep",
                        count=removed_count,
                    ),
                )
            try:
                await asyncio.wait_for(
                    stop_event.wait(), timeout=self._interval_seconds
                )
            except asyncio.TimeoutError:
                continue

    @staticmethod
    def _retrieve_task_exception(task: asyncio.Task[None]) -> None:
        try:
            task.exception()
        except asyncio.CancelledError:
            return


def normalize_valid_tokens(tokens: dict[str, str | None]) -> dict[str, bytes]:
    normalized: dict[str, bytes] = {}
    for route_class, token in tokens.items():
        if token is None:
            continue
        if not isinstance(token, str):
            raise ValueError(
                f"valid token for route class {route_class!r} must be str or None"
            )
        normalized[route_class] = token.encode("utf-8")
    return normalized


def identity_for_request(
    request: Request, route_class: str, valid_tokens: dict[str, bytes]
) -> tuple[str, str]:
    auth_header = request.headers.get("authorization", "")
    if auth_header.lower().startswith("bearer "):
        token = auth_header[7:]
        expected = valid_tokens.get(route_class)
        if expected is not None and secrets.compare_digest(
            token.encode("utf-8"), expected
        ):
            identity = hashlib.sha256(token.encode("utf-8")).hexdigest()
            return _TOKEN_PREFIX, identity
    client = request.scope.get("client")
    if isinstance(client, tuple) and len(client) >= 1:
        return _IP_PREFIX, str(client[0])
    return _IP_PREFIX, "unknown"


def logged_identity_hash(identity_type: str, identity_value: str) -> str:
    if identity_type == _IP_PREFIX:
        identity_value = hashlib.sha256(identity_value.encode()).hexdigest()
    return f"{identity_type}:{identity_value}"


class RateLimiterMiddleware(BaseHTTPMiddleware):
    def __init__(
        self,
        app: ASGIApp,
        limiter: InProcessRateLimiter,
        configs: dict[str, RateLimitConfig],
        valid_tokens: dict[str, str | None] | None = None,
    ) -> None:
        super().__init__(app)
        self.limiter = limiter
        self.configs = configs
        self._valid_token_bytes = normalize_valid_tokens(valid_tokens or {})

    async def dispatch(self, request: Request, call_next: Any) -> Any:
        route_class = classify_path(request.url.path)
        config = self.configs.get(route_class)
        if (
            config is None
            or not config.enabled
            or config.requests <= 0
            or config.window_seconds <= 0
        ):
            return await call_next(request)

        identity_type, identity_value = identity_for_request(
            request, route_class, self._valid_token_bytes
        )
        key = f"{route_class}:{identity_type}:{identity_value}"
        allowed, retry_after = await self.limiter.check(
            key, config.requests, config.window_seconds
        )
        if allowed:
            return await call_next(request)

        logger.warning(
            "rate limit exceeded",
            extra=safe_log_extra(
                event="rate_limit_exceeded",
                route_class=route_class,
                identity_hash=logged_identity_hash(identity_type, identity_value),
                limit=config.requests,
                window_seconds=config.window_seconds,
                retry_after=retry_after,
            ),
        )
        headers = {"Retry-After": str(retry_after)} if retry_after is not None else {}
        return JSONResponse(
            status_code=429,
            content={"detail": _DETAIL},
            headers=headers,
        )
