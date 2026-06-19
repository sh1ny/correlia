# Roadmap: Correlia

## Milestones

- ✅ **v1.0 MVP** — Phases 1-4 shipped 2026-06-09. [Archive](milestones/v1.0-ROADMAP.md)
- 🚧 **v1.1 Vigilo/VDE Compatibility** — Phases 5-10 planned.

## Overview

v1.1 makes Correlia a practical Vigilo/VDE replacement at the auth, HTTP-control, canonical incident API, event-audit, config-migration, output-plugin, deployment, and operations boundaries. Compatibility is implemented on Correlia's canonical `/v1/incidents` surface; no `/api/v1/incidents` facade and no webhook endpoint compatibility are in scope. Correlia's stricter incident lifecycle, validation, rich incident representation, and refusal to mutate summaries without an audited domain model remain authoritative.

## Phases

**Phase Numbering:**

- Phases 1-4 belong to the shipped v1.0 MVP.
- v1.1 continues with integer phases 5-10.
- Decimal phases remain reserved for urgent insertions.

- [x] **Phase 5: Security and HTTP Controls** - Protected routes use production-safe Bearer auth, configurable public health/readiness exposure, request-size limits, and route rate limits. (completed 2026-06-17)
- [x] **Phase 6: Canonical Incident API Operation Parity** - `/v1/incidents` supports Vigilo-compatible list/detail/mutation workflows while preserving Correlia's richer canonical API and lifecycle rules. (completed 2026-06-17)
- [x] **Phase 7: Incident Event Audit Trail** - Accepted normalized events are recorded in an append-only audit table without influencing aggregation or lifecycle decisions. (completed 2026-06-18)
- [x] **Phase 8: Vigilo Config Migration** - Maintainers can convert supported Vigilo/VDE rules, topology, and email output config into validated Correlia YAML, with clear failures for unsupported semantics. (completed 2026-06-19)
- [ ] **Phase 9: Plugin and Notification Boundaries** - Output plugin loading and notification dispatch stay allowlisted, bounded, structured, and non-blocking.
- [ ] **Phase 10: Deployment and Operational Visibility** - Docker/compose runtime artifacts, sample config, compatibility metrics, readiness, and safe logs make the compatibility surface operable.

## Phase Details

### Phase 5: Security and HTTP Controls

**Goal**: Operator-facing Correlia routes have production-safe authentication and HTTP abuse controls before additional compatibility workflows are exposed.
**Depends on**: Phase 4
**Requirements**: SEC-01, SEC-02, SEC-03, SEC-04, SEC-05
**Success Criteria** (what must be TRUE):

  1. Operator API clients can access protected Correlia routes only when they provide the configured static Bearer token.
  2. Unauthenticated protected-route callers receive a deterministic unauthorized response with no development-mode bypass.
  3. Maintainers can choose which health/readiness paths are public while `/v1/health` remains public by default.
  4. Oversized HTTP request bodies are rejected before route handlers process payloads.
  5. Callers exceeding configured route limits receive a deterministic rate-limit response while allowed traffic still proceeds.

**Plans**: 2/2 plans complete

- [x] 05-01-PLAN.md
- [x] 05-02-PLAN.md

### Phase 6: Canonical Incident API Operation Parity

**Goal**: Vigilo-shaped incident list, detail, acknowledgement, and close workflows work on canonical `/v1/incidents` without downgrading Correlia's richer incident model.
**Depends on**: Phase 5
**Requirements**: API-01, API-02, API-03, API-04, API-05, API-06, API-07
**Success Criteria** (what must be TRUE):

  1. Operators can use Vigilo-supported `status`, `severity`, `rule_name`, `limit`, and `offset` filters on canonical `/v1/incidents` while Correlia cursor pagination remains available.
  2. Operators can request list metadata containing `items`, `total`, `limit`, and `offset` without removing Correlia's existing list response capabilities.
  3. Operators can fetch `/v1/incidents/{id}` and receive Correlia's rich incident fields unchanged.
  4. Operators can acknowledge or close incidents through compatibility-friendly status mutation or DELETE aliases, with `vigilo-compat` actor/reason defaults when omitted.
  5. Operators can continue using explicit `/ack` and `/close` endpoints, and summary mutation attempts return `422` without changing incident text.

