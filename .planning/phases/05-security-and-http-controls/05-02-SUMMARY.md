---
phase: 05-security-and-http-controls
plan: "02"
subsystem: api
tags:
  - fastapi
  - asgi-middleware
  - rate-limiting
  - request-size-limit
  - structured-logging

requires:
  - phase: 05-security-and-http-controls
    provides: Strict Pydantic security settings, route exposure wiring, and static Bearer auth route classes from Plan 01.

provides:
  - Single path-prefix route classifier shared by size and rate middleware.
  - ASGI request-body size cap returning deterministic 413 before route handlers.
  - In-process fixed-window route-class rate limiter returning 429 with Retry-After.
  - Token-hash-first, IP-fallback rate-limit identity with no raw token exposure.
  - Safe structured logging keys for control events without secrets or payloads.

affects:
  - 05-security-and-http-controls (already complete)
  - Future compatibility phases that extend protected operator APIs

tech-stack:
  added: []
  patterns:
    - ASGI middleware for cross-cutting HTTP controls before FastAPI routing.
    - Fixed-window per-route-class in-process rate limiting keyed by hashed identity.
    - Token-hash-first identity with IP fallback for unauthenticated requests.
    - Safe structured logging using an explicit allowlist for control events.

key-files:
  created:
    - app/middleware/__init__.py
    - app/middleware/classification.py
    - app/middleware/size_limit.py
    - app/middleware/rate_limit.py
    - tests/test_size_limit.py
    - tests/test_rate_limit.py
  modified:
    - app/main.py
    - app/processing/logging.py
    - tests/test_structured_logging.py

key-decisions:
  - "Installed RequestSizeLimiterMiddleware outermost so oversized requests are rejected before the rate limiter counts them."
  - "Used SHA-256 hashed Bearer token as the primary rate-limit identity and remote IP as fallback; raw tokens never enter limiter keys or logs."
  - "Extended SAFE_LOG_KEYS with route_class, identity_hash, content_length, retry_after, limit, and window_seconds for safe control-event logging."

patterns-established:
  - "Route classification is a single longest-prefix-first mapping consumed by both size and rate middleware."
  - "Per-route-class configuration is derived from Settings via dedicated helpers in app.main."
  - "Control events log only bounded safe fields; raw headers, tokens, and bodies are excluded by the allowlist."

requirements-completed:
  - SEC-04
  - SEC-05

# Metrics
duration: 15min
completed: 2026-06-17
status: complete
---

# Phase 5 Plan 2: Security and HTTP Controls Middleware Summary

**Request-size limiting and in-process route-class rate limiting with safe structured logging, wired into the app factory and tested for 413, 429/Retry-After, token/IP identity, and log safety.**

## Performance

- **Duration:** 15 min
- **Started:** 2026-06-17T08:50:54Z
- **Completed:** 2026-06-17T09:04:11Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments

- Created `app/middleware/classification.py` with `RouteClass`, `ROUTE_CLASS_PREFIXES`, and `classify_path`, mapping every current `/v1` route and defaulting unknown `/v1` paths to `operator`.
- Created `app/middleware/size_limit.py` with `RequestSizeLimiterMiddleware`, a pure ASGI middleware that rejects Content-Length and chunked bodies over per-route-class caps with `413 {"detail":"request body too large"}` before route handlers run, and replays under-cap bodies to downstream parsing.
- Created `app/middleware/rate_limit.py` with frozen `RateLimitConfig`, `InProcessRateLimiter`, `identity_for_request`, and `RateLimiterMiddleware`, returning `429 {"detail":"rate limit exceeded"}` with `Retry-After` when the fixed window is exceeded.
- Wired both middlewares into `create_app` with helpers `_body_size_limits_from_settings` and `_rate_limit_configs_from_settings`; size limiter is outermost so oversized requests do not consume rate-limit budget.
- Extended `app.processing.logging.SAFE_LOG_KEYS` with `route_class`, `identity_hash`, `content_length`, `retry_after`, `limit`, and `window_seconds` and added safe structured logging to both middlewares.
- Added `tests/test_size_limit.py` and `tests/test_rate_limit.py` covering classification, Content-Length 413, chunked 413, under-cap replay, default-cap fallback, 429/Retry-After, token/IP identity, per-class independence, disabled limits, and budget isolation.
- Extended `tests/test_structured_logging.py` to prove rate-limit and size-limit logs never contain raw tokens, Authorization headers, or request bodies.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add route classification and request-size middleware** - `e3dc9d3` (feat)
2. **Task 2: Add in-process route-class rate limiting and safe control logs** - `81b3af7` (feat)

## Files Created/Modified

- `app/middleware/__init__.py` - Package marker.
- `app/middleware/classification.py` - Route class mapping consumed by size and rate middleware.
- `app/middleware/size_limit.py` - ASGI request-body size cap with safe logging.
- `app/middleware/rate_limit.py` - In-process fixed-window rate limiter, identity helper, and middleware.
- `app/main.py` - Wired both middlewares and added settings-to-config helpers.
- `app/processing/logging.py` - Extended `SAFE_LOG_KEYS` with control-event fields.
- `tests/test_size_limit.py` - SEC-04 body-size rejection coverage.
- `tests/test_rate_limit.py` - SEC-05 rate-limit, identity, and Retry-After coverage.
- `tests/test_structured_logging.py` - Added control-event log-safety tests.

## Decisions Made

- Followed the plan's D-11 through D-18 decisions: conservative enabled defaults, token-first identity, chunked-aware size limits, deterministic 413/429 responses, and safe logging.
- Kept the size limiter outermost so abusive oversized payloads are stopped before they reach the rate limiter or route handlers.
- Hashed Bearer tokens with SHA-256 for rate-limit identity; stored keys use a non-secret `token_hash:` or `ip:` prefix so raw tokens are never in counters or logs.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

Security/size/rate settings are driven by environment variables already defined in Plan 01:

- `CORRELIA_MAX_BODY_BYTES` - default 1 MiB
- `CORRELIA_MAX_BODY_BYTES_OPERATOR` / `_INGRESS` / `_METRICS` / `_READYZ` / `_HEALTH` - optional overrides
- `CORRELIA_RATE_LIMIT_ENABLED` - default `true`
- `CORRELIA_RATE_LIMIT_REQUESTS_OPERATOR` / `_INGRESS` / `_METRICS` / `_READYZ` / `_HEALTH` - per-class request caps
- `CORRELIA_RATE_LIMIT_WINDOW_SECONDS_*` - per-class window durations

## Next Phase Readiness

- SEC-04 and SEC-05 are complete; Phase 5 is fully implemented and ready for phase verification.
- Route classification and middleware helpers are reusable for future compatibility APIs.

## Self-Check: PASSED

- [x] Key created files exist: `app/middleware/classification.py`, `app/middleware/size_limit.py`, `app/middleware/rate_limit.py`, `tests/test_size_limit.py`, `tests/test_rate_limit.py`
- [x] Commits exist: `e3dc9d3`, `81b3af7`
- [x] Targeted automated checks pass:
  - `uv run pytest tests/test_size_limit.py tests/test_ingress_router.py -q` → 49 passed
  - `uv run pytest tests/test_rate_limit.py tests/test_structured_logging.py tests/test_security.py -q` → 27 passed

---
*Phase: 05-security-and-http-controls*
*Completed: 2026-06-17*
