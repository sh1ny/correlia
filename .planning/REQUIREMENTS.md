# Requirements: Correlia v1.1 Vigilo/VDE Compatibility

**Defined:** 2026-06-14
**Core Value:** Operators receive one accurate, topology-aware incident for a related alert storm instead of many disconnected raw alerts.

## v1.1 Requirements

Requirements for the Vigilo/VDE compatibility milestone. Each requirement maps to exactly one roadmap phase.

### Security and HTTP Controls

- [x] **SEC-01**: Operator API clients can authenticate protected Correlia routes with a static Bearer token configured by environment.
- [x] **SEC-02**: Unauthenticated callers receive a deterministic unauthorized response on protected routes without any development-mode bypass.
- [x] **SEC-03**: Maintainers can configure which health/readiness paths are public while keeping `/v1/health` public by default.
- [x] **SEC-04**: Correlia rejects oversized HTTP request bodies before route handlers process payloads.
- [x] **SEC-05**: Correlia rate-limits configured API routes and returns a deterministic rate-limit response when the limit is exceeded.

### Canonical Incident API Compatibility

- [ ] **API-01**: Operators can list incidents on canonical `/v1/incidents` using Vigilo-supported filters `status`, `severity`, `rule_name`, `limit`, and `offset`.
- [ ] **API-02**: Operators can request list metadata containing `items`, `total`, `limit`, and `offset` without removing Correlia's cursor pagination support.
- [ ] **API-03**: Operators can fetch one incident on canonical `/v1/incidents/{id}` with Correlia's rich incident fields preserved.
- [ ] **API-04**: Operators can acknowledge an open incident through a status mutation alias while Correlia records the operator as `vigilo-compat` when no operator is supplied.
- [ ] **API-05**: Operators can close an open or acknowledged incident through status mutation or DELETE alias while Correlia records a compatibility close reason when no reason is supplied.
- [ ] **API-06**: Operators receive `422` when attempting summary mutation because Correlia does not support unaudited incident text changes.
- [ ] **API-07**: Operators can continue using Correlia's explicit `/ack` and `/close` endpoints alongside compatibility-friendly mutation aliases.

### Incident Event Audit

- [ ] **AUD-01**: Maintainers can migrate the database to include an append-only `incident_events` table with the required traceability columns and indexes.
- [ ] **AUD-02**: Correlia records one audit row for every accepted normalized event with raw payload, normalized event, decision summary, source ID, fingerprint, severity, host, service, and timestamps.
- [ ] **AUD-03**: Correlia records audit rows without using them to decide incident aggregation, notification thresholds, recovery, or lifecycle transitions.
- [ ] **AUD-04**: Operators can correlate audit rows to incidents when an incident exists and can inspect no-op accepted events when no incident was created or updated.

### Vigilo Config Migration

- [ ] **CFG-01**: Maintainers can run `scripts/migrate_vigilo_config.py` with `--rules`, `--topology`, `--plugins`, and `--out-dir` to generate Correlia `rules.yaml`, `topology.yaml`, and `plugins.yaml`.
- [ ] **CFG-02**: The migration command rewrites supported Vigilo rule fields into strict Correlia rule schema, including severity, host/service patterns, topology tag keys, summary placeholders, and action objects.
- [ ] **CFG-03**: The migration command rewrites supported Vigilo topology fields into strict Correlia hostname and subnet topology schemas.
- [ ] **CFG-04**: Correlia supports topology regex capture-group substitution needed to preserve Vigilo hostname-derived topology tags, or the migration fails clearly when substitution is required but unavailable.
- [ ] **CFG-05**: The migration command rewrites supported Vigilo email output plugin configuration into Correlia output plugin schema without copying plaintext SMTP credentials.
- [ ] **CFG-06**: The migration command exits non-zero with a clear unsupported-field error for Vigilo semantics Correlia cannot preserve, including `min_hosts`, `is_dc_level`, empty actions, non-output plugin sections, LLM config, and unsupported plugin types.
- [ ] **CFG-07**: The migration command validates generated files with Correlia's existing rule, topology, and plugin config loaders before reporting success.

### Plugin and Notification Boundaries

- [ ] **PLG-01**: Maintainers can load output plugins only from Correlia's allowlisted output plugin namespace with strict plugin configuration validation.
- [ ] **PLG-02**: Output plugins receive bounded `NotificationEnvelope` data instead of mutable incident ORM objects or raw configuration dictionaries.
- [ ] **PLG-03**: Notification dispatch converts plugin exceptions into structured `NotificationResult` records instead of relying on logs alone.
- [ ] **PLG-04**: Correlia preserves non-blocking task submission so notification delivery does not block the ingress request path.

### Deployment and Operations

