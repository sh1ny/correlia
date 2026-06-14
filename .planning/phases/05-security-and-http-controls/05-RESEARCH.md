# Phase 5: Security and HTTP Controls - Research

**Researched:** 2026-06-14
**Domain:** FastAPI HTTP perimeter controls (authentication, request-size limits, rate limiting, exposure configuration)
**Confidence:** MEDIUM - Implementation approach is grounded in the inspected codebase and FastAPI/Starlette APIs; numeric defaults and exact middleware ordering are recommendations that the discuss/plan phase should confirm.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** `/v1/health` remains public by default and is never part of the protected operator surface.
- **D-02:** `/v1/readyz` is public by default, but its exposure must be configurable with a named setting because it reports dependency status.
- **D-03:** Existing `/v1` operator/config surfaces are protected by default when auth is enabled: `/v1/incidents`, `/v1/rules`, `/v1/topology`, and `/v1/plugins`.
- **D-04:** `/v1/metrics` is not hard-protected by default; metrics exposure must be configurable with a named setting.
- **D-05:** `/v1/icinga2/events` uses a separate ingress Bearer token from operator API clients. Do not reuse the operator token for sender traffic.
- **D-06:** Public exposure is configured through named exposure flags, not an arbitrary path allowlist.
- **D-07:** Missing and invalid tokens return the same deterministic response: HTTP `401` with compact JSON body `{"detail":"unauthorized"}`.
- **D-08:** Unauthorized responses include `WWW-Authenticate: Bearer`.
- **D-09:** If a protected route class is enabled but its required token environment variable is missing, Correlia fails startup. Do not add a local/development bypass.
- **D-10:** Operator-token, ingress-token, and optionally protected metrics failures use the same unauthorized response shape. Do not reveal which token class failed.
- **D-11:** Rate limiting applies to all protected routes by default.
- **D-12:** Rate-limit identity is token first, then remote IP for unauthenticated requests.
- **D-13:** Ship conservative enabled defaults, configurable per named route class.
- **D-14:** Over-limit callers receive HTTP `429` with compact JSON body `{"detail":"rate limit exceeded"}` and a `Retry-After` header when computable.
- **D-15:** Default maximum request body size is 1 MiB.
- **D-16:** Size configuration uses one global default plus named route-class overrides.
- **D-17:** Oversized requests receive HTTP `413` with compact JSON body `{"detail":"request body too large"}`.
- **D-18:** Bodies without `Content-Length` and chunked uploads are counted while read. They must fail before route handler logic once the configured cap is exceeded.

### Claude's Discretion
- Choose the simplest in-process implementation consistent with the current single-worker runtime. Do not introduce Redis, Celery, external rate-limit services, or distributed counters in this phase.
- Choose exact conservative default numeric request-per-window values during planning, unless a later requirement gives concrete values. Preserve configurability per named route class.

### Deferred Ideas (OUT OF SCOPE)
None - discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SEC-01 | Operator API clients can authenticate protected Correlia routes with a static Bearer token configured by environment. | Implement FastAPI `HTTPBearer` dependencies bound to operator routers; store token in `pydantic.SecretStr` with `CORRELIA_` env prefix. |
| SEC-02 | Unauthenticated callers receive a deterministic unauthorized response on protected routes without any development-mode bypass. | Raise `HTTPException(401, detail="unauthorized", headers={"WWW-Authenticate":"Bearer"})` from dependencies; fail startup when auth is enabled but tokens are missing. |
| SEC-03 | Maintainers can configure which health/readiness paths are public while keeping `/v1/health` public by default. | Add named boolean settings `expose_readyz` and (implicitly) `expose_health` hard-coded True; apply operator-token dependency to `/v1/readyz` only when protected. |
| SEC-04 | Correlia rejects oversized HTTP request bodies before route handlers process payloads. | Add in-repo ASGI middleware that intercepts `receive`, counts bytes, buffers up to the cap, and returns `413` before dispatching the route handler. |
| SEC-05 | Correlia rate-limits configured API routes and returns a deterministic rate-limit response when the limit is exceeded. | Add in-process fixed-window rate limiter middleware keyed by route class + identity (token hash or client IP), returning `429` with `Retry-After`. |
</phase_requirements>

## Summary

Phase 5 hardens Correlia's HTTP perimeter before later v1.1 phases expand the compatibility surface. The work is concentrated in four areas: (1) static Bearer-token authentication for operator and ingress routes with deterministic `401` responses, (2) named configuration flags that keep `/v1/health` public while making `/v1/readyz` and `/v1/metrics` exposure configurable, (3) a request-size-limiting ASGI middleware that counts both `Content-Length` and chunked bodies, and (4) an in-process, per-route-class rate limiter that keys by token hash when authenticated and by client IP otherwise.

The existing codebase already uses a strict Pydantic-settings model, a central `create_app` factory, request-state dependencies, and ASGI-transport tests. These patterns make it natural to implement the controls as a combination of FastAPI `Security` dependencies for auth and Starlette-style middleware for size and rate limits. No external rate-limit or auth library is required for the single-worker default, which keeps the dependency tree small and avoids distributed-state assumptions.

