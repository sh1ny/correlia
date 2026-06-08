# Pitfalls Research

**Domain:** API-first alert aggregation, event correlation, and incident management backend
**Project:** Vigilo
**Researched:** 2026-06-08
**Confidence:** HIGH for PostgreSQL concurrency, Icinga2 state mapping, YAML/Pydantic validation, Alertmanager-style grouping concepts, and SRE alerting principles; MEDIUM for Vigilo-specific phase ordering because implementation has not started.

## Critical Pitfalls

### Pitfall 1: Duplicate Open Incidents Under Concurrent Alert Bursts

**What goes wrong:**
Two or more workers ingest matching PROBLEM events at the same time and create multiple `OPEN` incidents for the same `(rule_name, group_key)`. The product promise fails: operators see several incidents for one failure domain, recoveries may close only one, and notifications can fan out from each duplicate.

**Why it happens:**
Developers implement incident aggregation as `SELECT open incident -> if none INSERT -> else UPDATE`, or rely on in-process locks that only protect one process. The race is rare in local testing but common during real outages, when the same rule receives concurrent events.

**How to avoid:**
- Make PostgreSQL the source of truth: partial unique index on `(rule_name, group_key) WHERE status = 'OPEN'`.
- Use one atomic PostgreSQL `INSERT ... ON CONFLICT ... DO UPDATE` statement for open incident creation/update.
- Target the partial unique index predicate explicitly from SQLAlchemy's PostgreSQL insert API; do not hide this behind a generic repository method that cannot express `index_where`.
- Return the updated incident row from the upsert and compute notification threshold-crossing from old/new values in the same transaction.
- Treat duplicate-key errors around this path as bugs, not as retryable normal behavior.

**Warning signs:**
- Code path contains `select(Incident).where(status == OPEN)` followed by conditional `session.add()`.
- Unit tests pass but no test exercises two concurrent events for the same group.
- Incident list shows repeated `OPEN` rows with the same rule/group and near-identical timestamps.
- Notifications include different incident IDs for the same burst.

**Phase to address:**
Phase 1 defines the model/index; Phase 4 implements and verifies the atomic upsert before any notification fan-out depends on it.

---

### Pitfall 2: Noisy or Over-Broad Grouping Rules Hide the Real Failure

**What goes wrong:**
Grouping collapses unrelated alerts into one vague incident (`prod` or `datacenter:london` for everything), or fails to group related alerts because the key is too specific (`host+service+fingerprint`). Operators either receive one useless mega-incident or hundreds of single-host incidents.

**Why it happens:**
Rules are written from data availability rather than operator actionability. Wildcards and topology tags look convenient, but grouping semantics are product behavior, not just query filters. Alertmanager exists largely because deduplication, grouping, routing, silencing, and inhibition need deliberate semantics.

**How to avoid:**
- Require every rule to declare `group_by`, `trigger_threshold`, and `window.duration_seconds` explicitly.
- Normalize group keys deterministically from validated fields/tags; include field names in key segments (`datacenter=lon`, not just `lon`).
- Sort rules by priority and stop or annotate processing decisions so overlapping rules are visible.
- Start with two boring rule families: topology-level outage aggregation and single-host/service deduplication.
- Add a dry-run/evaluation API that shows matched rules, group key, threshold state, and suppression/dispatch decision for a sample event.

**Warning signs:**
- Rules use `tags: {datacenter: "*"}` without a threshold/window tuned to that failure domain.
- Operators cannot predict which incident an event will join.
- `affected_hosts` grows without bound for one incident while the summary remains generic.
- Frequent manual incident splits/closures after an outage.

**Phase to address:**
Phase 4 rule engine and grouping; expose rule-evaluation diagnostics before Phase 5 notification dispatch.

---

### Pitfall 3: Recovery Semantics Are Treated as “Just Another OK Event”

**What goes wrong:**
OK/UP events either create new incidents, are ignored, or resolve the wrong incident. Open incidents stay open after services recover, stale incidents expire as `CLOSED` instead of `RESOLVED`, and operators lose trust in incident lifecycle state.

**Why it happens:**
Input plugins map source severities but not source semantics. Icinga2 has host and service states plus hard/soft state behavior; future systems such as Alertmanager send `firing`/`resolved` semantics and expect clients to resend resolved alerts for a period. A plain severity field is insufficient for lifecycle decisions.

