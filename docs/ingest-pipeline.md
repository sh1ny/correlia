# Ingest pipeline schema ownership

Serverpod migrations own source and configuration snapshots, the active pointer, secret commitments, transport and observation keys, pipeline failures and delivery attempts. Correlia's ordered `correlia_server/schema/*.sql` steps exclusively own `raw_inbox`, `events` and `outbox`. These tables have no generated table models. They are ordinary PostgreSQL tables with time-qualified composite primary keys; future partition maintenance remains with the SQL schema owner. References to SQL-owned identities always include their time component. Managed tables do not have foreign keys to SQL-owned tables.

## Fresh databases and upgrades

Start the server from `correlia_server`, with its `schema/` directory deployed alongside the package. Serverpod applies managed migrations first. Each process role then initializes the schema before starting its subsystems, even if ingest is not configured. A transaction advisory lock serializes starters, and each step and its version record commit together. Existing steps are immutable: append a new numbered script and register it in the runner for every forward change. Both a fresh installation and an upgrade need the schema steps because Serverpod fresh installs use its latest managed definition rather than replaying every migration SQL file.

The database test helper `test/support/ingest_schema.dart` must receive a non-rollback session and run after managed migrations. Do not change generated test tools or hand-edit generated migration definitions. Failure of a schema step rolls back that step and prevents subsystem startup; fix the underlying problem and restart. The reported error names the step without exposing database details.

## Schema step 4 and the offline upgrade

Step 4 (`schema/0004_icinga2.sql`) adds a nullable `events.effective_source_time timestamptz` and the SQL function `events_effective_source_time(events)`. The column has no default and no backfill, so PostgreSQL changes only the catalog: no event row is rewritten, no extra disk is needed on a populated table, and the step holds its exclusive lock on `events` only briefly.

Every row this release writes sets the column to the effective time, which the pipeline computes with the same ordering-key function that fences alert state: the source time, capped at the observed time plus the five minute skew allowance. The value is stored whether or not it was capped, with microsecond precision like `source_time`; it serves queries and stored ordering evidence, while exact ordering still uses the canonical evidence's nanosecond times. The event's published `source_time` always stays as the source reported it. The raw outcome JSON of the row gains a `clamped` count of the events whose effective time was capped. Expiry, correlation windows and reminders use observed time, not this value.

A null column marks a row written before step 4. Read the effective time of any row through `events_effective_source_time(events)` and never read the column alone: for a null column the function returns `LEAST(source_time, observed_at + interval '5 minutes')`, which is the cap the alert state service already applied to those rows without recording it. For example, `SELECT events_effective_source_time(e) FROM events e`.

Every schema transaction starts with `SET LOCAL lock_timeout`, before it requests the schema advisory lock (30 seconds in production). Waiting behind another starter, or step 4's `ALTER TABLE` waiting for a lock on `events` (for example a long reader or an open transaction), therefore ends in a failure and not in a hang. The startup error names the step and a sanitized failure class: `lock_timeout` (SQLSTATE 55P03) or `failed`, for example `Schema step 4 failed: lock_timeout`. The process exits non-zero, the transaction rolled back and no version was recorded. Step `0` is the version table itself, which is where a wait on the advisory lock ends. Once the blocking session ends, start the process again; the next start applies the step.

The upgrade is offline. Stop every older process of every role (`api`, `worker`, `all`) before any process of this release starts, and do not restart an older one afterwards. Any role of this release applies step 4 at startup, while an older process decodes every row as Alertmanager, writes no effective time and publishes configuration with a publisher that overwrites a source's kind. Rows admitted before the stop stay `pending` in `raw_inbox` and are claimed and processed by the upgraded workers, so nothing admitted is lost. No mixed-version mechanism exists, because the cutover happens once.

## Repair migrations

Serverpod's repair diff sees SQL-owned tables as extraneous and may propose destructive changes. Before applying any generated repair, inspect its entire SQL against the current schema and **remove all operations that drop or alter** `raw_inbox`, `events`, `outbox`, `activity`, `correlia_schema_versions`, their indexes, constraints and time-qualified references. Review related cascades as well. Preserve data and the version table; never force a destructive repair merely to silence drift. Inspect any other unmanaged exceptions individually. If the desired SQL-owned schema itself needs correction, write a new forward schema step, not an edit to an applied step or a generated definition. Review the resulting repair and schema step together on a populated copy before production use.

