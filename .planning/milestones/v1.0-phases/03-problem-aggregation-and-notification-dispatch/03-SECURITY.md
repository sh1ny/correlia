---
phase: 03
slug: problem-aggregation-and-notification-dispatch
status: verified
threats_open: 0
asvs_level: 1
created: 2026-06-09
---

# Phase 03 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| RuleDecision/NormalizedEvent → persistence | Typed but untrusted event/config-derived strings enter PostgreSQL incident writes. | Rule/group/fingerprint/summary/severity/window facts |
| PostgreSQL row state → API response | Durable JSONB decision facts are exposed as compact response fields. | Incident IDs, status, threshold, notification metadata |
| Concurrent ingress workers → one open incident row | Multiple workers can target the same `rule_name + group_key`. | Open-incident identity and threshold state |
| YAML plugin registry → Python plugin objects | Operator-controlled config selects trusted plugin classes and options. | Plugin class path and SMTP options |
| Correlia → SMTP server | Notification content leaves the process through an external network service. | Rendered incident notification email |
| Async handler → background task lifecycle | Failures can occur after request processing has moved on. | Serialized task payload and exception metadata |
| HTTP webhook → processing pipeline | Untrusted Icinga2 requests flow through normalization, topology, rules, aggregation, and response. | Icinga2 event data and derived tags |
| Durable incident transaction → TaskRunner | Output work must not observe or announce uncommitted incident state. | Incident id, plugin name, config hash |
| TaskRunner payload → NotificationDispatcher | Plain payload values select incident id and plugin name for background dispatch. | Serialized notification task payload |
| Output dispatcher → plugin/SMTP | Plugin code and external SMTP can fail after the ingest response path. | Notification envelope and failure category |
| Plugin registry → REST listing | Configured plugin status is exposed through an API route. | Safe plugin status rows |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-03-01-T | Tampering | `app/persistence/incidents.py` SQL writes | mitigate | SQLAlchemy PostgreSQL `insert(...).values(...)` uses bound values; partial open-incident conflict predicate remains `status = 'OPEN'`. Evidence: `app/persistence/incidents.py:342-358`, `app/persistence/incidents.py:382-402`, `app/persistence/incidents.py:493-516`. | closed |
| T-03-01-R | Repudiation | threshold marker write | mitigate | Durable write result returns incident id, effect, replay, counted, threshold, and first-transition facts from the transaction result. Evidence: `app/persistence/incidents.py:149-159`, `app/persistence/incidents.py:421-430`, `app/persistence/incidents.py:474-483`. | closed |
| T-03-01-I | Information Disclosure | `DecisionContext` and envelope fields | mitigate | Strict context model stores bounded safe fields and rejects secret/raw-payload note fragments; manager persists only derived event/rule/threshold/action facts; tests assert forbidden strings are absent. Evidence: `app/domain/incidents.py:23-31`, `app/domain/incidents.py:48-78`, `app/processing/incident_manager.py:206-223`, `tests/test_incident_manager.py:256-295`. | closed |
| T-03-01-D | Denial of Service | JSONB `window_state` growth | mitigate | Window fingerprints are capped by `MAX_WINDOW_FINGERPRINTS`, input bounds, timestamp pruning, and newest-entry truncation before write. Evidence: `app/persistence/incidents.py:19-21`, `app/persistence/incidents.py:91-108`, `app/persistence/incidents.py:214-244`. | closed |
| T-03-01-D2 | Denial of Service | notification storm | mitigate | Incident-side `threshold_crossed` marker computes first transition once; manager only submits notifications when `first_threshold_transition` is true and otherwise returns explicit no-dispatch reasons. Evidence: `app/persistence/incidents.py:444-468`, `app/processing/incident_manager.py:135-140`, `app/processing/incident_manager.py:225-235`, `tests/test_incident_manager.py:150-192`. | closed |
| T-03-01-E | Elevation of Privilege | database substitute | mitigate | Migration and repository use PostgreSQL-specific JSONB/insert APIs; test source asserts no SQLite branch in the incident repository. Evidence: `migrations/versions/0002_add_threshold_state.py:10-28`, `app/persistence/incidents.py:10-12`, `tests/test_migrations.py:67-79`, `tests/test_incident_repository.py:842-847`. | closed |
| T-03-02-E | Elevation of Privilege | `app/plugins/loader.py` | mitigate | Registry config uses `yaml.safe_load`, strict Pydantic models, duplicate-name rejection, class-path prefix validation, and loader-side `app.plugins.outputs.` allowlist; tests scan for unsafe YAML/eval/exec/import calls. Evidence: `app/config/plugins.py:16-32`, `app/config/plugins.py:44-77`, `app/plugins/loader.py:58-69`, `tests/test_plugin_registry.py:79-118`, `tests/test_plugin_registry.py:160-175`. | closed |
| T-03-02-I | Information Disclosure | `PluginStatus` and registry listing | mitigate | `PluginRegistry.list_plugins()` returns only name/type/status/ready, omitting options, credentials, class paths, exception text, rendered bodies, and config hash; route tests assert secret fields are absent. Evidence: `app/plugins/loader.py:33-46`, `app/api/routers/plugins.py:13-17`, `tests/test_plugin_registry.py:51-57`, `tests/test_plugins_router.py:50-80`. | closed |
| T-03-02-D | Denial of Service | `AsyncIOTaskRunner` | mitigate | Runner tracks task handles, removes completed tasks, retrieves/logs exceptions, and provides deterministic `drain()`; app lifespan drains on shutdown. Evidence: `app/processing/task_runner.py:25-62`, `app/processing/task_runner.py:64-77`, `app/main.py:58-66`, `tests/test_task_runner.py:49-62`. | closed |
| T-03-02-T | Tampering | task payloads | mitigate | Task runner accepts one mapping payload and shallow-copies it before scheduling; notification submission constructs only string/config-hash fields and dispatcher revalidates with `NotificationTaskPayload`. Evidence: `app/processing/task_runner.py:10-22`, `app/processing/task_runner.py:45-57`, `app/processing/incident_manager.py:162-167`, `app/processing/notification_dispatcher.py:21-33`, `tests/test_task_runner.py:13-35`. | closed |
| T-03-SC | Tampering | `aiosmtplib` dependency install | mitigate | Summary records the blocking human checkpoint was resumed with exact `aiosmtplib` approval; dependency was added through `uv` with locked hashes. Evidence: `03-02-SUMMARY.md:93-108`, `pyproject.toml:7-10`, `uv.lock:9-15`. | closed |
| T-03-03-R | Repudiation | `IncidentManager.apply_problem` ordering | mitigate | Manager commits durable incident state before notification submission; payload includes incident id, plugin name, and config hash; source-order test asserts commit precedes submit. Evidence: `app/processing/incident_manager.py:107-115`, `app/processing/incident_manager.py:162-167`, `tests/test_incident_manager.py:112-118`. | closed |
| T-03-03-I | Information Disclosure | notification failure results | mitigate | Dispatcher uses closed result categories and bounded messages; notification result recording stores only plugin/category/success/message notes with truncation and Pydantic revalidation; tests assert no password/secret/SMTP transcript/traceback leakage. Evidence: `app/processing/notification_dispatcher.py:41-83`, `app/processing/notification_dispatcher.py:93-94`, `app/persistence/incidents.py:253-300`, `tests/test_notification_dispatch.py:176-215`. | closed |
| T-03-03-D | Denial of Service | repeated notifications | mitigate | Dispatch is skipped unless `first_threshold_transition` is true; replay and already-notified branches return explicit no-dispatch reasons and tests prove no additional submissions. Evidence: `app/processing/incident_manager.py:135-140`, `app/processing/incident_manager.py:225-235`, `tests/test_incident_manager.py:150-218`. | closed |
| T-03-03-T | Tampering | task payload plugin selection | mitigate | `NotificationTaskPayload` strictly validates incident id, plugin name, config hash, and rejects extras; dispatcher resolves plugin names from the trusted registry and maps missing plugins safely. Evidence: `app/processing/notification_dispatcher.py:21-33`, `app/processing/notification_dispatcher.py:41-62`, `tests/test_notification_dispatch.py:151-198`. | closed |
| T-03-03-D2 | Denial of Service | background task failure | mitigate | Runner retrieves task exceptions, dispatcher records failures using a fresh session, and lifespan drains outstanding tasks on shutdown. Evidence: `app/processing/task_runner.py:59-77`, `app/processing/notification_dispatcher.py:85-90`, `app/main.py:58-66`, `tests/test_task_runner.py:49-62`. | closed |
| T-03-03-E | Elevation of Privilege | `/plugins` route | mitigate | Route delegates to safe registry listing only; tests assert no incident REST API was added and response omits options, credentials, rendered bodies, class names, and module internals. Evidence: `app/api/routers/plugins.py:13-17`, `app/plugins/loader.py:33-46`, `tests/test_plugins_router.py:50-95`. | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Summary Threat Flags

| Source | Finding | Disposition |
|--------|---------|-------------|
| `03-01-SUMMARY.md:122-124` | No additional threat flags; schema and processing surfaces covered by plan threat model. | mapped |
| `03-02-SUMMARY.md` | No `## Threat Flags` section present; no executor threat flags reported. | none |
| `03-03-SUMMARY.md:141-143` | No additional threat flags; dispatcher payload, output plugin, and `/plugins` route covered by plan threat model. | mapped |

---

## Accepted Risks Log

No accepted risks.

---

## Security Audit 2026-06-09

| Metric | Count |
|--------|-------|
| Threats found | 17 |
| Closed | 17 |
| Open | 0 |

Notes:
- Initial `gsd-security-auditor` subagent returned `ESCALATE` because its runtime lacked filesystem tools, not because of an implementation gap.
- Orchestrator completed the same plan-time threat-register verification against implementation and test evidence.
- Implementation files were not modified.

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-06-09 | 17 | 17 | 0 | openai-codex/gpt-5.5 orchestrator |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-06-09
