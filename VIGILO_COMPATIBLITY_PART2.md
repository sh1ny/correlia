# Vigilo Compatibility Plan — Part 2: Advisory Trigger Output

## Decision

After `VIGILO_COMPATIBILITY.md` is implemented, Correlia can be used as the replacement base for Vigilo's operational incident path. Part 2 adds only the Correlia-side pieces required for the predictive advisory design: selected Correlia incidents can produce compact, durable advisory triggers and expose bounded incident context for an external advisory consumer.

Correlia remains the operational source of truth. It does not call Hermes, query Hindsight, send Google Chat messages, execute remediation, suppress alerts, close incidents from AI output, or store advisory memory.

## Relationship to Part 1

Part 1 establishes compatibility at the API, config, plugin, event-audit, auth, deployment, and operational boundaries. This document lands after that work and depends on these Part 1 outcomes:

- strict Correlia rule/config loading remains canonical;
- plugin registry expansion exists for output plugins and preserves namespace allowlisting;
- static API auth, request-size limits, and rate limiting protect non-public routes;
- `incident_events` exists as append-only event audit/history;
- Correlia deployment packaging exists and defaults to one Uvicorn worker;
- `/v1/incidents`, `/v1/readyz`, and `/v1/metrics` remain canonical operational APIs.

Part 2 does not replace Part 1. It adds a new advisory-output path beside the compatibility path.

## Required Changes to Part 1

The current `VIGILO_COMPATIBILITY.md` should be amended in these places when Part 2 is adopted:

1. **Plugin architecture direction**
   - Part 1 says to expand plugin ports for input, enrichment, decision, output, and task-runner adapters.
   - Add that `nats-advisory` is a Correlia output plugin used for machine advisory trigger publication, not a human notification plugin.
   - Its config must use strict Pydantic validation and remain namespace-allowlisted like other plugins.

2. **Operational compatibility metrics**
   - Part 1 lists metrics for compatibility API requests, config migration failures, incident event audit writes, and plugin dispatch results.
   - Add low-cardinality advisory metrics listed in this document.
   - Preserve Part 1's rule: no host, service, incident ID, or fingerprint Prometheus labels.

3. **API auth protected routes**
   - Part 1 protects `/v1/incidents`, `/v1/rules`, `/v1/topology`, `/v1/plugins`, and `/v1/metrics`.
   - Add the advisory context endpoint to protected API routes.
   - Keep `/v1/health` public and keep `/v1/readyz` configurable as Part 1 specifies.

4. **Database schema direction**
   - Part 1 says `incident_events` is the audit/history complement to canonical `incidents`.
   - Add that `advisory_outbox` is not an audit table; it is a durable publishing outbox.
   - Add that `incident_context_snapshots` is not a raw-event table; it is a bounded advisory read model.

No Part 1 behavior should be weakened. Correlia must still keep its stricter core behavior and must not copy Vigilo's warn-and-skip config semantics.

## Compatibility Scope

| Area | Status |
| --- | --- |
| Advisory rule opt-in | Add `advisory_actions` to Correlia rule config. |
| Advisory trigger schema | Add compact `AdvisoryTrigger` model. |
| Durable publishing | Add `advisory_outbox` and publisher worker. |
| NATS publication | Add `nats-advisory` output plugin. |
| Advisory context | Add bounded `incident_context_snapshots` and read-only context endpoint. |
| External AI services | Out of scope for Correlia. |
| Chat delivery | Out of scope for Correlia. |
| Memory promotion | Out of scope for Correlia. |

## Non-Goals

- No Hermes client in Correlia.
- No Hindsight client in Correlia.
- No Google Chat provider in Correlia.
- No advisory review UI or CLI in Correlia.
- No automated remediation.
- No AI-driven alert suppression.
- No AI-driven incident close, ack, or status mutation.
- No raw monitoring stream in NATS advisory triggers.
- No raw monitoring stream in `incident_context_snapshots`.

## Terminology

Use Correlia names in implementation, even when upstream design documents still say Vigilo.

| Concept | Correlia implementation name |
| --- | --- |
| Advisory rule field | `advisory_actions` |
| Trigger model | `AdvisoryTrigger` |
| Durable trigger table | `advisory_outbox` |
| Context read model table | `incident_context_snapshots` |
| Output plugin key | `nats-advisory` |
| Publisher worker/process | `correlia-advisory-outbox-publisher` |
| Publish mode config | `advisory_publish_mode` |
| Publish transport mode config | `delivery_mode` |
| Trigger schema version | `advisory-trigger.v1` |
| Trigger subject | `advisory.triggers.v1` |
| Source system value | `correlia` |

