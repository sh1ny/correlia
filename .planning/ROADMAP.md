# Roadmap: Correlia

## Overview

Correlia v1 builds one coherent API-first alert aggregation backend: first establish stable domain contracts and PostgreSQL-owned incident invariants, then prove Icinga2 ingestion with topology-aware rule decisions, then turn problem events into durable incidents and transition-controlled notifications, and finally complete lifecycle closure, REST operator workflows, and operability signals. The roadmap uses coarse MVP phases so each phase delivers a broad, verifiable capability without splitting the product into disconnected technical layers.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Foundations, Contracts, and Database Invariant** - Maintainers can run Correlia with strict domain/config contracts and PostgreSQL-enforced incident state.
- [ ] **Phase 2: Icinga2 Ingress, Topology, and Rule Decisions** - Operators can send real Icinga2 alerts through normalization, enrichment, and deterministic rule evaluation.
- [ ] **Phase 3: Problem Aggregation and Notification Dispatch** - Problem events become durable topology-aware incidents and threshold transitions dispatch through pluggable tasks/outputs.
- [ ] **Phase 4: Lifecycle, Operator APIs, and Operability** - Recovery, expiration, REST workflows, logs, readiness, metrics, and verification complete the v1 operational surface.

## Phase Details

### Phase 1: Foundations, Contracts, and Database Invariant
**Goal:** Maintainers can run Correlia with strict domain/config contracts and PostgreSQL-enforced incident state.
**Mode:** mvp
**Depends on:** Nothing (first phase)
**Requirements:** FND-01, FND-02, FND-03, FND-04, DOM-01, DOM-02, DOM-03, DOM-04, PRS-01, PRS-02, PRS-03, PRS-04
**Success Criteria** (what must be TRUE):
  1. Maintainer can install and run the FastAPI service with Python 3.13, uv-managed dependencies, validated settings, Alembic migrations, and a REST health endpoint.
  2. Input, config, and persistence code share strict domain contracts for normalized events, event type, incident lifecycle, severity, tags, messages, timestamps, and optional debug metadata.
  3. Malformed domain/config data fails with explicit validation errors instead of silently accepting partial or coerced state.
  4. PostgreSQL enforces one active incident per rule/group and supports atomic incident upsert without SELECT-then-INSERT behavior.
**Plans:** TBD

### Phase 2: Icinga2 Ingress, Topology, and Rule Decisions
**Goal:** Operators can send real Icinga2 alerts through normalization, enrichment, and deterministic rule evaluation.
**Mode:** mvp
**Depends on:** Phase 1
**Requirements:** ING-01, ING-02, ING-03, ING-04, ING-05, TOP-01, TOP-02, TOP-03, TOP-04, TOP-05, TOP-06, RUL-01, RUL-02, RUL-03, RUL-04, RUL-05, RUL-06
**Success Criteria** (what must be TRUE):
  1. Icinga2 can POST validated host and service alert payloads and receive a response identifying the accepted event, fingerprint, event type, enrichment tags, matched rules, incident effects, closures, and notification count.
  2. Correlia maps Icinga2 states into stable normalized severity and PROBLEM/RECOVERY values with replay-tolerant fingerprints.
  3. Topology enrichment runs through a pluggable interface; the static YAML plugin enriches events with hostname rules before IP subnet fallback, with conflict handling and diagnostics that explain which rule affected an event.
  4. Operator-defined YAML rules load strictly, reject invalid references/placeholders/window values/actions, evaluate in deterministic priority order, and produce inspectable matches, group keys, and threshold/window decisions.
**Plans:** TBD

### Phase 3: Problem Aggregation and Notification Dispatch
**Goal:** Problem events become durable topology-aware incidents and threshold transitions dispatch through pluggable tasks/outputs.
**Mode:** mvp
**Depends on:** Phase 2
**Requirements:** AGG-01, AGG-02, AGG-03, AGG-04, AGG-05, TSK-01, TSK-02, TSK-03, NOT-01, NOT-02, NOT-03, NOT-04, NOT-05
**Success Criteria** (what must be TRUE):
  1. A PROBLEM event flows through enrichment, rule matching, group key generation, and durable incident mutation end to end.
  2. Correlia creates a new active incident for the first matching group and atomically updates the existing active incident for later events in the same group.
  3. Incident severity, last update time, event count, summary, affected hosts, and processing outcomes accurately distinguish inserted, updated, threshold-crossed, and notification-triggered decisions.
  4. Notification work is submitted only through the asyncio-backed TaskRunner after durable incident state transitions, with no repeated notification for the same durable threshold/status transition.
  5. Configured output plugins can be loaded, cached, listed, invoked through an email-style channel, and report missing plugin, missing incident, plugin exception, and notification failure cases.
**Plans:** TBD

### Phase 4: Lifecycle, Operator APIs, and Operability
**Goal:** Recovery, expiration, REST workflows, logs, readiness, metrics, and verification complete the v1 operational surface.
**Mode:** mvp
**Depends on:** Phase 3
**Requirements:** LCY-01, LCY-02, LCY-03, LCY-04, LCY-05, LCY-06, API-01, API-02, API-03, API-04, API-05, OPS-01, OPS-02, OPS-03, OPS-04
**Success Criteria** (what must be TRUE):
  1. RECOVERY events route to lifecycle resolution, resolve matching host/service incidents, and record resolution context without entering problem aggregation.
  2. Stale active incidents expire through FastAPI lifespan-managed background work when no events arrive within the configured rule window.
  3. Operators can list, filter, view, acknowledge, and manually close incidents through REST without allowing duplicate active incidents for the same rule/group.
  4. Operators can inspect loaded rules, topology summaries, plugin registry status, health, readiness, structured logs, and low-cardinality metrics without exposing secrets.
  5. Maintainer can run automated coverage for domain models, config validation, Icinga2 mapping, topology enrichment, rule evaluation, PostgreSQL upsert concurrency, notification dispatch, recovery, and expiration.
**Plans:** TBD

## Requirement Coverage

| Requirement Range | Phase |
|-------------------|-------|
| FND-01–FND-04, DOM-01–DOM-04, PRS-01–PRS-04 | Phase 1 |
| ING-01–ING-05, TOP-01–TOP-06, RUL-01–RUL-06 | Phase 2 |
| AGG-01–AGG-05, TSK-01–TSK-03, NOT-01–NOT-05 | Phase 3 |
| LCY-01–LCY-06, API-01–API-05, OPS-01–OPS-04 | Phase 4 |

**Coverage:** 57/57 v1 requirements mapped; 0 unmapped.

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundations, Contracts, and Database Invariant | 0/TBD | Not started | - |
| 2. Icinga2 Ingress, Topology, and Rule Decisions | 0/TBD | Not started | - |
| 3. Problem Aggregation and Notification Dispatch | 0/TBD | Not started | - |
| 4. Lifecycle, Operator APIs, and Operability | 0/TBD | Not started | - |

---
*Roadmap created: 2026-06-08*
*Granularity: coarse*
*Project mode: mvp*