**Primary recommendation:** Implement auth with FastAPI `HTTPBearer` dependencies attached at the router level, implement size and rate limits with small in-repo ASGI middleware classes installed in `create_app`, and drive all configuration through `app.config.settings.Settings` with Pydantic v2 validators so misconfiguration fails at import/start time.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Static Bearer authentication | API / Backend | Settings (env) | Tokens are secrets, validated by the API tier; configuration lives in environment. |
| Route exposure configuration | API / Backend | Settings | Named flags decide whether readiness/metrics are public or protected. |
| Request body size enforcement | API / Backend | ASGI middleware | Middleware intercepts the request stream before route handlers run. |
| Route-class rate limiting | API / Backend | ASGI middleware | In-process counters are an API-tier concern; storage is memory-only in v1. |
| Fail-fast config validation | Settings | API / Backend | Pydantic validators reject bad security config before the app starts serving. |
| Observability of control events | API / Backend | Logging | Safe structured logs already exist and must be reused for auth/rate/size events. |

## Inventory of Directly Relevant Files

### Implementation files
| File | Why it matters |
|------|----------------|
| `app/main.py` | App factory and router inclusion point; install middleware and route-level dependencies here. |
| `app/config/settings.py` | Add auth, exposure, size-limit, and rate-limit settings; add fail-fast validators. |
| `app/api/deps.py` | Existing request-state dependency helpers; new auth helpers can live here or in a new `app/api/security.py`. |
| `app/api/routers/health.py` | `/v1/health` and `/v1/readyz`; readyz exposure must become configurable. |
| `app/api/routers/ingress.py` | `POST /v1/icinga2/events`; protect with the separate ingress token. |
| `app/api/routers/incidents.py` | `GET/POST /v1/incidents/*`; protected operator surface. |
| `app/api/routers/config_status.py` | `GET /v1/rules` and `/v1/topology`; protected operator surface. |
| `app/api/routers/plugins.py` | `GET /v1/plugins`; protected operator surface. |
| `app/api/routers/metrics.py` | `GET /v1/metrics`; exposure configurable and may be protected. |
| `app/processing/logging.py` | `safe_log_extra` helper; use for control events without leaking tokens or payloads. |

### Test files
| File | Why it matters |
|------|----------------|
| `tests/conftest.py` | Already scrubs `CORRELIA_*` env vars; new settings keys must be added to `_SETTINGS_ENV_KEYS`. |
| `tests/test_health.py` | Existing health/readyz behavior; add tests for public/protected readyz and unchanged health. |
| `tests/test_ingress_router.py` | Existing ingress tests; add ingress-token auth, size, and rate-limit cases. |
| `tests/test_incidents_api.py` | Existing operator API tests; add operator-token auth cases. |
| `tests/test_config_status_api.py` | Existing rules/topology tests; add operator-token auth cases. |
| `tests/test_plugins_router.py` | Existing plugins tests; add operator-token auth cases. |
| `tests/test_metrics_api.py` | Existing metrics tests; add public/protected metrics tests. |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| FastAPI | already in `pyproject.toml` | Router/dependency injection and `HTTPBearer` security helper. | Existing project framework; `Security`/`Depends` is the idiomatic auth hook. [CITED: fastapi.tiangolo.com/reference/security/] |
| Starlette | transitively via FastAPI | ASGI middleware base for size and rate limits. | FastAPI is built on Starlette; raw ASGI middleware works without extra dependencies. [CITED: starlette.io/middleware/] |
| Pydantic v2 / pydantic-settings | already in `pyproject.toml` | Strict settings model with validators and `SecretStr`. | Already used for `CORRELIA_` env-prefix config; natural place for fail-fast security validation. [CITED: docs.pydantic.dev/latest/concepts/settings/] |
| `python-multipart` | transitively via FastAPI | Body parsing (already available). | FastAPI form/JSON parsing continues to work after size-limit middleware replays the body. |

### Supporting
| Component | Purpose | When to Use |
|-----------|---------|-------------|
| In-repo `app.middleware.security` (new module) | `RequestSizeLimiterMiddleware`, `RateLimiterMiddleware`, auth dependencies. | Keeps the implementation aligned with the single-worker, no-external-service scope. |
| In-repo `app.api.security` (new module) | `require_operator_token`, `require_ingress_token`, and exposure-aware helpers. | Centralizes auth logic so routers only declare dependencies. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| In-repo in-process rate limiter | `slowapi` or `fastapi-limiter` | Adds a dependency and either Redis or a memory store; unnecessary for single-worker default. |
| In-repo size-limit middleware | Uvicorn `--limit-max-requests-size` | Not per-route-class configurable, not chunked-aware at the application layer, and not testable via ASGI transport. |
| Middleware-based auth | Router `Security` dependencies | Dependencies are easier to unit test and keep route-level intent explicit; middleware is reserved for cross-cutting size/rate behavior. |

**Installation:** None required for this phase if the in-repo approach is chosen.

## Package Legitimacy Audit

No new external packages are recommended for Phase 5. The implementation relies on FastAPI, Starlette, and Pydantic already declared in `pyproject.toml`.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| *(none proposed)* | — | — | — | — | — | No install step required |

