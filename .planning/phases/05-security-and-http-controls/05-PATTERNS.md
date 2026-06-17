# Phase 5: Security and HTTP Controls - Pattern Map

**Mapped:** 2026-06-14
**Files analyzed:** 9 new modules + 8 modified files + 2 new test files
**Analogs found:** 14 with matches / 19 total

This map is the planner's checklist for the auth/size/rate/exposure work. Every new file
below points at an existing file in the repo that already exercises the relevant convention.
Read the linked analog before drafting PLAN.md; the excerpts are the shortest copy-paste anchors.

## File Classification

|New/Modified File|Role|Data Flow|Closest Analog|Match Quality|
|---|---|---|---|---|
| `app/api/security.py` (new) | middleware/dependencies | request-response | `app/api/deps.py` | role-match |
| `app/middleware/__init__.py` (new) | package | n/a | `app/api/__init__.py`, `app/api/routers/__init__.py` | exact |
| `app/middleware/classification.py` (new) | utility | path→class | `app/api/routers/health.py` (prefix pattern) | partial |
| `app/middleware/size_limit.py` (new) | middleware | request-body | `app/main.py` `request_validation_exception_handler` (compact JSONResponse shape) | partial |
| `app/middleware/rate_limit.py` (new) | middleware | request-response | `app/main.py` `request_validation_exception_handler` (compact JSONResponse shape) | partial |
| `app/config/settings.py` (modify) | config | env→typed | `app/config/settings.py` (self) + `app/config/plugins.py` (model_validator style) | exact |
| `app/main.py` (modify) | factory | wiring | `app/main.py` (self) | exact |
| `app/api/routers/health.py` (modify) | router | request-response | `app/api/routers/health.py` (self) | exact |
| `app/api/routers/ingress.py` (modify) | router | request-response | `app/api/routers/ingress.py` (self) | exact |
| `app/api/routers/incidents.py` (modify) | router | request-response | `app/api/routers/incidents.py` (self) | exact |
| `app/api/routers/config_status.py` (modify) | router | request-response | `app/api/routers/config_status.py` (self) | exact |
| `app/api/routers/plugins.py` (modify) | router | request-response | `app/api/routers/plugins.py` (self) | exact |
| `app/api/routers/metrics.py` (modify) | router | request-response | `app/api/routers/metrics.py` (self) | exact |
| `app/processing/logging.py` (modify or extend) | logging | n/a | `app/processing/logging.py` (self) | exact |
| `tests/conftest.py` (modify) | test | env scrubbing | `tests/conftest.py` (self) | exact |
| `tests/test_security.py` (new) | test | request-response | `tests/test_health.py`, `tests/test_plugins_router.py` | exact |
| `tests/test_size_limit.py` (new) | test | request-body | `tests/test_ingress_router.py` (ASGI fixture) | role-match |
| `tests/test_rate_limit.py` (new) | test | request-response | `tests/test_incidents_api.py` (ASGI fixture) | role-match |
| `tests/test_exposure_config.py` (new) | test | settings→router | `tests/test_settings.py` (validator coverage) | partial |

## Pattern Assignments

### `app/api/security.py` (new module — auth dependencies + exposure helpers)

**Analog:** `app/api/deps.py` (request-state dependency helpers)

The current `app/api/deps.py` already establishes the convention: dependencies that pull
typed objects off `request.app.state` via `cast(...)`. The new security module extends
that style with `HTTPBearer`-backed dependencies and a single `Unauthorized` exception
shape shared by every protected route class.

**Imports pattern** (`app/api/deps.py:1-17`):

```python
from typing import cast

from fastapi import Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from app.config.rules import CompiledRuleConfig
from app.config.topology import CompiledTopologyConfig

from app.config.settings import Settings
from app.plugins.loader import PluginRegistry
from app.processing.lifecycle_worker import LifecycleWorker
from app.processing.task_runner import TaskRunner
from app.processing.ingress import Icinga2DecisionProcessor


def get_app_settings(request: Request) -> Settings:
    return cast(Settings, request.app.state.settings)
```