## Required Correlia Additions

### 1. Advisory rule configuration

Extend Correlia rules with optional `advisory_actions`:

```yaml
rules:
  - name: "DC-Level Outage Aggregator"
    priority: 100
    match:
      severity: ["CRITICAL", "WARNING"]
      tags:
        datacenter: "*"
    window:
      duration_seconds: 1800
      group_by: ["datacenter"]
      trigger_threshold: 10
      min_hosts: 5
    output_summary: "Major outage detected in Datacenter {datacenter}"
    actions: ["email-ops"]
    advisory_actions: ["nats-advisory"]
```

Default behavior:

- missing `advisory_actions` means `[]`;
- empty `advisory_actions` means no advisory trigger;
- invalid advisory action names fail startup config validation;
- advisory actions do not replace notification `actions`.

Eligibility for MVP:

1. Incoming normalized event is a `PROBLEM` event.
2. A rule matches the event.
3. The incident update causes the rule threshold to cross.
4. The rule has at least one configured `advisory_actions` entry.
5. Global advisory output is enabled.

MVP exclusions:

- no recovery-event advisory triggers;
- no repeated advisory triggers while the same incident remains open and already crossed the advisory threshold;
- no service-tracker advisory triggers unless explicitly configured;
- no advisory trigger for rules without `advisory_actions`.

Operational notification suppression and advisory trigger suppression are separate. Do not implicitly reuse host/DC notification suppression for advisory output unless an explicit advisory-specific config is added later.

### 2. Advisory trigger schema

Add a strict Pydantic model named `AdvisoryTrigger`.

Required fields:

| Field | Requirement |
| --- | --- |
| `schema_version` | Literal `advisory-trigger.v1`. |
| `trigger_id` | Deterministic idempotency key. |
| `trigger_mode` | `shadow` or `active`. |
| `created_at` | UTC trigger creation timestamp. |
| `source_system` | Literal `correlia`. |
| `incident_id` | Correlia incident id. |
| `rule_name` | Rule that emitted the trigger. |
| `group_key` | Rule aggregation group key. |
| `severity` | Normalized severity. |
| `event_count` | Current threshold/window event count. |
| `affected_hosts_count` | Count, not full inventory. |
| `affected_hosts_sample` | Capped host sample. |
| `situation_summary` | Compact operational summary. |
| `event_fingerprint` | Current event fingerprint. |
| `event_source_id` | Current event source id. |
| `event_host` | Current event host. |
| `event_service` | Current event service, nullable. |
| `event_tags` | Allowlisted, capped tags. |
| `context_url` | Advisory context endpoint URL. |
| `data_classification` | Literal `operational-summary`. |

Excluded from the trigger:

- raw webhook payload;
- full incident row;
- full host inventory;
- full logs;
- traces;
- bulk metrics;
- environment variables;
- credentials, tokens, secrets, private keys, webhook URLs, or cookies;
- unbounded free-form event text.

`trigger_id` must be deterministic. Recommended basis:

```text
incident_id + rule_name + group_key + threshold_crossed_at
```

Do not generate a random UUID for the same threshold-crossing event. If the same advisory trigger is rebuilt after retry, the same `trigger_id` must be produced.

### 3. Advisory output plugin configuration

Add an output plugin entry:

```yaml
outputs:
  nats-advisory:
    module: "app.plugins.outputs.nats_advisory"
    class: "NatsAdvisoryPlugin"
    config:
      enabled: true
      advisory_publish_mode: "shadow"
      servers:
        - "nats://nats:4222"
      stream: "ADVISORY_TRIGGERS"
      subject: "advisory.triggers.v1"
      delivery_mode: "outbox"
      publish_timeout_seconds: 3
```

`advisory_publish_mode` values:

| Value | Behavior |
| --- | --- |
| `disabled` | Do not enqueue or publish advisory triggers. |
| `shadow` | Publish triggers with `trigger_mode: shadow`. |
| `active` | Publish triggers with `trigger_mode: active`. |

`delivery_mode` values:

| Value | Behavior |
| --- | --- |
| `direct_publish` | Local/dev proof of concept only. Publish directly to NATS. |
| `outbox` | Required for production pilot. Persist intent before publishing. |

