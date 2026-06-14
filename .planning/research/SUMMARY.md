# Correlia v1.1 Vigilo/VDE Compatibility — Research Synthesis

**Scope:** API facade, event audit, auth/rate-limit/request-size surface, Docker packaging, and strict VDE-to-Correlia config migration required for Correlia to replace Vigilo/VDE clients without weakening Correlia's canonical incident lifecycle.

**Explicit exclusion:** Webhook endpoint compatibility. Sender-side systems adapt to Correlia's canonical `/v1/icinga2/events` ingress. No `/webhook/icinga2` route and no payload-shape compromise on the canonical path.

**Synthesis method:** The four research files agree on the additive-shell strategy but differ on scope timing. This summary resolves those differences conservatively: v1.1 ships the smallest surface that satisfies Vigilo-shaped clients while preserving Correlia's strict validation model; architecture seeds that are not safely implementable in v1.1 are documented as out-of-scope or follow-on rather than deferred silently.

---

## 1. Executive Recommendation

Build Vigilo/VDE compatibility as an **additive shell around Correlia**, not as a core rewrite:

- Keep `/v1/incidents` as the canonical API with cursor pagination, explicit `/ack` and `/close`, rich decision context, and Correlia lifecycle semantics.
- Add `/api/v1/incidents` only as a Vigilo-shaped facade that projects Correlia incidents into Vigilo response fields and maps Vigilo mutations onto Correlia audited lifecycle operations.
- Add an append-only `incident_events` table for traceability; it does not participate in aggregation decisions.
- Add static Bearer-token auth, Slowapi-based rate limiting, and a request-body size limit for the new production surface; do not copy VDE's `DEV_MODE` bypass.
- Provide a strict `scripts/migrate_vigilo_config.py` that fails loudly on unsupported VDE semantics and never emits plaintext SMTP credentials.
- Ship Docker + docker-compose packaging with a single-worker default and an Alembic migration step at startup.
- Do not add `litellm` or LLM dependencies to core; keep any LLM adapters as opt-in, disabled-by-default plugin-level work outside v1.1.

---

## 2. Stack/Deployment Additions

### Dependencies
- Add `slowapi` for per-route rate limiting; match VDE's `app.state.limiter` + `RateLimitExceeded` handler pattern.
- Do **not** add `python-multipart`, `python-jose`, or `litellm` to core dependencies.
- Keep `prometheus-client`, `alembic`, `pydantic-settings`, `aiosmtplib`.
- Pin Python requirement at `>=3.14`; do not relax to `>=3.13` just because VDE supports it.
- Likely touched: `pyproject.toml`, `uv.lock` (regenerate via `uv lock`).

### Authentication
- Add `CORRELIA_API_TOKEN` (optional) and `CORRELIA_AUTH_PUBLIC_PATHS` (set of strings) to `Settings`.
- If `api_token` is set, enforce it on protected routes via FastAPI `HTTPBearer` + `hmac.compare_digest`.
- If `api_token` is unset, protected routes return `401` with `WWW-Authenticate: Bearer`.
- Keep `/v1/health` public by default.
- Make `/v1/readyz` configurable: public only when listed in `CORRELIA_AUTH_PUBLIC_PATHS`; otherwise require a token because it exposes dependency state.
- **Do not add a `DEV_MODE` bypass.** Local development and tests must supply a token explicitly or accept `401` on protected routes.

### Rate Limiting & Request Size
- Add global request-body size limit as Starlette middleware (`CORRELIA_API_MAX_BODY_BYTES`, default 1 MiB).
- Add per-route rate limits via Slowapi (`CORRELIA_API_RATE_LIMIT_REQUESTS` + `CORRELIA_API_RATE_LIMIT_WINDOW_SECONDS`).
- Register middleware in order: size-limit first, then auth, then rate-limit.
- Apply `@limiter.limit(...)` on public/abuse-prone routes (e.g., ingress) and protected compatibility routes.
- Likely touched: `app/main.py`, `app/config/settings.py`, `app/api/routers/ingress.py`.

