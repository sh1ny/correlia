# Architecture Research — Correlia v1.1 Vigilo/VDE Compatibility

**Scope:** Plugin interfaces, loader/task runner, notification dispatch, metrics, readiness, logging, and event audit integration points required to absorb Vigilo/VDE plugin ABCs while preserving Correlia's stricter incident lifecycle.
**Exclusions:** Webhook endpoint compatibility is explicitly out of scope; sender-side systems will adapt payload shape and URL.
**Sources inspected:** Correlia source + `compatibility research (removed for privacy)` + `CONFIGURATION.md` + VDE (`../vde-event-aggregation`) source.

## Executive Recommendation

Keep Correlia's existing port/adapters skeleton and expand it from output plugins to every adapter boundary (input, enrichment, decision/processor, output, task runner). Do not replace Correlia's `app.plugins.interfaces.Protocol` style with VDE's `app.core.interfaces.ABC` style; instead provide thin VDE-compatible adapters that satisfy both contracts behind the scenes. Preserve Correlia's strict allowlisting, Pydantic `extra="forbid"`, startup-fail config validation, non-blocking task runner, structured notification results, and canonical `/v1` APIs. Add an append-only `incident_events` audit table and extend metrics/readiness/logging to cover the new adapter categories without weakening the core incident lifecycle.

## Source Evidence

### Correlia current state

| File | Key symbols | Relevant behavior |
|---|---|---|
| `app/plugins/interfaces.py` | `OutputPlugin`, `InputPlugin`, `TopologyEnricher` protocols; `NotificationEnvelope`; `PluginStatus` | Defines Protocol-based plugin ports. Today only output plugins are loaded through the registry; input and topology are wired manually in `build_icinga2_processor`. |
| `app/plugins/loader.py` | `PluginRegistry`, `_ALLOWED_CLASS_PREFIX = "app.plugins.outputs."` | Loads only output plugins; enforces a single module namespace prefix; validates that instances implement `send_notification` + `plugin_status`. |
| `app/config/plugins.py` | `PluginRegistryEntry`, `PluginRegistryConfigFile`, `_ALLOWED_PLUGIN_TYPES = {"email"}`, `_ALLOWED_CLASS_PREFIX` | Strict Pydantic config with `extra="forbid"`; only `email` plugin type allowed; class path must live under `app.plugins.outputs`. |
| `app/processing/task_runner.py` | `TaskRunner` Protocol, `AsyncIOTaskRunner` | Non-blocking submit via `asyncio.create_task`; task names registered up front; exceptions recorded to metrics and logs. |
| `app/processing/notification_dispatcher.py` | `NotificationDispatcher.process`, `NotificationTaskPayload`, `_result`, `record_notification_result` | Loads incident from DB, builds `NotificationEnvelope`, dispatches to plugin, and persists structured `NotificationResult` in the incident `decision_context`. Detects stale plugin config via `config_hash`. |
| `app/processing/metrics.py` | Counters for events, rules, incidents, notifications, tasks, lifecycle worker health | Prometheus registry scoped to Correlia names; bounded labels only (`event_type`, `reason`, `rule_name`, `effect`, `plugin_name`, `category`, `task_name`). |
| `app/api/routers/health.py` | `/v1/health`, `/v1/readyz` | Readiness checks database, settings, rules/topology config, plugin registry, lifecycle worker. |
| `app/processing/logging.py` | `safe_log_extra`, `SAFE_LOG_KEYS`, `JsonFormatter` | Structured JSON logging with an explicit allowlist of safe extra keys. |
| `app/processing/incident_manager.py` | `IncidentManager.apply_problem`, `_submit_notifications` | Submits notifications through `TaskRunner` only on `first_threshold_transition`; records success/failure via `NotificationResult`. |
| `app/processing/ingress.py` | `Icinga2DecisionProcessor.process_payload` | Orchestrates input plugin -> topology enrichment -> rule engine -> incident manager -> lifecycle/recovery. |
| `app/processing/rule_engine.py` | `RuleEngine.evaluate` | Pure in-memory rule matching; returns `RuleDecision` or `NoOpDecision`; no DB writes. |
| `app/persistence/models.py` | `Incident` SQLAlchemy model | Rich incident schema with lifecycle timestamps, decision context, window state, affected sets. |
| `app/persistence/incidents.py` | `record_problem_incident`, `record_notification_result`, `resolve_host_recovery`, etc. | Atomic PostgreSQL upsert with partial unique index; notification audit stored in `decision_context.notes`. |
| `app/api/routers/incidents.py` | `/v1/incidents` canonical endpoints | Cursor pagination, explicit `/ack` and `/close`; rich response fields. |