**Compact 401-response shape** is not yet in the codebase. The closest analog is the
compact 503/422 JSONResponse pattern from `app/main.py:39-47`:

```python
async def request_validation_exception_handler(
    _request: Request,
    exc: Exception,
) -> JSONResponse:
    if not isinstance(exc, RequestValidationError):
        raise exc
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        content={"detail": _safe_validation_errors(exc)},
    )
```

Plan: mirror this for `Unauthorized(detail="unauthorized", headers={"WWW-Authenticate":
"Bearer"})`, raised from `require_operator_token` and `require_ingress_token`. Use
`fastapi.security.HTTPBearer(auto_error=False)` (no existing usage in the repo; this
is the only new external class) so that the 401 shape is identical for missing and
invalid tokens.

**Auth-dependency skeleton** (the new file should look like this — drop the `TODO`s
when implementing):

```python
from typing import Annotated

from fastapi import HTTPException, Request, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from app.api.deps import get_app_settings
from app.config.settings import Settings

_security = HTTPBearer(auto_error=False)


class Unauthorized(HTTPException):
    def __init__(self) -> None:
        super().__init__(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="unauthorized",
            headers={"WWW-Authenticate": "Bearer"},
        )


def _matches(credentials: HTTPAuthorizationCredentials | None, expected: str | None) -> bool:
    if expected is None or credentials is None:
        return False
    return credentials.credentials == expected


def require_operator_token(
    request: Request,
    settings: Annotated[Settings, Depends(get_app_settings)],
    credentials: HTTPAuthorizationCredentials | None = Security(_security),
) -> None:
    if not settings.api_auth_enabled:
        return
    if not _matches(credentials, settings.operator_api_token.get_secret_value()):
        raise Unauthorized()
```

`request: Request` is included so the dependency can be extended for logging via
`request.scope["client"]` without changing the signature (compare with `app/api/routers/health.py:24-31`).

### `app/middleware/__init__.py` (new package)

**Analog:** `app/api/__init__.py` and `app/api/routers/__init__.py`

Both are empty marker files (0 bytes). The new `app/middleware/__init__.py` should be a
zero-byte file. This is the established pattern, not a stylistic choice.

### `app/middleware/classification.py` (new utility — path → route class)

**Analog:** `app/api/routers/health.py:18` (router prefix declaration)

```python
router = APIRouter(prefix="/v1")
```

Plus per-route paths declared alongside route handlers (e.g.
`app/api/routers/incidents.py:38` uses `prefix="/v1/incidents"` and the
`@router.get("")`, `@router.get("/{incident_id}")` decorators).

The classification helper is a `dict[str, str]` (or frozen module-level constant) mapping
prefix → class:

```python
# app/middleware/classification.py
from typing import Final

# (path_prefix, route_class) — order longest-first for matching
ROUTE_CLASS_PREFIXES: Final[tuple[tuple[str, str], ...]] = (
    ("/v1/icinga2/events", "ingress"),
    ("/v1/incidents", "operator"),
    ("/v1/rules", "operator"),
    ("/v1/topology", "operator"),
    ("/v1/plugins", "operator"),
    ("/v1/metrics", "metrics"),
    ("/v1/readyz", "health"),
    ("/v1/health", "health"),
)


def classify_path(path: str) -> str:
    for prefix, route_class in ROUTE_CLASS_PREFIXES:
        if path == prefix or path.startswith(prefix + "/"):
            return route_class
    return "operator"  # conservative default; planner should confirm
```

Reference: `app/main.py:140-145` (router include order) is the source of truth for the
current path surface; the helper is consumed by both middleware classes.

### `app/middleware/size_limit.py` (new ASGI middleware)

**Analog for compact JSONResponse shape:** `app/main.py:39-47`
(see excerpt above — `JSONResponse(status_code=..., content={"detail": ...})`).

**Analog for ASGI middleware class:** no precedent in this repo. Starlette's
`BaseHTTPMiddleware` (`starlette.middleware.base.BaseHTTPMiddleware`) is the
standard fit; it is already an indirect dependency of FastAPI.

