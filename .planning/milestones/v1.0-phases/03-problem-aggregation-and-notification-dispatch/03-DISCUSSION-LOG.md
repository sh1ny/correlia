# Phase 3: Problem Aggregation and Notification Dispatch - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-08
**Phase:** 3-Problem Aggregation and Notification Dispatch
**Areas discussed:** Durable threshold transition, TaskRunner and output boundary, Processing outcome envelope, Aggregation state source

---

## Durable threshold transition

### When does a rule/group count as threshold-crossed for durable behavior?

| Option | Description | Selected |
|--------|-------------|----------|
| First crossing only | Only the transition from below threshold to crossed triggers durable notification behavior for the current open incident. Later events update the incident only. | ✓ |
| Every crossing window | Each event-time window that reaches threshold can trigger again if the counted set changes enough. | |
| Every crossed event | Once crossed, every later event in the group can trigger notification work. | |
| You decide | Default to the safest behavior for v1 based on the existing dedupe and incident identity decisions. | |

**User's choice:** First crossing only
**Notes:** Locks notification dispatch to a durable transition, not repeated event processing.

### Where should notification submission sit relative to incident persistence?

| Option | Description | Selected |
|--------|-------------|----------|
| After durable write | Commit/flush the incident mutation first, then submit notification work through TaskRunner using the durable incident id and transition facts. | ✓ |
| Same processor before commit | Build and submit notification work while still processing the event, before durability is guaranteed. | |
| You decide | Use the project’s concurrency-first constraints to pick the safest boundary. | |

**User's choice:** After durable write
**Notes:** Preserves PostgreSQL as the source of truth before side effects.

### While the same incident stays OPEN, should any later condition trigger another notification?

| Option | Description | Selected |
|--------|-------------|----------|
| No repeats | One notification-triggering threshold transition per open incident/rule/group. Severity and affected hosts still update the incident. | ✓ |
| Severity escalation only | Initial threshold crossing notifies; later max-severity escalation can notify again. | |
| Periodic reminders | Allow repeat notifications while the incident remains open, based on window/elapsed time. This starts to resemble escalation policy. | |
| You decide | Default to the smallest v1 behavior that satisfies NOT-05. | |

**User's choice:** No repeats
**Notes:** Severity escalation and reminders are not v1 notification triggers.

### What durable fact should downstream planners preserve to prevent repeated notifications?

| Option | Description | Selected |
|--------|-------------|----------|
| Incident transition marker | Store notification-triggered/threshold-crossed facts on incident-side decision metadata or dedicated incident columns; no separate durable outbox in v1. | ✓ |
| Notification attempt log | Add a durable notification-attempt record keyed by incident/rule/group/transition before dispatch. | |
| Output plugin decides | Let each output plugin dedupe its own sends; core only submits tasks. | |
| You decide | Choose the minimal durable marker compatible with PostgreSQL-owned correctness. | |

**User's choice:** Incident transition marker
**Notes:** Dedupe remains a core durable incident fact, not plugin-specific behavior.

---

## TaskRunner and output boundary

### For v1 asyncio TaskRunner, how should notification work execute?

| Option | Description | Selected |
|--------|-------------|----------|
| Async in-process runner | TaskRunner is the only submission API; v1 implementation schedules/awaits in-process asyncio work with deterministic test hooks. No Celery/Redis. | ✓ |
| Fire-and-forget background | TaskRunner schedules background tasks and returns immediately; failures surface later through task health/logs. | |
| Inline direct call | Processor calls the output plugin directly and TaskRunner is only a future seam. | |
| You decide | Use the smallest runner that preserves the Celery cutover path. | |

**User's choice:** Async in-process runner
**Notes:** v1 remains asyncio but must use the runner seam.

### How should configured output plugins be represented in v1?