### VDE current state

| File | Key symbols | Relevant behavior |
|---|---|---|
| `app/core/interfaces.py` | `OutputPlugin`, `InputPlugin`, `TaskRunner`, `EnricherPlugin`, `ProcessorPlugin` | ABC-based plugin system with `from_config` factories for enricher/processor plugins. `OutputPlugin.send_notification(incident, config)`. `InputPlugin.process_payload(request: Request)`. `TaskRunner.submit` awaits handler synchronously. |
| `app/core/plugins.py` | `load_plugin_from_config`, `get_runner`, `get_output_plugin`, `get_processor_plugin` | Generic importlib loader; no namespace allowlist; singleton caching for runner/output/processor; output plugins carry their own `config` dict. |
| `app/plugins/runners/asyncio_runner.py` | `AsyncIOTaskRunner` | `submit()` calls `await handler(payload)` directly — blocks until handler completes. |
| `app/plugins/enrichers/topology.py` | `TopologyEnricher.enrich` | Hostname regex + IP subnet fallback; mutates/returns a copy of `NormalizedEvent`. |
| `app/plugins/enrichers/llm.py` | `LLMEnricher` | litellm-based enrichment; `from_config`; asyncio.Semaphore burst protection; skip-and-log on errors. |
| `app/plugins/processors/llm.py` | `LLMProcessorPlugin` | litellm-based rule selection; returns `list[RuleDecision]`; confidence filtering done by caller. |
| `app/plugins/outputs/email.py` | `EmailPlugin.send_notification` | Receives `Incident` + `config` dict; dry-run mode; SMTP delivery. |
| `app/core/event_processor.py` | `EventProcessor.process` | Orchestrates rule matching, LLM processor fallback, DC-level notification suppression, incident creation, notification triggering. |
| `app/core/rules.py` | `Rule`, `MatchCriteria`, `WindowConfig`, `RuleEvaluator` | Supports `min_hosts`, `is_dc_level`, wildcard `host: "*"`, `severity` (singular list). |
| `app/models/incident.py` | `Incident`, `RawEventLog` | Thinner incident schema; only `affected_hosts` persisted; separate `RawEventLog`. |
| `config/plugins.yaml` | `task_runner`, `inputs`, `outputs`, `llm`, `enrichers`, `processor` | VDE config surface has sections Correlia does not yet support. |
| `config/rules.yaml` | `is_dc_level`, `min_hosts`, `actions: []` | VDE rules include fields absent from Correlia's strict schema. |

## Best Approach

### 1. Expand plugin registry to five adapter categories while keeping Correlia's strict allowlist

Current Correlia only registers output plugins (`app/plugins/loader.py`, `app/config/plugins.py`). VDE registers task runner, inputs, enrichers, processor, and outputs (`config/plugins.yaml`). Recommendation:

- Add `inputs`, `enrichers`, `processors`, `outputs`, and `task_runner` sections to `PluginRegistryConfigFile` in `app/config/plugins.py`.
- Keep one `PluginRegistryEntry` schema but allow `plugin_type` to be one of `{"input", "enrichment", "processor", "output", "task_runner"}`.
- Expand `_ALLOWED_CLASS_PREFIX` to enforce each type lives under the correct package:
  - `app.plugins.inputs.`
  - `app.plugins.enrichers.`
  - `app.plugins.processors.`
  - `app.plugins.outputs.`
  - `app.plugins.runners.`
- Preserve startup-fail behavior: invalid plugin config must raise before the app accepts traffic. Do not copy VDE's warn-and-skip pattern.
- Keep Pydantic `extra="forbid"` on every plugin entry.

### 2. Preserve Correlia's Protocol style; add VDE-compatible adapter shims

VDE uses ABCs; Correlia uses Protocols. Do not replace Correlia protocols with VDE ABCs. Instead:

- Keep `app/plugins/interfaces.py` as the canonical Correlia port definitions.
- Add adapter classes under `app/plugins/adapters/` (or co-located in each plugin package) that wrap a VDE-style plugin so it satisfies Correlia's Protocol. For example:
  - `VDEOutputAdapter` adapts `OutputPlugin.send_notification(incident, config)` to Correlia's `send_notification(envelope: NotificationEnvelope)` by building the envelope from the incident and baking plugin config into the adapter instance.
  - `VDEEnricherAdapter` adapts `EnricherPlugin.enrich(event) -> NormalizedEvent` to Correlia's `EnrichmentResult` envelope.
  - `VDEProcessorAdapter` adapts `ProcessorPlugin.process(event) -> list[RuleDecision]` to Correlia's `RuleDecision` model (VDE's `RuleDecision` only has `rule_name` + `confidence`; Correlia needs full decision context).
