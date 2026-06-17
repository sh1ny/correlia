---
phase: 05-security-and-http-controls
verified: 2026-06-17T09:19:17Z
status: passed
score: 10/10 must-haves verified
behavior_unverified: 0
overrides_applied: 0
re_verification:
  previous_status: null
  previous_score: null
  gaps_closed: []
  gaps_remaining: []
  regressions: []
---

# Phase 5: Security and HTTP Controls Verification Report

**Phase Goal:** Operator-facing Correlia routes have production-safe authentication and HTTP abuse controls before additional compatibility workflows are exposed.

**Verified:** 2026-06-17T09:19:17Z

**Status:** passed

**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #   | Truth   | Status     | Evidence       |
| --- | ------- | ---------- | -------------- |
| 1   | SEC-01/D-03: `/v1/incidents`, `/v1/rules`, `/v1/topology`, and `/v1/plugins` require the configured operator Bearer token when auth is enabled. | ✓ VERIFIED | `app/api/routers/incidents.py`, `app/api/routers/config_status.py`, and `app/api/routers/plugins.py` declare `dependencies=[Security(require_operator_token)]`; `tests/test_security.py` proves operator routes reject missing/invalid/ingress tokens and accept the operator token. |
| 2   | SEC-01/D-05: `/v1/icinga2/events` requires the configured ingress Bearer token and never accepts the operator token as a substitute. | ✓ VERIFIED | `app/api/routers/ingress.py` declares `dependencies=[Security(require_ingress_token)]`; `tests/test_security.py::test_ingress_route_rejects_operator_token` and related tests prove token-class separation. |
| 3   | SEC-02/D-07/D-08/D-10: missing, invalid, and wrong-class tokens all return status 401, body `{"detail":"unauthorized"}`, and `WWW-Authenticate: Bearer` without revealing token class. | ✓ VERIFIED | `app/api/security.py` defines `Unauthorized` with the exact status, body, and header; `tests/test_security.py` covers each failure mode and asserts the shared response shape. |
| 4   | SEC-02/D-09: auth-enabled settings fail during `Settings` construction when required tokens are absent or empty, including local and test environments. | ✓ VERIFIED | `app/config/settings.py` `model_validator` `_require_security_tokens_when_enabled` raises `ValueError` when tokens are missing or blank; `tests/test_settings.py::test_auth_enabled_requires_both_tokens`, `test_auth_enabled_requires_non_empty_tokens`, and `test_token_validation_has_no_environment_bypass` pass for `local`, `test`, and `production`. |
| 5   | SEC-03/D-01/D-02/D-04/D-06: `/v1/health` stays public, `/v1/readyz` is public by default but protectable by `expose_readyz`, and `/v1/metrics` is public by default but protectable by `expose_metrics`. | ✓ VERIFIED | `app/api/routers/health.py` registers `/health` without auth and only protects `/readyz` when `protect_readyz=True`; `app/api/routers/metrics.py` conditionally appends the operator dependency; `app/main.py` computes protection from `expose_*` settings; `tests/test_exposure_config.py` covers all flag combinations. |
| 6   | SEC-04/D-15/D-16/D-17: requests with `Content-Length` greater than the configured route-class body cap return status 413 and body `{"detail":"request body too large"}` before route handlers run. | ✓ VERIFIED | `app/middleware/size_limit.py` fast-rejects when `int(content_length) > limit` and sends the 413 response without calling `self.app`; `tests/test_size_limit.py::test_oversized_content_length_returns_413_and_skips_handler` proves the handler/processor are not invoked. |
| 7   | SEC-04/D-18: requests without `Content-Length` and chunked uploads are counted while read and return 413 before route handler logic once the cap is exceeded. | ✓ VERIFIED | `app/middleware/size_limit.py` accumulates body chunks and drains any remaining stream before sending 413; `tests/test_size_limit.py::test_chunked_body_over_cap_returns_413_and_skips_handler` proves streaming over-cap rejection. |
| 8   | SEC-05/D-11/D-13: rate limiting is enabled by conservative defaults for protected route classes and configurable per named route class. | ✓ VERIFIED | `app/config/settings.py` defines per-route-class request/window fields with conservative defaults; `app/main.py` maps them to `RateLimitConfig` instances; `tests/test_rate_limit.py::test_rate_limit_per_class_configs_are_independent` verifies independent class behavior. |
| 9   | SEC-05/D-12: rate-limit identity uses the Bearer token hash first and remote IP when no token is present. | ✓ VERIFIED | `app/middleware/rate_limit.py::identity_for_request` hashes `Authorization: Bearer <token>` with SHA-256, falls back to `scope["client"][0]`, then `unknown`; `tests/test_rate_limit.py` tests all three identity paths. |
| 10  | SEC-05/D-14: over-limit callers receive status 429, body `{"detail":"rate limit exceeded"}`, and `Retry-After` when the fixed window can compute it. | ✓ VERIFIED | `app/middleware/rate_limit.py::RateLimiterMiddleware` returns `JSONResponse(status_code=429, content={"detail":_DETAIL}, headers={"Retry-After":...})`; `tests/test_rate_limit.py::test_rate_limit_rejects_over_limit_with_429_and_retry_after` asserts the header is a positive integer. |