| Option | Description | Selected |
|--------|-------------|----------|
| Named registry from YAML | Load trusted Python output plugin classes from the existing plugins_path config; cache by plugin name and expose safe status/listing. | ✓ |
| Hardcoded default only | Ship one built-in output plugin and defer YAML registry until later. | |
| Dynamic arbitrary import strings | YAML names import paths directly and the loader imports whatever config says. | |
| You decide | Pick the registry shape that matches Phase 2 rule action validation. | |

**User's choice:** Named registry from YAML
**Notes:** Must remain declarative/trusted; YAML is not executable plugin code.

### Which Docker/open-source mail target should Phase 3 optimize the v1 email-style output around?

| Option | Description | Selected |
|--------|-------------|----------|
| Mailpit SMTP | Use Mailpit as the recommended Docker dev/test target. Implement a generic SMTP/email-envelope output plugin so production can point at Mailu or any SMTP relay later. | ✓ |
| Postal HTTP API | Implement a Postal-style JSON HTTP output plugin for programmable production sending. More modern/programmable, but adds HTTP auth/API semantics to Phase 3. | |
| Mailu SMTP | Treat Mailu as the recommended self-hosted production SMTP server. Correlia still just speaks SMTP; Mailu setup/DNS/TLS remains external. | |
| You decide | Choose the smallest v1 target that proves notification dispatch without over-scoping the phase. | |

**User's choice:** Mailpit SMTP
**Notes:** User asked whether Mailu or another Docker-based modern programmable option should be researched. Sources checked: Mailpit docs, Mailu docs, Postal API docs. Decision: optimize v1 around Mailpit SMTP while preserving generic SMTP output.

### If TaskRunner/output dispatch fails after the incident is durable, what should happen to the incident path?

| Option | Description | Selected |
|--------|-------------|----------|
| Record failure, keep incident | Do not roll back the incident. Return/record notification failure details and keep the durable incident mutation as source of truth. | ✓ |
| Rollback incident mutation | Undo or fail the incident update if notification dispatch fails. | |
| Silent retry later | Do not expose failure in the response; rely on background retry/health later. | |
| You decide | Pick the behavior that preserves incident correctness first. | |

**User's choice:** Record failure, keep incident
**Notes:** Incident correctness is independent of output transport success.

---

## Processing outcome envelope

### What should the Phase 3 ingest response add once incident mutation is real?

| Option | Description | Selected |
|--------|-------------|----------|
| Compact incident result | Add incident id, inserted/updated flag, status, threshold_crossed, notification_submitted/failed counts, and bounded failure reasons. Keep raw payloads out. | ✓ |
| Full incident snapshot | Return the complete incident record after every accepted event. | |
| Minimal counts only | Keep only inserted/updated/notification counts and require clients to fetch details later. | |
| You decide | Preserve Phase 2 envelope style and operator inspectability. | |

**User's choice:** Compact incident result
**Notes:** Keep response inspectable but not full incident-detail API.

### What should be stored in incident decision_context for Phase 3?

| Option | Description | Selected |
|--------|-------------|----------|
| Bounded processing facts | Store fingerprint, source id, matched rule/group, threshold transition, counted event facts, output action names, plugin names/status, config hash; no raw payload or secrets. | ✓ |
| Full event and notification payload | Store raw normalized event plus rendered email/output payload for replay/debugging. | |
| Only rule/group metadata | Keep decision_context very small; omit threshold and output facts. | |
| You decide | Follow Phase 1 compact non-secret metadata decision. | |

**User's choice:** Bounded processing facts
**Notes:** Extends Phase 1 compact non-secret metadata decision.

### How much notification failure detail should responses expose?

| Option | Description | Selected |
|--------|-------------|----------|
| Typed safe failure codes | Expose categories like missing_plugin, missing_incident, plugin_exception, dispatch_failed plus safe messages. Never expose secrets/config/raw SMTP transcript. | ✓ |
| Full exception details | Return exception repr/stack traces to clients for easy debugging. | |
| Boolean failed only | Only expose notification_failed true/false; details go to logs later. | |
| You decide | Balance operator debugging with no secret leakage. | |

