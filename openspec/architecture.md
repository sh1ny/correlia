# Correlia Architecture

The current system shape. Change designs read this first. Detail lives in the ADRs (`docs/adr/`), the
research (`docs/research/`) and the change designs.

## System triage

- **T1 Components: yes.** The system has an api role, a worker role with pipeline stages and relays, a
  plugin host, external plugin processes, a Flutter web console and Postgres.
- **T2 State: yes.** It holds the alert state, the incident lifecycle state machine, rule versions,
  outbox/delivery state and plugin supervision state.
- **T3 Concurrency: yes.** Workers are claim-based and run on several instances and isolates, in no
  processing order; only the per-alert ordering fence orders state (ADR 0016, 0017). Relays and supervisors
  run in the background.
- **T4 Boundaries: yes.** These are versioned contracts:
  - the canonical event format (CloudEvents + protobuf/JSON);
  - the plugin gRPC protocol;
  - the public REST/webhook API;
  - NATS subjects;
  - the DB schema and its migrations.
- **T5 Volume: yes.** Raw inbox, events, activity and outbox grow without bound unless partitioned and
  retained. Alert storms create hot correlation groups.
- **T6 Risk: yes.** Ingest credentials, user auth, secrets in plugin configs, and sensitive data in alert
  text that goes out to external systems.

## Components

```mermaid
flowchart LR
  subgraph Sources
    I2[Icinga2]:::ext
    AM[Alertmanager / Thanos Ruler]:::ext
    GW[Any tool via generic webhook]:::ext
  end
  subgraph API[correlia_server role=api]
    WH[Webhook routes /hooks/kind/instance]
    EP[Serverpod endpoints + streams]
    WEB[Static Flutter web bundle]
  end
  subgraph WRK[correlia_server role=worker]
    PIPE[Pipeline stages: decode, normalize, enrich, classify, route]
    COR[Alert state + correlation engine]
    REL[Outbox relays, one per output]
    PH[Plugin host + supervisor]
    SCH[Scheduled jobs: pull sources, expiry, retention, reminders]
  end
  PG[(PostgreSQL 16+)]
  subgraph Plugins[External plugin processes, gRPC]
    PN[output-nats Go]
    PX[other plugins, any language]
  end
  NATS[(NATS JetStream)]:::ext
  UI[Flutter web console]

  I2 -- webhook / event stream --> WH
  AM -- webhook --> WH
  GW --> WH
  WH -- raw inbox insert --> PG
  PIPE -- claim / commit --> PG
  COR -- same transaction --> PG
  REL -- claim outbox --> PG
  REL -- gRPC stream --> PH
  PH -- spawn, handshake, gRPC --> PN
  PH --> PX
  PN --> NATS
  SCH -- pull via source plugins --> I2
  UI -- endpoints + streams --> EP
  EP -- read / write --> PG
  classDef ext fill:#eee,stroke:#999
```

