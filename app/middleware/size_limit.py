from __future__ import annotations

from collections import deque
import logging

from starlette.datastructures import Headers
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.middleware.classification import classify_path
from app.processing.logging import safe_log_extra

logger = logging.getLogger(__name__)

_DETAIL = "request body too large"


class RequestSizeLimiterMiddleware:
    def __init__(
        self,
        app: ASGIApp,
        default_limit: int,
        class_limits: dict[str, int | None],
    ) -> None:
        self.app = app
        self.default_limit = max(default_limit, 0)
        self.class_limits = class_limits

    def _limit_for(self, route_class: str) -> int:
        override = self.class_limits.get(route_class)
        return override if override is not None else self.default_limit

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        route_class = classify_path(scope.get("path", ""))
        limit = self._limit_for(route_class)
        if limit <= 0:
            await self.app(scope, receive, send)
            return

        headers = Headers(scope=scope)
        content_length = headers.get("content-length")
        if content_length is not None:
            try:
                length = int(content_length)
            except ValueError:
                length = 0
            if length > limit:
                logger.warning(
                    "request body too large",
                    extra=safe_log_extra(
                        event="request_body_too_large",
                        route_class=route_class,
                        content_length=length,
                        limit=limit,
                    ),
                )
                await self._send_413(send)
                return

        body_chunks: deque[bytes] = deque()
        total = 0
        while True:
            message = await receive()
            if message["type"] != "http.request":
                return
            chunk = message.get("body", b"")
            total += len(chunk)
            if total > limit:
                logger.warning(
                    "request body too large",
                    extra=safe_log_extra(
                        event="request_body_too_large",
                        route_class=route_class,
                        content_length=total,
                        limit=limit,
                    ),
                )
                await self._send_413(send)
                return
            body_chunks.append(chunk)
            if not message.get("more_body", False):
                break

        messages: deque[Message] = deque()
        for i, chunk in enumerate(body_chunks):
            messages.append(
                {
                    "type": "http.request",
                    "body": chunk,
                    "more_body": i < len(body_chunks) - 1,
                }
            )

        async def replay_receive() -> Message:
            if messages:
                return messages.popleft()
            return {"type": "http.request", "body": b"", "more_body": False}

        await self.app(scope, replay_receive, send)

    async def _send_413(self, send: Send) -> None:
        await send(
            {
                "type": "http.response.start",
                "status": 413,
                "headers": [(b"content-type", b"application/json")],
            }
        )
        await send(
            {
                "type": "http.response.body",
                "body": b'{"detail":"request body too large"}',
            }
        )