## Identity evidence

Alertmanager's upstream fingerprint is retained in raw input and, when present, the `correlia.io/alertmanager_fingerprint` extension. It is not a label or an identity input. Original selected labels determine identity; see ADR 0024. Source-side setup screenshots have not been collected.

## Bootstrap and rotation

Set `CORRELIA_INGEST_CONFIG` to a regular JSON file (at most 64 KiB) and
`CORRELIA_SECRET_KEY_FILE` to the external 32-byte encryption key file. Both the key and optional
`CORRELIA_INGEST_SECRETS` import file must be regular, non-symlink files owned by the process user,
mode 0600 or stricter. The import file is bounded at 512 KiB encoded and 256 KiB decoded across 128 entries.
Errors expose only file kind, field and code. Keep plaintext imports and the external key out of Git and diagnostics.

Generate the key once in a private directory; use the same key on every instance sharing the database:

```sh
(umask 077; set -o noclobber; openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' > correlia-secret.key)
```

Back up the key separately from PostgreSQL and retain it for restores. Without it, the existing encrypted
records cannot be opened. Do not generate a replacement over an existing key file during deployment or restore.

Generate a separate value for every source credential and signing-key reference:

```sh
openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
```

The result is exactly 43 unpadded base64url characters. Put these generated values in the secret JSON object under the reference names below, then run `chmod 600` on that file. Never commit either operator file or print the secret file in diagnostics.

Format v2 configuration:

```json
{
  "format_version": 2,
  "revision": 1,
  "namespaces": ["platform"],
  "sources": [{
    "id": "11111111-1111-4111-8111-111111111111",
    "enabled": true,
    "kind": "alertmanager",
    "namespace": "platform",
    "credentials": [{
      "type": "bearer",
      "ref": "alertmanager-token-v1"
    }],
    "rate_limit": {"per_second": 20, "burst": 40},
    "path_token_enabled": false,
    "body_limit_bytes": 1048576,
    "excluded_identity_labels": [],
    "output_ids": ["22222222-2222-4222-8222-222222222222"]
  }],
  "outputs": [{
    "id": "22222222-2222-4222-8222-222222222222",
    "kind": "webhook",
    "url": "https://receiver.example/events",
    "signing_key_ref": "webhook-signing-v1"
  }]
}
```

The secret object needs `alertmanager-token-v1` and `webhook-signing-v1`, each mapped to its separately generated value. The registry permits at most 64 sources, 64 outputs, 128 secret references and eight distinct output ids per source. An empty output list is explicitly unrouted; an unknown output reference is an error, even if the output registry is empty. Source namespaces default to their UUID.

V2 namespaces must be declared, unique, at most 128 UTF-8 bytes, and not UUID-shaped. Give sources
the same declared namespace only when identical input should map to the same alert.
V2 supports one to four distinct `bearer` or `hmac` credential references. Optional `not_before` and
`not_after` are ISO 8601 instants with a timezone (inclusive start, exclusive end). At least one
credential must be unexpired when published. Rotate by adding the replacement reference, updating the
sender, then removing the old credential at a higher revision. V2 rate limits are per authenticated source
per API process: `per_second` 1–1000, `burst` 1–10000, default 20/40. Replicas multiply the effective budget.

A v2 source's `kind` is `alertmanager` or `icinga2`; any other value fails activation with a field error at
`sources[i].kind`. Each source accepts deliveries only on its own kind's route, `/hooks/alertmanager/<source-uuid>`
or `/hooks/icinga2/<source-uuid>`. `path_token_enabled` and `excluded_identity_labels` are Alertmanager-only
options: an `icinga2` source that declares either fails activation with a field error naming
`sources[i].path_token_enabled` or `sources[i].excluded_identity_labels` (code `alertmanager_only`), and a request
with a credential in the path of the Icinga 2 route (`/hooks/icinga2/<source-uuid>/<credential>`) is answered 401
with nothing stored. A source UUID keeps the kind it was first published with, so a pinned raw row always decodes
with the kind it was admitted under. Publishing the same UUID with another kind fails with code `kind_changed` at
`sources[i].kind`, also when the source was removed or disabled in between; the prior snapshot stays active. To
change a source's kind, give it a new UUID.

