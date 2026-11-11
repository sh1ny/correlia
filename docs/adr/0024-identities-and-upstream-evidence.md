# 0024. Four identities and upstream fingerprint evidence

- Status: accepted (2026-11-11)
- Date: 2026-11-11
- Supersedes: [0019](0019-identities.md)
- Chosen by: agent

## Context

ADR 0019's identity and durable deduplication decisions remain unchanged. Its placement of an Alertmanager fingerprint in `labels_origin` conflicts with the canonical codec: `labels_origin` describes actual labels, and its keys must occur in `labels`. Adding a synthetic label would change source evidence. This decision changes only the fingerprint evidence location; it changes no fingerprint or observation bytes, UUID namespace or v1 schema.

## Decision

Every identity hashes an ordered list of field-name/value pairs encoded as length-prefixed UTF-8, with label maps sorted by key. Hashes use SHA-256 and UUIDs use UUIDv5 under Correlia's fixed namespace `f36aac0f-16fa-46db-951b-bb578b323aed`.

### Source

Every source instance has a UUID, its own credentials and a namespace defaulting to the instance. Operators may explicitly share a named namespace across replicas. Namespace is part of each alert identity, preventing accidental cross-source recovery.

### Transport delivery

Each raw inbox row represents a delivery. Exact sender retries deduplicate on a supplied `Idempotency-Key`, or otherwise on source instance and body SHA-256 within the deduplication window (default ten minutes). Duplicates receive 202 and increment the duplicate counter without creating another row.

### Observation

The event id is UUIDv5 over source instance, fingerprint, observation key and pipeline generation. Native observation keys include Icinga2 check-result execution time, Alertmanager status/startsAt/endsAt, and a declared generic-mapping id. Otherwise the key is status, severity and the exact reported source time, never clamped time. Every source must provide delivery-independent evidence; no arrival-time fallback exists. Rebatches and reordering preserve event ids. Equal fingerprint/status/severity/source-time observations are the same, and observation thresholds count distinct event ids. Initial processing and pipeline replay use generation zero; applied reprocessing increments it and links the original.

An unpartitioned `observation_keys` table records event id, fingerprint, first ordering evidence and first seen time. Insert on conflict before state effects. A duplicate preserves first evidence, increments duplicate-observation count, advances only the alert's `last_observed_at`, and causes no other state, contribution, notification or output effect. Far-future evidence (default more than 24 hours ahead) is quarantined without a key or state effect. Keys are retained through `max(first seen, source time)` plus lateness horizon and skew allowance (defaults seven days plus five minutes), using fixed first evidence; retries cannot extend retention. After expiry the same evidence is late and cannot apply; quarantine did not consume a key and can later apply once eligible.

### Alert

The fingerprint is SHA-256 of canonical tenant, namespace, source kind and decoder-defined identity fields. Icinga2 uses host and optional service name. Alertmanager and Thanos use all original labels including severity, minus the per-source exclusion list, empty by default. Thus two severity-labelled rules are distinct unless the operator excludes severity. Generic mappings declare at least one identity field. Decoder-declared fields take precedence: normalized status and severity, summary, message, check output and timestamps are not identity inputs, although an original severity label remains one when selected. Source-modelled severity is an update; label-modelled severity is a replacement unless excluded.

Alertmanager's upstream fingerprint is retained as raw evidence and in `extensions[correlia.io/alertmanager_fingerprint]`, not as identity and not as `labels_origin`. The latter remains reserved for actual label-origin evidence.

Identity-field limits are enforced at the decoder. Overlong identity values are hashed in full rather than truncated for identity; display projections carry a truncation marker. Schema-valid input must not fail later solely for length.

## Alternatives and reversal cost

Upstream fingerprints as identity are rejected because their scope and algorithms can change; payload hashes break rebatching; global host/service identity permits cross-source recovery. A synthetic label or relaxing `labels_origin` constraints would pollute evidence or weaken the codec, so neither is chosen. Reversal cost is high for published identity bytes because consumers deduplicate by event id, and medium for the published evidence location because later consumers depend on it.

## Consequences

Only deliberately shared namespaces permit cross-source recovery. Distinct-event thresholds exclude retries and rebatches. Observation keys grow with event volume over the lateness horizon until retention prunes them. Changing decoder identity fields is a breaking integration change requiring a migration note; old alerts resolve by expiry. The current ingest slice retains observation keys without pruning and defers alert-state mutation and retention to later work; it does not claim those later state effects are implemented.