**Score:** 10/10 truths verified (0 present, behavior-unverified)

### Required Artifacts

| Artifact | Expected | Status | Details |
| -------- | -------- | ------ | ------- |
| `app/config/settings.py` | Typed security, exposure, body-size, and rate-limit settings with fail-fast token validation. | ✓ VERIFIED | All Phase 5 fields present; validator `_require_security_tokens_when_enabled` enforces non-empty operator and ingress tokens when `api_auth_enabled=True`; no environment bypass. |
| `app/api/security.py` | Shared static Bearer auth helpers and deterministic unauthorized response. | ✓ VERIFIED | Exports `Unauthorized`, `require_operator_token`, `require_ingress_token`, `bearer_identity_hash`; uses `HTTPBearer(auto_error=False)`, `SecretStr.get_secret_value()`, and `secrets.compare_digest`. |
| `app/api/routers/health.py` | Router factory keeping `/v1/health` public and conditionally protecting `/v1/readyz`. | ✓ VERIFIED | `build_router(protect_readyz=...)` applies auth dependency only to `/readyz`. |
| `app/api/routers/metrics.py` | Router factory conditionally protecting `/v1/metrics`. | ✓ VERIFIED | `build_router(protect_metrics=...)` appends operator-token dependency when configured. |
| `app/api/routers/ingress.py` | Ingress route protected by ingress token. | ✓ VERIFIED | `dependencies=[Security(require_ingress_token)]`. |
| `app/api/routers/incidents.py` | Operator incident routes protected by operator token. | ✓ VERIFIED | `dependencies=[Security(require_operator_token)]`. |
| `app/api/routers/config_status.py` | Operator config/routes protected by operator token. | ✓ VERIFIED | `dependencies=[Security(require_operator_token)]`. |
| `app/api/routers/plugins.py` | Operator plugin route protected by operator token. | ✓ VERIFIED | `dependencies=[Security(require_operator_token)]`. |
| `app/middleware/classification.py` | Single path-prefix to route-class mapping. | ✓ VERIFIED | `RouteClass` literal, `ROUTE_CLASS_PREFIXES`, and `classify_path` default unknown `/v1` paths to `operator`. |
| `app/middleware/size_limit.py` | ASGI request body cap enforcement before route handlers. | ✓ VERIFIED | `RequestSizeLimiterMiddleware` handles `Content-Length` fast rejection and chunked counting with body replay for under-cap requests. |
| `app/middleware/rate_limit.py` | In-process fixed-window route-class rate limiting. | ✓ VERIFIED | `RateLimitConfig`, `InProcessRateLimiter`, `identity_for_request`, and `RateLimiterMiddleware` produce 429 + `Retry-After` with hashed-token/IP identity. |
| `app/main.py` | Middleware wiring and settings-to-middleware config helpers. | ✓ VERIFIED | `create_app` installs `RequestSizeLimiterMiddleware` outermost, then `RateLimiterMiddleware`, and includes conditional health/metrics routers. |
| `app/processing/logging.py` | Safe structured logging keys for control events. | ✓ VERIFIED | `SAFE_LOG_KEYS` extended with `route_class`, `identity_hash`, `content_length`, `retry_after`, `limit`, `window_seconds`; no raw tokens/payloads logged. |
| `tests/test_settings.py` | Settings fail-fast coverage. | ✓ VERIFIED | 20 passed. |
| `tests/test_security.py` | SEC-01/SEC-02 auth behavior coverage. | ✓ VERIFIED | Covers valid/missing/invalid/wrong-class tokens and auth-disabled behavior. |
| `tests/test_exposure_config.py` | SEC-03 named exposure flag coverage. | ✓ VERIFIED | Covers public/protected readyz/metrics and health isolation. |
| `tests/test_size_limit.py` | SEC-04 body-size rejection coverage. | ✓ VERIFIED | Covers classification, Content-Length, chunked, replay, default cap, and class overrides. |
| `tests/test_rate_limit.py` | SEC-05 rate-limit coverage. | ✓ VERIFIED | Covers 429/Retry-After, token/IP identity, per-class independence, disabled limits, and budget isolation. |
| `tests/test_structured_logging.py` | Safe control-event log coverage. | ✓ VERIFIED | Proves rate-limit and size-limit logs omit raw tokens, Authorization headers, and request bodies. |