V1 accepts `token_ref` instead of `kind`, `credentials`, and `rate_limit`; it maps to one Alertmanager bearer
credential and keeps any existing namespace. For an M1 upgrade supply the key file and original import
file, including keys needed by live deliveries and by outputs routed from already-pinned pending raw rows.
Bump the revision once even if the v1 input is otherwise unchanged. New public snapshots use the v2 shape.
Rotate v1 source tokens under a new `token_ref`; never
replace bytes under an existing reference.

Plugin outputs use exactly `id`, `"kind": "plugin"`, `plugin`, `sha256`, `config` and `secret_refs`. `plugin` is a filename matching `^[a-z0-9][a-z0-9._-]{0,63}$`; `sha256` is its 64-character lowercase executable digest. `config` is a JSON object of at most 16 KiB; `secret_refs` maps at most eight plugin secret names to references in the secret file. Workers require `CORRELIA_PLUGIN_DIR`, owned by the process user and not writable by group or others. Api-only processes validate the definition without requiring that directory. Executable safety and digest are checked again at every launch.

A secret entry may instead be `{"bytes": "<unpadded base64url>"}`, holding 1 byte to 16 KiB decoded.
Source credentials and signing keys still require 32 bytes. Publication seals them in PostgreSQL.
After import, processes can restart without the plaintext file; include it when adding new references.
New plugin snapshot commitments are keyed. Historical M1 hashes remain, so rotate low-entropy M1 plugin
secrets under new references rather than relying on encryption to protect those old hashes.

Every plugin intent pins its public definition digest and snapshot. Missing historical plugin secrets do not fail worker startup: that definition stays unavailable with its work queued and no new attempts, while other outputs progress. Missing historical webhook signing material still fails startup. Pending work is never redirected to a newer definition.

Startup atomically publishes immutable public snapshots, credential commitments and the active pointer. Identical active input is a no-op. Every changed publication must be unseen and have a higher integer revision (1–2147483647). Stale or equal-conflicting input fails without changing active credentials or routes. To revert, republish the desired content under a new higher revision; restarting old files never rolls back configuration. Omitted sources become disabled.

Rotate all secrets under new references. The store retains historical material for pinned work without
adding it to current configuration. Work with an unavailable signing key remains queued without consuming
an attempt. Terminal rows retain commitments and do not require keys until future explicit replay.
Active plus retained live output lanes cannot exceed 64.

Every configured process needs the external key. No admin/configuration/raw-payload API is exposed.
Without bootstrap, a worker/all process refuses startup whenever an active snapshot or unfinished
ingest/output work exists. An unconfigured api still serves workspace behavior and rejects hook admission.

## Alertmanager sender setup and admission

POST to `/hooks/alertmanager/<source-uuid>` with `Authorization: Bearer <token>` and `Content-Type: application/json`. Prefer this header form. Only when `path_token_enabled` is true, the alternative is `/hooks/alertmanager/<source-uuid>/<token>` with no Authorization header. The token is the generated 43-character unpadded base64url value. Query parameters and simultaneous credential forms are rejected. Configure reverse proxies to omit or redact credential-bearing paths, queries, Authorization and Idempotency-Key; proxy logs are outside this process's privacy proof. Use TLS for sender traffic.

HMAC-capable senders can instead use a `hmac` credential. Send `X-Correlia-Timestamp` (Unix seconds,
1–10 ASCII decimal digits, within 300 seconds of receipt) and `X-Correlia-Signature: sha256=<64 lowercase hex>`.
Do not also send a bearer or path token. Compute HMAC-SHA256 with the decoded 32-byte key over
`<timestamp>.<K>.<body>`. Use the timestamp digits exactly as sent, `-` for `K` if `Idempotency-Key`
is absent, otherwise lowercase hex SHA-256 of the key's UTF-8 bytes. Append the exact uncompressed body
bytes, with no extra newline. Redact both HMAC headers in proxy logs.

Signing vector (example key only): key bytes `00 01 … 1f`, timestamp `1794960000`, body
`{"status":"firing"}` without a newline. With `Idempotency-Key: hook-42`, the signature hex is
`d1f085472bf0810321dfd82e0fe82b030183b0d5fac61e04e1b177cf190c29e1`; with no key, it is
`1312b999043956efa24658369e0edfd4a94820d000efa08437b9a6ac4ee00e99`.