- For new Correlia-native plugins, require the Correlia Protocol. For ported VDE plugins, the shim is the integration point.

### 3. Do not pass `Incident` ORM objects or raw `config` dicts into output plugins

VDE's `OutputPlugin.send_notification(incident, config)` passes the ORM model and a config dict. Correlia's `NotificationEnvelope` is a bounded Pydantic model with only the fields a notification channel needs. Recommendation:

- Keep `NotificationEnvelope` as the output plugin contract.
- Bake plugin-specific config into the plugin instance at load time (as Correlia does today with `entry.options`).
- Build the envelope inside `NotificationDispatcher` from the persisted `Incident` row.
- This preserves Correlia's audit boundary: output plugins cannot accidentally mutate incident state, and notification payloads are bounded.

### 4. Keep the task runner non-blocking

VDE's `AsyncIOTaskRunner.submit()` awaits the handler, making notification dispatch synchronous on the ingress path. Correlia's `AsyncIOTaskRunner.submit()` uses `asyncio.create_task` and returns immediately. Recommendation:

- Keep Correlia's non-blocking behavior.
- Add a `drain()` method for graceful shutdown (already present).
- If a VDE task-runner plugin is ported, wrap it so that `submit()` still returns immediately while scheduling the work as an asyncio task.
- Maintain the rule: core code never calls `asyncio.create_task` outside the runner implementation.

### 5. Structured notification results must remain mandatory

VDE output plugins raise or log on failure; Correlia records every attempt as a structured `NotificationResult` inside `decision_context.notes`. Recommendation:

- Keep `NotificationResult` as the contract between dispatcher and incident state.
- Adapter shims must catch exceptions from VDE-style plugins and convert them to `NotificationResult(success=False, category="plugin_exception", ...)`.
- Persist results via `record_notification_result` so operators can audit delivery per plugin per incident.

### 6. LLM enrichment and processor parity: opt-in, bounded, never sole authority

VDE has `LLMEnricher` and `LLMProcessorPlugin` using litellm. Correlia currently has no LLM path. Recommendation:

- Add LLM adapter plugins under `app/plugins/enrichers/llm.py` and `app/plugins/processors/llm.py` that implement Correlia protocols.
- Default both to `enabled: false` in config; when disabled they are not loaded.
- Require explicit API key config (e.g., `api_key_env`) and fail startup if the referenced env var is missing when enabled.
- LLM processor decisions must be validated against the compiled rule list; any unknown rule name is ignored.
- Static rule engine remains the default path. LLM must be a fallible assistant, not the only path for rule decisions.
- Add bounded concurrency via `asyncio.Semaphore` (matching VDE) and strict timeout defaults.

### 7. Strict config validation and migration

`CONFIGURATION.md` already documents VDE-to-Correlia config mapping gaps. Recommendation:

- Keep `extra="forbid"` on all config models.
- Implement `scripts/migrate_vigilo_config.py` that:
  - Translates VDE `match.severity` -> Correlia `match.severities`.
  - Translates VDE `host: "*"` -> Correlia `host_pattern: ".*"`.
  - Translates VDE `actions: ["email-ops"]` -> Correlia action objects with `name` and `plugin`.
  - Maps VDE `topology_rules.hostname_patterns[].regex` -> Correlia `hostname_rules[].hostname_pattern` and `target_tag: "datacenter"` -> `topology.datacenter`.
  - Maps VDE plugin sections to the expanded registry schema.
  - Fails loudly on unsupported fields (`min_hosts`, `is_dc_level`, actionless rules, unknown plugin types) rather than silently dropping them.
  - Never copies plaintext SMTP credentials into generated YAML; emits env-var references or fails with explicit message.

### 8. Event audit integration