### Docker / Compose Packaging
- Multi-stage `Dockerfile` using public `python:3.14-slim` or `ghcr.io/astral-sh/uv:python3.14-slim`; do not hard-code internal registries.
- Install with `uv sync --frozen --no-dev --no-install-project`, copy code, then run `uv sync --frozen --no-dev`.
- Default `UVICORN_WORKERS=1` because the in-process `AsyncIOTaskRunner` and `LifecycleWorker` are not multi-worker safe today.
- Expose `8000`; healthcheck hits `/v1/health`.
- `docker-compose.yml` includes Postgres 16+, Correlia app with `depends_on` health condition, Mailhog or equivalent SMTP capture, read-only `config/` volume, and `.env`.
- Run `alembic upgrade head` before Uvicorn startup; fail fast if migrations do not succeed.
- Likely new files: `Dockerfile`, `docker-compose.yml`, `.env.example`, sample `config/rules.yaml`, `config/topology.yaml`, `config/plugins.yaml`.

### Makefile / Local Gates
- Keep existing `make lint`, `make typecheck`, `make test`, `make run`.
- Add optional Docker helpers (`docker-build`, `docker-up`, `docker-down`).
- CI gates from `VIGILO_COMPATIBILITY.md`: `uv lock --check`, `make lint`, `make typecheck`, `make test`.

### Settings Additions
- `api_token: str | None = None`
- `auth_public_paths: set[str]`
- `api_max_body_bytes: int = 1_048_576`
- `api_rate_limit_requests: int`
- `api_rate_limit_window_seconds: int`
- (Existing required: `database_url`, `rules_path`, `topology_path`, `plugins_path`)

---

## 3. Feature Table Stakes

### 3.1 Vigilo Incident API Facade (`/api/v1/incidents`)
- `GET /api/v1/incidents` accepts `status`, `severity`, `rule_name`, `limit`, `offset` and returns `{items, total, limit, offset}`.
- `GET /api/v1/incidents/{id}` returns Vigilo-shaped incident fields only (`id`, `rule_name`, `group_key`, `status`, `severity`, `start_time`, `last_update_time`, `summary`, `event_count`, `affected_hosts`).
- `PATCH /api/v1/incidents/{id}` supports `status=ACKNOWLEDGED` and `status=CLOSED` by calling Correlia lifecycle functions.
  - `ACKNOWLEDGED` records `operator="vigilo-compat"`.
  - `CLOSED` records a close reason derived from the Vigilo mutation.
- `PATCH` with `summary` returns `422` because Correlia has no audited summary mutation model.
- `DELETE /api/v1/incidents/{id}` soft-closes through Correlia close lifecycle and returns `{id, deleted}`.
- Implement in a new `app/api/routers/incidents_compat.py` with prefix `/api/v1/incidents`.
- Use local Pydantic request/response models so canonical domain models remain unchanged.
- Apply the same auth dependency as protected canonical routes.
- Emit compatibility API metrics with bounded labels: `method`, `endpoint`, `status`.
- **Do not** change `/v1/incidents` to offset pagination and do not expose Correlia-only fields in the Vigilo facade.

### 3.2 Event Audit Traceability (`incident_events`)
- Add `incident_events` table with columns: `id`, `incident_id`, `source_id`, `fingerprint`, `event_type`, `severity`, `host`, `service`, `payload`, `normalized_event`, `decision_summary`, `received_at`, `processed_at`.
- Add indexes on `fingerprint`, `(source_id, received_at desc)`, and `(incident_id, processed_at desc)`.
- Write one row per accepted normalized event inside the ingress processor, after normalization and decision context are known.
- If an event is accepted but does not create/update an incident, persist the row with `incident_id = null` and a decision summary explaining the no-op/rejection reason.
- The table is append-only and does not participate in aggregation decisions.

### 3.3 Auth Exposure for Compatibility Routes
- Protect `/api/v1/incidents` with the same static Bearer-token policy as protected canonical `/v1` routes.
- Keep `/v1/health` public.
- Make `/v1/readyz` configurable as described above.
- No `DEV_MODE` bypass and no randomized 401 behavior.

### 3.4 Operational Compatibility Features
- Metrics for compatibility API requests, incident event audit writes, config migration failures, plugin load results, and plugin dispatch results.
- Safe structured logs for compat mutations with bounded fields only; no raw payloads, credentials, or LLM prompts through `safe_log_extra`.
- Readiness remains canonical at `/v1/readyz`; the compat layer does not create a separate health model.
- Extend `SAFE_LOG_KEYS` to support v1.1 events: `plugin_type`, `adapter`, `migration_status`, `unsupported_field`, `audit_event_id`, etc.

---

## 4. Config/Plugin Architecture Decisions