The receiver checks the source and bearer token or HMAC header syntax before reading the body. It checks
HMAC signatures after the bounded read. The storage transaction rechecks the current credential, source
kind, enabled flag and path-token policy. The inbox stores exact uncompressed bytes, their digest,
receipt time and normalized content type, not authorization, HMAC or idempotency headers.
`Idempotency-Key` is source-scoped and limited to 256 UTF-8 bytes; absent that header, the source/body digest
identifies retries. The ten-minute reservation window is fixed from first admission and does not slide.

Bodies default to—and cannot exceed—1 MiB; a source may select a lower positive limit. A ten-second total body deadline and sixteen request slots bound admission, with a smaller authentication lookup bound protecting the shared connection pool. In-memory source/unknown counters reset on restart and rekey to the active registry; they are not a durable ledger.

At most eight HMAC requests can occupy the sixteen admission slots, with at most two per source UUID. Both limits apply before database lookup and return 503 with `Retry-After: 1` when full.

| Status | Meaning |
|---|---|
| 202 | Raw bytes committed, or an exact transport retry committed as duplicate |
| 400 | Malformed request metadata or forbidden query |
| 401 | Missing, mismatched, revoked or conflicting credentials |
| 405 | Unsupported method |
| 409 | Live explicit idempotency key reused for different bytes |
| 413 | Source body limit exceeded |
| 415 | Unsupported media type or content encoding |
| 429 | Authenticated source over its process-local budget; retry after the supplied `Retry-After` |
| 503 | Startup/stopping gate, saturated admission or unavailable persistence; retry after the supplied `Retry-After: 1` |

A 202 is durable admission, not successful normalization or delivery. Invalid JSON can be accepted as raw bytes and later become a durable processing failure. Correlia-authored HTTP tests exercise the example source shape and a body above 512 KiB with exact persisted bytes/digest. Source-side UI captures and the owner's live-system result have not been collected.

## Normalization contract

Only Alertmanager webhook version `"4"` is supported. Every supplied alert uses its own labels, annotations and firing/resolved status; group metadata is validated but never substituted for per-alert evidence. Empty groups complete without events. `truncatedAlerts` records an upstream omission count without inventing missing alerts.

| Input | Canonical mapping |
|---|---|
| Complete original labels | Source-namespaced identity; severity participates unless explicitly excluded |
| `startsAt` | Required nonzero offset-bearing timestamp; firing source time |
| `endsAt` | Resolved source time; firing zero sentinel is absent from canonical resolution time but remains exact observation-key evidence |
| Severity label | Exact critical/error/warning/info, otherwise unknown with original text retained |
| Summary annotation | Summary; falls back to nonempty alertname, then `Alertmanager alert` |
| Description annotation | Display text from the original value, truncated at 4096 Unicode scalars; the stored annotation is separately capped at 1024 |
| Generator/external URL | Canonical-valid HTTP(S) links; empty omitted, invalid nonempty rejected |
| Upstream fingerprint | Namespaced extension evidence, never canonical identity or labels_origin |

Identity uses complete originals before display projection. Long label/annotation values and display text truncate with a visible marker; originals remain only in restricted raw bytes. Exact supplied timestamp strings determine observation evidence; arrival time is never a fallback. Reversed intervals, missing required time, empty selected identity, invalid field types and unknown per-alert fields fail the whole delivery with a bounded field path.

The decoder permits at most 1,000 alerts and JSON depth 32. Canonical map/count/key, original-identity and 256 KiB structured-event bounds still apply; entries are not removed to force acceptance. The pipeline separately bounds aggregate event-plus-fanout storage. Canonical event, CloudEvents and identity contracts are reused unchanged.

### Alertmanager release compatibility

The latest patch of every minor from 0.16 through 0.35 is supported, proven by real firing and resolved captures in `test/unit/ingest/fixtures/alertmanager/`. All send webhook version `"4"`; no sender-version configuration is needed.