**Plans**: 1 plan

Plans:

- [x] 06-01-PLAN.md — Canonical incident API list metadata, ACKNOWLEDGED filtering, detail preservation, PATCH/DELETE aliases, summary rejection, and explicit endpoint preservation.

### Phase 7: Incident Event Audit Trail

**Goal**: Maintainers and operators can trace accepted source events through normalization and incident decisions without using audit rows as decision state.
**Depends on**: Phase 5
**Requirements**: AUD-01, AUD-02, AUD-03, AUD-04
**Success Criteria** (what must be TRUE):

  1. Maintainers can migrate the database to an append-only `incident_events` table with traceability columns and lookup indexes.
  2. Every accepted normalized event records raw payload, normalized event, decision summary, source ID, fingerprint, severity, host, service, and timestamps.
  3. Incident aggregation, notification thresholds, recovery, and lifecycle transitions produce the same decisions from primary incident state rather than audit rows.
  4. Operators can correlate audit rows to incidents when one exists and inspect accepted no-op events when no incident was created or updated.

**Plans**: 3/3 plans complete
**Wave 1**

- [x] 07-01-PLAN.md — Audit schema, domain models, persistence repository, raw-payload redactor/HMAC, and foundation tests.

**Wave 2**

- [x] 07-02-PLAN.md — Ingress transaction refactor, manager commit ownership move, and audit write integration for all accepted event paths.

**Wave 3**

- [x] 07-03-PLAN.md — Read-only `/v1/incident-events` operator API, route classification, bounded response projection, and integration tests.

### Phase 8: Vigilo Config Migration

**Goal**: Maintainers can translate supported Vigilo/VDE YAML into strict Correlia config and get clear failures whenever Vigilo semantics cannot be preserved.
**Depends on**: Phase 5
**Requirements**: CFG-01, CFG-02, CFG-03, CFG-04, CFG-05, CFG-06, CFG-07
**Success Criteria** (what must be TRUE):

  1. Maintainers can run `scripts/migrate_vigilo_config.py` with `--rules`, `--topology`, `--plugins`, and `--out-dir` to generate Correlia `rules.yaml`, `topology.yaml`, and `plugins.yaml`.
  2. Supported Vigilo rule, topology, hostname-derived tag, and email output settings are rewritten into Correlia's strict schemas.
  3. Regex capture-group topology substitution is preserved when supported, or the migration exits clearly when substitution is required but unavailable.
  4. Plaintext SMTP credentials are not copied into generated plugin config.
  5. Unsupported Vigilo semantics such as `min_hosts`, `is_dc_level`, empty actions, non-output plugin sections, LLM config, and unsupported plugin types produce a non-zero migration result before success is reported.

**Plans**: 2/2 plans complete

Plans:

- [x] 08-01-PLAN.md — Runtime topology capture-group schema, compiled config, enrichment semantics, and tests.
- [x] 08-02-PLAN.md — Standalone Vigilo/VDE migration CLI, fail-closed unsupported reporting, atomic output, loader/plugin validation, fixtures, and documentation.

> **Planning status:** Plans 08-01 and 08-02 were produced and reviewed through 5 plan-check iterations. The final checker returned `## ISSUES FOUND` with 1 blocker, 1 warning, and 1 nit. The operator explicitly chose to proceed to execution with these known risks documented in `.planning/STATE.md`. Execution resolved all three accepted risks: unknown email plugin options are rejected, multi-input aggregation is pinned by a dedicated test, and generic unknown plugin sections are rejected.

### Phase 9: Plugin and Notification Boundaries