**User's choice:** Typed safe failure codes
**Notes:** No secrets or stack traces in API response.

### For accepted PROBLEM events that update an incident but do not trigger notification, how should the response read?

| Option | Description | Selected |
|--------|-------------|----------|
| Explicit no-dispatch outcome | Return updated incident effect plus threshold_crossed=false or notification_triggered=false with a reason such as already_notified, below_threshold, or replay. | ✓ |
| Silent zero count | Only notification_count=0; clients infer why from threshold_decision. | |
| Treat as no-op | Return no incident effect unless notification triggers. | |
| You decide | Make debugging threshold and dedupe behavior inspectable. | |

**User's choice:** Explicit no-dispatch outcome
**Notes:** Useful for operator debugging and test assertions.

---

## Aggregation state source

### Should threshold/window counting survive process restarts in v1?

| Option | Description | Selected |
|--------|-------------|----------|
| Durable bounded window state | Persist enough bounded fingerprint+event-time state per rule/group/open incident to evaluate thresholds across restarts without raw payload storage. | ✓ |
| Separate aggregation table | Create a dedicated durable window/fingerprint table keyed by rule_name+group_key for threshold math. | |
| In-memory only | Keep Phase 2 in-memory threshold state; restarts can lose pre-threshold counts in v1. | |
| You decide | Choose the smallest state source that keeps notifications trustworthy. | |

**User's choice:** Durable bounded window state
**Notes:** Restart-safe threshold decisions are required for v1 trustworthiness.

### How should replayed fingerprints affect incident event_count and affected sets?

| Option | Description | Selected |
|--------|-------------|----------|
| Unique fingerprints only | A replay already counted in the current open incident/window does not increment event_count or trigger notification; affected sets stay deterministic. | ✓ |
| Every accepted delivery | Every valid delivery increments event_count even if fingerprint was already seen. | |
| Threshold unique, incident total | Threshold dedupes fingerprints, but incident event_count counts all deliveries. | |
| You decide | Keep replay tolerance aligned across threshold and incident state. | |

**User's choice:** Unique fingerprints only
**Notes:** Aligns incident count with replay-tolerant threshold counting.

### What should be atomic in one PostgreSQL transaction?

| Option | Description | Selected |
|--------|-------------|----------|
| State plus marker | Threshold/window state update, incident insert/update, and notification-triggered marker are atomic; TaskRunner submission happens after durable write. | ✓ |
| Incident only | Only incident upsert is atomic; threshold/window and notification markers can be best-effort. | |
| Include dispatch | Hold the DB transaction open through TaskRunner/output dispatch. | |
| You decide | Preserve DB-owned correctness without blocking on output plugins. | |

**User's choice:** State plus marker
**Notes:** Side effects stay outside the DB transaction.

### How should out-of-order or older PROBLEM events affect an OPEN incident?

| Option | Description | Selected |
|--------|-------------|----------|
| Use event time, bounded update | Use NormalizedEvent.timestamp for window membership; last_update_time never moves backward; older events can count only if inside the current window and not replayed. | ✓ |
| Reject older events | Reject any event older than the incident last_update_time. | |
| Processing time wins | Ignore source event time for aggregation and use receipt time for all windows/updates. | |
| You decide | Stay consistent with Phase 2 event-time windows and Phase 1 timestamp invariants. | |

**User's choice:** Use event time, bounded update
**Notes:** Maintains event-time semantics while protecting incident timestamps.

---

## Claude's Discretion

None. The user selected explicit options for all discussed areas.

## Deferred Ideas

- Postal HTTP API output plugin — future programmable production mail output.
- Mailu deployment guidance — external mail infrastructure docs, not Correlia v1 implementation.
- Celery/Redis runner — future `TaskRunner` implementation.
- Periodic reminders/escalation policy — future notification behavior beyond one durable threshold transition.