If a later planner chooses to add a rate-limit package, run the Package Legitimacy Gate before committing to the dependency. For this research, the recommendation is to hand-roll the in-process limiter.

## Architecture Patterns

### System Architecture Diagram

```text
                              HTTP request
                                   │
                                   ▼
                    ┌──────────────────────────────┐
                    │ RequestSizeLimiterMiddleware │  413 if body > cap
                    └──────────────┬───────────────┘
                                   │
                                   ▼
                    ┌──────────────────────────────┐
                    │   RateLimiterMiddleware      │  429 if window exceeded
                    └──────────────┬───────────────┘
                                   │
                                   ▼
                    ┌──────────────────────────────┐
                    │      FastAPI routing           │
                    │  ┌────────────────────────┐   │
                    │  │ health_router          │   │  /v1/health always public
                    │  │ /v1/readyz conditional │   │  public or operator-token
                    │  └────────────────────────┘   │
                    │  ┌────────────────────────┐   │
                    │  │ ingress_router         │   │  /v1/icinga2/events → ingress-token
                    │  └────────────────────────┘   │
                    │  ┌────────────────────────┐   │
                    │  │ incidents_router       │   │  operator-token
                    │  │ config_status_router   │   │  operator-token
                    │  │ plugins_router         │   │  operator-token
                    │  └────────────────────────┘   │
                    │  ┌────────────────────────┐   │
                    │  │ metrics_router         │   │  public or operator-token
                    │  └────────────────────────┘   │
                    └──────────────────────────────┘
```

### Recommended Project Structure

```
app/
├── api/
│   ├── deps.py                    # existing request-state dependencies
│   ├── security.py                # NEW: HTTPBearer auth helpers + exposure helpers
│   └── routers/
│       ├── health.py              # add readyz exposure dependency
│       ├── ingress.py             # add ingress-token dependency
│       ├── incidents.py           # add operator-token dependency
│       ├── config_status.py       # add operator-token dependency
│       ├── plugins.py             # add operator-token dependency
│       └── metrics.py             # add conditional operator-token dependency
├── config/
│   └── settings.py                # add security/size/rate settings + validators
├── middleware/                    # NEW package
│   ├── __init__.py
│   ├── size_limit.py              # RequestSizeLimiterMiddleware
│   └── rate_limit.py              # RateLimiterMiddleware + InProcessLimiter
└── main.py                        # wire dependencies + middleware
```

### Pattern 1: Router-Level Static Bearer Auth

**What:** Attach a `Security(require_operator_token)` dependency to each operator router and `Security(require_ingress_token)` to the ingress router. The dependency checks `Authorization: Bearer <token>` against the configured `SecretStr` token.

**When to use:** For every route class that requires a distinct token (operator, ingress, optionally metrics).

**Example:**

```python
# app/api/security.py
from fastapi import HTTPException, Request, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

_security = HTTPBearer(auto_error=False)

class Unauthorized(HTTPException):
    def __init__(self) -> None:
        super().__init__(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="unauthorized",
            headers={"WWW-Authenticate": "Bearer"},
        )


def _token_matches(request: Request, credentials: HTTPAuthorizationCredentials | None, expected: str | None) -> bool:
    if expected is None or credentials is None:
        return False
    return credentials.credentials == expected


def require_operator_token(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Security(_security),
) -> None:
    settings = request.app.state.settings
    if not settings.api_auth_enabled:
        return
    if not _token_matches(request, credentials, settings.operator_api_token.get_secret_value()):
        raise Unauthorized()


def require_ingress_token(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Security(_security),
) -> None:
    settings = request.app.state.settings
    if not settings.api_auth_enabled:
        return
    if not _token_matches(request, credentials, settings.ingress_api_token.get_secret_value()):
        raise Unauthorized()
```

```python
# app/api/routers/incidents.py
router = APIRouter(
    prefix="/v1/incidents",
    dependencies=[Security(require_operator_token)],
)
```

### Pattern 2: Conditional Exposure for Readiness and Metrics

**What:** Add named boolean settings (`expose_readyz`, `expose_metrics`). When a path is not public, attach the operator-token dependency; when public, attach a no-op dependency.

**When to use:** `/v1/readyz` and `/v1/metrics` need runtime-configurable exposure without changing router prefixes.

**Example:**

```python
# app/api/security.py
from fastapi import Depends

async def _public(request: Request) -> None:
    return None


def readyz_dependency(settings: Settings) -> Depends:
    if not settings.api_auth_enabled or settings.expose_readyz:
        return Depends(_public)
    return Security(require_operator_token)
```

Because FastAPI dependencies are resolved at import time, it is simpler to build the router in `main.py` with the chosen dependency than to make a route-level helper dynamic at request time. See the "Don't Hand-Roll" section for the recommended approach.

### Pattern 3: Request-Size Limiting Middleware

**What:** An ASGI middleware class that intercepts `http.request` messages, accumulates a byte count, and returns `413` if the configured cap is exceeded before the route handler runs.

**When to use:** All requests with bodies; configured per route class (`operator`, `ingress`, `metrics`) with a global default.

**Example:**