**How to avoid:**
- Make `event_type: PROBLEM | RECOVERY` mandatory in `NormalizedEvent` from Phase 1.
- Keep source-specific state mapping inside input plugins; core processing must branch on `event_type`, not on raw Icinga fields.
- Match recoveries using stable identity: `source_id`, `host`, optional `service`, and incident membership (`affected_hosts` plus group key/rule metadata).
- Define host-level recovery separately from service-level recovery.
- Emit recovery processing result counts (`incidents_closed`) and optional recovery notifications with clear status transitions.

**Warning signs:**
- `severity == "OK"` appears inside the core incident upsert path.
- Recovery tests only cover a single-host incident and not topology-level incidents with multiple affected hosts.
- Incidents remain `OPEN` until expiration even after OK webhook payloads arrive.
- Recovery notification references a different incident than the original problem notification.

**Phase to address:**
Phase 1 model, Phase 2 Icinga2 mapping, Phase 6 lifecycle management.

---

### Pitfall 4: Topology Enrichment Misclassifies Hosts and Corrupts Grouping

**What goes wrong:**
Hostname regexes or IP subnet fallbacks assign the wrong datacenter/environment. Events aggregate into the wrong topology incident, leading operators to inspect the wrong failure domain. This is worse than missing enrichment because it gives confident but false context.

**Why it happens:**
Topology rules are easy to express but hard to reason about at scale: regex precedence, overlapping CIDRs, stale naming conventions, and pre-existing tags compete. The Vigilo design says hostname pattern matching wins over IP subnet fallback; violating or obscuring that rule creates inconsistent group keys.

**How to avoid:**
- Enforce deterministic precedence: existing trusted event tags, then hostname pattern rules in configured order, then IP subnet fallback, with explicit conflict behavior.
- Validate topology config for overlapping CIDRs, duplicate target tags, invalid regexes, unreachable rules, and ambiguous captures.
- Store enrichment provenance with the event or processing result (`tag`, `value`, `rule_name`, `source=hostname|ip|input`).
- Provide a topology dry-run endpoint/CLI for host/IP examples before config rollout.
- Prefer anchored regexes with named captures; reject broad unanchored patterns for production topology rules.

**Warning signs:**
- Topology code loops through dictionaries where order is implicit or undocumented.
- A host changes datacenter depending on whether `ip_address` is present.
- Rule summaries say `Datacenter unknown` for many production hosts.
- Operators frequently override topology in rules rather than fixing topology data.

**Phase to address:**
Phase 2 enrichment; Phase 4 grouping depends on this being stable.

---

### Pitfall 5: Plugin Boundary Leakage Turns the Core Into an Icinga2-Specific System

**What goes wrong:**
Core models, rule matching, incident updates, or notification code start depending on raw Icinga2 object names, state numbers, or payload structure. Adding Prometheus Alertmanager or another input later requires rewriting the processor instead of adding a plugin.

**Why it happens:**
The first concrete integration is always tempting to treat as the canonical model. Icinga2 has useful concepts (host/service, hard/soft state, check attempts) that can leak through if the plugin contract is not strict.

**How to avoid:**
- Core accepts only `NormalizedEvent`; input plugins own parsing, source validation, event type derivation, fingerprinting, and source-specific defaults.
- Preserve source-specific payloads only in optional raw-event/audit storage, not in incident logic.
- Define plugin contracts around semantic fields and capability flags, not inheritance from a shared concrete Icinga class.
- Keep output plugins behind a small `send_notification(incident, config)` contract; no output plugin should query input payloads.
- Version plugin payload/config contracts early and fail startup on incompatible plugins.

**Warning signs:**
- Core code branches on `check_result`, `state_type`, `host_state`, or Icinga numeric state.
- Rules refer to `icinga_*` fields instead of normalized tags/severity/source/host/service.
- Output messages require the raw webhook payload to format a useful incident.
- A mock second input plugin cannot generate a full incident without adding core conditionals.

**Phase to address:**
Phase 1 interfaces/models, Phase 2 Icinga2 plugin, Phase 3 plugin loader/task runner.

---

### Pitfall 6: Notification Storms From Threshold Re-Evaluation and Retry Loops

**What goes wrong:**
Every event after a threshold crossing sends another notification, or each output retry sends duplicate pages/emails. During a regional outage, Vigilo amplifies the alert storm it was built to reduce.

