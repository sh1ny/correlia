# Phase 5: Security and HTTP Controls - Context

**Gathered:** 2026-06-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 5 adds production-safe HTTP perimeter controls before compatibility APIs expand: static Bearer authentication, configurable public health/readiness/metrics exposure, request body size limits, and route rate limiting. It does not add compatibility incident mutations, audit tables, config migration, deployment packaging, or plugin-boundary hardening; those belong to later v1.1 phases.

</domain>

<decisions>
## Implementation Decisions

### Protected Route Boundary
- **D-01:** `/v1/health` remains public by default and is never part of the protected operator surface.
- **D-02:** `/v1/readyz` is public by default, but its exposure must be configurable with a named setting because it reports dependency status.
- **D-03:** Existing `/v1` operator/config surfaces are protected by default when auth is enabled: `/v1/incidents`, `/v1/rules`, `/v1/topology`, and `/v1/plugins`.
- **D-04:** `/v1/metrics` is not hard-protected by default; metrics exposure must be configurable with a named setting.
- **D-05:** `/v1/icinga2/events` uses a separate ingress Bearer token from operator API clients. Do not reuse the operator token for sender traffic.
- **D-06:** Public exposure is configured through named exposure flags, not an arbitrary path allowlist.

### Unauthorized Response Contract
- **D-07:** Missing and invalid tokens return the same deterministic response: HTTP `401` with compact JSON body `{"detail":"unauthorized"}`.
- **D-08:** Unauthorized responses include `WWW-Authenticate: Bearer`.
- **D-09:** If a protected route class is enabled but its required token environment variable is missing, Correlia fails startup. Do not add a local/development bypass.
- **D-10:** Operator-token, ingress-token, and optionally protected metrics failures use the same unauthorized response shape. Do not reveal which token class failed.

### Rate-Limit Policy
- **D-11:** Rate limiting applies to all protected routes by default.
- **D-12:** Rate-limit identity is token first, then remote IP for unauthenticated requests.
- **D-13:** Ship conservative enabled defaults, configurable per named route class.
- **D-14:** Over-limit callers receive HTTP `429` with compact JSON body `{"detail":"rate limit exceeded"}` and a `Retry-After` header when computable.

### Request-Size Policy
- **D-15:** Default maximum request body size is 1 MiB.
- **D-16:** Size configuration uses one global default plus named route-class overrides.
- **D-17:** Oversized requests receive HTTP `413` with compact JSON body `{"detail":"request body too large"}`.
- **D-18:** Bodies without `Content-Length` and chunked uploads are counted while read. They must fail before route handler logic once the configured cap is exceeded.

### Claude's Discretion
- Choose the simplest in-process implementation consistent with the current single-worker runtime. Do not introduce Redis, Celery, external rate-limit services, or distributed counters in this phase.
- Choose exact conservative default numeric request-per-window values during planning, unless a later requirement gives concrete values. Preserve configurability per named route class.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase Scope and Locked Requirements
- `.planning/ROADMAP.md` — Phase 5 goal, success criteria, and dependency on Phase 4.
- `.planning/REQUIREMENTS.md` — SEC-01 through SEC-05 and out-of-scope compatibility constraints.
- `.planning/PROJECT.md` — project architecture, API-first boundary, strict validation posture, and v1.1 compatibility goal.
- `.planning/STATE.md` — current milestone position and locked v1.1 roadmap decisions.

### Compatibility Target
- `compatibility research (removed for privacy)` lines 94-112 — original auth/rate-limit/request-size target. User decisions in this CONTEXT.md refine that target: ingress gets a separate token, `/v1/readyz` is public by default but configurable, `/v1/metrics` exposure is configurable, and public paths use named exposure flags.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `app.config.settings.Settings` — strict Pydantic settings with `CORRELIA_` env prefix; add auth, route exposure, size, and rate-limit settings here so invalid config fails early.
- `app.main.create_app` — central app factory and router inclusion point; best place to install middleware/dependencies once for tests and production.
- `app.api.deps.get_app_settings` — existing request-state dependency for reading settings in route handlers and reusable auth helpers.
- `app.processing.logging.safe_log_extra` — existing safe logging helper; use it for auth/rate-limit/size-limit logs without leaking tokens or payloads.

### Established Patterns
- FastAPI routers live under canonical `/v1` paths; the project intentionally removed legacy unversioned health/config paths.
- Current tests use `httpx.ASGITransport` with `create_app(...)` injection, so Phase 5 tests can exercise middleware without running Uvicorn.
- Existing error responses are compact FastAPI-style JSON (`detail` fields). Keep auth/rate/size failures in that style.
- Startup/config posture is fail-fast: bad security config should reject startup rather than silently weakening protection.

### Integration Points
- `app/main.py` currently includes routers for health, ingress, plugins, config status, incidents, and metrics; auth/rate/size middleware must classify these routes consistently.
- `app/api/routers/health.py` defines `/v1/health` and `/v1/readyz`; preserve `/v1/health` public behavior and make `/v1/readyz` exposure configurable.
- `app/api/routers/ingress.py` defines `/v1/icinga2/events`; protect it with the separate ingress token.
- `app/api/routers/incidents.py`, `app/api/routers/config_status.py`, and `app/api/routers/plugins.py` are protected operator surfaces.
- `pyproject.toml` has no rate-limit dependency today. Planning should decide whether a tiny in-repo limiter is sufficient for the single-worker default before adding a dependency.

</code_context>

<specifics>
## Specific Ideas

- Keep responses terse and deterministic: `401 {"detail":"unauthorized"}`, `429 {"detail":"rate limit exceeded"}`, and `413 {"detail":"request body too large"}`.
- Use named route classes/exposure flags rather than arbitrary path patterns to avoid route typo misconfiguration.
- Separate operator and ingress credentials so sender-side rotation does not affect operator clients.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 5-Security and HTTP Controls*
*Context gathered: 2026-06-14*