**Goal**: Output plugin execution remains isolated behind Correlia's bounded notification contract while preserving non-blocking ingress behavior.
**Depends on**: Phase 5
**Requirements**: PLG-01, PLG-02, PLG-03, PLG-04
**Success Criteria** (what must be TRUE):

  1. Maintainers can load output plugins only from Correlia's allowlisted output plugin namespace with strict plugin config validation.
  2. Output plugins receive bounded `NotificationEnvelope` data instead of mutable incident ORM objects or raw configuration dictionaries.
  3. Operators can inspect structured `NotificationResult` records for plugin exceptions and delivery outcomes rather than relying on logs alone.
  4. Ingress requests are not blocked by notification delivery work after dispatch is submitted.

**Plans**: TBD

### Phase 10: Deployment and Operational Visibility

**Goal**: Maintainers can run the compatibility-ready service in containers and operators can observe the new surface safely.
**Depends on**: Phases 5, 6, 7, 8, 9
**Requirements**: DEP-01, DEP-02, DEP-03, DEP-04, OPS-01, OPS-02, OPS-03
**Success Criteria** (what must be TRUE):

  1. Maintainers can run Correlia from a Docker image that applies Alembic migrations and then launches the FastAPI app factory with one Uvicorn worker by default.
  2. Maintainers can run Correlia locally with docker compose using PostgreSQL, Correlia, SMTP capture, environment variables, and read-only config mounts.
  3. Maintainers receive `.env.example` and sample `config/rules.yaml`, `config/topology.yaml`, and `config/plugins.yaml` aligned with Correlia settings.
  4. Operators can observe incident API compatibility requests, config migration failures, audit writes, plugin load results, plugin dispatch results, dependencies, and plugin categories through low-cardinality metrics and readiness responses.
  5. Operators receive safe structured logs for compatibility mutations, migration failures, audit writes, and plugin behavior without credentials, raw payloads, or unbounded labels.

**Plans**: TBD

## Requirement Coverage

| Requirement | Phase |
|-------------|-------|
| SEC-01 | Phase 5 |
| SEC-02 | Phase 5 |
| SEC-03 | Phase 5 |
| SEC-04 | Phase 5 |
| SEC-05 | Phase 5 |
| API-01 | Phase 6 |
| API-02 | Phase 6 |
| API-03 | Phase 6 |
| API-04 | Phase 6 |
| API-05 | Phase 6 |
| API-06 | Phase 6 |
| API-07 | Phase 6 |
| AUD-01 | Phase 7 |
| AUD-02 | Phase 7 |
| AUD-03 | Phase 7 |
| AUD-04 | Phase 7 |
| CFG-01 | Phase 8 |
| CFG-02 | Phase 8 |
| CFG-03 | Phase 8 |
| CFG-04 | Phase 8 |
| CFG-05 | Phase 8 |
| CFG-06 | Phase 8 |
| CFG-07 | Phase 8 |
| PLG-01 | Phase 9 |
| PLG-02 | Phase 9 |
| PLG-03 | Phase 9 |
| PLG-04 | Phase 9 |
| DEP-01 | Phase 10 |
| DEP-02 | Phase 10 |
| DEP-03 | Phase 10 |
| DEP-04 | Phase 10 |
| OPS-01 | Phase 10 |
| OPS-02 | Phase 10 |
| OPS-03 | Phase 10 |

**Coverage:** 30/30 v1.1 requirements mapped exactly once. No orphaned requirements. No duplicate mappings.

## Progress

**Execution Order:** 5 → 6 → 7 → 8 → 9 → 10

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 5. Security and HTTP Controls | v1.1 | 2/2 | Complete    | 2026-06-17 |
| 6. Canonical Incident API Operation Parity | v1.1 | 1/1 | Complete    | 2026-06-17 |
| 7. Incident Event Audit Trail | v1.1 | 3/3 | Complete    | 2026-06-18 |
| 8. Vigilo Config Migration | v1.1 | 2/2 | Complete   | 2026-06-19 |
| 9. Plugin and Notification Boundaries | v1.1 | 0/TBD | Not started | - |
| 10. Deployment and Operational Visibility | v1.1 | 0/TBD | Not started | - |

---
*Last updated: 2026-06-19 — Plan 08-02 complete, Phase 8 complete*
