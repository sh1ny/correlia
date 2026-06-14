# Stack & Deployment Research — Correlia v1.1 Vigilo/VDE Compatibility

## Summary

Correlia currently has a minimal runtime footprint: `uv`-managed Python 3.14 project, FastAPI application factory, in-memory task runner, and no Docker or auth/rate-limit middleware. VDE ships a full containerized deployment (Dockerfile, docker-compose.yml, Postgres + Mailhog), Slowapi-based per-route rate limiting, static Bearer auth with `DEV_MODE` bypass, and a request-size middleware.

The v1.1 compatibility task is **not** to become VDE. It is to preserve Correlia's stricter lifecycle, canonical `/v1` APIs, and settings model while adding the deployment and defensive HTTP surface required to run in Vigilo-shaped environments. Webhook endpoint compatibility remains explicitly excluded per `compatibility research (removed for privacy)`; sender-side adapters will handle path/payload differences.

---

## Evidence from current code

### Correlia (target)

| File | What it shows |
|------|----------------|
| `pyproject.toml` | `requires-python = ">=3.14"`; dependencies FastAPI, Pydantic Settings, SQLAlchemy, Alembic, asyncpg, uvicorn[standard], prometheus-client, aiosmtplib, PyYAML. Dev group has ruff, mypy, pytest, httpx, testcontainers, types-pyyaml. No slowapi, no python-multipart, no python-jose. |
| `uv.lock` | Locked against Python 3.14; resolution markers include `python_full_version >= '3.15'` and `< '3.15'`. |
| `Makefile` | `test` (`uv run pytest`), `lint` (`uv run ruff check .`), `typecheck` (`uv run mypy app`), `run` (`uv run uvicorn app.main:create_app --factory --reload`). No docker targets. |
| `app/main.py:52-166` | FastAPI factory `create_app`; lifespan bootstraps settings, DB engine/sessionmaker, plugin registry, rules/topology config, in-process `AsyncIOTaskRunner`, notification task, icinga2 processor, and `LifecycleWorker`. No auth, no rate limit, no request-size limit registered globally. |
| `app/api/routers/health.py:14-60` | `/v1/health` always returns `{"status":"ok"}`; `/v1/readyz` checks DB, settings, config, plugin registry, and lifecycle worker. |
| `app/api/routers/ingress.py:15-36` | `POST /v1/icinga2/events` unauthenticated. No rate limiting. |
| `app/api/routers/incidents.py:33` | `/v1/incidents` canonical router; ack/close are explicit `POST` sub-resources. |
| `app/config/settings.py:8-26` | `BaseSettings` with `env_prefix="CORRELIA_"`, `extra="forbid"`. Fields: `database_url`, `environment`, `log_level`, `rules_path`, `topology_path`, `plugins_path`, `lifecycle_scan_interval_seconds`, `lifecycle_batch_size`. No auth/rate-limit/body-limit settings. |
| `app/config/plugins.py:11-13` | Allowlist is output-only: `_ALLOWED_PLUGIN_TYPES = {"email"}`, `_ALLOWED_CLASS_PREFIX = "app.plugins.outputs."`. |
| `app/processing/task_runner.py:28-66` | `AsyncIOTaskRunner` keeps a `_tasks` set of `asyncio.Task`. Used for non-blocking notification dispatch. |
| `migrations/versions/0001_create_incidents.py` + `0002_add_threshold_state.py` | Postgres-only schema; JSONB columns; `alembic` managed. No `incident_events` audit table yet. |
| `migrations/env.py:17` | `target_metadata = Base.metadata` from `app.persistence.models`. Migrations are async via `async_engine_from_config`. |
| `app/persistence/database.py:12-13` | `create_async_engine(str(settings.database_url))` — no explicit pool size/timeouts. |

### VDE (reference)