| Component | Responsibility | Owns (state) | Talks to via (contract) |
|---|---|---|---|
| Webhook routes (api) | Authenticate the source instance, bound the body size, store raw input, return 202, push back with 429/503 | nothing (writes `raw_inbox`) | HTTP: per-source formats; DB |
| Endpoints + streams (api) | Console and automation API; live change feed | sessions (Serverpod auth) | Serverpod protocol (generated client); DB |
| Pipeline stages (worker) | Raw → canonical events: decode, split, normalize, enrich, classify, route | stage cursors and claims | In-process plugin interfaces; DB |
| Correlation engine (worker) and `StateMutationService` | Alert state with ordering fences, incident open/merge/resolve, thresholds, silences, maintenance; the only writer of incident state, also used by endpoints and jobs | `alerts`, `incidents`, `incident_alerts`, `threshold_contributions`, `incident_transitions`, `activity` | DB: one transaction per batch, lock protocol of ADR 0017 |
| Outbox relays (worker) | Deliver routed events and notifications per output, with retry, backlog budget and dead letters | `outbox` delivery state, `delivery_attempts` | Output plugin interface; DB |
| Plugin host (worker) | Spawn, handshake, configure, health-check and restart external plugins; adapt them to the Dart interfaces | plugin runtime state (memory) and plugin status rows | go-plugin handshake + Correlia plugin protocol v1 (gRPC) |
| Scheduler (worker) | Pull sources, incident expiry, reminders, retention, partition maintenance | job rows (Serverpod future calls) | DB. Future calls run in every Serverpod monolith, so the api role sets `futureCall.executionEnabled: false` (present in Serverpod 4.1.0's config); the first change that adds a future call applies it |
| External plugins | Source, decoder, enricher or output in any language | their own | Correlia plugin protocol v1 |
| Flutter web console | Operators' and engineers' UI | client-side view state only | Generated Serverpod client + streams |
| PostgreSQL | System of record | everything durable | SQL (Serverpod ORM + raw SQL for claims) |

**Roles.** Every role runs Serverpod as a monolith (bootstrap-workspace D11), so Serverpod's own services
run in every role unless they are switched off:
- future calls would also execute in the api role; it sets `futureCall.executionEnabled: false`, applied by
  the first change that adds a future call;
- the generated RPC endpoints are served on the API port in the worker role too, beside the health
  endpoints.

## State ownership

| State | Sole writer | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|
| `raw_inbox` | Webhook routes, pull sources (insert); pipeline (state) | `done` rows: retention window (configurable, default 30 d). `pending`/`failed` or dead-letter-referenced rows never expire (ADR 0016) | Automatic retries reuse the pinned config version; an operator's pipeline replay uses the current one (ADR 0016) | Postgres |
| `events` (canonical) | Pipeline normalize/enrich stage | Retention (configurable, default 90 d), partitioned; kept while referenced by a pending or dead-lettered outbox row | Evidence, not state. Re-derivable from `raw_inbox` while that is retained | Postgres |
| `alerts` (state per fingerprint, with ordering fence and `last_observed_at`) | `StateMutationService` | Firing: indefinite. Resolved: kept as tombstone at least the lateness horizon (default 7 d) | **Authoritative, never rebuilt** from events (ADR 0017) | Postgres |
| `incidents`, `incident_alerts`, `threshold_contributions`, `incident_transitions` | `StateMutationService` only (pipeline, operator actions, expiry/reminder jobs, merge/split all call it) | Indefinite (archival policy later) | Not rebuilt; the activity ledger explains every change | Postgres |
| `activity` ledger (also the change feed, cursor `(txid, id)`) | `StateMutationService`, endpoints; supervisor for plugin degraded/recovered entries in the status transaction | Indefinite (feed retention configurable; older cursors get `cursor_expired`) | Append-only | Postgres |
| Configuration versions (rules of every kind, source mappings, routing, plugin config) | M1 ingest publication repository; later endpoints and provisioning loader | Versioned forever | Immutable; M1 activation requires increasing revision; revert by publishing earlier content at a higher revision | Postgres; M1 bootstrap files are inputs |
| Source instances and namespaces | M1 ingest publication repository; later endpoints (admin) | Until removed | Admission state atomically follows the active snapshot | Postgres (ADR 0024) |
| `outbox`, `delivery_attempts` | Pipeline and `StateMutationService` (insert), relays (update) | M1 retains all rows; later retention applies to terminal work | Only durable delivery queue; plugin batches pin one definition digest and complete atomically under claim/lease fences; individually oversized intents are retained dead before transport without a new attempt (ADR 0027); replay (byte-identical) is later work | Postgres |
| Plugin configs and secrets | M1 publication repository owns webhook and plugin secret commitments; operator owns secret bytes in a local file; later endpoints own plugin configuration | Until changed | New reference for rotation; no secret values in Postgres; missing plugin material blocks only its definition, not startup | Postgres commitments and operator-owned secret file |
| Plugin process state and admission cursor | Plugin supervisor | Process lifetime | Restart and re-handshake; memory holds only running instances and one keyset cursor | Memory |
| `plugin_instance_status` | Supervisor of the named host; periodic cross-host expiry only after >24 h without a heartbeat | Every 60 s: own stopped rows >60 s old only without health for their key; other hosts' rows >24 h old | Transitions; ready/waiting rows every 15 s, starting at launch; >60 s heartbeats read stale, not proof of death | Postgres mirror |
| `plugin_definition_health` | Supervisor of the named host | While failed definitions have queued/delivering work; cross-host expiry after >24 h silence and last status-row removal | Backoff, ≤6 failure times and circuit survive eviction; owning host prunes only without live work; stopped status rows with health remain as expiry anchors | Postgres |
| Console view state | Console | Session | Re-fetch after a stream invalidation | Browser memory |

## Boundaries and contracts

- **Canonical event** `correlia.event.v1` (ADRs 0004, [0021](../docs/adr/0021-canonical-event-v1-contract.md)):
  annotated protobuf in `proto/correlia/event/v1/` generates strict payload JSON Schema, Dart messages
  and bounds. A small handwritten CloudEvents structured-JSON codec derives/checks envelope attributes.
  Strict ProtoJSON, full boundary validation (including 256 KiB aggregate size) and exact frozen-v1
  domains precede acceptance; JSON Schema alone is insufficient. Raw size is uint32 referenced-body
  metadata, not a raised default ingress limit. Events above 64 KiB need transport-specific support.
  Buf FILE plus exact annotation/enum-domain checks use one committed v1.0 baseline; later-minor
  publication must extend compatibility coverage first. Newer-minor JSON is a known-core projection,
  while frozen protobuf backing retains unknown binary fields. Optional binary metadata controls scope;
  absent metadata means unknown scope, never an inferred minor. CloudEvents `type` carries the major
  version and `dataschema` the minor.
- **Plugin protocol** `correlia.plugin.v1` (ADRs 0020, [0025](../docs/adr/0025-plugin-protocol-v1-output-contract-and-supervision.md), [0026](../docs/adr/0026-plugin-configure-diagnostics.md)):
  `proto/correlia/plugin/v1/plugin.proto` defines the production output subset: metadata, Configure with
  separate secrets, health and credit-bounded delivery with per-event outcomes. Stock go-plugin handshake
  negotiates application protocol 1 with cookie `CORRELIA_PLUGIN=correlia.plugin.v1`. One stream is one
  epoch. Shared launch internals use the D24 transport; the spike remains experimental. Buf lint and
  generated Dart/Go drift checks apply now; the breaking baseline freezes at 1.0.
  Configure separates non-secret result information (≤ 8 entries, keys ≤ 64 ASCII bytes, values ≤
  256 UTF-8 bytes) from a validated plugin error class. Response/frame checks (64 KiB) precede diagnostic
  and accepted/rejected exclusivity checks. Host rejection stays `plugin_config_rejected`; the plugin
  class is exposed separately and mirrored in status only after exact secret-byte scrubbing. Information
  and field messages are not automatically logged or persisted.
- **Experimental output probe** `correlia.plugin.spike.v1`
  ([0023](../docs/adr/0023-native-openssl-plugin-probe.md)): `proto/correlia/plugin/spike/v1/`. A
  Correlia-owned, unstable, output-only probe that carries immutable canonical event bytes in bounded
  batches with epoch and sequence acknowledgements, used to prove ADR 0020's four Linux spike criteria
  against stock go-plugin. It is not `correlia.plugin.v1`, not a preview of it and not a plugin SDK: no
  compatibility promise, no durable queue, no supervision. Its delivery guarantee is at-least-once with
  pending work only in the surviving host. The experimental authenticated connector uses system OpenSSL 3
  in process, with TLS 1.3 and observed P-521 identities; the failed built-in TLS path is retained separately.
  Production transport (D24), acceptance of this custom-connector interpretation/native dependency and any
  security fallback stay owner decisions, not consequences of passing runtime tests.
- **Inbound formats:** one mapping spec per integration (`openspec/specs/integration-<name>/`), with fixture
  payloads captured from real systems.
- **NATS subjects** (ADR 0018): `correlia.v1.ev.<tenant>.<kind>.<source_kind>.<severity>` and
  `correlia.v1.incident.<tenant>.<status>`. There is no delivery order per alert: consumers order by the
  event's time fields and dedupe by event id.
- **Public API:** Serverpod endpoints for the console (generated client). Versioned REST under `/api/v1/` for
  automation and third parties: incidents, alerts, actions and rule import/export. API keys are scoped. Any
  malformed input (bad timestamp, naive datetime, unknown enum, oversize field) is a 400/422 with a field
  error (`application/problem+json`), never a 500 (legacy B7).
- **Identities:** source, transport delivery, observation (event id) and alert (fingerprint), with one
  canonical encoding (ADRs [0024](../docs/adr/0024-identities-and-upstream-evidence.md), [0021](../docs/adr/0021-canonical-event-v1-contract.md)). The fixed UUIDv5
  namespace is `f36aac0f-16fa-46db-951b-bb578b323aed`, distinct from operator alert namespace strings.
- **Change feed:** `(txid, id)` cursors over the activity ledger with the xmin watermark (ADR 0017).
- **Database:** Serverpod-managed migrations by default. SQL-owned exception tables that require composite
  identities have no generated table model: Serverpod requires a scalar model id. Correlia's own **schema step**
  creates them. Serverpod builds a fresh database from the latest `definition.sql`
  alone, which leaves out unmanaged tables, so SQL added only to a `migration.sql` would exist after an
  upgrade but never on a fresh install. The schema step:
  - is an ordered set of forward-only SQL scripts in the server package, each applied once and recorded in
    a Correlia versions table;
  - runs at startup right after Serverpod applies its migrations, on fresh installs and upgrades alike,
    under a Postgres advisory lock, and before any role starts work; test databases run it too;
  - is tested on both paths: an empty database, and a populated database at the previous release;
  - owns only the listed exception tables, which managed tables do not reference by foreign key.

  Each exception is a reviewed one listed here:
  - `activity`: schema step 0002 creates the ledger with its
    `txid xid8 DEFAULT pg_current_xact_id()` column (ADR 0017);
  - `events`, `raw_inbox`, `outbox`: SQL-owned time-qualified composite primary keys, initially ordinary
    tables, with partition maintenance deferred to M2 (ADR 0016). Schema step 0002 adds nullable
    `events.state_outcome` to distinguish applied and stale observations.

  `alerts` is a Serverpod-managed table with a unique tenant/fingerprint index.

  Every migration is forward-only and tested against a populated database. Serverpod repair migrations try
  to drop tables outside the migration system. Review every repair and remove operations against SQL-owned
  tables and their indexes/constraints before applying it; see `docs/ingest-pipeline.md`.
- **M1 ingest configuration:** operator-owned JSON bootstrap files publish immutable public snapshots
  and source token digests atomically. Revisions only advance, including deliberate reverts; signing
  secrets stay in a separate process-owned file, with immutable digest commitments in Postgres. Pending
  work pins its snapshot. M2 provisioning and encrypted database secrets are not implied by this boundary.
- **Rule documents:** a versioned JSON/YAML format with a `language` field (ADR 0008).

## Resource bounds and failure visibility

| Flow / store | Bound | At the bound | On failure | Who finds out |
|---|---|---|---|---|
| Webhook body | 1 MiB default per source. Serverpod's `maxRequestSize` (512 KiB) is global and applies to endpoints; ingest webhooks are custom web routes that enforce their own per-source limit while reading the body (to be proven by the first webhook change, since Serverpod does not document whether web routes are bound by `maxRequestSize`) | 413 | n/a | The sender; an ingest-rejected counter |
| Raw inbox lag | Configurable age/count (default 30 s / 50k rows) | 429/503 + `Retry-After` | n/a | The sender retries; a console banner shows backpressure |
| Decode | Per-event time budget | Event dead-lettered | `pipeline_failures` row with error | Console dead-letter view with replay |
| Enrichment | Per-rule regex timeout; per-plugin deadline | Rule skipped and recorded | Soft: `pipeline.enrichment_errors[]` | Event detail; per-rule error counter |
| Correlation group size | Unbounded membership, relational; display capped | n/a | Group lock serializes writers; deadlock/lock-timeout retries (5) then batch split, then pipeline failure | Metrics: lock waits, retries, hot groups |
| Ingest storage | DB-size watermark (default 85 % of the disk budget) | 429/503 + `Retry-After`; pull sources pause | Accepted work is never dropped | Console banner; health `/readyz` degraded |
| Output storage | Per output: 500k rows / 1 GiB, pending and dead-lettered combined | Output `overflowing`; policy `discard_new` (default, counted in the ledger) or `block_ingest` (opt-in) | Others unaffected under `discard_new` | Self-alert; console output health; counter |
| Observation dedup | `observation_keys` kept until max(first seen, source time) + 7 d + 5 min; source time at most 24 h ahead | Pruned by retention; later retries are `late`; far-future observations quarantined `future_dated` | n/a | `duplicate_observation` and `future_dated` counters |
| Dead letters | Retention 14 d (configurable) | Expired without replay: discarded, count written to the ledger | n/a | Ledger entry; console dead-letter view |
| Change feed | Watermark lag bounded by the transaction timeout | Feed waits for the watermark; wake-up pushed when it advances; 10 s safety pull | `cursor_expired` beyond feed retention, client re-snapshots | Metric: feed lag |
| Ingest dedup | Window 10 min | Older retries are new deliveries; event ids still dedupe them downstream (ADR 0024) | n/a | M1 process-local duplicate counter, reset at restart |
| Outbox per output | M1: at most 20 started attempts, exponential backoff capped at 300 s | Intent becomes dead in `outbox` | Durable attempt record with error class | SQL inspection; later console and replay |
| Plugin process | 16 starting/ready per worker, 4 per output; 10 s start, 5 s health interval / 2 s deadline; 3 failed checks count as a crash | Keyset round-robin; 60 s idle release and rotation in the blocking scope after the current ≤ 27 s batch; unfinished probes protected through startup and 60 s readiness | 1–60 s exponential backoff; > 5 failures / 10 min opens degraded circuit; 5 min probes; 5 s shutdown grace | SQL status with 15 s heartbeat / 60 s staleness; degraded/recovered activity; console page later |
| Tables over time | Retention per table, configurable (defaults: raw `done` 30 d, events 90 d, delivered outbox 7 d), only terminal rows (ADR 0016) | Partitions dropped only when they hold no unfinished row; otherwise eligible rows deleted | Partition job failure alarm | Health endpoint + console system page |
| Batch jobs (retention, partition maintenance, dead-letter expiry, reprocess-apply) | Short transactions over bounded batches (ADR 0016) | The next batch waits for the next transaction | Job retries from its last committed batch | Metrics: batch duration, feed lag |

## Correctness invariants (legacy defects and hazards)

Every legacy defect (`docs/research/legacy-audit.md` 6.1) and hazard (6.2) has a preventive contract here,
not only a future test. Scenario ids refer to `docs/plan/acceptance-scenarios.md`.

| Legacy | Preventive contract | Where | Scenario |
|---|---|---|---|
| B1 old recovery clears newer problem (and stale problem resurrects) | Per-alert ordering fence; stale events change nothing; tombstones at least as long as the lateness horizon | ADR 0017 | ORD-1, ORD-2 |
| B2 insert/close race gives a 500 | One mutation service; group locks first, discover-lock-revalidate; unique index as backstop | ADR 0017 | COR-2, COR-9 |
| B3 polling misses lifecycle changes | Change feed over the ledger with `(txid, id)` cursor and xmin watermark; entity versions | ADR 0017 | UI-1, UI-3 |
| B4 wrong recovery counts | Mutation results report counts per effect | ADR 0017 | COR-4 |
| B5 group key collisions | Structured group keys with length-prefixed canonical encoding | ADR 0017, 0024 | ID-1 |
| B6 valid input fails later on length | One bounds contract end to end; identity hashed, display truncated, renders limited | ADR 0004, 0024 | ID-3 |
| B7 naive datetime gives a 500 | All malformed API input gives 400/422 problem+json | Boundaries above | ID-5 |
| B8 empty registry skips validation | Atomic config versions validated against an explicit registry; empty is a registry | ADR 0008 | DUR-5 |
| B9 converter promises atomicity it lacks | Excluded: no legacy config converter in scope (assumption 2) | Strategy | n/a |
| B10 re-ack mixes first time and last actor | Ack = ownership; re-ack by another actor transfers; ledger keeps both | ADR 0017 | COR-8 |
| B11 multiline subject suppresses email | Rendered fields folded and limited per channel | ADR 0004 | DUR-7 |
| Future timestamps poison expiry | Effective source time clamped by skew allowance; expiry and windows use observed time | ADR 0017 | ORD-4 |
| Cross-source recovery | Namespace in every fingerprint; sharing only by explicit operator choice | ADR 0024 | ID-2 |
| Ambiguous fingerprint preimage | Canonical encoding | ADR 0024 | ID-4 |
| Threshold meaning mixes samples and objects | Explicit counting policy per rule; observations counted by event id | ADR 0017, 0024 | COR-1 |
| First crossing is not a successful notification | Notification intent is an outbox row committed with the crossing; retries and dead letters | ADR 0016, 0017 | DUR-6 |
| Stale problem restores membership | Membership follows the fenced alert transition | ADR 0017 | ORD-2 |
| Severity never downgrades | Current and peak severity shown separately | ADR 0017 | COR-3 |
| Accepted work lost on crash (no outbox) | Raw inbox and transactional outbox; retention never deletes unfinished work | ADR 0016 | DUR-1, DUR-2 |
| Retries replay effects (no idempotency) | Durable observation dedup before any state effect | ADR 0024 | ORD-5 |

## In-force ADRs

Accepted ADRs only.

| ADR | Decision | Supersedes |
|---|---|---|
| [0001](../docs/adr/0001-serverpod-modular-monolith.md) | Serverpod 4.1 modular monolith; one binary with api/worker/all roles | none |
| [0002](../docs/adr/0002-postgresql-everywhere.md) | PostgreSQL in every run mode; embedded Postgres for development and tests | none |
| [0003](../docs/adr/0003-flutter-web-console.md) | Flutter web console | none |
| [0004](../docs/adr/0004-canonical-event-format.md) | Canonical event: CloudEvents envelope + `correlia.event.v1` protobuf; one bounds contract | none |
| [0016](../docs/adr/0016-durable-staged-pipeline.md) | Durable staged pipeline, transactional outboxes, retention by state, storage budgets, replay vs reprocess; no processing order; replay uses current config; short batch transactions | [0005](../docs/adr/0005-durable-staged-pipeline.md) |
| [0020](../docs/adr/0020-plugin-architecture.md) | Hybrid plugins: built-ins in process, external over go-plugin-compatible gRPC; spike gate on Linux with stdin-EOF exit and Unix-socket fallback | [0015](../docs/adr/0015-plugin-architecture-linux.md) |
| [0017](../docs/adr/0017-alert-and-incident-state-model.md) | Authoritative alert state with ordering fences and `last_observed_at`; one StateMutationService lock protocol; `(txid, id)` change feed | [0007](../docs/adr/0007-alert-and-incident-state-model.md) |
| [0008](../docs/adr/0008-rule-language.md) | Matcher rule tree with in-memory and SQL evaluators, field catalog, atomic config versions; CEL later | none |
| [0009](../docs/adr/0009-identity-and-access.md) | Serverpod auth (invite-only) for people, scoped tokens for machines; redaction | none |
| [0018](../docs/adr/0018-nats-output-as-go-plugin.md) | NATS output as the first external plugin, in Go; exits on stdin close; no delivery order per alert | [0011](../docs/adr/0011-nats-output-as-go-plugin.md) |
| [0024](../docs/adr/0024-identities-and-upstream-evidence.md) | Four identities and durable observation dedup; upstream fingerprint is extension evidence | [0019](../docs/adr/0019-identities.md) |
| [0014](../docs/adr/0014-linux-first-platform.md) | Linux-first platform (owner, 2026-11-03): develop and test in WSL, CI on Linux, Windows not a target; embedded Postgres in tiers; never touch another Postgres | [0013](../docs/adr/0013-develop-and-test-in-wsl.md) |
| [0021](../docs/adr/0021-canonical-event-v1-contract.md) | Additive v1 identity bytes/UUID namespace, strict wire and boundary validation, standard generation and single-baseline compatibility; parse-only future minors | none (clarifies 0004/0019) |
| [0023](../docs/adr/0023-native-openssl-plugin-probe.md) | Restated unstable output probe and four independent runtime gates; in-process system OpenSSL 3/TLS 1.3/P-521 custom connector, authenticated-only public API, isolated diagnostics and bounded native/surviving-host ownership; D24, criterion-2 interpretation and production adoption stay owner-only | [0022](../docs/adr/0022-experimental-output-plugin-probe.md) |
| [0025](../docs/adr/0025-plugin-protocol-v1-output-contract-and-supervision.md) | Production output protocol, readiness permits, atomic outbox batches, fair bounded instances, durable supervision history and kind-aware secret commitments | none |
| [0026](../docs/adr/0026-plugin-configure-diagnostics.md) | Typed bounded Configure diagnostics, validation precedence and exclusivity; secret-scrubbed plugin class separate from host classification | 0025 D1 Configure response (partial); other 0025 decisions remain in force |
| [0027](../docs/adr/0027-plugin-intent-byte-limit-admission.md) | Owner-chosen admission-time oversized-intent dead letters with unchanged bytes/counts, no new attempt, transactional readiness fencing and aggregate-only deferral | none (refines 0025 D4) |

### Superseded ADRs

| ADR | Superseded by |
|---|---|
| [0005](../docs/adr/0005-durable-staged-pipeline.md) | [0016](../docs/adr/0016-durable-staged-pipeline.md) |
| [0006](../docs/adr/0006-plugin-architecture.md) | [0015](../docs/adr/0015-plugin-architecture-linux.md) |
| [0007](../docs/adr/0007-alert-and-incident-state-model.md) | [0017](../docs/adr/0017-alert-and-incident-state-model.md) |
| [0011](../docs/adr/0011-nats-output-as-go-plugin.md) | [0018](../docs/adr/0018-nats-output-as-go-plugin.md) |
| [0012](../docs/adr/0012-identities.md) | [0019](../docs/adr/0019-identities.md) |
| [0019](../docs/adr/0019-identities.md) | [0024](../docs/adr/0024-identities-and-upstream-evidence.md) |
| [0015](../docs/adr/0015-plugin-architecture-linux.md) | [0020](../docs/adr/0020-plugin-architecture.md) |
| [0010](../docs/adr/0010-testing-strategy.md) | [0013](../docs/adr/0013-develop-and-test-in-wsl.md) |
| [0013](../docs/adr/0013-develop-and-test-in-wsl.md) | [0014](../docs/adr/0014-linux-first-platform.md) |
| [0022](../docs/adr/0022-experimental-output-plugin-probe.md) | [0023](../docs/adr/0023-native-openssl-plugin-probe.md) |