| Releases | Recognised additions to the base group fields |
|---|---|
| 0.16–0.18 | Base: version, status, alerts, receiver, groupKey, groupLabels, commonLabels, commonAnnotations, externalURL; no fingerprint or truncatedAlerts |
| 0.19–0.20 | per-alert fingerprint |
| 0.21–0.31 | truncatedAlerts |
| 0.32–0.33 | notification_reason (string) |
| 0.34–0.35 | routeLabels (string map, including an empty object) |

Only version, status and alerts are required at group level. All recognised fields are type-checked. `routeLabels` and `notification_reason` stay raw-only; neither substitutes for alert evidence. The existing `externalURL` link mapping is unchanged.

Unknown **top-level** fields are processed and flagged, not rejected. Unknown **per-alert** fields and wrong types on known fields still fail the complete delivery. Existing failed raw rows are not backfilled; replay is future work.

Every successful raw outcome includes `unknown_top_level_fields` and `unknown_top_level_overflow`, even when they are `[]` and `0`. The list contains the first 16 sorted unknown names matching `^[A-Za-z0-9_.-]{1,64}$`; all others, including oversized or control-character names, count toward overflow. Names remain restricted with the raw body; values are not copied into the outcome.

After commit, a best-effort warning is emitted:

```text
pipeline source=<uuid> unknown_top_level_fields=<count> tags=<t1,t2>
```

Count includes listed and overflow names. Each tag is the first 12 lowercase hex characters of SHA-256 over a listed name's UTF-8 bytes. Names and values never enter the log: a name can itself be a credential. Logger failure or a crash after commit loses only the warning, never the durable flag; completed rows are not retried.

Use restricted SQL to inspect names per source (the outcome column is stored as JSON text):

```sql
SELECT source_id, outcome_json::jsonb -> 'unknown_top_level_fields' AS names,
       (outcome_json::jsonb ->> 'unknown_top_level_overflow')::integer AS overflow,
       count(*) AS deliveries
FROM raw_inbox
WHERE status = 'done'
  AND (jsonb_array_length(outcome_json::jsonb -> 'unknown_top_level_fields') > 0
       OR (outcome_json::jsonb ->> 'unknown_top_level_overflow')::integer > 0)
GROUP BY source_id, names, overflow;
```

See [the compatibility runbook](runbooks/alertmanager-compatibility.md) for capture regeneration and real-Alertmanager verification.

## Durable processing and failure inspection

A worker first commits the active immutable configuration pin, then decodes and processes under a separate raw-row lock. A killed worker retains the pin; replacements never substitute the current configuration. If that first-pinned snapshot omits/disables the source, the raw row fails as `source_not_configured`, retaining its bytes.

Processing validates the complete batch before effects, folds repeated observations and inserts observation keys in stable event-id order. It then locks distinct alert fingerprints in ascending order before evaluating state, and finally writes event evidence and unique routed output intents in event-id order. Keys, alert state, activity, output intents and raw completion commit together. Invalid siblings or fanout beyond 16 MiB—including every event and intent payload copy—produce a failed raw delivery without partial effects.

The authoritative alert row is keyed by tenant and fingerprint. Its fence compares effective source time, receipt time and event id at canonical nanosecond precision; effective time is capped at receipt plus five minutes. An observation at or below the fence is stale and cannot change state. Applied observations advance the fence; only visible changes increment the version and append activity. `lastObservedAt` advances monotonically for applied or stale observations and duplicates of originally ready observations, without changing the version or writing activity.

Future-dated evidence (more than 24 hours ahead) has no observation key, state or output. Identical quarantined evidence at equal observed time collapses on the events key and increments `duplicate_quarantine`, not the error budget. Late evidence (older than seven days) retains a key and event but changes no state or output, including on duplicate delivery. Eligible duplicates preserve first evidence and produce no additional event/output effects. Empty routes record an unrouted event with no intent. Raw outcome JSON records committed, applied, stale, unrouted, upstream-omitted, duplicate-observation, future, duplicate-quarantine and late counts.

Serialization, deadlock, lock-timeout and connection-unavailable errors retry indefinitely with capped one-to-thirty-second backoff without spending the internal-error budget. Other internal failures consume five attempts, then produce `processing_exhausted`. Scheduling hints are bounded and process-local; database eligibility, raw bytes, pins and the internal-error budget remain durable. A ten-second total transaction deadline and five-second statement/lock bounds limit work.