| File | What it shows |
|------|----------------|
| `pyproject.toml` | `requires-python = ">=3.13"`; dependencies include `slowapi>=0.1.9`, `litellm>=1.86.0`, `fastapi>=0.128.0`, `uvicorn>=0.40.0`, `greenlet>=3.3.1`. No prometheus-client. No alembic. |
| `main.py:38-54` | FastAPI app registers `app.state.limiter = limiter` and `RateLimitExceeded` exception handler; adds `@app.middleware("http")` request-size limiter (413 when `content-length > 1 MB`). |
| `app/api/endpoints/ingress.py:24-32` | `APIRouter(prefix="/webhook")`; `POST /icinga2` is intentionally unauthenticated and uses `@limiter.limit("100/minute")` keyed by remote address. |
| `app/api/dependencies.py:24-80` | Static Bearer token auth via `HTTPBearer(auto_error=False)` and `hmac.compare_digest`. `DEV_MODE=true` bypasses auth. Random 1% Easter-egg 401 message. |
| `app/core/config.py:31-76` | `Settings` loads `.env`, validates `api_token` length >=32 unless `dev_mode`. Default DB URL points to `localhost`. |
| `Dockerfile` | Two-stage build using internal Broadcom registry base (`dockerhub.packages.vcfd.broadcom.net/python:3.13-slim`) and `ghcr.io/astral-sh/uv:latest`. Installs with `uv sync --frozen --no-dev --no-install-project`. Defaults `UVICORN_WORKERS=4`, exposes 8000, healthcheck hits `/health`. |
| `docker-compose.yml` | Postgres 16-alpine (`dockerhub.packages.vcfd.broadcom.net/postgres:16-alpine`), `vigilo` app service with `depends_on` health condition, `.env` file, `config/` volume read-only, Mailhog for SMTP capture. |
| `.env.example` | `APP_NAME`, `DEBUG`, `DEV_MODE`, `API_TOKEN`, `EMAIL_DRY_RUN`, `DATABASE_URL`, `RULES_CONFIG_PATH`, `TOPOLOGY_CONFIG_PATH`, `PLUGINS_CONFIG_PATH`. |
| `app/api/endpoints/incidents.py:28` | `/api/v1/incidents` router; PATCH mutates status/summary; DELETE soft-closes. |

---

## Best approach

### 1. Dependencies

Keep Correlia's existing dependency set lean. Add the smallest additions needed for the compatibility surface:

- `slowapi` — per-route rate limiting (matches VDE's decorator pattern, works with FastAPI `app.state.limiter` convention).
- `python-multipart` — only if adding form-based login or file upload endpoints (not required for v1.1); **do not add unless a concrete requirement appears**.
- No `litellm` in core dependencies. LLM enrichment/decision plugins should be optional plugin-level dependencies only, disabled by default, per `compatibility research (removed for privacy)` rules.
- Keep `prometheus-client`, `alembic`, `pydantic-settings`, `aiosmtplib`.
- Pin Python requirement at `>=3.14`; do not relax to `>=3.13` just because VDE supports it.

Likely touched:
- `pyproject.toml` — add `slowapi` to `dependencies`.
- `uv.lock` — regenerate via `uv lock`.

### 2. Authentication

Use FastAPI `HTTPBearer` for static Bearer-token auth, but **do not** copy VDE's `DEV_MODE` bypass or random Easter-egg message. Per `compatibility research (removed for privacy)`:

- Add `CORRELIA_API_TOKEN` (optional) and `CORRELIA_AUTH_PUBLIC_PATHS` (set) to `Settings`.
- If `api_token` is set, enforce it on protected routes via a dependency.
- If `api_token` is unset, protected routes return `401` with `WWW-Authenticate: Bearer`.
- Keep `/v1/health` public by default.
- Make `/v1/readyz` configurable: public when listed in `CORRELIA_AUTH_PUBLIC_PATHS`, otherwise requires token because it exposes dependency state.

Constant-time comparison should use `hmac.compare_digest`, matching VDE's safe pattern.

Likely touched:
- `app/config/settings.py` — add `api_token: str | None = None`, `auth_public_paths: set[str] = Field(default_factory=set)`.
- `app/api/deps.py` — add `get_current_user` / `require_auth` dependency.
- `app/api/routers/*.py` — apply auth dependency to `/v1/incidents`, `/v1/rules`, `/v1/topology`, `/v1/plugins`, `/v1/metrics` as specified in `compatibility research (removed for privacy)`.
- `tests/*` — add `Authorization` headers where needed.

### 3. Rate limiting & request size

Add a global request-body size limit as Starlette middleware and per-route rate limits using Slowapi:

- Middleware order matters: request-size limit should run **before** auth/rate-limit to avoid parsing large bodies. Starlette executes middleware in registration order (https://www.starlette.io/middleware/#middleware-order).
- Use `CORRELIA_API_MAX_BODY_BYTES` (default 1 MiB, matching VDE).
- Use `CORRELIA_API_RATE_LIMIT_REQUESTS` and `CORRELIA_API_RATE_LIMIT_WINDOW_SECONDS`.
- Register `Limiter(key_func=get_remote_address)` on `app.state.limiter` and add `RateLimitExceeded` exception handler, same as VDE.
- Apply `@limiter.limit(...)` selectively: webhook/ingress routes are the most abuse-prone and should be limited even if they remain public.

Likely touched:
- `app/main.py` — register middleware, exception handler, and `app.state.limiter`.
- `app/config/settings.py` — add rate-limit/body-limit fields.
- `app/api/routers/ingress.py` — add limiter decorator.
- Add tests for 413 and 429 behavior.

### 4. Docker / Compose packaging

Provide a multi-stage Dockerfile and `docker-compose.yml` that mirror VDE's shape but use Correlia's conventions:

- Use `python:3.14-slim` (or `ghcr.io/astral-sh/uv:python3.14-slim`) in builder/runtime stages. Do **not** hard-code Broadcom's internal registry.
- Install with `uv sync --frozen --no-dev --no-install-project`, then copy code and run `uv sync --frozen --no-dev` (or equivalent) so the project itself is installed.
- Default `UVICORN_WORKERS=1` because the in-process `AsyncIOTaskRunner` and `LifecycleWorker` are not multi-worker safe today. VDE defaults to 4; that is unsafe for Correlia without a distributed queue/leader election.
- Expose `8000`; healthcheck against `/v1/health` (canonical path), not `/health`.
- `docker-compose.yml` should include Postgres 16+, Correlia app, and an SMTP capture service (Mailhog or equivalent).
- Mount `config/` read-only and supply `.env`.
- Include an `alembic upgrade head` step before startup, or run migrations as an init container; Correlia uses Alembic, VDE does not.

Likely touched (new files):
- `Dockerfile`
- `docker-compose.yml`
- `.env.example`
- `config/rules.yaml`, `config/topology.yaml`, `config/plugins.yaml` (per `CONFIGURATION.md`)

### 5. Service runtime / Uvicorn

- Use `--factory` for `create_app` (Makefile already does: `uvicorn app.main:create_app --factory`). Dockerfile should do the same.
- For single-worker mode: `uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000`.
- Multi-worker mode (`--workers N` or Gunicorn) must be blocked behind a design decision because `AsyncIOTaskRunner` tasks and `LifecycleWorker` would duplicate across processes.
- Uvicorn's `--reload` must only be used in local development (Makefile `run` target), never in the Docker image default command.

### 6. Configuration files

`CONFIGURATION.md` already defines the required files and environment variables:

- `CORRELIA_RULES_PATH=config/rules.yaml`
- `CORRELIA_TOPOLOGY_PATH=config/topology.yaml`
- `CORRELIA_PLUGINS_PATH=config/plugins.yaml`
- `DATABASE_URL` remains required.

Add for v1.1:
- `CORRELIA_API_TOKEN`
- `CORRELIA_API_MAX_BODY_BYTES`
- `CORRELIA_API_RATE_LIMIT_REQUESTS`
- `CORRELIA_API_RATE_LIMIT_WINDOW_SECONDS`
- `CORRELIA_AUTH_PUBLIC_PATHS`

Likely touched:
- `app/config/settings.py`
- New `.env.example`
- New `config/*.yaml` examples

### 7. Local / CI gates

`compatibility research (removed for privacy)` mandates these gates run from the Correlia root:

- `uv lock --check`
- `make lint`
- `make typecheck`
- `make test`

Current Makefile already supports all four. Add Docker-specific targets only if needed for CI:

```makefile
.PHONY: docker-build docker-up docker-down
docker-build:
	docker build -t correlia:v1.1 .
docker-up:
	docker compose up --build -d
docker-down:
	docker compose down
```

Likely touched:
- `Makefile` — optional docker helpers.
- CI workflow (out of scope unless instructed).

### 8. Metrics / observability

Per `compatibility research (removed for privacy)`, add Prometheus counters only for new compatibility behavior:

- Compatibility API requests (if `/api/v1/incidents` facade is added later).
- Config migration failures.
- Incident event audit writes.
- Plugin dispatch results by plugin type.

Do **not** add host/service/incident ID labels.

### 9. Migrations / database

Correlia uses Alembic; VDE does not. Any schema additions (e.g., `incident_events` audit table from `compatibility research (removed for privacy)`) must be delivered as Alembic revisions, not raw SQL in docker-entrypoint.

Likely touched:
- `migrations/versions/0003_add_incident_events.py` (or similar).
- `app/persistence/models.py` — add `IncidentEvent` model.
- `alembic.ini` / `migrations/env.py` — likely unchanged, but verify the revision generates cleanly.

---

## Requirements implications

1. **Stricter core preserved**: Correlia keeps `extra="forbid"`, strict plugin allowlist, Pydantic validation, and explicit incident lifecycle. VDE's `DEV_MODE` bypass and warn-and-skip plugin loading are explicitly excluded.
2. **Webhook endpoint excluded**: no `/webhook/icinga2` route; sender side adapts to `/v1/icinga2/events`.
3. **Compatibility facade optional**: `/api/v1/incidents` only if external Vigilo clients require it. If added, it maps to canonical `/v1/incidents` internally.
4. **Auth is production-first**: no auth bypass switch. Local dev must set `CORRELIA_API_TOKEN` or accept 401s on protected routes; tests should inject the token.
5. **Single-worker default**: v1.1 does not promise horizontal scale-out of background workers.
6. **Config migration remains a script**: `scripts/migrate_vigilo_config.py` must fail on unsupported VDE fields and must not emit plaintext SMTP credentials.

---

## Roadmap implications

- **v1.1 immediate**: Dockerfile, compose, `.env.example`, sample `config/*.yaml`, auth dependency, rate-limit middleware, request-size middleware, settings additions, Makefile docker helpers.
- **v1.1-follow/optional**: Compatibility `/api/v1/incidents` facade, `incident_events` audit table + migration, `scripts/migrate_vigilo_config.py`, expanded plugin registry for input/enrichment/decision/task-runner adapters.
- **Post-v1.1**: Multi-worker safe task runner (external queue + leader election) before allowing `UVICORN_WORKERS > 1`.

---

## Risks

| Risk | Mitigation |
|------|------------|
| **Slowapi + FastAPI version mismatch** | Pin `slowapi` and verify the exception handler still works with the FastAPI version resolved by `uv` (currently 0.136.3). |
| **Middleware ordering breaks auth/rate-limit** | Register size-limit first, then auth, then rate-limit. Test each independently. |
| **Single-worker default appears underpowered vs VDE** | Document clearly; Correlia's correctness model requires it until task runner is distributed. |
| **Auth breaks existing tests** | Add a test fixture that sets a known token and injects `Authorization` header. |
| **Docker base image availability** | Avoid internal registries; use public `python:3.14-slim` and `ghcr.io/astral-sh/uv`. |
| **Alembic migrations in container startup** | Run `alembic upgrade head` in an entrypoint script that exits non-zero on failure; do not start Uvicorn on an unmigrated DB. |
| **VDE's `litellm` dependency not needed** | Do not add to core dependencies; keep LLM plugins optional. |
| **Prometheus label cardinality** | Avoid host/service/incident ID labels as required. |

---

## References

- FastAPI middleware ordering: https://fastapi.tiangolo.com/advanced/middleware/#technical-details
- Starlette middleware order: https://www.starlette.io/middleware/#middleware-order
- Uvicorn deployment & workers: https://www.uvicorn.org/deployment/
- Slowapi (rate limiting for FastAPI/Starlette): https://github.com/laurentS/slowapi
- Correlia source files listed above.
- VDE source files listed above.
- `compatibility research (removed for privacy)` and `CONFIGURATION.md` in Correlia root.