Production rule: `delivery_mode: outbox` is required before any production shadow or active pilot. Direct publish must not be used for production advisory triggers.

### 4. `advisory_outbox` table

Add a durable outbox table named `advisory_outbox`.

Purpose: preserve advisory trigger intent after the incident threshold-crossing transaction commits, even if NATS is unavailable.

Recommended columns:

| Column | Definition |
| --- | --- |
| `trigger_id` | `varchar` or UUID-compatible string primary key |
| `incident_id` | `uuid not null references incidents(id)` |
| `rule_name` | `varchar(256) not null` |
| `group_key` | `varchar(512) not null` |
| `subject` | `varchar(256) not null` |
| `payload` | `jsonb not null` |
| `payload_hash` | `varchar(128) not null` |
| `status` | `varchar(32) not null` |
| `attempt_count` | `integer not null default 0` |
| `next_attempt_at` | `timestamptz not null` |
| `last_error` | `text null` |
| `nats_stream` | `varchar(256) null` |
| `nats_sequence` | `bigint null` |
| `created_at` | `timestamptz not null` |
| `updated_at` | `timestamptz not null` |
| `published_at` | `timestamptz null` |

Recommended indexes:

- `(status, next_attempt_at)` for publisher polling;
- `(incident_id, created_at desc)` for audit/debug;
- `(rule_name, created_at desc)` for operational review.

Status values:

| Status | Meaning |
| --- | --- |
| `pending` | Row is ready or waiting for publication. |
| `publishing` | Publisher has claimed the row. |
| `published` | JetStream publish ACK was recorded. |
| `failed_retryable` | Transient failure; retry after `next_attempt_at`. |
| `failed_permanent` | Non-retryable schema/config/policy failure. |
| `abandoned` | Operator-abandoned after review. |

Enqueue rules:

- insert the row in the same database transaction as the incident threshold-crossing update;
- use insert-if-not-exists semantics on `trigger_id`;
- duplicate `trigger_id` with the same `payload_hash` is idempotent;
- duplicate `trigger_id` with a different `payload_hash` fails closed and records an error;
- advisory publishing failure after commit must not roll back incident creation/update.

### 5. Advisory outbox publisher

Add a Correlia-owned worker/process named:

```text
correlia-advisory-outbox-publisher
```

Responsibilities:

- poll due `advisory_outbox` rows;
- claim rows atomically;
- publish `payload` to configured JetStream `subject`;
- record JetStream stream and sequence on publish ACK;
- mark rows `published` with `published_at`;
- retry transient NATS failures with bounded backoff;
- mark non-retryable schema/config/policy failures as `failed_permanent`;
- leave rows unacknowledged/unpublished if NATS outcome is unknown.

The publisher must be outside request-path event ingestion for production. Incident ingestion must not wait on NATS availability.

### 6. NATS advisory plugin behavior

`NatsAdvisoryPlugin` is responsible for constructing or accepting an `AdvisoryTrigger` and placing it on the configured delivery path.

In `delivery_mode: outbox`:

- validate the trigger;
- compute `payload_hash`;
- enqueue into `advisory_outbox`;
- return structured plugin result indicating enqueue success/failure.

In `delivery_mode: direct_publish`:

- validate the trigger;
- publish to NATS within `publish_timeout_seconds`;
- return structured plugin result;
- restrict this mode to local/dev or explicitly non-production environments.

The plugin must not call Hermes, Hindsight, Chat, or any downstream advisory service.

### 7. `incident_context_snapshots` table

Add a bounded advisory read-model table named `incident_context_snapshots`.

Purpose: provide compact current operational facts to authorized advisory consumers without exposing raw monitoring payloads.

Recommended columns:

| Column | Definition |
| --- | --- |
| `incident_id` | `uuid primary key references incidents(id)` |
| `schema_version` | `varchar(64) not null` |
| `scope_tags` | `jsonb not null` |
| `service_counts` | `jsonb not null` |
| `severity_counts` | `jsonb not null` |
| `event_samples` | `jsonb not null` |
| `first_event` | `jsonb null` |
| `last_event` | `jsonb null` |
| `trigger_snapshot` | `jsonb null` |
| `limits` | `jsonb not null` |
| `updated_at` | `timestamptz not null` |

Allowed content:

- normalized host;
- normalized service;
- normalized severity;
- event timestamp;
- source id;
- fingerprint;
- allowlisted topology/tags;
- redacted and capped message text;
- service counts;
- severity counts;
- first/last event summaries;
- trigger threshold facts;
- truncation and redaction metadata.

Forbidden content:

- raw Icinga/webhook payload;
- logs;
- traces;
- metric bodies;
- environment variables;
- credentials or secrets;
- full host inventory;
- unbounded service lists;
- unreviewed AI output.

Default caps:

| Data | Default cap |
| --- | --- |
| `event_samples` | 20 entries per incident |
| message text | 500 characters per sample |
| host samples in endpoint response | separately capped, recommended 20 |
| tag keys | allowlist only |

This table is separate from Part 1's `incident_events`. `incident_events` is append-only audit/history. `incident_context_snapshots` is a current bounded factsheet.

### 8. Context snapshot update logic

Update `incident_context_snapshots` during incident processing from normalized/enriched event data only.

Required behavior:

- update service and severity counts for the incident;
- preserve first event summary;
- update last event summary;
- maintain capped event samples;
- apply tag allowlist before storage;
- apply message redaction/capping before storage;
- record truncation/redaction in `limits`;
- record `trigger_snapshot` when an advisory-enabled threshold crossing occurs.

Snapshot update failure should be visible through logs/metrics. Decide during implementation whether snapshot failure should fail the incident transaction. Default recommendation: fail closed only for data-policy violations; otherwise preserve incident processing and record degraded context completeness.

### 9. Advisory context endpoint

Add a protected read-only endpoint:

```text
GET /api/v1/incidents/{incident_id}/advisory-context
```

This path is intentionally compatibility-shaped because the external advisory consumer design expects `/api/v1`. It does not replace canonical Correlia incident APIs.

Required response sections:

| Section | Purpose |
| --- | --- |
| `primary_incident` | Current incident fields needed for advisory context. |
| `supporting_incidents` | Related lower-level incident buckets, bounded. |
| `scope_tags` | Allowlisted scope tags. |
| `trigger_facts` | Rule name, group key, thresholds, event count, affected-host count, trigger timestamp. |
| `service_counts` | Aggregated service counts. |
| `severity_counts` | Aggregated severity counts. |
| `event_samples` | Capped sanitized normalized event samples. |
| `first_event` | Sanitized first event summary. |
| `last_event` | Sanitized latest event summary. |
| `limits` | Caps, truncation flags, redaction markers, schema version. |
| `context_completeness` | `minimal`, `partial`, or `full`. |

`context_completeness` values:

| Value | Meaning |
| --- | --- |
| `minimal` | Response assembled from incident row only. |
| `partial` | Snapshot exists but some supporting data is missing or truncated. |
| `full` | Snapshot and supporting incident lookup are available within configured limits. |

The endpoint must not return raw payloads, logs, traces, secrets, or unbounded lists.

### 10. Supporting incident lookup

Add bounded lookup for related incidents used by the advisory context endpoint.

Candidate relationship signals:

- shared affected hosts;
- overlapping incident window;
- related rule scope;
- matching group tags;
- shared datacenter/environment/service tags.

Requirements:

- cap the number of supporting incidents returned;
- avoid returning unrelated incidents;
- avoid unbounded affected-host or affected-service expansion;
- include enough relationship reason metadata for the advisory consumer to understand why a supporting incident was included.

### 11. Observability

Add structured logs for:

- advisory trigger eligibility decision;
- advisory trigger build failure;
- advisory outbox enqueue success/failure;
- duplicate enqueue idempotency result;
- outbox claim;
- NATS publish success/failure;
- retry scheduling;
- permanent failure;
- context snapshot update/truncation/redaction;
- advisory context endpoint access.

Add low-cardinality metrics for:

- `advisory_triggers_enqueued`;
- `advisory_triggers_published`;
- advisory outbox publish failures by failure class;
- advisory outbox retry count;
- advisory outbox permanent failure count;
- context snapshot update count;
- context snapshot truncation/redaction count;
- advisory context endpoint request count.

Do not add labels for host, service, incident id, fingerprint, group key, or raw rule values. Rule names may be high-cardinality in some deployments; avoid them as labels unless the existing Correlia metrics policy explicitly permits bounded configured rule labels.

## Data Handling Requirements

Allowed in advisory triggers and context responses:

- `trigger_id`;
- `incident_id`;
- rule name or rule id;
- group key;
- severity;
- environment/tenant/deployment scope when allowlisted;
- service/component when allowlisted;
- datacenter/region when allowlisted;
- event count;
- affected host count;
- capped host sample;
- compact situation summary;
- timestamps;
- Correlia incident/context links.

Denied by default:

- raw monitoring payloads;
- full logs or traces;
- bulk metric samples;
- full host inventories;
- secrets, credentials, tokens, cookies, private keys, webhook URLs;
- customer-sensitive free text;
- remediation commands;
- autonomous operational actions;
- data copied from comments unless explicitly approved and redacted.

Policy violations should fail closed before publishing to NATS or returning from the advisory context endpoint.

## Configuration Additions

Recommended top-level settings, exact location to follow Correlia's existing settings conventions:

```yaml
advisory_output:
  enabled: true
  advisory_publish_mode: "shadow"
  default_action: "nats-advisory"
  context_endpoint_base_url: "https://correlia.example.com"
  max_trigger_payload_bytes: 65536
  max_host_sample: 20
  max_event_samples: 20
  max_message_chars: 500
  tag_allowlist:
    - datacenter
    - environment
    - tenant
    - service
    - region
```

Plugin-specific NATS settings remain under the `nats-advisory` plugin config.

## Rollout Sequence

1. Add rule parsing for `advisory_actions` with no behavior change when unset.
2. Add `AdvisoryTrigger` model and trigger builder tests.
3. Add `advisory_outbox` migration and repository methods.
4. Add advisory enqueue on threshold crossing behind `advisory_output.enabled`.
5. Add `NatsAdvisoryPlugin` in `delivery_mode: outbox`.
6. Add `correlia-advisory-outbox-publisher`.
7. Add `incident_context_snapshots` migration and bounded update logic.
8. Add advisory context endpoint.
9. Add supporting incident lookup.
10. Add metrics/logs and data-policy tests.
11. Enable only selected rules in `advisory_publish_mode: shadow`.

## Verification Targets

- Rule parsing accepts missing, empty, and populated `advisory_actions`.
- Invalid advisory action names fail startup validation.
- Existing rules without `advisory_actions` produce no advisory triggers.
- Existing operational notifications still use `actions` unchanged.
- Trigger eligibility requires `PROBLEM`, rule match, first threshold crossing, advisory action, and global enablement.
- Recovery events do not emit advisory triggers in MVP.
- Repeated events after the same threshold crossing do not emit duplicate triggers.
- `trigger_id` is deterministic for the same threshold crossing.
- `AdvisoryTrigger` rejects unsupported schema versions, unsupported modes, unknown fields, and oversized payloads.
- Trigger payload excludes raw webhook payload, logs, metrics, traces, secrets, and full incident rows.
- `advisory_outbox` row commits with incident threshold crossing.
- Duplicate enqueue with same `trigger_id` and same `payload_hash` is idempotent.
- Duplicate enqueue with same `trigger_id` and different `payload_hash` fails closed.
- NATS unavailable during threshold crossing does not break incident ingestion when outbox mode is used.
- Publisher records NATS stream and sequence on publish success.
- Publisher retries transient publish failures.
- Publisher marks non-retryable schema/config failures permanent.
- `incident_context_snapshots` stores only normalized/enriched sanitized data.
- Snapshot samples, tags, messages, host samples, and supporting incidents are capped.
- Advisory context endpoint returns all required sections.
- Advisory context endpoint reports `context_completeness: minimal` when only the incident row is available.
- Advisory context endpoint never returns raw payloads, logs, traces, secrets, or unbounded lists.
- Compatibility API behavior from Part 1 remains unchanged.
- Gates from Correlia root still pass: `uv lock --check`, `make lint`, `make typecheck`, `make test`.

## Source Alignment

This spec is structurally aligned with the predictive advisory design requirements while using Correlia implementation names:

- separate advisory rule outputs through `advisory_actions`;
- compact `advisory-trigger.v1` payloads;
- durable outbox before production NATS publishing;
- JetStream subject `advisory.triggers.v1`;
- strict separation between trigger publication and final advisory delivery;
- bounded context endpoint for downstream advisory analysis;
- `incident_context_snapshots` as a capped factsheet, not a raw event store;
- no Hermes, Hindsight, Chat, memory, or remediation responsibilities inside Correlia.