Plan shape (do not implement yet — this is the planner anchor):

```python
from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from app.middleware.classification import classify_path


class RequestSizeLimiterMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, default_limit: int, class_limits: dict[str, int | None]):
        super().__init__(app)
        self.default_limit = default_limit
        self.class_limits = class_limits

    def _limit_for(self, route_class: str) -> int:
        override = self.class_limits.get(route_class)
        return override if override is not None else self.default_limit

    async def dispatch(self, request: Request, call_next):
        route_class = classify_path(request.url.path)
        limit = self._limit_for(route_class)
        if limit <= 0:
            return await call_next(request)
        # 1. Reject when Content-Length already exceeds the cap (before reading body).
        # 2. Else wrap `request._receive` to count chunks, fail 413 on cap exceeded.
        # 3. Replay buffered messages to downstream.
        return await call_next(request)
```

The 413-response shape is `JSONResponse(status_code=413, content={"detail": "request body too large"})` —
mirroring the `request_validation_exception_handler` shape from `app/main.py:39-47`.

### `app/middleware/rate_limit.py` (new ASGI middleware)

**Analog for compact JSONResponse with extra header:** no exact precedent in the repo.
The closest shape is the `JSONResponse(status_code=503, content={"detail": "not ready",
"checks": checks})` pattern in `app/api/routers/health.py:55-58`:

```python
return JSONResponse(
    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
    content={"detail": "not ready", "checks": checks},
)
```

For 429, the `Retry-After` header goes in via `JSONResponse(..., headers=...)`. No
existing middleware in the repo, so the planner should also reuse the `asyncio.Lock` +
`dict`-based counter pattern from `app/persistence/incidents.py` (read separately if
needed; not pulled into PATTERNS.md because the rate-limit store is a clean sheet).

### `app/config/settings.py` (modify)

**Analog for the env-bound `BaseSettings` shape:** the file itself (lines 1-26).

```python
from pathlib import Path
from typing import Literal

from pydantic import Field, PostgresDsn
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="CORRELIA_",
        case_sensitive=False,
        extra="forbid",
    )

    database_url: PostgresDsn = Field(validation_alias="DATABASE_URL")
    environment: Literal["local", "test", "production"] = "local"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    rules_path: Path | None = None
    topology_path: Path | None = None
    plugins_path: Path | None = None
    lifecycle_scan_interval_seconds: int = Field(default=30, ge=1, le=86_400)
    lifecycle_batch_size: int = Field(default=100, ge=1, le=1_000)


def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
```

**Analog for `model_validator` (fail-fast, after-mode):** `app/config/plugins.py:45-52`
and `app/config/topology.py:52-?` (the latter also uses `model_validator(mode="after")`
to enforce cross-field invariants).

```python
# app/config/plugins.py
class PluginRegistryConfigFile(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    outputs: list[PluginRegistryEntry] = Field(default_factory=list, max_length=100)

    @model_validator(mode="after")
    def reject_duplicate_names(self) -> "PluginRegistryConfigFile":
        names: set[str] = set()
        for output in self.outputs:
            if output.name in names:
                raise ValueError(f"duplicate output plugin name: {output.name}")
            names.add(output.name)
        return self
```

`tests/test_settings.py` already covers `extra="forbid"`, `env_prefix="CORRELIA_"`, and
`ValidationError` for invalid env bindings. The new `model_validator` for token
presence must extend that test surface with a new `pytest.raises(ValidationError)`
case (`expected_error == "value_error"`) for the "auth enabled but token missing"
scenario.

**Pattern to import for `SecretStr`:** not currently in the repo. The new fields
should use `pydantic.SecretStr` exactly as the RESEARCH.md recommends, and the test
suite must extend `tests/conftest.py` to scrub the new env keys (see below).

### `app/main.py` (modify)

**Analog:** the file itself (lines 122-165 are the create_app body).