**Why it happens:**
Notification dispatch is treated as a side effect of “incident updated” rather than a state transition. Without a durable notification ledger or threshold-crossing marker, workers cannot distinguish first crossing from repeated updates. Output plugin failures can also trigger naive retry loops.

**How to avoid:**
- Trigger notifications only on durable transitions: threshold not met -> met, status change to RESOLVED/CLOSED, or configured reminder interval.
- Store notification attempts/results with `incident_id`, action/plugin, trigger reason, idempotency key, attempt count, and timestamps.
- Rate-limit per incident, per rule, and per output channel; make suppression visible in processing results.
- Use idempotency keys for output plugins where possible and deterministic message IDs for email-like outputs.
- Separate dispatch from incident transaction but persist the intent before submitting async work.

**Warning signs:**
- Dispatcher is called unconditionally after every upsert.
- Retrying a failed output task has no attempt record.
- Notification count is proportional to raw event count after threshold crossing.
- Operators receive multiple messages with identical summary but different send timestamps.

**Phase to address:**
Phase 4 computes threshold transitions; Phase 5 implements dispatcher idempotency and attempt audit.

---

### Pitfall 7: Fragile YAML Configuration Accepts Invalid or Dangerous Rules

**What goes wrong:**
A syntactically valid YAML file loads but changes behavior unexpectedly: strings become booleans, thresholds are strings, wildcard matches are too broad, actions reference missing plugins, regexes fail at runtime, or a bad config takes down ingestion. If unsafe YAML loading is used, config can construct arbitrary Python objects.

**Why it happens:**
YAML syntax validation is mistaken for semantic validation. PyYAML explicitly warns that `yaml.load` is unsafe for untrusted data and can construct arbitrary Python objects. Pydantic defaults can coerce values unless strict mode is enabled; this is useful for HTTP inputs but dangerous for rule/config contracts where `"5"` should not silently become `5`.

**How to avoid:**
- Use `yaml.safe_load` only, then validate into Pydantic v2 config models with strict fields where ambiguity is dangerous.
- Validate cross-references: rule actions must exist in `plugins.yaml`; topology target tags must match rule tag names; group_by fields must exist in `NormalizedEvent` or tags.
- Compile regexes and CIDRs at config load, not at event time.
- Fail startup on invalid mandatory config; for future hot reload, keep the last known-good config and reject bad reloads atomically.
- Emit human-readable validation errors with rule name/path and remediation.

**Warning signs:**
- Config loader returns raw dictionaries to the rule engine.
- Missing `actions` or bad plugin names fail only when an incident crosses threshold.
- YAML booleans/strings cause surprising behavior (`on`, `off`, `yes`, `no`, `300s`).
- Config reload can partially update rules, topology, and plugins independently.

**Phase to address:**
Phase 2 topology loader, Phase 3 plugin registry, Phase 4 rule parser; validation should precede runtime processing.

---

### Pitfall 8: Async Task Failures Disappear After Ingress Returns 202/200

**What goes wrong:**
The API accepts an event, returns success, and then notification or expiration work fails in a background task with no durable record. Operators see missing notifications or stale incidents but the ingress logs look healthy.

**Why it happens:**
`asyncio.create_task` schedules work but does not make it durable. Unawaited or untracked tasks can fail after the request scope is gone; cancellation during shutdown can drop work. FastAPI lifespan is the right place for long-lived startup/shutdown resources, but it does not make task execution reliable by itself.

**How to avoid:**
- Route all background work through `TaskRunner`; never call `asyncio.create_task` from core business logic except inside the runner.
- Persist task intent or notification attempt before dispatch when losing the task would affect operator behavior.
- Track task handles, attach done callbacks that record exceptions, and drain/cancel predictably during FastAPI lifespan shutdown.
- Make runner behavior explicit: `await inline` for critical synchronous processing, `submit durable-ish` for notifications with attempt logging, later replaceable by Celery/Redis.
- Expose task queue/running/failed counters and last error by task name.

**Warning signs:**
- `create_task` appears outside the runner.
- Logs show “Task exception was never retrieved”.
- Ingress response says `notifications_triggered: 1`, but there is no send attempt record.
- Shutdown loses expiration or notification tasks without marking them failed/cancelled.

**Phase to address:**
Phase 3 task runner abstraction; Phase 5 dispatcher; Phase 6 expiration lifecycle.