Inspect failures through restricted SQL, not a public API:

```sql
SELECT observed_at, raw_id, source_id, status, config_snapshot_id,
       attempt_count, outcome_json
FROM raw_inbox
WHERE status = 'failed';

SELECT "rawObservedAt", "rawId", "configSnapshotId", "errorClass", "fieldPath"
FROM pipeline_failures;
```

Use both time and id when joining raw/event/output evidence. Raw payloads remain private operational data; never paste them into diagnostics. Accepted bytes are not silently discarded, and no retention/replay scheduler is implemented in this slice. Provision disk headroom until M2 retention/backpressure work.

## Plugin batch delivery

Plugin rows are eligible only while a local instance serves their pinned definition. The relay takes a generation-checked permit before claiming; its last transaction step rechecks that permit before commit. Observed readiness loss before that boundary rolls back acquisition without spending attempts. Unavailable historical definitions do not block ready definitions of the same output. Voluntary stops drain outstanding permits; loss after the boundary makes unanswered events retryable with `plugin_connection_lost`.

One output has at most one delivering set across workers. A plugin batch contains at most 64 events and 1 MiB, further limited by the plugin's negotiated bounds, all from one definition. A monotonic 27-second budget starts before claiming; claim commit is limited to five seconds, delivery to at most twenty seconds while reserving completion time, and each SQL statement/lock timeout to the remaining budget capped at five seconds. The database sets the shared lease to thirty seconds from its own clock.

All per-event outcomes complete in one transaction. Both outbox and attempt updates require the current claim, delivering status, an unexpired `clock_timestamp()` lease and exact affected-row counts; any mismatch rolls everything back. Over-budget completion writes nothing and lease recovery records interruption. Webhooks retain one-row acquisition and their original signing behavior. As with webhooks, every started plugin attempt consumes the twenty-attempt budget; the destination must deduplicate redelivery by event id.

## Signed webhook delivery and recovery

Every routed intent stores its original structured CloudEvents bytes, event id, destination, snapshot and signing-key commitment. Rotation never redirects or re-encodes old work. Relays POST `Content-Type: application/cloudevents+json`, `Idempotency-Key: <event-id>` and `X-Correlia-Signature: sha256=<lowercase HMAC-SHA256 hex over the exact body>`. Receivers must deduplicate the event id: delivery is at least once, not exactly once or ordered per alert. HMAC authenticates bytes, not freshness.

Only 2xx acknowledges. Network errors, total-deadline expiry, 408, 429 and 5xx retry; other statuses, including redirects, are permanent. Redirects are not followed. Destinations require HTTPS except explicit loopback HTTP in development/test; userinfo, query and fragment are rejected. Calls have a ten-second total deadline. Response bodies are discarded up to 64 KiB, then the connection closes; an already received 2xx still acknowledges an oversized response.

One shared discovery loop serves independent lanes, with at most one in-flight request per retained output id. A failing output cannot hold a database transaction over HTTP or block healthy outputs. Acquiring an intent commits a random claim token, database-clock thirty-second lease and started attempt. Finalization is fenced by that current unexpired token. Death after remote success can therefore produce a byte-identical duplicate after restart; stale completions cannot overwrite a successor.

Expired claims mark their unfinished attempts `interrupted` and retry. Every started attempt spends the twenty-attempt budget, including ambiguous outcomes and process death. Backoff is `min(300 seconds, 2^(attempt-1) seconds)`; exhausted or permanent work becomes terminal `dead` with its payload retained. Delivered/dead rows have no automatic replay in this slice.

Inspect delivery state and attempts with restricted SQL:

```sql
SELECT created_at, delivery_id, output_id, event_id, status,
       attempt_count, lease_until, next_attempt_at, dead_reason
FROM outbox;

SELECT "outboxCreatedAt", "deliveryId", "attemptNumber",
       "startedAt", "finishedAt", outcome, "errorClass"
FROM delivery_attempts;
```

Historical target definitions and matching signing keys are retained for queued/delivering work. Missing
or unverifiable stored references leave work queued without an attempt and emit bounded availability
diagnostics; there is no unsigned fallback. Terminal metadata keeps commitments, not secret bytes.
Shutdown cancels acquisition and HTTP work before the database closes; unfinished started claims remain
recoverable through lease expiry.