```python
def create_app(
    settings: Settings | None = None,
    sessionmaker: async_sessionmaker[AsyncSession] | None = None,
    icinga2_processor: Icinga2DecisionProcessor | None = None,
    task_runner: TaskRunner | None = None,
    plugin_registry: PluginRegistry | None = None,
    lifecycle_worker: LifecycleWorker | None = None,
) -> FastAPI:
    app = FastAPI(lifespan=lifespan)
    app.add_exception_handler(RequestValidationError, request_validation_exception_handler)

    if settings is not None:
        app.state.settings = settings
        configure_json_logging(settings.log_level)
    # ... other state assignments ...

    app.include_router(health_router)
    app.include_router(ingress_router)
    app.include_router(plugins_router)
    app.include_router(config_status_router)
    app.include_router(incidents_router)
    app.include_router(metrics_router)
    return app
```

Phase 5 plan must:
1. Call `app.add_middleware(RequestSizeLimiterMiddleware, ...)` and
   `app.add_middleware(RateLimiterMiddleware, ...)` immediately after
   `app.add_exception_handler(...)`. The planner should preserve this order so size
   rejects before rate-limit counts.
2. Resolve the per-route-class `RateLimitConfig` and size limits from
   `app.state.settings` and pass them through middleware kwargs (mirroring the
   "optional kwargs" pattern already used for `sessionmaker`, `plugin_registry`,
   etc.).
3. Add unit-level tests in `tests/test_security.py` that pass these kwargs through
   the `create_app(...)` factory exactly the same way the existing tests do.

### `app/api/routers/health.py` (modify — readyz exposure dependency)

**Analog:** the file itself; the change is purely additive.

The pattern: add a router-level dependency to `/v1/readyz` that decides between
`Security(require_operator_token)` and a no-op `Depends(_public)` based on
`settings.expose_readyz`. The cleanest place to wire this is in `app/main.py`
when the router is included (mirroring how `app.state` is populated). Keep
`/v1/health` untouched and never attach the auth dependency to it.

Reference for the existing route shape: `app/api/routers/health.py:17-21`
(returns a plain dict) and lines 23-62 (readyz with `Annotated[Settings, Depends(get_app_settings)]`).

### `app/api/routers/ingress.py` (modify — add ingress-token dependency)

**Analog:** the file itself (`app/api/routers/ingress.py:1-43`).

```python
from __future__ import annotations

import logging
from typing import Annotated

from fastapi import APIRouter, Body, Depends, HTTPException, status

from app.api.deps import get_icinga2_processor
from app.domain.rules import IngressDecisionEnvelope
from app.plugins.inputs.icinga2 import Icinga2WebhookPayload
from app.processing.ingress import Icinga2DecisionProcessor
from app.processing.logging import safe_log_extra

router = APIRouter(prefix="/v1")
logger = logging.getLogger(__name__)


@router.post("/icinga2/events")
async def ingest_icinga2(
    processor: Annotated[Icinga2DecisionProcessor, Depends(get_icinga2_processor)],
    payload: Icinga2WebhookPayload = Body(...),
) -> IngressDecisionEnvelope:
    ...
```

Plan: add `dependencies=[Security(require_ingress_token)]` to the `APIRouter(...)`
constructor. The handler body and `safe_log_extra` style stay untouched.

### `app/api/routers/incidents.py` (modify)

**Analog:** `app/api/routers/incidents.py:36-37` — `router = APIRouter(prefix="/v1/incidents")`.

Plan: change to `router = APIRouter(prefix="/v1/incidents",
dependencies=[Security(require_operator_token)])`. No other changes — the existing
handler signatures, `safe_log_extra` calls, and `HTTPException` shapes stay.

### `app/api/routers/config_status.py` (modify)

**Analog:** `app/api/routers/config_status.py:14-15` — `router = APIRouter(prefix="/v1")`.

Same change: add `dependencies=[Security(require_operator_token)]` to the
`APIRouter(...)` constructor. The handler bodies reference only `get_rules_config`
and `get_topology_config` from `app/api/deps.py`; no auth helper duplication.

### `app/api/routers/plugins.py` (modify)

