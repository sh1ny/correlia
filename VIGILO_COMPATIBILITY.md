# Vigilo Compatibility Plan

## Decision

Correlia should be the replacement base because its incident lifecycle, persisted decision state, notification audit trail, readiness checks, metrics, and strict config validation are stronger than Vigilo/VDE.

Correlia is not a drop-in replacement today. The target is compatibility at the API, config, plugin, and deployment boundaries while preserving Correlia's stricter core behavior. Webhook endpoint compatibility is intentionally excluded from this plan; inbound payload and URL adjustments will be handled by the sender side.

## Compatibility Scope

| Area | Status |
| --- | --- |
| Icinga webhook endpoint shape | Excluded: sender side will adjust. |
| Incident API behavior | Add compatibility facade if existing Vigilo clients call /api/v1/incidents. |
| Database state model | Keep Correlia incident schema; add event audit table for Vigilo-style raw-event traceability. |
| Rule/topology/plugin config | Add migration/translation tooling from Vigilo YAML to Correlia strict schemas. |
| Plugin extension points | Expand Correlia registry to cover input, enrichment, decision, output, and task-runner ports. |
| Auth/rate-limit/deployment parity | Add API auth, request/rate limits, Dockerfile, and compose packaging. |

## Current Incompatibilities

- Correlia ingress currently exposes `POST /v1/icinga2/events` and accepts flat `Icinga2WebhookPayload`; Vigilo exposes `POST /webhook/icinga2` and accepts nested Icinga-style `host`/`service` payloads. This is excluded from this plan because the sender side will adjust.
- Correlia incident API is `/v1/incidents` with cursor pagination plus explicit `/ack` and `/close`; Vigilo uses `/api/v1/incidents` with offset pagination plus PATCH/DELETE status mutation.
- Correlia incident rows include affected services, decision context, window state, threshold/notified timestamps, lifecycle timestamps, and acknowledgement audit; Vigilo incident rows only persist the thinner incident summary plus `affected_hosts`.
- Correlia plugin loading currently has safe output-plugin registry behavior but does not yet match Vigilo's broader input/enricher/processor/task-runner extension slots.
- Vigilo has Docker/compose packaging and request/rate-limit middleware; Correlia currently has none in the inspected root.

## Required Correlia Additions

### 1. Incident API compatibility facade

Future implementation task: add `/api/v1/incidents` only if external Vigilo clients depend on that path.

- Map `GET /api/v1/incidents?status=&severity=&rule_name=&limit=&offset=` to Correlia's `list_incidents` cursor-based repository by translating `offset` into a compatibility page internally. If exact offset semantics are required, add a repository helper rather than changing canonical `/v1/incidents`.
- Map `GET /api/v1/incidents/{id}` to Correlia's detail response and down-project fields to Vigilo's response shape.
- Map `PATCH /api/v1/incidents/{id}` as follows:
  - `status=ACKNOWLEDGED` calls Correlia ack with `operator="vigilo-compat"`.
  - `status=CLOSED` calls Correlia close with `reason="vigilo-compat"`.
  - Summary-only PATCH updates are not currently supported by Correlia. Reject them with `422 detail="summary mutation is not supported"`; do not silently mutate incident text without an audit model.
- Map `DELETE /api/v1/incidents/{id}` to close with `reason="vigilo-compat-delete"`.
- Keep `/v1/incidents` as canonical; the compatibility facade must not replace it.

### 2. Event audit table

Future implementation task: add a new table named `incident_events`, not VDE's `raw_events`, because Correlia should keep both raw and normalized/decision context.

Columns:

| Column | Definition |
| --- | --- |
| `id` | `uuid primary key` |
| `incident_id` | `uuid nullable references incidents(id)` |
| `source_id` | `varchar(256) not null` |
| `fingerprint` | `varchar(64) not null` |
| `event_type` | `varchar(32) not null` |
| `severity` | `varchar(32) not null` |
| `host` | `varchar(256) not null` |
| `service` | `varchar(256) null` |
| `payload` | `jsonb not null` |
| `normalized_event` | `jsonb not null` |
| `decision_summary` | `jsonb not null` |
| `received_at` | `timestamptz not null` |
| `processed_at` | `timestamptz not null` |

Indexes:

- `(fingerprint)`
- `(source_id, received_at desc)`
- `(incident_id, processed_at desc)`

`incident_events` is append-only and does not participate in incident aggregation decisions.

### 3. Vigilo config migration command

Future implementation task: add `scripts/migrate_vigilo_config.py`.

Inputs:

- `--rules`
- `--topology`
- `--plugins`
- `--out-dir`

Outputs:

- Correlia-compatible `rules.yaml` in `--out-dir`
- Correlia-compatible `topology.yaml` in `--out-dir`
- Correlia-compatible `plugins.yaml` in `--out-dir`

Migration must fail on unsupported fields. It must not silently drop rules, topology entries, plugin config, actions, credentials, or LLM processor settings.

SMTP credentials must be emitted as environment-variable references or omitted with an explicit failure. Never copy plaintext `smtp_username` or `smtp_password` into generated Correlia plugin YAML.

### 4. API auth and API rate limiting

Add static Bearer-token auth for protected API routes first, matching Vigilo's operator model but without Vigilo's `DEV_MODE` bypass or random 401 Easter egg.