### 4.1 Config Migration Command (`scripts/migrate_vigilo_config.py`)
- Inputs: `--rules`, `--topology`, `--plugins`, `--out-dir`; optional `--smtp-username-env`, `--smtp-password-env`.
- Outputs: `rules.yaml`, `topology.yaml`, `plugins.yaml`, `.env.example` (placeholders only, no secrets).
- Validate output by reusing Correlia loaders (`load_plugin_registry_config`, `load_rules_config`, `load_topology_config`).
- **Fail fast** on unsupported VDE semantics rather than silently dropping them.
- Never copy plaintext `smtp_username` / `smtp_password` into generated YAML; emit env-var references or omit with instructions.

### 4.2 VDE → Correlia Mappings
- **Rules:**
  - `match.severity` → `match.severities` (non-empty list; fail if missing).
  - `match.host` → `host_pattern` (fnmatch `*` → `.*`, `?` → `.`; fail on complex patterns).
  - `match.service` → `service_pattern` (optional).
  - `match.tags` keys → prefix with `topology.` if bare; values must be literal (fail on `*`, `?`, `[`, `]`).
  - `actions[]` string → object `{name: "create_incident", plugin: <plugin_name>}`.
  - `output_summary` → rewrite `{datacenter}` → `{topology.datacenter}`; validate placeholders.
- **Topology:**
  - `hostname_patterns[].regex` → `hostname_rules[].hostname_pattern`.
  - `hostname_patterns[].target_tag` → `hostname_rules[].tags` key `topology.<target_tag>`.
  - Add regex backreference/substitution support to `StaticTopologyEnricher` so VDE capture-group tag values can be migrated automatically; if that is not implemented, migration must fail on capture groups.
  - `ip_subnets[].cidr` → `subnet_rules[].subnet`; `value`/`target_tag` → `subnet_rules[].tags`.
- **Plugins:**
  - VDE `outputs.<name>` → Correlia `outputs[]` with `name`, `plugin_type: "email"`, `class_path: app.plugins.outputs.email.SmtpOutputPlugin`, `options: <config>`.
  - **Fail fast** on VDE sections `task_runner`, `inputs`, `llm`, `enrichers`, `processor` for v1.1.
  - Fail fast on non-email plugin types and class paths outside `app.plugins.outputs.`.
- **Environment:**
  - `DATABASE_URL` → `DATABASE_URL`.
  - `API_TOKEN` → `CORRELIA_API_TOKEN`.
  - No `DEV_MODE`; no `EMAIL_DRY_RUN` unless a concrete requirement appears later.

### 4.3 Plugin Architecture
- Keep Correlia's Protocol-based plugin ports in `app/plugins/interfaces.py`.
- Do not replace them with VDE's ABC style.
- v1.1 plugin loading remains **output-only**. The plugin registry schema may be extended to five adapter categories (`input`, `enrichment`, `processor`, `output`, `task_runner`) as an architecture seed, but only output plugins are loaded and dispatched at runtime in v1.1.
- Preserve strict namespace allowlisting: output plugin class paths must live under `app.plugins.outputs.`.
- Preserve startup-fail behavior and Pydantic `extra="forbid"` on every plugin entry.
- Do not pass `Incident` ORM objects or raw `config` dicts into output plugins. Keep `NotificationEnvelope` as the output plugin contract and bake plugin-specific config into the plugin instance at load time.
- Keep the task runner non-blocking (`asyncio.create_task`, returns immediately). If VDE-style task-runner plugins are ported later, wrap them to preserve this behavior.
- Structured `NotificationResult` remains mandatory; adapter shims must convert VDE plugin exceptions into failed results.

### 4.4 LLM / litellm
- Out of scope for v1.1 core.
- If added later, implement as opt-in plugins (`app/plugins/enrichers/llm.py`, `app/plugins/processors/llm.py`) with `enabled: false` default, env-var API keys, bounded concurrency, and strict timeouts.
- Static rule engine remains the sole authority; LLM output is advisory and validated against known rules.
- The VDE `llm` and `processor` config sections fail fast in v1.1 migration.

---

## 5. Watch Outs