```python
# app/middleware/size_limit.py
from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

class RequestSizeLimiterMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, default_limit: int, class_limits: dict[str, int | None]):
        super().__init__(app)
        self.default_limit = default_limit
        self.class_limits = class_limits

    def _limit_for(self, route_class: str) -> int:
        return self.class_limits.get(route_class) or self.default_limit

    async def dispatch(self, request: Request, call_next):
        route_class = _classify_path(request.url.path)
        limit = self._limit_for(route_class)
        content_length = request.headers.get("content-length")
        if content_length is not None and int(content_length) > limit:
            return JSONResponse(
                status_code=413,
                content={"detail": "request body too large"},
            )
        body = b""
        messages = []
        while True:
            message = await request.receive()
            messages.append(message)
            if message["type"] == "http.request":
                body += message.get("body", b"")
                if len(body) > limit:
                    return JSONResponse(
                        status_code=413,
                        content={"detail": "request body too large"},
                    )
                if not message.get("more_body", False):
                    break
            elif message["type"] == "http.disconnect":
                break

        # Replay buffered messages so FastAPI body parsing works.
        idx = 0
        async def receive_proxy():
            nonlocal idx
            msg = messages[idx]
            idx += 1
            return msg

        request._receive = receive_proxy
        return await call_next(request)
```

**Caveat:** This buffers the full body up to the cap in memory. With a 1 MiB default and route-class overrides, the worst-case per-request allocation is bounded. The implementation should reject as soon as the cap is exceeded rather than continuing to buffer.

### Pattern 4: In-Process Fixed-Window Rate Limiter

**What:** A per-route-class fixed-window counter keyed by a hash of the Bearer token when present or by `scope["client"][0]` (client IP) otherwise. The middleware returns `429` with `Retry-After` when the window is full.

**When to use:** All protected routes by default; public routes can optionally be limited by IP.

**Example:**

```python
# app/middleware/rate_limit.py
import asyncio
import hashlib
import time
from typing import ClassVar

from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

class InProcessRateLimiter:
    def __init__(self):
        self._windows: dict[tuple[str, str, int], int] = {}
        self._lock = asyncio.Lock()

    async def is_allowed(
        self, route_class: str, identity: str, limit: int, window_seconds: int
    ) -> tuple[bool, int | None]:
        now = time.monotonic()
        window = int(now // window_seconds)
        key = (route_class, identity, window)
        async with self._lock:
            count = self._windows.get(key, 0)
            if count >= limit:
                retry_after = max(1, (window + 1) * window_seconds - int(now))
                return False, retry_after
            self._windows[key] = count + 1
            return True, None


class RateLimiterMiddleware(BaseHTTPMiddleware):
    limiter: ClassVar[InProcessRateLimiter] = InProcessRateLimiter()

    def __init__(self, app, default: RateLimitConfig, by_class: dict[str, RateLimitConfig | None]):
        super().__init__(app)
        self.default = default
        self.by_class = by_class

    async def dispatch(self, request: Request, call_next):
        route_class = _classify_path(request.url.path)
        cfg = self.by_class.get(route_class) or self.default
        if not cfg.enabled:
            return await call_next(request)
        identity = _identity_for(request)
        allowed, retry_after = await self.limiter.is_allowed(
            route_class, identity, cfg.requests, cfg.window_seconds
        )
        if not allowed:
            headers = {}
            if retry_after is not None:
                headers["Retry-After"] = str(retry_after)
            return JSONResponse(
                status_code=429,
                content={"detail": "rate limit exceeded"},
                headers=headers,
            )
        return await call_next(request)
```

Identity helper:

```python
def _identity_for(request: Request) -> str:
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        token = auth[7:].strip()
        return hashlib.sha256(token.encode()).hexdigest()
    client = request.scope.get("client")
    return f"ip:{client[0]}" if client else "ip:unknown"
```

### Pattern 5: Fail-Fast Settings Validation

**What:** Pydantic v2 `@model_validator` rejects the settings object when auth is enabled but required tokens are missing.

**When to use:** At `Settings()` construction time, which happens in `lifespan` and in tests.

**Example:**

```python
# app/config/settings.py
from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    # ... existing fields ...

    api_auth_enabled: bool = True
    operator_api_token: SecretStr | None = None
    ingress_api_token: SecretStr | None = None

    expose_readyz: bool = True
    expose_metrics: bool = True

    max_body_bytes: int = Field(default=1_048_576, ge=1_024)
    max_body_bytes_operator: int | None = Field(default=None, ge=1_024)
    max_body_bytes_ingress: int | None = Field(default=None, ge=1_024)
    max_body_bytes_metrics: int | None = Field(default=None, ge=1_024)

    rate_limit_enabled: bool = True
    rate_limit_requests: int = Field(default=60, ge=1)
    rate_limit_window_seconds: int = Field(default=60, ge=1)
    rate_limit_requests_operator: int | None = Field(default=None, ge=1)
    rate_limit_window_seconds_operator: int | None = Field(default=None, ge=1)
    rate_limit_requests_ingress: int | None = Field(default=None, ge=1)
    rate_limit_window_seconds_ingress: int | None = Field(default=None, ge=1)
    rate_limit_requests_metrics: int | None = Field(default=None, ge=1)
    rate_limit_window_seconds_metrics: int | None = Field(default=None, ge=1)

    @model_validator(mode="after")
    def _require_tokens_when_auth_enabled(self) -> Self:
        if self.api_auth_enabled:
            missing: list[str] = []
            if not self.operator_api_token or not self.operator_api_token.get_secret_value():
                missing.append("operator_api_token")
            if not self.ingress_api_token or not self.ingress_api_token.get_secret_value():
                missing.append("ingress_api_token")
            if missing:
                raise ValueError(
                    f"api_auth_enabled=True requires: {', '.join(missing)}"
                )
        return self
```