---

### Pitfall 9: Missing Auditability Makes Incident Behavior Unexplainable

**What goes wrong:**
After an outage, nobody can answer why an event matched a rule, why it grouped into a specific incident, why a notification was or was not sent, who changed the config, or which recovery closed the incident. Debugging depends on transient logs that may have rotated away.

**Why it happens:**
Aggregation systems compress many raw events into fewer incidents. Without preserving decision provenance, the compression destroys the evidence needed to trust and improve the rules. Configuration systems also need ownership, versioning, and change tracking because config changes can dramatically alter production behavior.

**How to avoid:**
- Store processing audit records for material decisions: normalized event fingerprint, enrichment outputs, matched/skipped rules with reasons, group key, incident transition, threshold transition, notification intent/result.
- Keep raw events optional/rotated, but preserve enough normalized event and decision metadata to explain every incident.
- Include config version/hash in processing results and incidents.
- Record manual status changes separately from automatic recovery/expiration.
- Expose incident timeline via REST API: event count, affected hosts, lifecycle transitions, notifications, recoveries, and expiration.

**Warning signs:**
- Incident table contains only current status/summary and no transition history.
- Operators ask “why did this page?” and answer requires reading application logs across multiple pods.
- Config changes are not tied to incident behavior.
- Recovery/expiration overwrites summary text instead of appending structured transition metadata.

**Phase to address:**
Phase 1 schema, Phase 4 processing decisions, Phase 5 notification attempts, Phase 6 lifecycle transitions.

---

### Pitfall 10: Operational Blind Spots in the Aggregator Itself

**What goes wrong:**
Vigilo becomes a critical alerting dependency but has no clear health surface. Ingestion latency rises, DB upserts block, task failures accumulate, config reload fails, or expiration stops running — and nobody notices until alerts are missing or storms reappear.

**Why it happens:**
Alerting systems are often treated as infrastructure glue, not as production systems needing their own observability. Google SRE guidance emphasizes latency, traffic, errors, and saturation as core monitoring signals; Vigilo has domain-specific versions of all four.

**How to avoid:**
- Expose health/readiness endpoints that check database connectivity, loaded config version, plugin registry status, and task runner status.
- Emit metrics/logs for ingestion rate, parse failures, normalization failures, enrichment misses, rule-match counts, upsert latency/conflicts, notification attempts/failures/suppression, recovery count, expiration count, and task failures.
- Add dead-letter/audit path for rejected payloads and failed notifications.
- Distinguish user-caused bad input from system errors in API responses and metrics.
- Keep alerting on Vigilo itself simple and actionable: failed ingestion, rising notification failures, DB saturation, stalled lifecycle runner.

**Warning signs:**
- Only web-server HTTP 200/500 counts are observable.
- No metric separates “accepted webhook” from “incident updated” from “notification sent”.
- Config load errors appear only at startup logs.
- Expiration task can stop without any status endpoint changing.

**Phase to address:**
Phase 1 health skeleton, Phase 2 ingress/enrichment counters, Phase 4 DB/rule metrics, Phase 5 notification metrics, Phase 6 lifecycle metrics.

## Moderate Pitfalls

### Partial Unique Index Predicate Drift

**What goes wrong:** SQLAlchemy upsert target, migration index predicate, and status enum values drift apart; conflict inference fails or updates the wrong uniqueness scope.

**Prevention:** Define the open-incident index once in migration/model conventions, name it clearly, and keep a focused concurrency test/spec for `(rule_name, group_key, status=OPEN)` only. Treat status enum string changes as migrations.

**Warning signs:** `ON CONFLICT` uses only column names with no predicate; migration has `status = 'open'` while model uses `OPEN`; duplicate closed/resolved incidents are impossible because uniqueness is global.

**Phase mapping:** Phase 1 schema and Phase 4 upsert.

### `affected_hosts` Grows Without Bound or Loses Uniqueness

**What goes wrong:** Large topology incidents update a JSONB list on every event, causing write amplification and duplicate hosts; summaries and API responses become slow.

**Prevention:** Store unique hosts deterministically; cap displayed host lists; consider a child table for incident-event/host membership if JSONB updates become hot.

**Warning signs:** JSONB array length far exceeds unique hosts; incident update latency grows with event count; summaries truncate randomly.