**Analog:** `app/api/routers/plugins.py:11-12` — `router = APIRouter(prefix="/v1")`.

Add `dependencies=[Security(require_operator_token)]`. The body returns
`plugin_registry.list_plugins()` (which is already filtered to safe fields per
`tests/test_plugins_router.py:60-69`); no auth-related body changes.

### `app/api/routers/metrics.py` (modify)

**Analog:** the file itself — `app/api/routers/metrics.py:1-12`.

```python
from fastapi import APIRouter, Response

from app.processing.metrics import CONTENT_TYPE_LATEST, render_metrics

router = APIRouter(prefix="/v1")


@router.get("/metrics")
async def metrics() -> Response:
    return Response(content=render_metrics(), media_type=CONTENT_TYPE_LATEST)
```

Plan: this is the conditional-exposure route. Two acceptable shapes:

- **Option A** (preferred per RESEARCH.md "Don't Hand-Roll"): build the router
  inside `app/main.py` with the chosen dependency (`Security(require_operator_token)`
  when `not settings.expose_metrics and settings.api_auth_enabled`, else no
  dependency). The static `app/api/routers/metrics.py` keeps the handler and
  exports a `build_router(*, protected: bool) -> APIRouter` factory.
- **Option B**: keep the router as-is and attach `dependencies=[]`; the planner
  must document why this diverges from `health.py`'s pattern.

The planner should pick option A so the route-intent stays in `app/main.py` next
to the other wiring decisions.

### `app/processing/logging.py` (extend SAFE_LOG_KEYS)

**Analog:** `app/processing/logging.py:9-33` (current `SAFE_LOG_KEYS` allowlist).

```python
SAFE_LOG_KEYS = frozenset(
    {
        "event",
        "event_type",
        "incident_id",
        "rule_name",
        "group_key",
        "status",
        "severity",
        "reason",
        "category",
        "plugin_name",
        "task_name",
        "exception_type",
        "effect",
        "operator",
        "count",
        "matched_rule_count",
        "notification_count",
        "closure_count",
        "expired_count",
        "previous_host_count",
        "previous_service_count",
        "affected_object_removed",
        "healthy",
        "ready",
    }
)
```

Plan: extend the allowlist with `route_class`, `identity_hash` (or a similar hashed
identifier for rate-limit identity), `content_length` (for size-limit logs), and
`retry_after` (for rate-limit logs). Never add `authorization`, `token`, or
`headers` to the allowlist — the existing `tests/test_structured_logging.py:14-19`
forbids `"raw_payload"`, `"plugin_options"`, `"password"`, `"token-secret"`,
`"smtp transcript"`, `"Traceback"`, `"secret exception"` and the new control
events must respect the same rule.

Call sites follow the existing convention, e.g. `app/api/routers/incidents.py:142-152`:

```python
logger.info(
    "incident acknowledged",
    extra=safe_log_extra(
        event="operator_mutation",
        incident_id=str(result.incident.id),
        status=result.incident.status,
        effect=result.effect,
        reason="acknowledged",
        operator=body.operator,
    ),
)
```

The planner should add `event="auth_failed"` and `event="request_body_too_large"`
and `event="rate_limit_exceeded"` log lines, and extend
`tests/test_structured_logging.py:13-19` (`FORBIDDEN_FRAGMENTS`) to grep for token
strings, ensuring the new control code does not log the bearer token.

### `tests/conftest.py` (modify)

**Analog:** `tests/conftest.py:1-22` (the file is 22 lines total).

```python
from collections.abc import Iterator

import pytest


_SETTINGS_ENV_KEYS = (
    "DATABASE_URL",
    "CORRELIA_DATABASE_URL",
    "CORRELIA_ENVIRONMENT",
    "CORRELIA_LOG_LEVEL",
    "CORRELIA_RULES_PATH",
    "CORRELIA_TOPOLOGY_PATH",
    "CORRELIA_PLUGINS_PATH",
)


@pytest.fixture(autouse=True)
def clean_settings_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    for key in _SETTINGS_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    yield
```