| Risk | Mitigation |
|---|---|
| **Compatibility facade becomes the de facto canonical API** | Document `/v1` as canonical; keep rich fields only there; never remove `/v1/incidents`. |
| **Offset pagination over cursor repository becomes inefficient or inaccurate** | Add a dedicated offset+count repository helper for the compatibility facade only; monitor query plans. |
| **PATCH summary mutation pressure** | Return `422` until an audited domain operation exists; do not mutate text silently. |
| **Event audit writes hurt ingress throughput** | Append-only insert in same transaction boundary as incident upsert; no unique constraints on `incident_events`; measure before batching/outbox. |
| **Auth breaks existing tests / local clients** | Provide a known token via test fixtures and `.env.example`; no bypass switch. |
| **Metrics cardinality creeps upward** | Limit labels to bounded method/endpoint/status/plugin_type/category; never use host/service/incident ID/raw payload labels. |
| **Middleware ordering breaks auth/rate-limit** | Register size-limit first, then auth, then rate-limit; test each independently. |
| **Single-worker default appears underpowered vs VDE** | Document clearly; do not expose multi-worker config until task runner is distributed. |
| **Config migration silently drops VDE fields** | `extra="forbid"` + explicit unsupported-field checks; migration exits non-zero on unsupported semantics. |
| **Topology regex capture groups not supported** | Add backreference substitution to `StaticTopologyEnricher`, or fail migration on dynamic patterns. |
| **VDE output plugins expect `Incident` + `config`** | Adapter builds `NotificationEnvelope` from DB row and bakes config into plugin instance; contract stays bounded. |
| **Slowapi + FastAPI version mismatch** | Pin `slowapi` and verify exception handler works with resolved FastAPI version. |
| **Alembic migrations skipped in containers** | Run `alembic upgrade head` in entrypoint; exit non-zero on failure before starting Uvicorn. |
| **Scope creep into webhook parity** | Reject `/webhook/icinga2`; sender side adapts to `/v1/icinga2/events`. |
| **LLM plugins become default decision path** | Keep LLM out of v1.1; if added later, default `enabled: false` and require static-rule validation. |

---

## 6. Requirements Seed List

1. **Canonical API preservation:** `/v1/incidents` keeps cursor pagination, explicit ack/close subresources, rich `IncidentDetailResponse`, and Correlia lifecycle semantics.
2. **Vigilo API facade:** `/api/v1/incidents` provides offset-shaped list/detail, PATCH status ACK/CLOSED, DELETE soft-close, and 422 on summary mutation.
3. **Incident event audit:** Append-only `incident_events` table with defined columns/indexes; one row per accepted normalized event written in the ingress path.
4. **Static Bearer auth:** `CORRELIA_API_TOKEN` + `CORRELIA_AUTH_PUBLIC_PATHS`; `hmac.compare_digest`; no `DEV_MODE` bypass.
5. **Rate limiting:** Slowapi per-route limits configured via `CORRELIA_API_RATE_LIMIT_REQUESTS` and `CORRELIA_API_RATE_LIMIT_WINDOW_SECONDS`.
6. **Request size limit:** Starlette middleware enforces `CORRELIA_API_MAX_BODY_BYTES` (default 1 MiB) before auth/rate-limit.
7. **Docker packaging:** Multi-stage `Dockerfile`, `docker-compose.yml`, `.env.example`, sample config files, single-worker default, Alembic migration step.
8. **Config migration CLI:** `scripts/migrate_vigilo_config.py` translates VDE YAML to Correlia YAML, fails fast on unsupported semantics, and validates output with Correlia loaders.
9. **Plugin loading strictness:** Output-only plugin loading in v1.1; class paths under `app.plugins.outputs.`; `extra="forbid"`; startup-fail on invalid config.
10. **Topology backreference support:** `StaticTopologyEnricher` supports regex capture-group substitution, or migration fails on dynamic hostname patterns.
11. **Notification envelope boundary:** Output plugins receive `NotificationEnvelope`, not `Incident` ORM or raw config dicts.
12. **Non-blocking task runner:** `AsyncIOTaskRunner.submit` schedules via `asyncio.create_task` and returns immediately.
13. **Structured notification results:** Every dispatch attempt records a `NotificationResult`; exceptions from ported plugins become failed results.
14. **Bounded metrics/labels:** New counters for compat API, audit writes, migration failures, plugin load/dispatch; no host/service/incident ID labels.
15. **Readiness/logging extensions:** `/v1/readyz` covers enabled adapter categories; `SAFE_LOG_KEYS` extended for v1.1 events without raw payloads/credentials.
16. **Webhook endpoint parity:** Explicitly excluded from v1.1.
17. **LLM/litellm core dependency:** Explicitly excluded from v1.1 core; opt-in plugin-level only if added later.