Protect these routes unless deployment config explicitly marks them public:

- `/v1/incidents`
- `/v1/rules`
- `/v1/topology`
- `/v1/plugins`
- `/v1/metrics`

Add request size limit and rate limiting middleware with these config fields:

- `api_max_body_bytes`
- `api_rate_limit_requests`
- `api_rate_limit_window_seconds`

Keep `/v1/health` public. Make `/v1/readyz` configurable because it exposes dependency status.

### 5. Deployment parity

Add Dockerfile and docker-compose for Correlia with PostgreSQL and SMTP capture service.

Default to one Uvicorn worker because Correlia's task runner and lifecycle worker are in-process. If multi-worker mode is later required, first add a distributed queue or leader-election design.

Use these CI/local gate commands from the Correlia root:

- `uv lock --check`
- `make lint`
- `make typecheck`
- `make test`

### 6. Operational compatibility

Preserve Correlia's `/v1/readyz` and Prometheus `/v1/metrics` as canonical.

Add metrics only where compatibility work creates new behavior:

- Compatibility API requests
- Config migration failures
- Incident event audit writes
- Plugin dispatch results by plugin type

Do not add host, service, or incident ID Prometheus labels.

## Database Schema Direction

Keep Correlia's current `incidents` shape as the canonical schema because it stores lifecycle and decision state that Vigilo does not.

Do not downgrade to Vigilo's thinner `incidents` table. Add `incident_events` as the audit/history complement.

If existing Vigilo data must be imported later, write a one-way import that maps `affected_hosts` into Correlia `affected_hosts`, leaves `affected_services` empty when unavailable, sets `decision_context.notes.import_source="vigilo"`, and sets lifecycle timestamps from best available Vigilo timestamps.

## Plugin Architecture Direction

Recommended ports/adapters design:

```python
class InputAdapter:
    async def normalize(self, payload: object) -> NormalizedEvent | Icinga2Rejection: ...

class EnrichmentAdapter:
    async def enrich(self, event: NormalizedEvent) -> EnrichmentResult: ...

class DecisionAdapter:
    async def decide(self, event: NormalizedEvent, rules: CompiledRuleConfig) -> RuleDecision | NoOpDecision: ...

class NotificationAdapter:
    async def send(self, envelope: NotificationEnvelope) -> NotificationResult: ...

class TaskRunnerAdapter:
    def register(self, task_name: str, handler: Callable[[Mapping[str, object]], Awaitable[None]]) -> None: ...
    async def submit(self, task_name: str, payload: Mapping[str, object]) -> None: ...
    async def drain(self) -> None: ...
```

Rules:

- Keep Correlia's plugin namespace allowlist; expand it from output plugins to each adapter type.
- Every plugin config must be strict Pydantic with `extra="forbid"`.
- Startup must fail on invalid plugin config; do not copy Vigilo's warn-and-skip behavior.
- LLM enrichment/decision plugins may be supported for Vigilo parity, but must be disabled by default, require explicit API-key config when enabled, and must never be the only path for rule decisions.
- Notification plugins must return structured `NotificationResult`; they must not only raise/log.
- Task runners must not await notification delivery on the ingress request path; preserve Correlia's non-blocking submit/drain behavior.

## Verification Targets

- Compatibility API: create one Correlia incident, call `GET /api/v1/incidents`, expect Vigilo-shaped list response with `items`, `total`, `limit`, `offset`.
- PATCH compatibility: `PATCH status=ACKNOWLEDGED` records `acknowledged_by="vigilo-compat"`; `PATCH summary="x"` returns 422.
- Event audit: process one event and assert exactly one `incident_events` row with matching fingerprint and non-empty `normalized_event`/`decision_summary`.
- Config migration: run migration on Vigilo sample YAML and assert generated Correlia YAML loads through `load_rule_config`, `load_topology_config`, and `load_plugin_registry_config`.
- Plugin architecture: register a test enrichment adapter and a test notification adapter through the registry; assert startup fails on an adapter outside the allowlisted namespace.
- Gates from Correlia root: `uv lock --check`, `make lint`, `make typecheck`, `make test`.

## Source Evidence

- `app/api/routers/ingress.py` — Correlia canonical ingress route is `/v1/icinga2/events`.
- `app/plugins/inputs/icinga2.py` — Correlia flat strict Icinga payload and SOFT-state rejection.
- `app/api/routers/incidents.py` — Correlia canonical incident list/detail/ack/close API and rich response fields.
- `app/persistence/incidents.py` — Correlia recovery shrinks affected sets using `active_service_pairs` and persists lifecycle context.
- `app/plugins/interfaces.py` — current Correlia plugin protocols.
- `app/plugins/loader.py` — current Correlia output-plugin registry and allowlist behavior.
- `/home/bgshi/Development/python/vde-event-aggregation/app/api/endpoints/incidents.py` — Vigilo incident CRUD route shape.
- `/home/bgshi/Development/python/vde-event-aggregation/app/models/incident.py` — Vigilo thinner incident/raw-event schema.
- `/home/bgshi/Development/python/vde-event-aggregation/app/core/interfaces.py` — Vigilo broader plugin ABCs.
- `/home/bgshi/Development/python/vde-event-aggregation/Dockerfile` and `docker-compose.yml` — Vigilo deployment packaging.