Plan: extend `_SETTINGS_ENV_KEYS` with every new `CORRELIA_*` env var (auth, exposure,
size, rate-limit) so `monkeypatch.delenv` resets them between tests. The fixture is
`autouse=True`, so any new test module inherits the scrub automatically.

### `tests/test_security.py` (new) — auth + size + rate cases

**Analog:** `tests/test_plugins_router.py:1-80` (the closest stylistic twin — same
fixture pattern, same `_app` factory style, same `get_client` helper, same
`Settings(DATABASE_URL=...)` constructor invocation).

```python
# tests/test_plugins_router.py
from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest
import yaml
from httpx import ASGITransport, AsyncClient

from app.config.plugins import load_plugin_registry_config
from app.plugins.loader import PluginRegistry

pytestmark = pytest.mark.anyio


async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def test_v1_plugins_route_lists_safe_output_status_only(tmp_path: Path) -> None:
    from app.config.settings import Settings
    from app.main import create_app

    registry = _registry(tmp_path)
    app = create_app(
        settings=Settings(DATABASE_URL="postgresql+asyncpg://user:pass@localhost:5432/correlia"),
        sessionmaker=lambda: object(),
        plugin_registry=registry,
    )

    async for client in get_client(app):
        response = await client.get("/v1/plugins")
    ...
```

**Analog for fail-fast settings tests:** `tests/test_settings.py:38-54`:

```python
@pytest.mark.parametrize(
    ("kwargs", "expected_error"),
    [
        ({}, "missing"),
        ({"DATABASE_URL": "not-a-postgres-url"}, "url_parsing"),
        ({"DATABASE_URL": VALID_DATABASE_URL, "environment": "staging"}, "literal_error"),
        ({"DATABASE_URL": VALID_DATABASE_URL, "log_level": "TRACE"}, "literal_error"),
        ({"DATABASE_URL": VALID_DATABASE_URL, "unexpected": "value"}, "extra_forbidden"),
    ],
)
def test_invalid_settings_raise_explicit_validation_errors(
    kwargs: dict[str, str], expected_error: str
) -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(**kwargs)

    error_types = {error["type"] for error in exc_info.value.errors()}
    assert expected_error in error_types
```

Plan: copy the `pytestmark = pytest.mark.anyio`, `get_client(app)`, and
`Settings(DATABASE_URL=...)` patterns. Add cases for:

- Missing token when `api_auth_enabled=True` → `Settings(...)` raises `ValidationError`.
- Operator route with no Authorization header → 401, body `{"detail":"unauthorized"}`,
  header `WWW-Authenticate: Bearer`.
- Operator route with ingress token → same 401 (token class is invisible in the
  response).
- `/v1/health` is public in every variant.
- `/v1/readyz` is public by default; protected when `expose_readyz=False`.
- `/v1/metrics` is public by default; protected when `expose_metrics=False`.
- POST `/v1/icinga2/events` with a body over `max_body_bytes` → 413 with
  `{"detail":"request body too large"}`.
- POST `/v1/icinga2/events` with chunked body over the cap → 413 (the size middleware
  must catch this without `Content-Length`).
- Burst of N+1 requests to a protected route within the window → 429 with
  `{"detail":"rate limit exceeded"}` and a `Retry-After` header.

### `tests/test_size_limit.py` (new) — body size ASGI cases

**Analog:** `tests/test_ingress_router.py` (the largest existing ASGI test module,
~40KB; already uses `ASGITransport` and `app.router.lifespan_context`). The planner
should read it for the exact `httpx.AsyncClient(transport=ASGITransport(app=app),
base_url="http://test")` shape and the `httpx` upload idiom for sending bodies
larger than `max_body_bytes` (httpx supports `content=` with explicit byte count and
`Transfer-Encoding: chunked` is exercised via `httpx.AsyncClient(transport=...,
headers={"transfer-encoding": "chunked"}, content=...)`).

### `tests/test_rate_limit.py` (new) — burst/identity/Retry-After cases