### Anti-Patterns to Avoid

- **Arbitrary path allowlists in config (D-06):** Do not let operators supply a regex or glob list of public paths. Use named route-class flags instead.
- **Development bypass (D-09):** Do not skip token checks in `local` or `test` environment. Tests must provide tokens explicitly or set `api_auth_enabled=False`.
- **Token logging:** Never log raw tokens, request bodies, or `Authorization` headers. Use `safe_log_extra` with event/category/identity-hash fields only.
- **Distributed state in this phase:** Do not add Redis, Memcached, or external stores for rate limits.
- **Leaking token class in 401 (D-10):** The same dependency shape must be used for operator, ingress, and protected metrics failures.
- **Relying on Uvicorn size limits alone:** They are not per-route-class and do not count chunked bodies in a testable way.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Token parsing | Regex on `Authorization` header | FastAPI `HTTPBearer(auto_error=False)` | Handles scheme, whitespace, and missing header consistently. [CITED: fastapi.tiangolo.com/reference/security/] |
| Request body size limit | Uvicorn `--limit-max-requests-size` only | In-repo ASGI middleware with per-route-class overrides | Uvicorn setting is global and hard to exercise in ASGI-transport tests; middleware gives deterministic `413` responses. |
| Rate-limit storage | Redis / Memcached | In-process dict with fixed windows | Matches single-worker scope and avoids new infrastructure. |
| Settings env loading | `os.getenv` scattered through code | `pydantic-settings` with `CORRELIA_` prefix | Already the project standard; gives typed, validated, fail-fast config. |
| Secret storage | Plain `str` settings | `pydantic.SecretStr` | Prevents accidental serialization of tokens in logs, responses, or settings dumps. |

**Key insight:** The controls in this phase are policy wrappers around the existing FastAPI surface. Building them in-repo keeps the runtime state in the same process and avoids the operational complexity of external services that the current single-worker design cannot assume.

## Common Pitfalls

### Pitfall 1: Middleware Runs Before Routing, So Path Classification Must Be Stable

**What goes wrong:** A size-limit or rate-limit middleware that relies on `request.scope["route"]` will fail because the route has not been matched yet.

**Why it happens:** Middleware wraps the application dispatch; routing occurs inside the application.

**How to avoid:** Classify requests by path prefix in middleware (`/v1/incidents`, `/v1/icinga2/events`, `/v1/metrics`, etc.) and keep a single source of truth mapping prefixes to route classes. Use named route classes in settings, not arbitrary patterns.

**Warning signs:** Tests pass for known paths but fail for trailing slashes or sub-resource paths because the classification is too specific.

### Pitfall 2: Request Body Buffering Breaks FastAPI Parsing

**What goes wrong:** The size-limit middleware consumes the `receive` channel, and the route handler sees an empty body.

**Why it happens:** ASGI messages are consumed once. If middleware reads without replaying, downstream never sees the bytes.

**How to avoid:** Buffer messages (not just bytes) and replace `request._receive` with a callable that replays them in order. Keep buffering bounded by the size cap.

**Warning signs:** `POST /v1/icinga2/events` returns `422` for a valid payload only when the size middleware is installed.

### Pitfall 3: Rate-Limit Identity Collides Across Token Classes

**What goes wrong:** An ingress token presented to an operator route is counted in the operator bucket, or vice versa.

**Why it happens:** The identity function only hashes the token without binding it to a route class.

**How to avoid:** The middleware key is `(route_class, identity, window)`. A token that is invalid for a route class still consumes the IP bucket if unauthenticated, not the protected-class bucket.

**Warning signs:** A load test of the ingress endpoint causes operator endpoints to throttle.

### Pitfall 4: Deterministic 401 Shape Is Violated by FastAPI Defaults

**What goes wrong:** Missing tokens return a different body such as `{"detail":"Not authenticated"}`.

**Why it happens:** `HTTPBearer(auto_error=True)` raises its own exception with a different message.

**How to avoid:** Use `auto_error=False` and raise a single custom `HTTPException` with `detail="unauthorized"` and `WWW-Authenticate: Bearer`.

**Warning signs:** Tests expect `{"detail":"unauthorized"}` but receive a capitalized message.

### Pitfall 5: Secrets Leak in Settings Dumps or Error Responses

**What goes wrong:** A startup validation error or a `/v1/readyz` check includes the token value.

**Why it happens:** `SecretStr` is bypassed by `str(settings)` or by returning raw settings objects.

**How to avoid:** Compare with `.get_secret_value()` only inside the auth helper. Never serialize, log, or return the secret. Reuse `safe_log_extra` for security events.

**Warning signs:** A test grep for the token string appears in a log or response fixture.