### Key Link Verification

| From | To  | Via | Status | Details |
| ---- | --- | --- | ------ | ------- |
| `app/main.py` | `app/config/settings.py` | `create_app` resolves `effective_settings` before building routers/middleware. | ✓ WIRED | `effective_settings = settings if settings is not None else getattr(app.state, "settings", get_settings())`. |
| `app/api/routers/incidents.py` | `app/api/security.py` | `Security(require_operator_token)` router dependency. | ✓ WIRED | Declared at router level. |
| `app/api/routers/config_status.py` | `app/api/security.py` | `Security(require_operator_token)` router dependency. | ✓ WIRED | Declared at router level. |
| `app/api/routers/plugins.py` | `app/api/security.py` | `Security(require_operator_token)` router dependency. | ✓ WIRED | Declared at router level. |
| `app/api/routers/ingress.py` | `app/api/security.py` | `Security(require_ingress_token)` router dependency. | ✓ WIRED | Declared at router level. |
| `app/main.py` | `app/api/routers/health.py` | `build_health_router(protect_readyz=...)` included before other routers. | ✓ WIRED | Called with computed flag. |
| `app/main.py` | `app/api/routers/metrics.py` | `build_metrics_router(protect_metrics=...)` included. | ✓ WIRED | Called with computed flag. |
| `app/main.py` | `app/middleware/size_limit.py` | `app.add_middleware(RequestSizeLimiterMiddleware, ...)` after rate limiter so it wraps the app outermost. | ✓ WIRED | Installed after `RateLimiterMiddleware`; FastAPI insertion makes size limiter outermost. |
| `app/main.py` | `app/middleware/rate_limit.py` | `app.add_middleware(RateLimiterMiddleware, limiter=InProcessRateLimiter(), configs=...)` before size limiter. | ✓ WIRED | Installed first; runs inside size limiter. |
| `app/middleware/size_limit.py` | `app/middleware/classification.py` | `classify_path(scope.get("path", ""))` selects body-size override. | ✓ WIRED | Called in `__call__`. |
| `app/middleware/rate_limit.py` | `app/middleware/classification.py` | `classify_path(request.url.path)` selects fixed-window config. | ✓ WIRED | Called in `dispatch`. |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
| -------- | ------------- | ------ | ------------------ | ------ |
| `RequestSizeLimiterMiddleware` | `content_length`, body chunks | HTTP `scope`/`receive` | Yes — reads actual Content-Length header and stream chunks; no hardcoded fallback. | ✓ FLOWING |
| `RateLimiterMiddleware` | `identity_type`, `identity_value` | `Authorization` header or `scope["client"]` | Yes — derives identity from request; hashed token stored in in-memory counter. | ✓ FLOWING |
| `build_health_router` | `protect_readyz` | `Settings.expose_readyz` and `Settings.api_auth_enabled` | Yes — computed from effective settings. | ✓ FLOWING |
| `build_metrics_router` | `protect_metrics` | `Settings.expose_metrics` and `Settings.api_auth_enabled` | Yes — computed from effective settings. | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
| -------- | ------- | ------ | ------ |
| Phase 5 settings, auth, exposure, size-limit, rate-limit, and structured-log tests pass | `uv run pytest tests/test_settings.py tests/test_security.py tests/test_exposure_config.py tests/test_size_limit.py tests/test_rate_limit.py tests/test_structured_logging.py tests/test_health.py tests/test_metrics_api.py tests/test_ingress_router.py tests/test_incidents_api.py tests/test_config_status_api.py tests/test_plugins_router.py -q` | 129 passed in 7.89s | ✓ PASS |