**Phase mapping:** Phase 4 state management; revisit before high-volume deployment.

### Expiration Closes Incidents Still Receiving Late Events

**What goes wrong:** Clock skew, stale timestamps, or ingestion delays close an incident while related events are still in flight; the next event opens a new incident and splits one outage.

**Prevention:** Use server-side `last_update_time` for expiration decisions; define event timestamp separately from processing timestamp; make expiration query atomic and conservative.

**Warning signs:** Incidents close and reopen with same group key within one window; expiration logs cluster around DB latency or deployment restarts.

**Phase mapping:** Phase 6 lifecycle.

### Acknowledgement Semantics Fight Automatic Recovery

**What goes wrong:** An `ACKNOWLEDGED` incident either stops aggregating new events or cannot be auto-resolved, creating inconsistent lifecycle behavior.

**Prevention:** Define whether acknowledgement is an overlay on active incident state or a separate status. If status enum remains single-valued, explicitly allow recovery from `ACKNOWLEDGED` and decide whether upsert targets `OPEN` only or active statuses.

**Warning signs:** Acknowledged incidents stop updating `last_update_time`; OK events close open incidents but leave acknowledged incidents active.

**Phase mapping:** Phase 6 lifecycle; model implication should be considered in Phase 1.

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| In-memory incident cache/lock | Fast local prototype | Duplicate incidents across processes; lost state on restart | Never for authoritative incident state |
| Raw dict configs after YAML load | Quick parser | Runtime surprises, poor errors, unsafe cross-references | Never beyond a throwaway spike |
| Icinga fields in core rules | Faster first integration | Blocks future plugin support | Never; normalize in plugin |
| Fire-and-forget notifications | Simple dispatch | Silent loss and duplicate retries | Only if send attempt is durably/auditably recorded first |
| Summary-only incident history | Smaller schema | Cannot explain decisions or recover from bugs | Never for lifecycle/notification transitions |
| Broad wildcard grouping | Easy demo aggregation | Hides unrelated incidents and creates operator distrust | Only in dry-run examples |
| Expiration loop scans all incidents | Simple lifecycle | DB load grows with incident history | Acceptable in v1 only if filtered to active statuses and measured |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Icinga2 | Treat numeric service and host states identically | Map host/service states in the Icinga plugin to normalized severity and `EventType`; respect host/service distinction |
| Icinga2 | Process SOFT states as operator-worthy problems | Decide explicitly whether v1 accepts only HARD states or tags SOFT states; avoid paging on transient retries by default |
| PostgreSQL | Use generic ORM merge/select-insert | Use PostgreSQL dialect `insert().on_conflict_do_update()` against the partial unique index |
| PostgreSQL | Global uniqueness on `(rule_name, group_key)` | Partial uniqueness only for active/open scope so historical resolved/closed incidents can coexist |
| PyYAML | Use `yaml.load` or trust syntax-only validation | Use `safe_load` plus strict Pydantic semantic models |
| FastAPI/asyncio | Start background lifecycle loops outside lifespan | Start/stop long-lived tasks in FastAPI lifespan and route submissions through `TaskRunner` |
| Output plugins | Let plugins query arbitrary DB/config state | Pass incident/config through the output contract; keep plugins side-effect scoped |
| Future Alertmanager input | Ignore resolved alert resend/`endsAt` semantics | Map `firing`/`resolved` into `PROBLEM`/`RECOVERY`; preserve source timestamps separately from processing timestamps |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Regex/CIDR compilation per event | CPU spikes during alert bursts | Compile topology config at load time | Hundreds of events/sec or many topology rules |
| Full-table open incident scans | DB latency in expiration/API | Index active statuses and query only candidates; consider batch updates | Thousands of historical incidents |
| JSONB append/update hot row | Slow upserts for large incidents | Deduplicate hosts; cap inline arrays; consider membership table later | Large topology incidents with many hosts/events |
| Notification dispatch inside DB transaction | Long locks, duplicate retries on rollback | Persist incident transition, commit, then submit notification intent | Slow SMTP/API outputs |
| Rule evaluation over every rule without indexing/priorities | Ingestion latency grows linearly | Priority ordering, precompiled matchers, simple predicate structure | Dozens/hundreds of rules |
| Unbounded task creation | Memory growth, delayed sends | Bounded runner queue, backpressure, failed-task metrics | Output plugin outage during alert storm |
| Raw event retention without rotation | Storage growth and slow audit queries | Optional rotated raw events; durable compact decision audit | Sustained webhook traffic |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Unsafe YAML loading | Arbitrary Python object construction from config | `yaml.safe_load` only; validate into Pydantic models |
| Unauthenticated webhook ingress | Anyone can create incidents/notification spam | Require shared secret/API key or source-auth mechanism before public exposure |
| Plugin import path from untrusted config | Arbitrary code import/execution | Restrict plugin registry to trusted config/allowlisted module prefixes |
| Secret leakage in incident summaries/logs | SMTP credentials, tokens, or payload secrets exposed via API | Redact config and raw payload fields; never include plugin config secrets in incidents |
| Over-broad REST audit exposure | Incident/topology data leaks infrastructure layout | Authn/authz on APIs before non-local deployment; separate operator/admin endpoints |