---

## 7. Roadmap Seed Phases

Order matters where dependencies exist; parallel tracks are noted.

### Phase 1 — Auth, Rate Limit, and Settings Foundation
- Add `CORRELIA_API_TOKEN`, `CORRELIA_AUTH_PUBLIC_PATHS`, `CORRELIA_API_MAX_BODY_BYTES`, `CORRELIA_API_RATE_LIMIT_REQUESTS`, `CORRELIA_API_RATE_LIMIT_WINDOW_SECONDS` to `Settings`.
- Implement auth dependency in `app/api/deps.py`.
- Register size-limit middleware, Slowapi limiter, and exception handler in `app/main.py`.
- Apply auth dependency to protected canonical and future compat routes; update tests to inject a known token.
- *Why first:* every new API surface inherits protection.

### Phase 2 — Event Audit Persistence
- Add `IncidentEvent` SQLAlchemy model and Alembic migration (`migrations/versions/0003_add_incident_events.py`).
- Add `app/persistence/incident_events.py` with `record_incident_event(...)` helper.
- Write audit rows from `app/processing/ingress.py` after normalization and decision context are known.
- Add metrics counter for audit writes.
- *Can run in parallel with Phase 3 once schema conventions are settled.*

### Phase 3 — Config Migration and Topology Backreferences
- Implement `scripts/migrate_vigilo_config.py` with fail-fast rules and output validation.
- Add regex capture-group/backreference support to `StaticTopologyEnricher` (or keep migration failing on dynamic patterns until ready).
- Generate `.env.example` and sample config files.
- *Can run in parallel with Phase 2.*

### Phase 4 — Vigilo Incident API Facade
- Add `app/api/routers/incidents_compat.py` with prefix `/api/v1/incidents`.
- Implement offset pagination helper in persistence layer (facade-only).
- Map PATCH/DELETE to Correlia audited lifecycle operations.
- Add compatibility API metrics and structured logs.
- *Depends on Phase 1 (auth).*

### Phase 5 — Plugin/Output Architecture Hardening
- Preserve Protocol-based ports and output-only loading.
- Ensure `NotificationEnvelope` remains the output contract.
- Verify `AsyncIOTaskRunner` stays non-blocking and records structured results.
- Add plugin load/dispatch metrics and readyz checks for output plugins.
- *Depends on Phase 1 (settings/auth baseline).* Note: full input/enricher/processor/task-runner adapter loading is **not** in v1.1; registry schema may be seeded but runtime loading remains output-only.

### Phase 6 — Metrics, Readiness, and Logging Extensions
- Extend `app/processing/metrics.py` with v1.1 counters.
- Extend `/v1/readyz` to report on enabled adapter categories.
- Extend `SAFE_LOG_KEYS` in `app/processing/logging.py`.
- *Depends on Phases 2 and 4 (behaviors exist to observe).*

### Phase 7 — Docker / Compose Packaging
- Write `Dockerfile`, `docker-compose.yml`, `.env.example`, sample `config/*.yaml`.
- Enforce single-worker default and Alembic `upgrade head` entrypoint.
- Add optional `docker-*` Makefile targets.
- *Last because it captures completed runtime requirements.*

### Phase 8 — Verification / Acceptance
- End-to-end tests:
  - Create a Correlia incident, call `GET /api/v1/incidents`, and assert `{items, total, limit, offset}` with Vigilo-shaped fields.
  - `GET /api/v1/incidents/{id}` omits Correlia-only decision fields.
  - `PATCH /api/v1/incidents/{id}` with `status=ACKNOWLEDGED` records `acknowledged_by="vigilo-compat"`.
  - `PATCH /api/v1/incidents/{id}` with `summary` returns `422`.
  - `DELETE /api/v1/incidents/{id}` closes with `reason="vigilo-compat-delete"`.
  - Processing one accepted event creates exactly one `incident_events` row with matching fingerprint and non-empty `normalized_event` / `decision_summary`.
  - Migration fails on `min_hosts`, `is_dc_level: true`, empty actions, non-output plugin sections, and plaintext SMTP credentials.
  - Auth returns `401` without token; `403`/`401` behavior is consistent.
  - Rate limit returns `429`; oversized body returns `413`.

---

*Synthesized from `.planning/research/STACK.md`, `.planning/research/FEATURES.md`, `.planning/research/CONFIG.md`, and `.planning/research/ARCHITECTURE.md`.*
