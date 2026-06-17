from __future__ import annotations

import asyncio
import hashlib
import logging
import time
from dataclasses import dataclass
from typing import Any

from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp

from app.middleware.classification import RouteClass, classify_path
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
        self._counters: dict[str, tuple[int, float]] = {}
        self._lock = asyncio.Lock()

    async def check(
        self, key: str, limit: int, window_seconds: int
    ) -> tuple[bool, int | None]:
        now = time.time()
        async with self._lock:
            count, window_start = self._counters.get(key, (0, now))
            if now - window_start >= window_seconds:
                count = 0
                window_start = now
            if count >= limit:
                reset_at = window_start + window_seconds
                retry_after = max(1, int(reset_at - now))
                return False, retry_after
            self._counters[key] = (count + 1, window_start)
            return True, None

    def clear(self) -> None:
        self._counters.clear()


def identity_for_request(request: Request) -> tuple[str, str]:
    auth_header = request.headers.get("authorization", "")
    if auth_header.lower().startswith("bearer "):
        token = auth_header[7:]
        identity = hashlib.sha256(token.encode()).hexdigest()
        return _TOKEN_PREFIX, identity
    client = request.scope.get("client")
    if isinstance(client, tuple) and len(client) >= 1:
        return _IP_PREFIX, str(client[0])
    return _IP_PREFIX, "unknown"


class RateLimiterMiddleware(BaseHTTPMiddleware):
    def __init__(
        self,
        app: ASGIApp,
        limiter: InProcessRateLimiter,
        configs: dict[str, RateLimitConfig],
    ) -> None:
        super().__init__(app)
        self.limiter = limiter
        self.configs = configs

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

        identity_type, identity_value = identity_for_request(request)
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
                identity_hash=f"{identity_type}:{identity_value}",
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
