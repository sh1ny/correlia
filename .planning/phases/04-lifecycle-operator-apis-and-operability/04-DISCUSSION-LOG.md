# Phase 4: Lifecycle, Operator APIs, and Operability - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-09
**Phase:** 4-Lifecycle, Operator APIs, and Operability
**Areas discussed:** Recovery matching, Stale expiration, Operator REST workflows, Operability signals

---

## Recovery matching

### Which OPEN incidents may RECOVERY resolve?

| Option | Description | Selected |
|--------|-------------|----------|
| Any containing object | Resolve every OPEN incident whose affected_hosts contains the host and, for service recovery, affected_services contains that service. | ✓ |
| Same rule/group only | Only resolve incidents that match the recovered event's current rule/group evaluation. | |
| Source object only | Resolve only incidents whose group key is exactly the recovered host/service. | |

**User's choice:** Any containing object
**Notes:** Recovery matching should use affected membership already stored on incidents, not require re-derived current rule/group identity.

### Service-level recovery narrowness

| Option | Description | Selected |
|--------|-------------|----------|
| Host + service exact | Resolve incidents containing the host and recovered service; host-only incidents stay OPEN. | ✓ |
| Service across hosts | Resolve incidents containing the service name anywhere. | |
| Cascade to host incident | Resolve service-specific and host-level incidents for that host. | |

**User's choice:** Host + service exact

### Partial recovery inside grouped incidents

| Option | Description | Selected |
|--------|-------------|----------|
| Resolve whole incident | A matching recovery closes the incident immediately. | |
| Remove object then resolve if empty | Drop recovered host/service from affected sets; move to RESOLVED only when no affected objects remain. | ✓ |
| Record recovery only | Keep affected sets and OPEN status; append recovery context. | |

**User's choice:** Remove object then resolve if empty

### Resolution context

| Option | Description | Selected |
|--------|-------------|----------|
| Compact event facts | Store recovered fingerprint, source_id, host/service, recovery timestamp, prior affected counts, and reason source_recovery. | ✓ |
| Full decision trail | Also store matched recovery candidates and object-removal details. | |
| Minimal timestamps only | Set resolved_at and status only. | |

**User's choice:** Compact event facts

---

## Stale expiration

### Stale definition

| Option | Description | Selected |
|--------|-------------|----------|
| Rule window since last update | Expire when now - last_update_time > rule.window. | ✓ |
| Fixed global TTL | One configured TTL for all incidents. | |
| Window plus grace | Expire after rule.window plus a grace period. | |

**User's choice:** Rule window since last update

### Expiration clock

| Option | Description | Selected |
|--------|-------------|----------|
| Database current time | Use PostgreSQL now() against last_update_time. | ✓ |
| Application monotonic loop | Use FastAPI process clock. | |
| Source event time only | Expire only when newer source events prove the window passed. | |

**User's choice:** Database current time

### Worker model

| Option | Description | Selected |
|--------|-------------|----------|
| Single lifespan task | Start one asyncio background task from FastAPI lifespan, scan periodically, stop cleanly on shutdown. | ✓ |
| TaskRunner scheduled task | Register expiration through TaskRunner. | |
| Request-triggered cleanup | Run expiration opportunistically on ingest/API requests. | |

**User's choice:** Single lifespan task

### Expiration outcome

| Option | Description | Selected |
|--------|-------------|----------|
| CLOSED with reason expired | Move to CLOSED, set closed_at, and record compact reason/window facts. | ✓ |
| RESOLVED with reason stale | Treat expiry like resolution, set resolved_at. | |
| Leave OPEN flagged stale | Keep status OPEN with stale metadata. | |

**User's choice:** CLOSED with reason expired

---

## Operator REST workflows

### Exposure/auth assumption

| Option | Description | Selected |
|--------|-------------|----------|
| Trusted internal API | Expose endpoints without auth, assuming deployment behind trusted network/proxy. | ✓ |
| Require simple API key | Protect APIs with a configured API key. | |
| Read-only public, mutations protected | List/detail/config status open; ack/close require API key. | |

**User's choice:** Trusted internal API

### API namespace

| Option | Description | Selected |
|--------|-------------|----------|
| Root resource paths | Use /incidents, /rules, /topology, /plugins. | |
| Versioned /v1 paths | Use /v1/incidents and related endpoints. | |
| Operator prefix | Use /operator/incidents and /operator/config. | |
| Other | Free-form answer. | ✓ |

**User's choice:** Use `/v1` and move existing routes to match that.
**Notes:** Interpreted as a clean cutover to `/v1` for existing and new routes, not parallel aliases unless planning finds a hard compatibility constraint.

### Incident listing

| Option | Description | Selected |
|--------|-------------|----------|
| Cursor + common filters | Cursor pagination with filters for status, severity, rule_name, host, service, updated_since; stable last_update_time desc then id ordering. | ✓ |
| Offset + common filters | Offset/limit plus the same filters. | |
| Minimal list only | Limit/status filters only. | |

**User's choice:** Cursor + common filters

### Ack/close mutations

| Option | Description | Selected |
|--------|-------------|----------|
| Idempotent explicit mutations | POST action endpoints for ack and close; retry-tolerant state changes. | ✓ |
| PATCH incident status | One generic PATCH can acknowledge or close. | |
| Strict one-shot actions | Ack/close fail if already acknowledged or terminal. | |

**User's choice:** Idempotent explicit mutations

---

## Operability signals

### Readiness checks

| Option | Description | Selected |
|--------|-------------|----------|
| DB + config + plugins + worker | Check database connectivity, strict config load, plugin registry status, and lifecycle worker health. | ✓ |
| DB + config only | Plugin/worker issues appear in status endpoints. | |
| DB only plus details endpoint | Leave readiness simple and expose richer checks elsewhere. | |

**User's choice:** DB + config + plugins + worker

### Metrics format

| Option | Description | Selected |
|--------|-------------|----------|
| Prometheus text at /v1/metrics | Low-cardinality counters/gauges in Prometheus exposition format. | ✓ |
| JSON metrics endpoint | Return counters as JSON. | |
| Structured logs only | Skip metrics endpoint and rely on logs. | |

**User's choice:** Prometheus text at `/v1/metrics`

### Structured logging

| Option | Description | Selected |
|--------|-------------|----------|
| JSON event logs | One JSON object per significant step with event name, safe IDs/reasons, and no secrets/raw payloads. | ✓ |
| Key-value text logs | Human-readable lines with stable key=value fields. | |
| Only errors/warnings | Log failures and lifecycle transitions only. | |

**User's choice:** JSON event logs

### Config/status summaries

| Option | Description | Selected |
|--------|-------------|----------|
| Safe summaries with hashes | Expose rule names/priorities/group_by/action plugin names, topology rule ids/tag keys, plugin names/types/ready, and non-secret hashes. | ✓ |
| Names/status only | Expose only counts, names, and ready/error status. | |
| Full rendered config redacted | Return redacted YAML-derived config. | |

**User's choice:** Safe summaries with hashes

---

## Claude's Discretion

None. The user selected concrete options for every discussed area.

## Deferred Ideas

- API-key/session authentication for operator APIs — future phase if Correlia is exposed beyond a trusted internal network/proxy.
- Public internet hardening and user management — outside v1 Phase 4.
- Bidirectional Icinga2 acknowledgement/mutation — explicitly out of scope for v1.
- Reminder/escalation policy and repeated notification behavior — future notification policy work, not Phase 4 lifecycle.
- Celery/Redis scheduling or durable outbox execution — remains deferred behind existing seams.