### Pitfall 6: Tests Rely on a Global Rate-Limit Counter

**What goes wrong:** Tests are flaky because the in-process counter retains state between test cases.

**Why it happens:** The middleware stores counters in a module-level or class-level object.

**How to avoid:** Reset the limiter state in each test (e.g., expose a `clear()` method and call it from a fixture) or use per-app limiter instances injected through `create_app`.

**Warning signs:** A rate-limit test passes in isolation but fails when the full suite runs.

## Code Examples

### Adding auth dependency to a router

```python
# app/api/routers/incidents.py
from fastapi import APIRouter, Security
from app.api.security import require_operator_token

router = APIRouter(
    prefix="/v1/incidents",
    dependencies=[Security(require_operator_token)],
)
```

### Wiring middleware in `create_app`

```python
# app/main.py
def create_app(...) -> FastAPI:
    app = FastAPI(lifespan=lifespan)
    # ... existing state setup ...

    app.add_middleware(
        RequestSizeLimiterMiddleware,
        default_limit=app.state.settings.max_body_bytes,
        class_limits={
            "operator": app.state.settings.max_body_bytes_operator,
            "ingress": app.state.settings.max_body_bytes_ingress,
            "metrics": app.state.settings.max_body_bytes_metrics,
        },
    )
    app.add_middleware(
        RateLimiterMiddleware,
        default=RateLimitConfig(
            enabled=app.state.settings.rate_limit_enabled,
            requests=app.state.settings.rate_limit_requests,
            window_seconds=app.state.settings.rate_limit_window_seconds,
        ),
        by_class={
            "operator": _rate_limit_config(app.state.settings, "operator"),
            "ingress": _rate_limit_config(app.state.settings, "ingress"),
            "metrics": _rate_limit_config(app.state.settings, "metrics"),
        },
    )

    app.include_router(health_router)
    # ... include other routers ...
    return app
```

### Test pattern for protected routes