## UX Pitfalls for API Consumers and Operators

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Ingress returns only `accepted` | Clients cannot debug normalization/rule decisions | Include fingerprint, event type, tags, matched rules, incidents updated/closed, notifications triggered/suppressed |
| Incident summary lacks affected entities | Operators cannot act from notification | Include top affected hosts/services, topology, severity, count, timeline, and API link |
| Validation errors point to parser internals | Operators cannot fix YAML quickly | Report config path, rule/plugin name, bad value, expected type, and remediation |
| Suppression is invisible | Users think notifications were lost | Expose suppression reason and next eligible notification time |
| Recovery/expiration look the same | Operators cannot tell healed vs stale | Use distinct statuses/transitions: `RESOLVED` for recovery, `CLOSED` for manual/expiration |

## “Looks Done But Isn’t” Checklist

- [ ] **Incident upsert:** One event creates an incident, but concurrent identical events still need to prove exactly one `OPEN` row per rule/group.
- [ ] **Rule engine:** Matching works, but dry-run diagnostics must show why rules matched or skipped.
- [ ] **Topology enrichment:** Tags appear, but provenance and ambiguous rule detection are missing.
- [ ] **Icinga2 input:** CRITICAL maps to PROBLEM, but OK/UP recovery and host-vs-service behavior must be validated.
- [ ] **Notification dispatch:** Email sends once in a happy path, but threshold transition, retries, idempotency, and attempt audit must exist.
- [ ] **Task runner:** `asyncio.create_task` works locally, but failures, shutdown draining, and replacement boundary must be explicit.
- [ ] **YAML loader:** Files parse, but semantic validation must reject bad cross-references before processing events.
- [ ] **Lifecycle:** Expiration closes stale incidents, but recovery, acknowledgement, late events, and status transition audit must be coherent.
- [ ] **REST API:** Endpoints return data, but incident timelines and processing explanations must be available for operator trust.
- [ ] **Observability:** Service starts, but Vigilo must expose its own ingestion, DB, rule, task, notification, and lifecycle health.

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Duplicate open incidents | HIGH | Add partial unique index after deduplicating existing opens; merge affected hosts/event counts; choose canonical incident; mark duplicates closed with audit note; fix upsert path before re-enabling notifications |
| Noisy grouping rules | MEDIUM | Disable/suppress offending rule; replay sample events through dry-run; narrow group_by/match/threshold; publish config version change |
| Wrong recovery semantics | HIGH | Stop auto-close path; identify incidents closed by bad recovery; reopen or correct statuses; patch plugin mapping; add regression coverage for host/service recovery |
| Topology misclassification | MEDIUM/HIGH | Freeze topology config; identify incidents by bad config version; correct tags/rules; reclassify open incidents if safe; preserve audit note |
| Notification storm | HIGH | Disable output action or rate-limit globally; dedupe sent notifications by incident/action; add durable transition-based dispatch; notify operators of duplicate-noise window |
| Bad YAML config rollout | MEDIUM | Revert to last known-good config; add semantic validation for the missed class; expose config version/status in health endpoint |
| Async task loss | MEDIUM | Reconstruct intended notifications from incident transitions where possible; add attempt ledger; make failed/cancelled tasks visible |
| Missing audit trail | HIGH | Add decision records going forward; reconstruct only from logs/backups with explicit uncertainty; do not claim full historical accuracy |
| Operational blind spot | HIGH | Add minimal health/metrics first: DB, config, task failures, notification failures, ingestion failures; then tune alerts for actionable symptoms |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification / Acceptance Signal |
|---------|------------------|----------------------------------|
| Duplicate open incidents | Phase 1 + Phase 4 | Schema has partial unique index; concurrent same-group events produce one open incident and one notification transition |
| Noisy grouping rules | Phase 4 | Rule dry-run explains match, group key, threshold; default rules cover topology outage and single-host dedupe |
| Broken recovery semantics | Phase 1 + Phase 2 + Phase 6 | `event_type` mandatory; Icinga OK/UP maps to RECOVERY; recovery closes matching active incidents without creating new ones |
| Topology misclassification | Phase 2 | Enrichment precedence documented/enforced; ambiguous regex/CIDR config rejected; provenance visible |
| Plugin boundary leakage | Phase 1 + Phase 2 + Phase 3 | Core processor accepts only `NormalizedEvent`; no Icinga raw fields in rule/incident/notification code |
| Notification storms | Phase 4 + Phase 5 | Notification triggered only on threshold/status transitions; attempts logged with idempotency key and suppression reason |
| Fragile YAML validation | Phase 2 + Phase 3 + Phase 4 | `safe_load` + strict semantic Pydantic validation; bad cross-references fail before serving traffic |
| Async task failures | Phase 3 + Phase 5 + Phase 6 | All background work goes through `TaskRunner`; failures recorded; lifespan shutdown drains/cancels visibly |
| Missing auditability | Phase 1 + Phase 4 + Phase 5 + Phase 6 | Incident API shows decision/timeline: rule match, group key, transitions, notification attempts, recovery/expiration |
| Operational blind spots | Every phase | Health/metrics cover DB, config, ingestion, rule engine, task runner, notifications, lifecycle |