**Analog:** `tests/test_incidents_api.py:64-123` (ASGI fixture) and the
`get_client(app)` pattern from `tests/test_health.py:90-100`.

The plan must also extend the rate-limiter fixture: every new test should reset the
in-process counter (per RESEARCH.md Pitfall 6). The closest existing precedent is
the `SuccessfulSession` / `FailingSession` pattern in `tests/test_health.py:51-83` —
each test owns its fixtures and there is no global state.

## Shared Patterns

These cross-cutting conventions apply to every new file in Phase 5. The planner
must thread them through the plan actions.

### 1. Settings: Pydantic v2 + `CORRELIA_` env prefix + `extra="forbid"`

**Source:** `app/config/settings.py:1-26` (the canonical file) and
`tests/test_settings.py:30-54` (the test contract).

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="CORRELIA_",
        case_sensitive=False,
        extra="forbid",
    )
    ...
```

**Apply to:** `app/config/settings.py` modifications only. New fields:

- `api_auth_enabled: bool = True`
- `operator_api_token: SecretStr | None = None`
- `ingress_api_token: SecretStr | None = None`
- `expose_readyz: bool = True`
- `expose_metrics: bool = True`
- `max_body_bytes: int = Field(default=1_048_576, ge=1_024)` plus the
  `max_body_bytes_{operator,ingress,metrics}: int | None` overrides
- `rate_limit_enabled: bool = True` plus the per-class
  `rate_limit_requests_{operator,ingress,metrics}` and
  `rate_limit_window_seconds_{operator,ingress,metrics}` triples

The fail-fast `model_validator` follows the `app/config/plugins.py:45-52` template
exactly (`@model_validator(mode="after")`, raise `ValueError`, return `self`).

### 2. App factory + lifespan

**Source:** `app/main.py:55-118` (lifespan) and `app/main.py:121-165` (create_app).

```python
def create_app(
    settings: Settings | None = None,
    sessionmaker: async_sessionmaker[AsyncSession] | None = None,
    ...
) -> FastAPI:
    app = FastAPI(lifespan=lifespan)
    app.add_exception_handler(RequestValidationError, request_validation_exception_handler)
    ...
    app.include_router(health_router)
    ...
    return app
```

**Apply to:** `app/main.py` modifications. New kwargs for size/rate limit
configuration mirror the existing optional-kwargs style. The `app.add_middleware(...)`
calls go immediately after `add_exception_handler` so size rejects before rate-limit
counts and before routing.

### 3. FastAPI dependency style for request-state

**Source:** `app/api/deps.py:1-17` (the entire file is the pattern).

```python
def get_app_settings(request: Request) -> Settings:
    return cast(Settings, request.app.state.settings)
```

Plus the `Annotated[Settings, Depends(get_app_settings)]` consumer pattern from
`app/api/routers/health.py:25`:

```python
settings: Annotated[Settings, Depends(get_app_settings)],
```

**Apply to:** `app/api/security.py`. The new auth dependencies should accept
`Annotated[Settings, Depends(get_app_settings)]` so they reuse the same settings
resolution; do not call `get_settings()` from inside the dependency (it would
construct a fresh `Settings()` per request and bypass `app.state`).

### 4. Compact JSON error responses

**Source:** `app/main.py:39-47` (validation 422) and `app/api/routers/health.py:55-58`
(readiness 503):

```python
return JSONResponse(
    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
    content={"detail": "not ready", "checks": checks},
)
```

**Apply to:** `app/api/security.py` (`Unauthorized` exception) and both
`app/middleware/size_limit.py` and `app/middleware/rate_limit.py` (early-return
JSONResponses for 413/429). Keep the body to `{"detail": "<lowercase message>"}`
to honor D-07 and D-14; extra headers like `Retry-After` are added via
`JSONResponse(..., headers=...)` and do not appear in the body.

### 5. ASGITransport test fixture

**Source:** `tests/test_health.py:90-100` and `tests/test_plugins_router.py:14-22`
(both files share the same shape).

```python
async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client
```

**Apply to:** `tests/test_security.py`, `tests/test_size_limit.py`,
`tests/test_rate_limit.py`. The fixture wraps `app.router.lifespan_context` so the
new middleware sees the same startup state as production.

### 6. Safe structured logging

**Source:** `app/processing/logging.py:1-72` and the usage in
`app/api/routers/incidents.py:142-152` and `app/api/routers/health.py:53-55`.

```python
logger.info(
    "incident acknowledged",
    extra=safe_log_extra(
        event="operator_mutation",
        incident_id=str(result.incident.id),
        status=result.incident.status,
        effect=result.effect,
        reason="acknowledged",
        operator=body.operator,
    ),
)
```

**Apply to:** all three new modules. Never log the bearer token, the raw
`Authorization` header, or the request body. Extend
`tests/test_structured_logging.py:13-19` (`FORBIDDEN_FRAGMENTS`) with token-shaped
strings so a regression is caught.

### 7. Settings env scrubbing in tests

**Source:** `tests/conftest.py:1-22` (the entire file).

```python
_SETTINGS_ENV_KEYS = (
    "DATABASE_URL",
    "CORRELIA_DATABASE_URL",
    "CORRELIA_ENVIRONMENT",
    ...
)