```python
# tests/test_security.py
import pytest
from httpx import ASGITransport, AsyncClient
from app.config.settings import Settings
from app.main import create_app

pytestmark = pytest.mark.anyio

VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


def _app(**kwargs) -> FastAPI:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=True,
        operator_api_token="operator-secret",
        ingress_api_token="ingress-secret",
        **kwargs,
    )
    return create_app(settings=settings, sessionmaker=lambda: object())


async def test_operator_route_rejects_missing_token() -> None:
    app = _app()
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            response = await client.get("/v1/incidents")
    assert response.status_code == 401
    assert response.json() == {"detail": "unauthorized"}
    assert response.headers.get("www-authenticate") == "Bearer"


async def test_ingress_token_is_rejected_on_operator_route() -> None:
    app = _app()
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            response = await client.get(
                "/v1/incidents",
                headers={"Authorization": "Bearer ingress-secret"},
            )
    assert response.status_code == 401
    assert response.json() == {"detail": "unauthorized"}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Unauthenticated `/v1` operator/config surface | Static Bearer tokens per route class | Phase 5 | Prevents accidental exposure of operator data and mutations. |
| `/v1/readyz` always public | Configurable public/protected via `expose_readyz` | Phase 5 | Lets operators hide dependency details while keeping health probes public. |
| No request size limit | ASGI middleware with per-route-class caps | Phase 5 | Rejects oversized payloads before route handlers and JSON parsing. |
| No rate limiting | In-process fixed-window per-route-class limiter | Phase 5 | Bounded abuse protection without external infrastructure. |
| `str` settings for secrets | `pydantic.SecretStr` for tokens | Phase 5 | Reduces accidental secret serialization. |

**Deprecated/outdated:**
- Vigilo `DEV_MODE` auth bypass: explicitly out of scope; Correlia must be production-safe by default.
- Uvicorn-only body-size limits: insufficient because they are not per-route-class and are hard to test via ASGI transport.

## Concrete Risks

| Risk | Likelihood | Impact | Mitigation in Plan |
|------|------------|--------|--------------------|
| Middleware path classification drifts when new routes are added. | Medium | Medium (wrong auth/size/rate applied) | Centralize route-class mapping in `app/middleware/classification.py` and add a test that asserts every route is classified. |
| Size-limit middleware buffers more memory than expected on chunked uploads. | Low | Medium (memory pressure) | Reject as soon as the cap is exceeded; cap default is 1 MiB; overrides can be lowered but not raised without explicit config. |
| Rate-limit counter state leaks between tests. | Medium | Low (flaky tests) | Provide a `clear()` method on the limiter and reset it in an autouse fixture. |
| A malformed `Authorization` header leaks the token class (operator vs ingress). | Low | Medium (information disclosure) | Use one `Unauthorized` exception shape everywhere and never include the route class in the response. |
| Metrics protected by operator token breaks existing Prometheus scraping. | Medium | Medium (observability outage) | Default `expose_metrics=True` keeps existing behavior; operators must explicitly opt in to protected metrics and update scrape config. |
| `SecretStr` bypassed in a settings dump or error response. | Low | High (secret leak) | Never return settings objects from routes; compare tokens with `get_secret_value()` only in auth helpers; grep tests for token strings. |
| Auth dependency ordering causes rate limit to count unauthenticated requests against protected buckets. | Low | Low | Auth first for protected routes (router dependencies); rate limit by token after auth; public routes rate-limited by IP. |
| Chunked body rejected after partial read leaves the ASGI server in a bad state. | Low | Low | Return `413` and do not replay; rely on ASGI server to close the connection cleanly. |

## Plan Decomposition Guidance

The planner should split Phase 5 into small, independently reviewable plans that each deliver a working control. A recommended decomposition:

1. **Settings and fail-fast validation** (SEC-01, SEC-02, D-09)
   - Add auth, exposure, size, and rate-limit fields to `Settings`.
   - Add `model_validator` requiring operator/ingress tokens when auth is enabled.
   - Update `tests/conftest.py` env scrub list.

2. **Static Bearer auth dependencies** (SEC-01, SEC-02, D-01..D-10)
   - Create `app/api/security.py` with `require_operator_token`, `require_ingress_token`, and shared `Unauthorized` shape.
   - Attach dependencies to `incidents`, `config_status`, `plugins`, and conditionally to `readyz`/`metrics`.
   - Add tests for 401 on protected routes, wrong token class, unchanged public health, and configurable readyz/metrics.

3. **Request-size limiting middleware** (SEC-04, D-15..D-18)
   - Create `app/middleware/size_limit.py`.
   - Add `Content-Length` fast path and chunked-byte counting with bounded buffering.
   - Add tests for `413` on oversized `Content-Length` and chunked bodies, and valid bodies under the cap.

4. **In-process rate-limiting middleware** (SEC-05, D-11..D-14)
   - Create `app/middleware/rate_limit.py` with fixed-window counters and identity by token hash or IP.
   - Add per-route-class defaults and overrides.
   - Add tests for 429 after threshold, `Retry-After`, and resettable state.

5. **Integration wiring and observability**
   - Install middleware and dependencies in `create_app`.
   - Add safe structured logs for auth failures, rate-limit hits, and size-limit hits using `safe_log_extra`.
   - Add a cross-cutting test that exercises all controls on a single request path.

6. **Test hygiene and environment parity**
   - Ensure all existing tests still pass when auth defaults to enabled (they will need explicit tokens or `api_auth_enabled=False`).
   - Document required env vars in any sample config produced later (Phase 10).

**Ordering notes:**
- Plan 1 should be first because later plans depend on the settings shape.
- Plans 2-4 can be implemented in parallel once settings exist; if parallelized, coordinate on the route-class naming convention.
- Plan 5 must follow plans 2-4.
- Plan 6 validates the whole phase and should be the final plan.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | FastAPI `HTTPBearer(auto_error=False)` returns `HTTPAuthorizationCredentials | None` and works inside `Security` dependencies. | Pattern 1 | Dependency injection would fail; fallback is to parse the header manually. |
| A2 | Replacing `request._receive` with a replay callable is sufficient for FastAPI/Starlette body parsing after buffering. | Pattern 3 | Body would appear empty to route handlers; fallback is to implement a custom `Request` subclass. |
| A3 | `request.scope["client"][0]` reliably provides the remote IP for ASGI transport tests. | Pattern 4 | Rate-limit identity would be `unknown` for unauthenticated tests; fallback is to accept `ip:unknown` bucket for testing. |
| A4 | A 1 MiB default request body cap is acceptable for Icinga2 webhook payloads and JSON API requests. | Pattern 3 / Settings | Legitimate payloads could be rejected; fallback is to raise the default or add explicit overrides. |
| A5 | Protected metrics should use the operator token (not a separate metrics token). | Pattern 2 / Summary | If metrics needs its own token, a third `metrics_api_token` setting must be added; D-10 only says "optionally protected metrics failures use the same unauthorized response shape," which is satisfied by using the operator token. |

**If this table is empty:** Not applicable - assumptions are listed above.

## Open Questions

1. **Exact rate-limit defaults**
   - What we know: D-13 asks for conservative enabled defaults configurable per route class.
   - What's unclear: Concrete requests-per-window values for operator, ingress, and metrics classes.
   - Recommendation: Start with `operator=60/min`, `ingress=120/min`, `metrics=30/min`, and expose `rate_limit_requests_*` plus `rate_limit_window_seconds_*` overrides. Confirm during planning whether ingress bursts from Icinga2 need a higher burst allowance.

2. **Ordering of size and rate-limit middleware**
   - What we know: Both must run before route handlers.
   - What's unclear: Whether size should be outermost to reject huge bodies before counting them against rate limits.
   - Recommendation: Install size-limit middleware outside rate-limit middleware so oversized payloads are rejected before they consume rate-limit budget.

3. **ReadyZ and metrics default exposure values**
   - What we know: D-02 says readyz public by default and configurable; D-04 says metrics not hard-protected by default and configurable.
   - What's unclear: Whether "not hard-protected" means public by default or protected only when auth is enabled.
   - Recommendation: Model both as `expose_readyz=True` and `expose_metrics=True` by default. When a flag is `False` and `api_auth_enabled=True`, the route requires the operator token. This keeps backward compatibility and gives operators an explicit opt-in to protection.

4. **Route-class classification for unversioned or future paths**
   - What we know: All current routes are under `/v1`.
   - What's unclear: How to classify a future `/v2` route or a route without a recognized prefix.
   - Recommendation: Treat unrecognized paths as `operator` by default in middleware, but fail loudly in a classification test so new routers are explicitly categorized.

5. **Logging of rate-limit and size-limit events**
   - What we know: `safe_log_extra` provides a safe structured log helper.
   - What's unclear: Whether rate-limit hits should be logged at warning or info level.
   - Recommendation: Log rate-limit hits at `INFO` with fields `event="rate_limit_exceeded"`, `route_class`, and a hash of the identity. Log size-limit hits at `INFO` with `event="request_body_too_large"`, `route_class`, and `content_length` if available.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| uv | Package/runtime management | ✓ | 0.11.7 | — |
| Python | Runtime | ✓ | 3.12.3 in environment; project requires >=3.14 | Use project-specified interpreter (`uv run` should resolve correct Python) |
| PostgreSQL | Existing DB-backed tests | ✓ via Testcontainers | latest available image | Tests without DB can use mocked sessionmaker |
| FastAPI / Starlette | Auth and middleware | ✓ | transitively from `pyproject.toml` | — |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** None.

**Note:** The workstation Python is 3.12.3, but `pyproject.toml` requires `>=3.14`. This is an existing environment gap, not introduced by Phase 5. Phase 5 code should be written for Python 3.14 syntax (e.g., `Self` return annotations, PEP 695 where appropriate) and validated through the project's chosen runtime, not the bare workstation interpreter.

## Security Domain

`security_enforcement` is enabled in `.planning/config.json`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V1 Architecture | yes | In-process controls only; no external auth/rate-limit services assumed. |
| V2 Authentication | yes | Static Bearer tokens configured via environment (`SecretStr`). |
| V3 Session Management | no | Stateless tokens; no sessions. |
| V4 Access Control | yes | Router-level dependencies restrict operator vs ingress surfaces. |
| V5 Input Validation | yes | Request body size limits and Pydantic validators for settings. |
| V6 Cryptography | yes | `SecretStr` for token storage; SHA-256 hash for rate-limit identity, never stored raw. |
| V7 Error Handling | yes | Deterministic `401`/`413`/`429` responses with no stack traces or token class hints. |
| V8 Data Protection | yes | Tokens never logged, returned, or serialized; payloads never logged by control code. |
| V10 Logging | yes | Reuse `safe_log_extra` for security events. |

### Known Threat Patterns for FastAPI/ASGI

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Missing authentication on operator routes | Elevation of privilege | Router-level `Security(require_operator_token)` dependencies. |
| Token brute-force / credential stuffing | Brute force | Rate limiting by token hash or IP; deterministic 401 hides token validity. |
| Oversized request DoS | Denial of service | ASGI size-limit middleware with `Content-Length` and chunked counting. |
| Enumeration of protected endpoints | Information disclosure | Identical 401 shape for missing/invalid tokens and across token classes. |
| Secret token leak in logs/responses | Information disclosure | `SecretStr`, `safe_log_extra`, and explicit grep tests. |
| Slowloris-style chunked upload | Denial of service | Bound byte counting and early 413; keep default cap conservative. |

## Sources

### Primary (HIGH confidence)
- Inspected codebase files listed in "Inventory of Directly Relevant Files" - route structure, settings patterns, test patterns, and logging helper.
- `.planning/phases/05-security-and-http-controls/05-CONTEXT.md` - locked decisions D-01..D-18.
- `.planning/REQUIREMENTS.md` - requirements SEC-01..SEC-05 and out-of-scope constraints.
- `.planning/PROJECT.md` - project architecture and v1.1 compatibility context.
- `.planning/ROADMAP.md` - Phase 5 success criteria.
- `VIGILO_COMPATIBILITY.md` lines 94-112 - original auth/rate-limit/request-size target, refined by CONTEXT.md.

### Secondary (MEDIUM confidence)
- FastAPI `HTTPBearer` and `Security` behavior documented at `fastapi.tiangolo.com/reference/security/` [CITED] - used to recommend dependency-based auth.
- Starlette middleware and ASGI request-replay patterns documented at `starlette.io/middleware/` and `starlette.io/requests/` [CITED] - used for size-limit middleware design.
- Pydantic v2 `SecretStr` and `model_validator` documented at `docs.pydantic.dev/latest/concepts/settings/` [CITED] - used for fail-fast settings validation.

### Tertiary (LOW confidence)
- Recommended default numeric rate-limit values (60/min operator, 120/min ingress, 30/min metrics) are not specified in requirements; they are planning recommendations and should be confirmed during discuss/plan.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - No new packages; uses existing FastAPI/Starlette/Pydantic stack visible in `pyproject.toml`.
- Architecture: MEDIUM - Middleware ordering and request-replay mechanics are well-understood but must be validated by tests in the implementation phase.
- Pitfalls: MEDIUM - Based on common FastAPI/ASGI patterns and the inspected test setup; actual edge cases may surface during implementation.

**Research date:** 2026-06-14
**Valid until:** 2026-07-14 for stable FastAPI/Starlette APIs; revisit if a major version is released before implementation.