## Sources

- PostgreSQL 18 documentation, `INSERT ... ON CONFLICT`: atomic insert/update outcome under high concurrency and partial-index conflict targets. https://www.postgresql.org/docs/current/sql-insert.html (HIGH)
- PostgreSQL 18 documentation, partial indexes and unique partial indexes. https://www.postgresql.org/docs/current/indexes-partial.html (HIGH)
- SQLAlchemy 2.0 PostgreSQL dialect documentation, `insert().on_conflict_do_update()` and PostgreSQL-specific index/upsert support. https://docs.sqlalchemy.org/en/20/dialects/postgresql.html#insert-on-conflict-upsert (HIGH)
- Icinga 2 Monitoring Basics: host/service states, check result mapping, hard/soft states. https://icinga.com/docs/icinga-2/latest/doc/03-monitoring-basics/ (HIGH)
- Prometheus Alertmanager documentation: deduplication, grouping, routing, inhibition, silences, alert limits. https://prometheus.io/docs/alerting/latest/alertmanager/ (HIGH)
- Prometheus Alertmanager Alerts API: labels for deduplication, resolved/firing expectations, resend behavior. https://prometheus.io/docs/alerting/latest/alerts_api/ (HIGH for future plugin implications)
- Python 3 asyncio task documentation: task scheduling, `create_task`, TaskGroup, coroutine/task behavior. https://docs.python.org/3/library/asyncio-task.html (HIGH)
- FastAPI lifespan events documentation: startup/shutdown resource lifecycle. https://fastapi.tiangolo.com/advanced/events/ (HIGH)
- PyYAML documentation: `yaml.load` unsafe for untrusted data; `safe_load` limits object construction. https://pyyaml.org/wiki/PyYAMLDocumentation (HIGH)
- Pydantic validation documentation: strict mode and validators for semantic config validation. https://docs.pydantic.dev/latest/concepts/strict_mode/ and https://docs.pydantic.dev/latest/concepts/validators/ (HIGH)
- Google SRE, Monitoring Distributed Systems: alert fatigue, signal/noise, four golden signals, simplicity. https://sre.google/sre-book/monitoring-distributed-systems/ (HIGH)
- Google SRE Workbook, Alerting on SLOs: precision, recall, detection time, reset time, suppression implications. https://sre.google/workbook/alerting-on-slos/ (HIGH)
- Google SRE Workbook, Configuration Design and Best Practices: semantic validation, ownership/change tracking, safe config rollout. https://sre.google/workbook/configuration-design/ (HIGH)

---
*Pitfalls research for: Vigilo alert aggregation backend*
*Researched: 2026-06-08*