- [ ] **DEP-01**: Maintainers can run Correlia from a Docker image that starts with Alembic migrations and then launches the FastAPI app factory.
- [ ] **DEP-02**: Maintainers can run Correlia locally with docker compose using PostgreSQL, Correlia, SMTP capture, environment variables, and read-only config mounts.
- [ ] **DEP-03**: The default container runtime uses one Uvicorn worker unless a future durable queue or leader-election design exists.
- [ ] **DEP-04**: Maintainers receive `.env.example` and sample `config/rules.yaml`, `config/topology.yaml`, and `config/plugins.yaml` files aligned with Correlia settings.
- [ ] **OPS-01**: Operators can observe incident API compatibility requests, config migration failures, incident audit writes, plugin load results, and plugin dispatch results through low-cardinality Prometheus metrics.
- [ ] **OPS-02**: Operators can inspect readiness for configured dependencies and plugin categories without exposing secrets or raw payloads.
- [ ] **OPS-03**: Operators receive safe structured logs for compatibility mutations, migration failures, audit writes, and plugin behavior without credentials, raw payloads, or unbounded labels.

## Future Requirements

Deferred to future milestones. Tracked but not in current roadmap.

### Durable Execution and Advanced Plugins

- **FUT-01**: Maintainers can switch task execution to a durable broker-backed queue with retry/outbox semantics.
- **FUT-02**: Maintainers can load input, enrichment, decision/processor, and task-runner plugin adapters from strict allowlisted namespaces.
- **FUT-03**: Operators can enable LLM enrichment or decision-assist plugins explicitly with bounded timeouts, API-key environment references, and static-rule validation.
- **FUT-04**: Operators can use API-managed suppressions, silences, maintenance windows, config dry-run, and config reload workflows.
- **FUT-05**: Operators can dispatch to Slack, generic webhook, PagerDuty Events API, or Grafana OnCall output plugins.

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Webhook endpoint compatibility (`/webhook/icinga2`) | Sender side will adjust to Correlia's canonical ingress; preserving canonical payload validation matters more than URL parity. |
| Vigilo `DEV_MODE` auth bypass | Correlia should be production-safe by default; tests and local clients can provide a token explicitly. |
| PATCH summary mutation | Correlia has no audited domain model for mutating incident text; silently changing summaries would weaken traceability. |
| Downgrading Correlia incident schema to Vigilo's thinner model | Correlia's lifecycle, decision context, affected services, threshold state, and notification audit are core strengths. |
| LLM/litellm as a core dependency | Deterministic rules remain the authoritative decision path; optional LLM plugins can be considered later. |
| Multi-worker container default | In-process task and lifecycle workers are not safe to duplicate without a distributed queue or leader election. |
| Long-term raw event warehouse | `incident_events` is an operational audit trail, not a data-lake product. |
| `/api/v1/incidents` compatibility facade | No current clients rely on the Vigilo path; Correlia can evolve canonical `/v1/incidents` directly instead of carrying a parallel facade. |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SEC-01 | Phase 5 | Complete |
| SEC-02 | Phase 5 | Complete |
| SEC-03 | Phase 5 | Complete |
| SEC-04 | Phase 5 | Complete |
| SEC-05 | Phase 5 | Complete |
| API-01 | Phase 6 | Pending |
| API-02 | Phase 6 | Pending |
| API-03 | Phase 6 | Pending |
| API-04 | Phase 6 | Pending |
| API-05 | Phase 6 | Pending |
| API-06 | Phase 6 | Pending |
| API-07 | Phase 6 | Pending |
| AUD-01 | Phase 7 | Pending |
| AUD-02 | Phase 7 | Pending |
| AUD-03 | Phase 7 | Pending |
| AUD-04 | Phase 7 | Pending |
| CFG-01 | Phase 8 | Pending |
| CFG-02 | Phase 8 | Pending |
| CFG-03 | Phase 8 | Pending |
| CFG-04 | Phase 8 | Pending |
| CFG-05 | Phase 8 | Pending |
| CFG-06 | Phase 8 | Pending |
| CFG-07 | Phase 8 | Pending |
| PLG-01 | Phase 9 | Pending |
| PLG-02 | Phase 9 | Pending |
| PLG-03 | Phase 9 | Pending |
| PLG-04 | Phase 9 | Pending |
| DEP-01 | Phase 10 | Pending |
| DEP-02 | Phase 10 | Pending |
| DEP-03 | Phase 10 | Pending |
| DEP-04 | Phase 10 | Pending |
| OPS-01 | Phase 10 | Pending |
| OPS-02 | Phase 10 | Pending |
| OPS-03 | Phase 10 | Pending |

**Coverage:**

- v1.1 requirements: 30 total
- Mapped to phases: 30
- Unmapped: 0 ✓
- Duplicate mappings: 0 ✓

---
*Requirements defined: 2026-06-14*
*Last updated: 2026-06-14 after v1.1 roadmap traceability mapping*
