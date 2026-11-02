# 0004. Canonical event: CloudEvents envelope with a versioned Correlia payload

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: none

## Context

The owner wants every ingested format (Icinga2, Alertmanager, Thanos, …) normalized and enriched into one
standardized, versioned format that output plugins can publish (NATS first). The legacy `NormalizedEvent`
was an internal Pydantic model with no versioning and no separation of "who reported" from "what it is about".

## Decision

- **Envelope:** CloudEvents 1.0.2, JSON structured mode on the wire. `type = io.correlia.<kind>.v<major>`
  (`kind`: alert, state, ack, downtime, comment, heartbeat); `dataschema` names the exact minor version;
  `id` is the observation identity and `subject` the fingerprint, both defined in ADR 0012; extensions `partitionkey`, `traceparent`, `correliatenant`.
- **Payload `correlia.event.v1`:** fingerprint and optional `dedup_key`; `status` (firing, resolved, info)
  separate from `severity` (critical, error, warning, info, unknown) plus `severity_number` (OTel 1-24) and
  `severity_original`; `summary`, `description`; `resource{}` with OpenTelemetry semantic-convention keys;
  `observer{}` (the reporting system); `labels{}` with a `labels_origin{}` sidecar; `annotations{}`;
  `links[]`; `starts_at`, `ends_at`, `observed_at`, `processed_at`; `raw{ref, sha256, size}`;
  `pipeline{version, stages_applied, enrichment_errors}`; namespaced `extensions{}`.
- **Source of truth:** protobuf (`proto/correlia/event/v1/`), with explicit snake_case `json_name`, a generated
  JSON Schema, and `buf breaking` as a gate. Minor versions are additive only; a breaking change is a new
  major (`.v2` type, `correlia.v2` subjects) published side by side during migration.

- **Bounds, one contract end to end:** every string field has a documented maximum, and decoders enforce it
  at the boundary. Over-long display text is truncated with a marker (full text stays in the raw row);
  over-long identity fields are hashed (ADR 0012). Rendered outputs (summaries, subjects, chat titles) have
  per-channel limits and are folded to one line where the channel requires it. A schema-valid input never
  fails later on length; an invalid one is rejected at ingest with 4xx or dead-lettered with its reason,
  never a 500 (legacy B6, B11).

Rejected: a bespoke JSON schema without an envelope (loses CloudEvents tooling and bindings), and PagerDuty
PD-CEF as the format (too thin for resource/observer/labels). Reversal cost: high once external consumers
exist, which is why the format is fixed in the first milestone.

## Consequences

- Correlia doubles as a normalizer: consumers can ignore incidents and just subscribe to events.
- Codegen (buf) for Dart, Go, Python, Rust and TypeScript from one definition.
- Field naming of Alertmanager, Icinga2 and OTel must be mapped explicitly per source; mapping tables are part
  of each integration's spec.
