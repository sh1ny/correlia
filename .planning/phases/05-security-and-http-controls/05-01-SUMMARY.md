---
phase: 05-security-and-http-controls
plan: "01"
subsystem: api

tags:
  - fastapi
  - bearer-auth
  - pydantic-settings
  - secretstr
  - route-exposure

requires:
  - phase: 04-lifecycle-operator-apis-and-operability
    provides: FastAPI app factory, operator routers, health/readiness/metrics routers

provides:
  - Strict Pydantic settings for auth, exposure, body-size caps, and rate limits
  - Static Bearer-token dependencies separating operator and ingress tokens
  - Deterministic 401 unauthorized response with WWW-Authenticate: Bearer
  - Conditional public/protected exposure for /v1/readyz and /v1/metrics
  - Test coverage proving no environment-based auth bypass

affects:
  - 05-security-and-http-controls (Plan 02 middleware)
  - Future compatibility phases that extend protected operator APIs

tech-stack:
  added: []
  patterns:
    - Router-level Security dependencies for static Bearer auth
    - Router factory functions for runtime-configurable exposure
    - Pydantic model_validator fail-fast for security-critical settings

key-files:
  created:
    - app/api/security.py
    - tests/test_security.py
    - tests/test_exposure_config.py
  modified:
    - app/config/settings.py
    - app/main.py
    - app/api/routers/health.py
    - app/api/routers/metrics.py
    - app/api/routers/ingress.py
    - app/api/routers/incidents.py
    - app/api/routers/config_status.py
    - app/api/routers/plugins.py
    - tests/conftest.py
    - tests/test_settings.py
    - tests/test_health.py
    - tests/test_ingress_router.py
    - tests/test_incidents_api.py
    - tests/test_config_status_api.py
    - tests/test_plugins_router.py
    - tests/test_metrics_api.py

key-decisions:
  - "Applied token dependency at the route level for /v1/readyz so /v1/health stays public even when readyz is protected."
  - "Used router-level Security(require_operator_token) for operator surfaces and Security(require_ingress_token) for /v1/icinga2/events."
  - "Kept auth disable as an explicit setting (api_auth_enabled) rather than an environment-specific bypass."

patterns-established:
  - "Shared Unauthorized exception: single 401 shape with WWW-Authenticate: Bearer, no token-class leakage."
  - "Settings fail-fast: auth enabled requires non-empty operator_api_token and ingress_api_token in every environment."
  - "Named exposure flags: expose_readyz and expose_metrics replace path allowlists."

requirements-completed:
  - SEC-01
  - SEC-02
  - SEC-03

duration: 19min
completed: 2026-06-17
status: complete
---

# Phase 5 Plan 1: Security and HTTP Controls Foundation Summary

**Static Bearer auth with separated operator/ingress tokens, fail-fast Pydantic settings, and named public/protected route exposure for /v1/readyz and /v1/metrics.**

## Performance

- **Duration:** 19 min
- **Started:** 2026-06-17T08:08:32Z
- **Completed:** 2026-06-17T08:27:34Z
- **Tasks:** 2
- **Files modified:** 18

## Accomplishments
- Added strict security, exposure, body-size, and rate-limit settings to `Settings` with a fail-fast validator requiring both operator and ingress tokens when auth is enabled.
- Created `app/api/security.py` with shared `Unauthorized` response and separate `require_operator_token` / `require_ingress_token` dependencies using `secrets.compare_digest` and `SecretStr`.
- Protected operator routers (`/v1/incidents`, `/v1/rules`, `/v1/topology`, `/v1/plugins`) with the operator token and `/v1/icinga2/events` with the ingress token.
- Made `/v1/health` always public and `/v1/readyz` / `/v1/metrics` conditionally public via `expose_readyz` / `expose_metrics` settings.
- Added targeted tests for auth behavior and exposure configuration, and updated existing route tests to remain compatible with auth enabled by default.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add strict security and HTTP-control settings** - `21ec22a` (feat)
2. **Task 2: Add static Bearer auth and configurable exposure wiring** - `6cf0021` (feat)

**Plan metadata:** pending

## Files Created/Modified
- `app/config/settings.py` - Added auth, exposure, size, and rate-limit settings with fail-fast validator.
- `app/api/security.py` - Shared Bearer auth dependencies and `Unauthorized` response shape.
- `app/main.py` - Resolves effective settings and builds conditional health/metrics routers.
- `app/api/routers/health.py` - Router factory keeping `/v1/health` public and protecting `/v1/readyz` when configured.
- `app/api/routers/metrics.py` - Router factory conditionally protecting `/v1/metrics`.
- `app/api/routers/ingress.py` - Protected with ingress token.
- `app/api/routers/incidents.py` - Protected with operator token.
- `app/api/routers/config_status.py` - Protected with operator token.
- `app/api/routers/plugins.py` - Protected with operator token.
- `tests/conftest.py` - Extended `_SETTINGS_ENV_KEYS` to cover new settings.
- `tests/test_settings.py` - Added Phase 5 validator and default tests.
- `tests/test_security.py` - New auth behavior tests for operator and ingress routes.
- `tests/test_exposure_config.py` - New named exposure flag tests.
- Existing route tests updated to provide tokens or disable auth via explicit fixtures.

## Decisions Made
- Followed the plan's D-01 through D-10 decisions: `/v1/health` stays public, `/v1/readyz` and `/v1/metrics` use named flags, and token failures return a single deterministic 401 shape without revealing token class.
- Applied the operator-token dependency to `/v1/readyz` only (not the whole health router) so `/v1/health` remains public even when readyz is protected.
- Disabled auth explicitly in non-auth route tests via `CORRELIA_API_AUTH_ENABLED=false` monkeypatch rather than using environment names as a bypass.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- Initial `main.py` edit accidentally dropped the `config_status_router` import; restored before committing.
- Existing route tests instantiated `Settings` without tokens after auth became enabled by default; resolved by updating helpers or adding per-file autouse fixtures that explicitly disable auth.
- Alembic migration subprocesses invoked by integration tests also required auth-disabled env because `get_settings()` is called in `migrations/env.py`; added `CORRELIA_API_AUTH_ENABLED=false` to the subprocess environment.

## User Setup Required

None - no external service configuration required.

Security settings are driven by environment variables:
- `CORRELIA_OPERATOR_API_TOKEN` - required when `CORRELIA_API_AUTH_ENABLED=true` (default)
- `CORRELIA_INGRESS_API_TOKEN` - required when `CORRELIA_API_AUTH_ENABLED=true` (default)
- `CORRELIA_EXPOSE_READYZ` - default `true`
- `CORRELIA_EXPOSE_METRICS` - default `true`

## Next Phase Readiness
- Ready for Plan 02 middleware work: size-limit and rate-limit settings are already defined in `Settings` and consumed from `app.main.create_app`.
- Auth and exposure wiring is stable; later v1.1 compatibility APIs can reuse `require_operator_token` and the named exposure pattern.

## Self-Check: PASSED

- [x] Key created files exist: `app/api/security.py`, `tests/test_security.py`, `tests/test_exposure_config.py`
- [x] Commits exist: `21ec22a`, `6cf0021`
- [x] Targeted automated checks pass:
  - `uv run pytest tests/test_settings.py -q` → 20 passed
  - `uv run pytest tests/test_security.py tests/test_exposure_config.py tests/test_health.py tests/test_metrics_api.py tests/test_ingress_router.py tests/test_incidents_api.py tests/test_config_status_api.py tests/test_plugins_router.py -q` → 79 passed

---
*Phase: 05-security-and-http-controls*
*Completed: 2026-06-17*
