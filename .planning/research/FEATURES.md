# Feature Research — Correlia v1.1 Vigilo/VDE Compatibility

**Scope:** API, event audit, auth exposure, compatibility behavior, and operational feature boundaries required for Correlia to replace Vigilo/VDE clients without weakening Correlia's canonical lifecycle.

**Explicit exclusion:** webhook endpoint compatibility. Sender-side systems will adapt to Correlia's canonical ingress.

## Executive Recommendation

Add compatibility as an additive shell around Correlia, not as a core rewrite. Keep `/v1/incidents` as the canonical API with cursor pagination, explicit `/ack` and `/close`, rich decision context, and Correlia lifecycle semantics. Add `/api/v1/incidents` only as a Vigilo-shaped facade that projects Correlia incidents into Vigilo response fields and maps Vigilo mutations onto Correlia audited lifecycle operations. Add `incident_events` for traceability, not as an aggregation input.

## Evidence

| Source | Evidence | Implication |
|---|---|---|
| `compatibility research (removed for privacy)` | Declares Correlia stronger than Vigilo/VDE and targets compatibility at API, config, plugin, deployment boundaries while excluding webhook endpoint compatibility. | v1.1 must preserve Correlia core behavior and avoid `/webhook/icinga2` parity work. |
| `app/api/routers/incidents.py` | Correlia canonical router is `prefix="/v1/incidents"`; list uses `limit` + `cursor`; detail returns rich fields; ack/close use explicit POST subresources. | Compatibility facade must not replace canonical routes. |
| `app/api/routers/incidents.py` | `IncidentDetailResponse` includes `affected_services`, `acknowledgement`, `decision_context`, `threshold_crossed`, `notified_at`, lifecycle timestamps. | Vigilo response projection is lossy by design; canonical API remains source of full state. |
| `../vde-event-aggregation/app/api/endpoints/incidents.py` | VDE router is `prefix="/api/v1/incidents"`; list supports `status`, `severity`, `rule_name`, `limit`, `offset`; PATCH mutates `status` and/or `summary`; DELETE soft-closes. | Facade must implement offset-shaped list response and PATCH/DELETE compatibility. |
| `../vde-event-aggregation/app/api/schemas/incidents.py` | VDE `IncidentResponse` fields are `id`, `rule_name`, `group_key`, `status`, `severity`, `start_time`, `last_update_time`, `summary`, `event_count`, `affected_hosts`; list response adds `total`, `limit`, `offset`. | Facade response shape is small and can be projected from Correlia `Incident`. |
| `compatibility research (removed for privacy)` | Summary mutation should return `422 detail="summary mutation is not supported"`; ACK maps to `operator="vigilo-compat"`; DELETE maps to close reason `vigilo-compat-delete`. | Preserve Correlia audit model; do not add unaudited summary mutation. |
| `compatibility research (removed for privacy)` | `incident_events` table is append-only, includes raw payload, normalized event, decision summary, and does not participate in aggregation. | Event audit is a traceability feature only. |

## Feature Categories

### 1. Vigilo Incident API Facade

**Table stakes:**

- `GET /api/v1/incidents` accepts `status`, `severity`, `rule_name`, `limit`, `offset` and returns `{items,total,limit,offset}`.
- `GET /api/v1/incidents/{id}` returns Vigilo-shaped incident fields only.
- `PATCH /api/v1/incidents/{id}` supports `status=ACKNOWLEDGED` and `status=CLOSED` by calling Correlia lifecycle functions.
- `PATCH` with `summary` returns `422` because Correlia has no audited summary mutation model.
- `DELETE /api/v1/incidents/{id}` soft-closes through Correlia close lifecycle and returns `{id,deleted}`.

**Best approach:**

- Add `app/api/routers/incidents_compat.py` with prefix `/api/v1/incidents`.
- Use Correlia persistence functions where possible; add a repository helper for exact offset pagination and `total` if cursor emulation would be inefficient or ambiguous.
- Define local Pydantic response/request models in the compat router/module so canonical domain models remain unchanged.
- Apply the same auth dependency as protected canonical routes.
- Emit compatibility API metrics with bounded labels: `method`, `endpoint`, `status`.

**Do not:**

- Do not change `/v1/incidents` to offset pagination.
- Do not expose Correlia-only fields in the Vigilo facade unless the client explicitly moves to `/v1`.
- Do not add summary mutation without an explicit audited domain operation.

