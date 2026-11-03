# 0019. Four identities: source, transport delivery, observation and alert

- Status: proposed
- Date: 2026-11-03
- Supersedes: [0012](0012-identities.md)

## Context

This ADR restates ADR 0012 with one change from the 2026-11-03 design review: a duplicate observation
advances its alert's `last_observed_at` (ADR 0017) instead of recording nothing, so an alert that a source
keeps repeating (for example an Alertmanager repeat notification) is known to be still reported. Duplicates
are not routed to outputs (owner, 2026-11-03, D25). Everything else is unchanged from ADR 0012.

The legacy service had several identity problems (legacy audit B5, 6.2):
- It built fingerprints from pipe-joined strings, which collide.
- It erased the source when matching recoveries, so one source could recover another's problem.
- It mixed "stable object identity" with "sample identity", so the meaning of a threshold depended on a
  cache.


Alert state, ordering and incident membership (ADR 0017) all hang on identity. So does deduplication by
consumers (ADR 0016, 0018). Each of these needs a different notion of "the same".

## Decision

### Canonical encoding
Every identity hashes a **canonical encoding**:
- an ordered list of (field name, value) pairs;
- each name and value is UTF-8 and length-prefixed;
- label maps are sorted by key.

No delimiter can make two different tuples encode the same way. Hashes are SHA-256. UUIDs are UUIDv5 under a
fixed Correlia namespace UUID.

### 1. Source identity
- Every source instance is registered and has an id (UUID), its own credentials and a **namespace**.
- By default the namespace is the source instance itself.
- An operator may put several instances into one named shared namespace. For example, two Alertmanager
  replicas, or Icinga2 HA masters.
- The namespace is part of every alert identity. So a recovery from one namespace can never resolve an alert
  of another.

### 2. Transport delivery identity
- A raw inbox row.
- An exact retry by the sender is deduplicated at ingest. It is detected by:
  - an `Idempotency-Key` header, when the sender provides one; or
  - (source instance, body SHA-256) inside a dedup window (default 10 minutes).
- A deduplicated delivery gets 202 and a `duplicate` counter, and creates nothing.

### 3. Observation identity (the event id)
- A UUIDv5 over (source instance, fingerprint, observation key, pipeline generation).
- The **observation key** is source-native where it exists:
  - Icinga2 check result execution time;
  - Alertmanager (status, `startsAt`, `endsAt`);
  - a declared id field in a generic mapping.
- Otherwise the observation key is (status, severity, **reported source time**): the timestamp exactly as
  the source sent it, never the clamped effective time, so it cannot change between deliveries.
- **Every source has delivery-independent evidence.** Each built-in decoder has a native key or a source
  time. A generic mapping must declare an observation id field or a source time field; activation of a
  mapping without either fails validation (ADR 0008). There is no arrival-time fallback.
- It does not depend on how a sender batched alerts into one webhook. Re-batched or reordered webhooks give
  the same event ids.
- Two observations with the same fingerprint, status, severity and source time are the same observation, by
  definition. The `observations` threshold policy counts distinct event ids.
- **Generation:** first processing and pipeline replay use generation 0. An applied reprocess (ADR 0016)
  increments it, so the reprocessed event gets a new id and links to the original.
- **Durable observation dedup, before any state effect.** `observation_keys` (event id primary key,
  fingerprint, first ordering evidence, first seen at) is an unpartitioned table. In the batch transaction,
  before touching alert state, contributions or notification intents, the pipeline inserts the event id
  with `ON CONFLICT DO NOTHING`. A conflict means the observation was already applied: the event is
  counted as `duplicate_observation`, its original ordering evidence stays, and it advances only its alert's
  `last_observed_at` (ADR 0017). It has **no** other state, contribution, notification or output effect,
  and it is not routed. This holds for sender retries after the transport dedup window,
  re-batched webhooks and pipeline replays.
- **Far-future observations are quarantined.** An observation whose source time is more than the future
  limit (default 24 h) ahead of its observed time is stored with status `future_dated`, shown in the
  console and counted, and has no state effect. It gets no observation key.
- **Dedup retention uses stable evidence only.** A key is kept until `max(first seen, source time)` plus
  the lateness horizon plus the skew allowance (default 7 d + 5 min). Both inputs are fixed on first
  application; a redelivery cannot advance them. The future limit bounds the retention at first seen +
  24 h + 7 d + 5 min.
- **Why at most once:** a retry R arriving after its key expired has R later than the source time + horizon
  + skew. Its effective source time is `min(source time, R + skew)`, which is the source time, so it is older
  than the lateness horizon: `late`, no state effect (ADR 0017). Before expiry the key itself blocks it. A
  quarantined observation was never applied, so applying it later (once its source time is within the
  future limit) is its first and only application.

### 4. Alert identity (the fingerprint)
- SHA-256 of the canonical encoding of (tenant, namespace, source kind, identity fields).
- Each decoder's integration spec lists its **identity fields**, and they are tested with fixtures:
  - **Icinga2:** host name, plus service name when present. A host-only alert and a service alert are
    different alerts.
  - **Alertmanager / Thanos:** the full label set, **including** `severity`, minus a per-source list of
    excluded labels (empty by default). This matches Alertmanager's own semantics and the common pattern of
    two rules (`warning` and `critical`) for one condition that fire at the same time: they are two alerts,
    and the correlation rule groups them into one incident. An operator whose rules change a severity label
    in place can exclude it per source; then a label change is a severity update of one alert. Upstream
    fingerprints are kept as `labels_origin` evidence, not used as identity.
  - **Generic webhook:** the fields declared in its mapping. A mapping must declare at least one.
- **Precedence:** a decoder's declared identity fields always win. The *normalized* `status` and
  `severity` fields, summary, message, check output and timestamps are never identity inputs. A source label
  that is an identity field stays one even when the decoder also maps it to severity: then a change of that
  label is a different alert, and the previous one ends through its own resolve, its `endsAt`, or expiry.
- So a severity change is an update of one alert where the source models severity as state (Icinga2 host
  and service states, Zabbix problem severity), and a replacement alert where the source models it as
  identity (Alertmanager labels, unless excluded).

### Bounds
Identity fields have hard length limits enforced by the decoder. An over-long identity field is hashed, not
truncated: the event records the hash, and the display field shows a truncation marker. A schema-valid input
never fails later because of length (legacy B6).

Rejected:
- Upstream fingerprints as identity: they are per-instance, and their algorithms change between versions.
- Raw-payload hashes as event ids: they break on re-batching and conflate distinct deliveries.
- Global host/service identity across sources: it causes cross-source recovery (legacy 6.2).

Reversal cost: high once events are published, since consumers dedupe on event ids.

## Consequences

- Cross-source recovery happens only between instances that an operator put in the same namespace
  (scenario ID-2).
- Thresholds that count observations are well defined, and neither transport retries nor re-batching
  inflate them or replay their effects (scenario ORD-5).
- The `observation_keys` table grows with event volume over the lateness horizon; it is bounded by that
  horizon and pruned by the retention job.
- Changing a decoder's identity fields changes fingerprints. That is a breaking change to the integration
  spec: it needs a migration note, and old alerts resolve by expiry.