Per `compatibility research (removed for privacy)`, add an append-only `incident_events` table (do not reuse VDE's `raw_events` name):

- Columns: `id`, `incident_id`, `source_id`, `fingerprint`, `event_type`, `severity`, `host`, `service`, `payload`, `normalized_event`, `decision_summary`, `received_at`, `processed_at`.
- Indexes on `(fingerprint)`, `(source_id, received_at desc)`, `(incident_id, processed_at desc)`.
- Write one row per accepted normalized event inside the ingress processor, after normalization and decision context are available.
- The table does not participate in aggregation decisions; it is for traceability and compliance.

### 9. Metrics additions for compatibility work

Extend `app/processing/metrics.py` only where new behavior is created:

- `correlia_plugin_load_results_total{plugin_type, status}` — load/validation outcomes per adapter category.
- `correlia_config_migration_failures_total{reason}` — migration command failures.
- `correlia_incident_events_written_total` — audit row writes.
- `correlia_compat_api_requests_total{method, endpoint, status}` — if `/api/v1/incidents` facade is added.
- `correlia_notification_results_total{plugin_name, category, success}` — already partially covered; keep `plugin_name` + `category` but no host/service/incident ID labels.
- Do not add unbounded labels (host, service, incident ID) to Prometheus metrics.

### 10. Readiness extensions

Extend `/v1/readyz` in `app/api/routers/health.py` to report on each adapter category:

- `input_plugins` — registry initialized and at least the configured input plugins report ready.
- `enricher_plugins` — pipeline loaded and ready.
- `processor_plugin` — if enabled, reports ready.
- `output_plugins` — existing behavior.
- `task_runner` — registered handlers present and runner healthy.
- Keep `/v1/health` as a simple liveness check.

### 11. Logging extensions

Extend `SAFE_LOG_KEYS` in `app/processing/logging.py` to support new v1.1 events:

- `plugin_type`, `adapter`, `enricher_name`, `processor_name`, `llm_provider`, `llm_model`, `migration_status`, `unsupported_field`, `audit_event_id`.
- Ensure no raw payloads, credentials, or LLM prompts are logged through `safe_log_extra`.

### 12. Incident lifecycle remains Correlia's core; no Vigilo-style thin model

- Keep Correlia's `Incident` schema (`app/persistence/models.py`) with decision context, window state, lifecycle timestamps, affected hosts/services.
- Do not downgrade to VDE's thinner incident table.
- Recovery resolution, acknowledgement, close, and expiration stay in Correlia's lifecycle code.
- VDE's `is_dc_level` notification suppression and `min_hosts` thresholds are not supported directly; migration must fail on these fields until Correlia implements equivalent semantics.

## Requirements Implications

1. **Plugin architecture requirement:** v1.1 must support five adapter categories natively, with strict namespace allowlisting and config validation. This is a requirement derived from VDE's plugin surface, but the implementation must follow Correlia's Protocol/strict-validation style.

2. **Config compatibility requirement:** Operators must be able to migrate VDE YAML to Correlia YAML via a command that fails on unsupported semantics. Silent data loss is unacceptable.

3. **LLM parity requirement:** v1.1 must support opt-in LLM enrichment and rule-assist processors, but they must be disabled by default and never the only decision path. This preserves deterministic incident behavior.

4. **Audit requirement:** Every accepted normalized event must be written to `incident_events` with raw payload, normalized event, and decision summary. This closes VDE's raw-event traceability gap without using VDE's schema.

5. **Operational continuity requirement:** `/v1/readyz`, `/v1/metrics`, and canonical `/v1/incidents` remain the primary interfaces. Any Vigilo compatibility facade (`/api/v1/incidents`) is additive and maps to canonical behavior.

6. **Security requirement:** Plugin loading must remain namespace-allowlisted; plugin options must remain bounded scalar/list primitives; SMTP credentials must never be stored in generated YAML.

## Roadmap Implications

| Phase | Work | Files likely touched |
|---|---|---|
| v1.1a — Plugin registry expansion | Extend `PluginRegistryConfigFile`, `PluginRegistry`, loader allowlists; add adapter categories; add adapter shim helpers. | `app/config/plugins.py`, `app/plugins/loader.py`, `app/plugins/interfaces.py`, `app/api/deps.py`, `app/main.py` |
| v1.1b — Input/enricher/processor adapters | Port or wrap VDE input plugin, topology enricher, LLM enricher, LLM processor to Correlia protocols. | `app/plugins/inputs/icinga2.py`, `app/plugins/enrichers/topology.py`, `app/plugins/enrichers/llm.py`, `app/plugins/processors/llm.py`, `app/plugins/adapters/` |
| v1.1c — Task runner adapter | Ensure task runner accepts adapter plugins; keep non-blocking submit. | `app/plugins/runners/asyncio_runner.py`, `app/processing/task_runner.py` |
| v1.1d — Event audit table | Alembic migration + `app/persistence/incident_events.py` + write path in ingress processor. | `migrations/versions/`, `app/persistence/models.py`, `app/persistence/incident_events.py`, `app/processing/ingress.py` |
| v1.1e — Config migration command | `scripts/migrate_vigilo_config.py` with strict failure semantics. | `scripts/migrate_vigilo_config.py` |
| v1.1f — Metrics/readiness/logging extensions | Add new counters, readyz checks, safe log keys. | `app/processing/metrics.py`, `app/api/routers/health.py`, `app/processing/logging.py` |
| v1.1g — Compatibility API facade (optional) | Add `/api/v1/incidents` only if external Vigilo clients need it. | `app/api/routers/incidents_compat.py` |
| v1.1h — Deployment parity | Dockerfile, docker-compose, rate-limit middleware, static Bearer auth. | `Dockerfile`, `docker-compose.yml`, middleware/auth modules |

The order matters: plugin registry expansion (a) unblocks input/enricher/processor work (b, c); event audit (d) and config migration (e) can proceed in parallel; metrics/readiness/logging (f) should follow the behavioral changes; API facade (g) and deployment parity (h) are additive and can be last.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Namespace allowlist too permissive after expansion** | High | Enforce separate prefixes per adapter category (`app.plugins.inputs.`, `app.plugins.enrichers.`, etc.) and reject any class outside those prefixes. Keep `_ALLOWED_CLASS_PREFIX` as a tuple or mapping by type. |
| **VDE output plugins expect `Incident` + `config` and may leak DB state** | Medium | Adapter builds `NotificationEnvelope` from the DB row and bakes config into the plugin instance. Output plugin contract stays as `NotificationEnvelope` only. |
| **VDE's blocking task runner semantics ported accidentally** | Medium | Adapter must schedule handlers via `asyncio.create_task` and return immediately. Add a behavioral test that asserts `submit()` does not await the handler. |
| **LLM plugins become the default decision path** | High | Require `enabled: false` default; validate that static rule engine always runs when LLM processor fails or returns no decisions; log and metric when LLM is consulted. |
| **LLM plugin errors/costs under alert storms** | Medium | Default `max_concurrent` and `timeout_seconds`; skip-and-log on failure; never block ingestion on LLM latency. |
| **Config migration silently drops VDE fields** | High | `extra="forbid"` and explicit unsupported-field checks in migration script; migration must exit non-zero on unsupported semantics. |
| **Event audit writes hurt ingress throughput** | Low-Medium | Append-only insert in same transaction boundary as incident upsert; no unique constraints on `incident_events`; async DB driver; measure before optimizing. |
| **Prometheus label cardinality explosion** | Medium | Continue banning host/service/incident ID labels; only add bounded labels (`plugin_type`, `status`, `category`). |
| **Ready/z checks become too strict and fail on optional plugins** | Low | Treat disabled plugin categories as `ready`; only fail when an enabled plugin reports not ready. |
| **LLM prompts or credentials logged** | High | Extend `SAFE_LOG_KEYS` carefully; never pass prompt text or API keys through `safe_log_extra`; use env-var references only in config. |
| **Scope creep into full API/webhook parity** | Medium | Document webhook endpoint compatibility as explicitly excluded; any `/api/v1/incidents` facade is additive behind canonical `/v1/incidents`. |

## Verification Targets

- A test VDE-style output plugin under `app.plugins.outputs.vde_compat` loads through the registry and receives a `NotificationEnvelope` via adapter.
- A test VDE-style enricher under `app.plugins.enrichers.vde_compat` returns an `EnrichmentResult` via adapter.
- Startup fails when plugin config uses `class_path` outside the allowlisted namespace.
- Startup fails when migration script encounters `min_hosts`, `is_dc_level`, or actionless rules.
- Processing one accepted event creates exactly one `incident_events` row with non-empty `normalized_event` and `decision_summary`.
- `AsyncIOTaskRunner.submit("notify", payload)` returns before the notification handler completes.
- `/v1/readyz` reports new adapter categories correctly when enabled.

## Conclusion

Correlia's existing architecture is the right foundation: Protocol-based plugin ports, strict config validation, non-blocking task runner, structured notification audit, and database-enforced incident lifecycle. v1.1 compatibility work should expand those ports to cover VDE's broader plugin surface, add VDE-compatible adapter shims, implement the event audit table, and provide a strict config migration tool — all without relaxing Correlia's core invariants.
