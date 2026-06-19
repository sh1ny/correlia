---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: Vigilo/VDE Compatibility
status: in_progress
stopped_at: Completed 08-01-PLAN.md
last_updated: "2026-06-19T09:39:25.855Z"
last_activity: 2026-06-19
progress:
  total_phases: 6
  completed_phases: 3
  total_plans: 9
  completed_plans: 7
  percent: 78
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-17)

**Core value:** Operators receive one accurate, topology-aware incident for a related alert storm instead of many disconnected raw alerts.
**Current focus:** Phase 08 — Vigilo Config Migration

## Current Position
Phase: 8
Plan: 08-02 next (08-01 complete)
Status: Plan 08-01 executed; runtime topology capture-group support complete
Last activity: 2026-06-19

### Accepted planning risks (Phase 8)

Planning for Phase 8 was accepted by explicit user override despite `## ISSUES FOUND` in the final plan check. The remaining items are carried to the executor as implementation/test-tightening work, not re-planning blockers:

- **Blocker accepted:** CFG-05 does not yet define behavior for unknown Vigilo email plugin option keys (e.g. `smtp_timeout`, `connection_pool_size`). The executor must choose either (a) reject with `unsupported_plugin_option` / `CFG-06`, or (b) explicitly document a known-set-only policy and test that unmapped keys are omitted.
- **Warning accepted:** D-13 multi-input aggregation is not pinned by a named end-to-end test. The executor should add `test_report_aggregates_issues_across_inputs_and_domains` that runs bad rules + bad topology + bad plugins together.
- **Nit accepted:** Only five non-output plugin section names have fixtures. The executor should add one fixture with an unknown sixth section name to pin the generic "any" rejection.

Progress: [████████░░] 78%

## Milestone Archive
- Roadmap archive: `.planning/milestones/v1.0-ROADMAP.md`
- Requirements archive: `.planning/milestones/v1.0-REQUIREMENTS.md`
- Milestone summary: `.planning/MILESTONES.md`
- Retrospective: `.planning/RETROSPECTIVE.md`

## Accumulated Context

### Decisions

Decisions are logged in `.planning/PROJECT.md` Key Decisions table. v1.0 validated:

- API-first backend with no built-in frontend.
- Icinga2 as first input plugin behind plugin-agnostic normalization.
- PostgreSQL partial unique index and atomic upsert as incident correctness boundary.
- Static YAML topology enrichment behind a plugin seam.
- YAML rules, topology, and plugin registry as trusted operator configuration.
- Asyncio `TaskRunner` as v1 implementation with future Celery/Redis cutover seam.
- Trusted internal `/v1` operator API with cursor-based listing and idempotent ack/close actions.

v1.1 roadmap decisions:

- Compatibility mutates canonical `/v1/incidents`; no `/api/v1/incidents` facade is planned.
- Webhook endpoint compatibility remains explicitly out of scope.
- Correlia's stricter incident lifecycle, validation, and rich incident fields stay authoritative.
- Summary mutation returns `422` unless a future audited domain model exists.
- Container runtime defaults to one Uvicorn worker until durable queue or leader election exists.
- [Phase ?]: Applied token dependency at the route level for /v1/readyz so /v1/health stays public even when readyz is protected. — D-01 requires /v1/health to remain public; router-level dependencies would have made it protected when readyz was protected.
- [Phase ?]: Used router-level Security(require_operator_token) for operator surfaces and Security(require_ingress_token) for /v1/icinga2/events. — Keeps token classes separate per D-05 and makes route intent explicit.
- [Phase ?]: Kept auth disable as an explicit setting (api_auth_enabled) rather than an environment-specific bypass. — Satisfies D-09 fail-fast requirement with no local/test/development bypass.
- [Phase ?]: Size limiter is installed outermost so oversized requests are rejected before the rate limiter counts them.
- [Phase ?]: Rate-limit identity uses SHA-256 hashed Bearer token first, then remote IP, with no raw token in logs or limiter keys.
- [Phase ?]: Extended SAFE_LOG_KEYS with route_class, identity_hash, content_length, retry_after, limit, and window_seconds for safe control-event logging.
- [Phase 7]: Moved commit ownership from IncidentManager.apply_problem and LifecycleManager.resolve_for_event to Icinga2DecisionProcessor.process_payload (D-01/D-02). Managers return commit-free result objects with notification_intent; ingress inserts the audit row and commits once.
- [Phase 7]: Audit rows record notification_intent only; actual plugin delivery results stay out of the append-only incident_events table (D-03). Notification submission runs after the incident/audit commit.
- [Phase 7]: Audit router uses idempotent redact_normalized_event_message_tags call in _audit_event_response, try/except ValueError for invalid cursors (400), and ValidationError-to-HTTPException(422) conversion for strict filter construction. Route classified as operator in ROUTE_CLASS_PREFIXES (D-16).
- [Phase 08]: tag_capture_groups is a strict dict[str, int] with Field(default_factory=dict), so existing literal-only topology YAML remains valid. — Decision recorded during execution of 08-01-PLAN.md.
- [Phase 08]: Derived capture-group tags are applied after literal tags; a derived value that overrides a literal value updates tags_added to the final captured value and records literal->derived in conflicts. — Decision recorded during execution of 08-01-PLAN.md.
- [Phase 08]: Subnet topology rules intentionally reject tag_capture_groups via Pydantic extra=forbid, preserving D-11 literal-only semantics. — Decision recorded during execution of 08-01-PLAN.md.

### Deferred Items

Items acknowledged and carried forward from milestone close:

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

### Future Milestone Seeds

- Prometheus Alertmanager and additional input plugins.
- Durable broker-backed task runner/outbox retries.
- API-managed suppressions, silences, maintenance windows, dry-run, and config reload.
- Additional output plugins beyond SMTP email.
- AI-driven topology enrichment and root-cause assistance after deterministic history matures.

## Session Continuity

**Resume file:** None

Last session: 2026-06-19T09:38:57.876Z
Stopped at: Completed 08-01-PLAN.md
Resume: Phase 7 complete — begin Phase 8 (Vigilo Config Migration) when ready

## Performance Metrics

| Phase | Plan | Duration | Notes |
|-------|------|----------|-------|
| Phase 05-security-and-http-controls P01 | 19min | 2 tasks | 18 files |
| Phase 05-security-and-http-controls P02 | 15min | 2 tasks | 9 files |
| Phase 07-incident-event-audit-trail P02 | 60min | 3 tasks | 10 files |
| Phase 07-incident-event-audit-trail P03 | 28min | 3 tasks | 6 files |
| Phase 08 P01 | 30min | 3 tasks | 3 files |