### 2. Event Audit Traceability

**Table stakes:**

- Add `incident_events` table with columns from `compatibility research (removed for privacy)`.
- Record one row per accepted normalized event with raw payload, normalized event, decision summary, timestamps, and optional `incident_id`.
- Add indexes on `fingerprint`, `(source_id, received_at desc)`, and `(incident_id, processed_at desc)`.
- Keep audit writes append-only and out of aggregation decisions.

**Best approach:**

- Add `IncidentEvent` SQLAlchemy model and Alembic migration.
- Add `app/persistence/incident_events.py` with a narrow `record_incident_event(...)` helper.
- Write audit rows from the ingress processing path after normalization and decision context are known.
- If an event is accepted but does not create/update an incident, persist the row with `incident_id = null` and a decision summary explaining no-op/rejection reason.

### 3. Auth Exposure for Compatibility Routes

**Table stakes:**

- Protect `/api/v1/incidents` with the same static Bearer-token policy as protected canonical `/v1` routes.
- Keep `/v1/health` public.
- Make `/v1/readyz` configurable because it exposes dependency status.
- No VDE `DEV_MODE` bypass and no randomized 401 behavior.

**Best approach:**

- Centralize auth in `app/api/deps.py`.
- Use `hmac.compare_digest` for token comparison.
- Let test and local development supply a token explicitly rather than bypassing security.

### 4. Operational Compatibility Features

**Table stakes:**

- Metrics for compatibility API requests.
- Metrics for incident event audit writes.
- Safe structured logs for compat mutations with bounded fields only.
- Readiness remains canonical at `/v1/readyz`; the compat layer does not create a separate health model.

**Best approach:**

- Extend existing metrics module rather than adding a second metrics registry.
- Avoid host, service, incident ID, raw payload, or customer-controlled labels.

## Requirements Implications

- v1.1 needs a dedicated API compatibility requirement set, separate from canonical API requirements.
- v1.1 needs event audit requirements because Vigilo users expect raw-event traceability, but implementation must keep Correlia's richer incident schema as canonical.
- v1.1 needs security/operational requirements because Vigilo environments expect static token auth, request/rate limits, deployment packaging, and health/metrics surfaces.
- Summary mutation, webhook endpoint compatibility, and downgrading Correlia's incident schema must be explicitly out of scope.

## Roadmap Implications

1. Start with auth/request limits because all new API surfaces should inherit protection.
2. Add the compatibility incident facade after auth and before deployment validation.
3. Add event audit as a persistence slice; it can proceed in parallel with config migration once schema conventions are settled.
4. Add metrics/logging/readiness extensions after the behaviors exist.
5. Deployment packaging should be final in the roadmap so Docker/compose captures the completed runtime requirements.

## Risks

| Risk | Mitigation |
|---|---|
| Offset pagination over cursor repository becomes inefficient or inaccurate | Add a dedicated offset+count repository helper for the compatibility facade only. |
| Compatibility facade becomes the de facto canonical API | Document `/v1` as canonical and keep rich fields only there. |
| PATCH summary mutation pressure | Return 422 until an audited domain operation exists; do not mutate text silently. |
| Event audit table adds ingress latency | Keep rows append-only with simple indexes; measure before adding batching/outbox. |
| Auth breaks internal/local clients | Provide explicit `.env.example` and test helpers; do not add bypass behavior. |
| Metrics cardinality creeps upward | Limit labels to bounded method/endpoint/status and counters without host/service/incident IDs. |

## Verification Targets

- Create one Correlia incident, call `GET /api/v1/incidents`, and assert response has `items`, `total`, `limit`, `offset` with Vigilo-shaped item fields.
- `GET /api/v1/incidents/{id}` returns the projected Vigilo response and omits Correlia-only decision fields.
- `PATCH /api/v1/incidents/{id}` with `status=ACKNOWLEDGED` records `acknowledged_by="vigilo-compat"`.
- `PATCH /api/v1/incidents/{id}` with `summary="x"` returns 422.
- `DELETE /api/v1/incidents/{id}` closes the incident with `reason="vigilo-compat-delete"`.
- Processing one accepted event creates exactly one `incident_events` row with matching fingerprint and non-empty `normalized_event` and `decision_summary`.

---

*Research for: Correlia v1.1 Vigilo/VDE API compatibility*
