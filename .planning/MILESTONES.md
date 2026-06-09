# Milestones

## v1.0 MVP (Shipped: 2026-06-09)

**Phases completed:** 4 phases, 16 plans, 34 tasks

**Key accomplishments:**

- Python 3.14 uv environment with strict startup settings and reusable async PostgreSQL readiness helpers.
- Strict Pydantic domain contracts for normalized alerts, severity ranking, incident lifecycle, acknowledgement metadata, and bounded decision context.
- Alembic async migration environment, PostgreSQL incidents table with JSONB metadata and a partial unique index enforcing one OPEN incident per rule/group, and Testcontainers-backed schema verification.
- PostgreSQL atomic upsert repository for open incidents with max severity, bounded JSONB set merge, and Testcontainers-backed security verification.
- FastAPI app factory with separate `/health` liveness and sanitized `/readyz` database readiness routes.
- Icinga2 webhook endpoint with strict payload validation, deterministic state mapping, replay-tolerant fingerprints, and a typed no-op decision envelope.
- Static YAML topology enrichment with strict validation, hostname/IP subnet matching, reserved-namespace conflict resolution, and plugin-protocol isolation behind the Icinga2 ingress pipeline.
- Strict YAML rule loading with semantic validation, deterministic priority-ordered first-match-wins evaluation, human-readable collision-resistant group keys, and inspectable in-memory threshold/window decisions wired into the Icinga2 ingress response envelope.
- PostgreSQL-backed incident aggregation with bounded fingerprint windows, replay-safe event counts, first threshold transition detection, and compact safe manager outcomes.
- Named asyncio task execution plus trusted YAML-loaded output plugins, including aiosmtplib SMTP delivery compatible with Mailpit.
- Icinga2 PROBLEM events now become durable PostgreSQL incidents and submit configured notification work through TaskRunner after commit, with safe failure recording and plugin status listing.
- PostgreSQL-backed recovery, acknowledgement, and manual-close lifecycle mutations with RECOVERY ingress routing that bypasses problem aggregation and notification dispatch.
- PostgreSQL-time stale incident expiration with a FastAPI lifespan-owned worker and readiness-safe health seam.
- Trusted internal /v1 operator REST APIs for incident inspection/mutation plus safe rule, topology, plugin, health, readiness, and ingress route cutover.
- Approved prometheus-client metrics surface with /v1/metrics and low-cardinality instrumentation across ingress, lifecycle, notification, task, and worker seams.
- Safe JSON event logging plus expanded /v1/readyz dependency checks and explicit Phase 04 targeted verification readiness.

---