### Probe Execution

No phase-declared or conventional probes were required. Targeted pytest coverage serves as the executable evidence.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
| ----------- | ---------- | ----------- | ------ | -------- |
| SEC-01 | 05-01 | Operator API clients can authenticate protected Correlia routes with a static Bearer token configured by environment. | ✓ SATISFIED | Separate operator/ingress `SecretStr` tokens; operator routers enforce operator token; ingress route enforces ingress token. |
| SEC-02 | 05-01 | Unauthenticated callers receive a deterministic unauthorized response on protected routes without any development-mode bypass. | ✓ SATISFIED | Shared `Unauthorized` 401 + `WWW-Authenticate: Bearer`; settings validator fails fast with no environment bypass; tests cover all environments. |
| SEC-03 | 05-01 | Maintainers can configure which health/readiness paths are public while keeping `/v1/health` public by default. | ✓ SATISFIED | `expose_readyz` and `expose_metrics` named flags; `/v1/health` always public; verified by `tests/test_exposure_config.py`. |
| SEC-04 | 05-02 | Correlia rejects oversized HTTP request bodies before route handlers process payloads. | ✓ SATISFIED | `RequestSizeLimiterMiddleware` returns 413 for Content-Length and chunked over-cap bodies before reaching route handlers. |
| SEC-05 | 05-02 | Correlia rate-limits configured API routes and returns a deterministic rate-limit response when the limit is exceeded. | ✓ SATISFIED | `RateLimiterMiddleware` with per-route-class fixed-window limits returns 429 + `Retry-After`; identity is hashed token or IP. |

### Anti-Patterns Found

No `TBD`, `FIXME`, `XXX`, `TODO`, `HACK`, `PLACEHOLDER`, stub return values, or console-log-only implementations were found in the Phase 5 modified source or test files.

### Human Verification Required

None. All Phase 5 must-haves are verified by automated checks and code inspection.

### Gaps Summary

No gaps identified. Phase 5 goal is achieved: protected routes enforce production-safe static Bearer auth with separated operator/ingress tokens, health/readiness exposure is configurable by named flags, oversized request bodies are rejected before route handlers, and route-class rate limiting returns deterministic 429 responses with `Retry-After`.

---

_Verified: 2026-06-17T09:19:17Z_
_Verifier: Claude (gsd-verifier)_