@pytest.fixture(autouse=True)
def clean_settings_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    for key in _SETTINGS_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    yield
```

**Apply to:** `tests/conftest.py` only. Add every new `CORRELIA_*` env var
(`api_auth_enabled`, `operator_api_token`, etc.) so `monkeypatch.delenv` resets
them between tests and the existing autouse fixture continues to scrub.

## No Analog Found

| File | Role | Data Flow | Reason | Fallback |
|---|---|---|---|---|
| `app/middleware/size_limit.py` | middleware | request-body | First ASGI middleware in the repo. | Use Starlette's `BaseHTTPMiddleware` (transitive via FastAPI); 413 shape mirrors `app/main.py:39-47`. |
| `app/middleware/rate_limit.py` | middleware | request-response | First ASGI middleware in the repo. | Use Starlette's `BaseHTTPMiddleware`; 429 shape mirrors `app/api/routers/health.py:55-58`; store is an in-process dict with `asyncio.Lock`. |
| `app/api/security.py` auth helpers | middleware/dependencies | request-response | First use of `fastapi.security.HTTPBearer` in the repo. | Pattern is well-documented; mirror `app/api/deps.py:1-17` for module style. |

## Metadata

**Analog search scope:** `app/main.py`, `app/config/*`, `app/api/deps.py`,
`app/api/routers/*`, `app/processing/logging.py`, `tests/conftest.py`,
`tests/test_health.py`, `tests/test_plugins_router.py`, `tests/test_settings.py`,
`tests/test_incidents_api.py`, `tests/test_config_status_api.py`,
`tests/test_structured_logging.py`.

**Files scanned:** ~25 (every file in `app/api/routers/`, the entire `app/config/`
package, the entire `app/processing/` package's `logging.py`, the entire
`tests/` package).

**Pattern extraction date:** 2026-06-14

**Notes for the planner:**
- Every new dependency should `Annotated`-bind `Settings` via
  `Depends(get_app_settings)` — never call `get_settings()` inside a route or
  dependency.
- The `Unauthorized` exception in `app/api/security.py` is the *only* 401 shape
  allowed in the repo; do not duplicate it inside routers or middleware.
- The `tests/conftest.py` env scrub is `autouse=True`; new tests inherit it
  automatically, but the planner must add the new env keys to
  `_SETTINGS_ENV_KEYS` or they will leak across tests.
- `app/middleware/classification.py` is the single source of truth for the
  path → route-class map; both size and rate-limit middleware import it.
- The `ROUTE_CLASS_PREFIXES` list must be ordered longest-prefix-first so
  `/v1/icinga2/events` classifies as `ingress` rather than `operator`.
- For tests, the planner must reset the rate-limiter state between cases (per
  RESEARCH.md Pitfall 6) and add `pytest.raises(ValidationError)` cases to
  `tests/test_settings.py` for the new fail-fast validator.
