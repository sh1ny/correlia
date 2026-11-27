# Ingest pipeline schema ownership

Serverpod migrations own source and configuration snapshots, the active pointer, secret commitments,
transport and observation keys, pipeline failures and delivery attempts. Correlia's ordered
`correlia_server/schema/*.sql` steps own `raw_inbox`, `events` and `outbox`, their partitions and
maintenance metadata. The queue tables have no generated table models. Their composite identities
always include the timestamp; managed tables do not reference them by foreign key.

## Fresh databases and upgrades

Start the server from `correlia_server`, with its `schema/` directory deployed alongside the package. Serverpod applies managed migrations first. Each process role then initializes the schema before starting its subsystems, even if ingest is not configured. A transaction advisory lock serializes starters, and each step and its version record commit together. Existing steps are immutable: append a new numbered script and register it in the runner for every forward change. Both a fresh installation and an upgrade need the schema steps because Serverpod fresh installs use its latest managed definition rather than replaying every migration SQL file.

The database test helper `test/support/ingest_schema.dart` must receive a non-rollback session and run after managed migrations. Do not change generated test tools or hand-edit generated migration definitions. Failure of a schema step rolls back that step and prevents subsystem startup; fix the underlying problem and restart. The reported error names the step without exposing database details.

## Schema step 4 and the offline upgrade

Step 4 (`schema/0004_icinga2.sql`) adds a nullable `events.effective_source_time timestamptz` and the SQL function `events_effective_source_time(events)`. The column has no default and no backfill, so PostgreSQL changes only the catalog: no event row is rewritten, no extra disk is needed on a populated table, and the step holds its exclusive lock on `events` only briefly.

Every row this release writes sets the column to the effective time, which the pipeline computes with the same ordering-key function that fences alert state: the source time, capped at the observed time plus the five minute skew allowance. The value is stored whether or not it was capped, with microsecond precision like `source_time`; it serves queries and stored ordering evidence, while exact ordering still uses the canonical evidence's nanosecond times. The event's published `source_time` always stays as the source reported it. The raw outcome JSON of the row gains a `clamped` count of the events whose effective time was capped. Expiry, correlation windows and reminders use observed time, not this value.

A null column marks a row written before step 4. Read the effective time of any row through `events_effective_source_time(events)` and never read the column alone: for a null column the function returns `LEAST(source_time, observed_at + interval '5 minutes')`, which is the cap the alert state service already applied to those rows without recording it. For example, `SELECT events_effective_source_time(e) FROM events e`.

Every schema transaction starts with `SET LOCAL lock_timeout`, before it requests the schema advisory lock (30 seconds in production). Waiting behind another starter, or step 4's `ALTER TABLE` waiting for a lock on `events` (for example a long reader or an open transaction), therefore ends in a failure and not in a hang. The startup error names the step and a sanitized failure class: `lock_timeout` (SQLSTATE 55P03) or `failed`, for example `Schema step 4 failed: lock_timeout`. The process exits non-zero, the transaction rolled back and no version was recorded. Step `0` is the version table itself, which is where a wait on the advisory lock ends. Once the blocking session ends, start the process again; the next start applies the step.

The upgrade is offline. Stop every older process of every role (`api`, `worker`, `all`) before any process of this release starts, and do not restart an older one afterwards. Any role of this release applies step 4 at startup, while an older process decodes every row as Alertmanager, writes no effective time and publishes configuration with a publisher that overwrites a source's kind. Rows admitted before the stop stay `pending` in `raw_inbox` and are claimed and processed by the upgraded workers, so nothing admitted is lost. No mixed-version mechanism exists, because the cutover happens once.

## Schema step 5 and stream credential cutover

Step 5 records the historical secret-inventory boundaries and installs the publisher-version
fence in the same transaction under the publication lock. Upgrade every role before publishing
an Icinga 2 stream source. An older process cannot publish after step 5, and older workers must
not run against a database that has accepted a stream source.

Startup inventories historical bare commitments in batches and resumes from the last committed
batch after interruption. A stream password cannot be published until that scan finishes. Use
new references when rotating credentials: removing a password or a webhook key does not remove
its reuse protection. Preserve `secret_reuse_digest`, `secret_reuse_retired_credential` and
`secret_reuse_backfill`, plus the two publication fences, when preparing a Serverpod repair.

Step 6 adds `icinga2_raw_origin`, the admission record for stream and sync rows. Its admission
snapshot determines state policy; the snapshot pinned at first claim still determines source
lookup, identity namespace, and routing. Preserve the table and its snapshot reference in repairs.

Step 7 adds `icinga2_sync_progress`, the durable `raw_admission_cutoff`, and the silent-tombstone
marker on `alerts`. It also builds indexes for pending receipts and retained evidence, including
an index on the CloudEvent subject in historical event payloads. Budget upgrade time and index
space on a populated database. Preserve the two tables, the marker, the cutoff trigger, and
their supporting indexes and functions in repairs.

Step 8 adds a partial index on `raw_inbox(source_id)` for `pending` and `failed` rows.
The consumer checks this bound before a new batch; a retry of an already committed batch does
not take another slot. The lease, status, resync sequence, and batch receipt tables are managed
by the Serverpod migration, not by schema step 8.

Step 9 adds sync read metadata and a shared database function, `icinga2_finalize_sync`, that
decides a sync's phase under its progress-row lock. Both the consumer and the pipeline call it
in the transaction that records their part of the work. Preserve the function and the partial
index on open syncs when preparing a repair.

## Icinga 2 Event Streams setup

Upgrade **every process of every role** (`api`, `worker`, `all`) before publishing
the first stream source or password. Do not restart older releases on that
database. An older worker sends `correlia.icinga2.stream.v1` rows to the webhook
decoder and cannot process them. An older publisher omits the password reuse
check; the upgraded database refuses that publisher. To roll back to an older
release, restore a pre-cutover database and its matching secret key.

Configure one Icinga 2 instance per stream source. If that instance already sends
webhooks, use a **new source UUID** for the stream; source mode is immutable.
Only `worker` and `all` connect; one worker holds the lease per source. Each
checks for a new revision every 30 seconds and also on a refused batch. Rotate
the API password or CA by publishing a new secret reference, not by overwriting
the old reference.

Install [`correlia-stream-api-user.conf`](../contrib/icinga2/event-streams/correlia-stream-api-user.conf)
on the Icinga 2 instance. Define `CorreliaStreamApiPassword` in a protected Icinga
configuration fragment, run `icinga2 daemon -C`, then reload Icinga 2. Use only
these grants; no event filter or wildcard is needed:

| Purpose | ApiUser permissions |
|---|---|
| Subscription | `events/StateChange`, `events/AcknowledgementSet`, `events/AcknowledgementCleared`, `events/DowntimeStarted`, `events/DowntimeRemoved`, `events/Flapping` |
| State sync | `objects/query/Host`, `objects/query/Service` |

Publish the source in a `format_version: 2` configuration using
`kind: "icinga2"`, `mode: "event_streams"`, and `enabled: true`. Set `api.url`
to the HTTPS origin (for example `https://icinga.example.net:5665`, with no
trailing slash, path, query or fragment), `api.username` to `correlia-stream`,
and `api.password_ref` and `api.ca_ref` to the imported password and CA bundle.
The secret file entries are objects with one `bytes` property: unpadded
base64url of the UTF-8 password or the PEM bundle bytes. Use the CA that signed
the endpoint certificate and a hostname matching the certificate. The client
uses only this CA bundle, TLS 1.2 or newer, no proxy, and no redirects. Do not
set webhook `credentials` on the stream source.
If a worker logs `missing_secret_pin`, check the reported source and credential
role against the restored secret store. The worker cannot adopt that revision
until both referenced records are available; the diagnostic omits secret names
and material.
Before storage, the consumer removes echoed password forms and the exact
Basic authentication token from stream and sync content, even if the `Basic `
prefix is absent. Input and admission limits still apply after redaction.
`state_type_policy` defaults to `hard_only`; use `soft_and_hard` to apply SOFT
problems as well as HARD problems. Confirm that the expected check state is
current before migrating a notification-only source.

First sync reads projected host and service results. A 403 indicates a refused
request; a 404 is ambiguous and fails sync even for an empty collection. Populate
the instance and verify both object query grants rather than treating 404 as an
empty successful sync. Local development/test status uses the same policy as
the console; production operators can read database status and state-change logs.

The verified Event Streams releases are 2.13.14, 2.14.10, 2.15.7 and 2.16.6
on Linux x64. Older releases and unlisted releases are not covered by the
capture matrix. Versions 2.13–2.15 can use close-delimited event responses;
2.16 uses chunked responses. Both carry newline-delimited JSON.

## Icinga 2 Event Streams limits

| Limit | Value |
|---|---|
| Configured sources | Up to 64 total; at most one dedicated PostgreSQL session per held stream lease |
| API password and CA bundle | Password 1–1,024 bytes, PEM CA bundle at most 16 KiB |
| Input line limit | 1 MiB; larger lines are skipped, counted and request a sync |
| Encoded row budget | 256 KiB; one larger item may occupy a row by itself |
| Items per row | 100 |
| Batch fanout budget | 8 MiB, counting one canonical event and up to 8 copies to outputs; pipeline hard limit 16 MiB |
| Pipeline row deadline | 10 seconds for a claimed raw row |
| Flush interval | 1 second from the first item; one batch per consumer in flight |
| `max_pending_rows` | 1,000 by default, 100–10,000; includes failed rows and can overshoot by one in-flight batch |
| Reader stall | 30 seconds, including pauses at the cap or an unavailable insert slot; silence when reading is healthy |
| Excess read lag | More than 60 seconds over that connection's lowest lag, sustained for 120 seconds |
| TCP connect through response headers | 10 seconds total, including TLS; separate for each subscription or query |
| TCP keepalive | 60 seconds idle, then six probes at 10-second intervals |
| Reconnect backoff | 1 to 60 seconds, doubles with ±20% jitter; resets after 5 minutes connected |
| Config adoption | Check every 30 seconds and on refused batches |
| Lease | Renew every 10 seconds; expires after 30 seconds by database time; close locally after 20 seconds from sending the last acknowledged acquire or renewal |
| Dedicated PostgreSQL connection | 1-second connect and client-connection check; normal 2-second statement, query and lock budgets; 5-second idle transaction limit |
| PostgreSQL TCP (not Unix sockets) | Keepalive idle/interval/count 5 s/1 s/3, unacknowledged data timeout 10 s |
| Local consumer shutdown | 10 seconds; force-close the dedicated session by 4 seconds; final release has its own 1-second connection and 1-second transaction budgets |
| Admitted batch receipt retention | 1 hour, including for removed sources |
| `sync_interval_seconds` | 3,600 by default; 300–86,400 seconds |
| Sync start spacing | 60 seconds between starts, including across reconnect and takeover; one active sync per source |
| Unserved sync request | Start within 5 minutes while connected and not paused (from the request or the end of current reading, whichever is later) |
| Sync reading deadline | 15 minutes total and 60 seconds of body silence; both close the subscription |
| Sync framing and diagnostics | Up to 1 MiB per object and 1,048,576 open containers; at most 20 bad-object samples of 600 bytes each plus one log summary. Unreadable names or names over 255 bytes are reported by position |
| Sync progress stall | Applying for 15 minutes after reading; late rows may still complete it |
| Sync progress retention | 30 days after completion or failure and only after every admitted row is done or failed |
| Clock skew allowance | Effective source time is capped at receipt plus 5 minutes; source time more than 24 hours ahead is counted as future-dated, not stored |
| Lateness horizon | 7 days from receipt, inclusive; older stream results are counted, not stored |

Correlia does not bound the memory used by Icinga 2's per-client queue. Below
the stall and lag thresholds, a consumer can remain behind when input matches
drain. Disconnecting drops that upstream queue. A gap can lose acknowledgement,
downtime and flapping events and intermediate states; sync repairs current
state only. Distinct results with equal execution starts need not converge.
An object removed from Icinga 2 keeps its alert; absence from sync does not
resolve it. Retained rows grow until pruned or handled; failed rows consume
the same admission budget as pending rows.

The manual full-input test (`mise run test -- --tags load`) measured
**335.65 events/s** committed over the final 5 minutes of a 10-minute run.
It used one stream source, no output routes, and embedded PostgreSQL on
Linux x64 with six logical CPUs. This is a measured drain rate, not a
capacity guarantee for a different workload or host.

The shutdown limit covers the worker's own sockets. PostgreSQL releases locks
when it can process the closed connection; no lock-release deadline is promised
for every backend state and network topology. A release that does not commit
leaves the lease to expire.

The reclamation cutoff can pass the receipt time of a buffered batch. The
consumer rejects it without a raw row or reservation, reconnects, and syncs
current state. A webhook rejected at this boundary returns `503`; retry the
delivery so it gets a fresh receipt. An already committed reservation still
deduplicates within its retention window. Reclaiming a silent tombstone ends
its unpublished lifecycle: a later problem can create a new alert.

### Read Icinga 2 Event Streams status

From a local development or test `api` or `all` process, call
`icinga2Stream.status(sourceId)`. The endpoint is read-only and uses the same
console access policy as the alert console. For production, use the
`icinga2-stream` state-change logs or run this read-only query in PostgreSQL:

```sql
SELECT s."sourceId",
       CASE WHEN s.state IN ('connecting', 'syncing', 'connected', 'backoff', 'paused')
              AND (l."sourceId" IS NULL OR l."expiresAt" <= clock_timestamp())
            THEN 'stale' ELSE s.state END AS state,
       s."connectionSeq", s."gapCount", s."oversizeLines", s."lastErrorClass"
FROM icinga2_stream_status s
LEFT JOIN icinga2_stream_lease l USING ("sourceId");
```

Do not read the stored `state` alone: an expired lease can leave a `connected`
row even though the worker is gone. The query reports `stale` without rewriting it.

## Offline partition cutover

Stop all old `api`, `worker` and `all` processes before starting the first upgraded process. Back up
the database before the cutover. When upgrading from a release that already has matcher support,
there is no need to drain pending inbox rows or queued output. Older releases still need to follow
the [matcher upgrade procedure](adr/0033-offline-matcher-upgrade.md) first. Do not restart an older
binary after the cutover.

The startup schema step attaches each populated heap to a new parent under the original name. It
includes timestamps through the last populated UTC day, then uses daily UTC partitions and a
default partition for timestamps outside prepared ranges. It does not rewrite existing payload tuples.
Allow offline time to validate the attachments and backfill metadata. Existing delivered and dead
entries without a matching terminal attempt receive the cutover time, not their original creation
time. A plugin intent rejected as oversized before a new attempt gets the cutover time even if
it previously retried.

The partition script has a one-hour execution timeout. Set
`CORRELIA_PARTITION_CUTOVER_TIMEOUT_SECONDS` to a larger positive integer on the upgraded process if
the database needs a longer maintenance window. This changes only the partition script's client
deadline. The 30-second PostgreSQL lock timeout and other startup query deadlines are unchanged.

Wait for startup before restarting writers. If the schema step fails, its table changes and
version record roll back together. Clear the blocking transaction or fix the cause and restart the
new binary. A successful forward cutover can be undone only by restoring the pre-upgrade backup.

A partition validation failure leaves default routing intact. The worker records a bounded retry;
a delayed error from an earlier attempt cannot overwrite a successful attachment. The worker
tries unprepared days with no previous attempt first, then retries the least recently attempted
range. Preparation has no deadline when PostgreSQL must validate a large default child.
If a write fills a day after its attachment failed, later retries skip that occupied day
without clearing its failure. It remains degraded until attachment succeeds or the day ages
out of the preparation window.

Retention measures days as 24 hours in UTC, regardless of the database session time zone.

A closed child whose drop times out waits for its scheduled retry. Other eligible children
can be dropped during that wait. A drop still rechecks retention and protection under
the DDL locks. Outbox drops check exact counts per child and output without scanning
the payload heap. A writer can delay cleanup of its own count without holding up another output.
Target the `raw_inbox` parent for writes so the admission cutoff and pending count apply.
The database rejects direct writes to raw children and truncation of nonempty outbox
children because those operations can leave queue usage, failure entries or references behind.

For offline repair, stop all writers first. In one transaction use the maintenance advisory
lock `1129271900` and the `correlia_reserve_partition` and `correlia_attach_partition` SQL
functions with one parent and one UTC date. The second function checks both the recorded range
and the default child, and registers the partition in the same transaction as attachment.
If the reserve call returns `NULL`, check the catalog and respect any active retry deadline.
Never detach the default child or move protected rows to make validation pass.

## Shared pressure and queue policy

In a format-version 2 configuration, `pipeline_operations` can override the following limits.
Omitting the section or explicitly supplying the defaults leaves the canonical snapshot ID
unchanged. Adjusting a budget does not change an output's definition digest.

| Field | Default |
|---|---:|
| `pending_max_rows` | 50,000 |
| `pending_max_age_seconds` | 30 |
| `disk_budget_bytes` | Omitted: no disk watermark |
| `disk_watermark_percent` | 85 |
| `raw_retention_days` | 30 |
| `event_retention_days` | 90 |
| `outbox_retention_days` | 7 |
| `dead_letter_retention_days` | 14 |

`output_budgets` is an object keyed by UUIDs in the configured output registry. Each entry can
set `max_rows` (default 500,000), `max_payload_bytes` (default 1 GiB) and `overflow_policy`
(`discard_new` by default, or `block_ingest`). A blocking output must fit at least 1,000 intents
and 16 MiB in an empty queue. The latest published policy applies by output ID, including to
already-pinned work. Retiring an output keeps its last budget while it still has retained work.

A new webhook gets `429` when inbox count or oldest pending age reaches its limit, or `503` at a
configured disk watermark or blocking output. Both include `Retry-After` in whole seconds.
Refused requests leave neither a raw row nor a transport reservation. A known exact retry keeps
its prior acknowledgement. Reusing the same live idempotency key with different request bytes
returns `409`; a different key is subject to admission pressure. Leased pulls pause on the same
shared limits and retain their batch for retry. Queue limits complement the per-process
request-rate limiter; they do not replace it.

Disk pressure uses `pg_database_size(current_database())` with a shared one-second sample.
A request refused for disk pressure keeps the fresh measurement but no receipt. Disk pressure also
causes `/readyz` to return `503` on `api` and `all`; `/livez` and `/startupz` do not depend on the
watermark. This is a database budget, not a free-space check for the host or its WAL volume.

Queued, delivering and dead intents consume one slot and the length of the exact stored
CloudEvent. Successful delivery or dead-letter expiry frees that capacity. A budget reduction
does not purge existing work: the output may remain over budget until enough intents leave.

`discard_new` drops only new intents that do not fit and increments the output's durable
discard count. The same transaction appends one `output_discarded` ledger row per affected
output with the number discarded from that raw row. Other outputs still receive their
intents. `block_ingest` defers an accepted raw row if all its intents for that output cannot fit.
The row keeps its configuration pin and retry allowance. No partial state, event or delivery
effects commit. The worker tries the row again when it becomes eligible. A rolled-back attempt
cannot replace a newer attempt's recorded demand.
A database timeout while writing outbox intents, including a wait for retention to release
an outbox partition count, does not spend a processing attempt.

An output opens one overflow episode per period of saturation or refusal. The activity
ledger records the episode before the worker tries to route a sanitized Correlia alert to
the other active outputs. Routing tries once: it skips a destination if its capacity row is
locked or it has no room. Skipped destinations do not receive the same notice later. The
notice does not alter alert state or generate another notice. It carries a reference and hash
of its ledger evidence, not sender data. The ledger shows the episode even when no other
output can take the notice.
Notice routing and expired-lease recovery each run one transaction at a time. Neither blocks
delivery discovery. Lease recovery rotates between outputs, even when one attempt times out
waiting for a lock. A change to either overflow policy's budget can open an episode even when
the inbox is empty.

## Retention and expiry

Worker and all processes expire failures after 14 days by default. Expiry removes the active
failure and records the number discarded in `activity` in the same transaction. The raw row
or delivery is then eligible for ordinary retention, not replay. An output's retention window
starts when it is delivered or discarded, not when it was created or moved to `dead`.
If a delivery's capacity or event-reference row is locked, the sweep skips that delivery.
It can still expire unrelated failures and revisit the skipped one when the cursor wraps.

The worker reclaims only terminal inbox rows and unprotected events after their age cutoffs.
Live and dead delivery references keep their event evidence. Deliberately small batches and a
durable cursor let it pass protected pages without scanning or locking the whole backlog.
Attempt cleanup follows the exact retired intent key and can span several batches.

Transport keys remain until the retry window and raw admission cutoff have both passed.
Worker maintenance advances that cutoff even if no Icinga 2 target can load.
Observation keys and silent Icinga 2 tombstones also respect the oldest pending or failed
receipt. A maintenance failure rolls back the whole batch; its recorded outcome has no
discarded or reclaimed count from that batch.

## Repair migrations

Serverpod's repair diff may propose dropping SQL-owned objects it does not recognize. Review the
complete repair SQL and remove operations against the `raw_inbox`, `events` and `outbox` parents,
their historical, daily and default children, and all associated indexes, constraints and triggers.
Preserve `activity`, `correlia_schema_versions`, `matcher_content_digest` (primary key `digest`),
`matcher_content_digest_fill` (primary key `singleton`), `pipeline_icinga2_replay_floor` and other
SQL-owned metadata listed in [the architecture](../openspec/architecture.md), including indirect
cascades and time-qualified references. Inspect any other unmanaged exceptions individually.
Correct the SQL-owned schema in a new forward step, not in an applied step or generated
definition. Test the repair and the new step together on a populated copy before production use.

`matcher_content_digest` has the foreign key `matcher_content_digest_first_snapshot_fk` from `first_snapshot_id` to `ingest_config_snapshot."snapshotId"`, and `icinga2_raw_origin` has one from `admission_snapshot_id`. A repair that drops or recreates `ingest_config_snapshot` must keep both constraints or recreate them, with their data intact. Correlia never deletes a snapshot, and deleting one by hand is not supported. The two foreign keys cover only digests and stream admissions. Other rows name a snapshot with no constraint: the active pointer `ingest_active_config."snapshotId"`, the pin `raw_inbox.config_snapshot_id` of a row still waiting to be processed, and `config_snapshot_id` of retained `events` and `outbox` rows. With their snapshot gone, the worker cannot decode a waiting row and the rule simulator returns `raw_unavailable` for those events.

## Identity evidence

Alertmanager's upstream fingerprint is retained in raw input and, when present, the `correlia.io/alertmanager_fingerprint` extension. It is not a label or an identity input. Original selected labels determine identity; see ADR 0024. Source-side setup screenshots have not been collected.

## Bootstrap and rotation

Use a `.yaml` or `.yml` extension for YAML. Other file names are parsed as JSON.

Set `CORRELIA_INGEST_CONFIG` to a regular JSON or YAML file (at most 64 KiB) and
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
The active registry, routes reachable from pending pins, and queued or delivering output intents may
refer to at most 64 distinct outputs. If publication rejects `retained_output_bound`, let pending work
drain before retrying. Removing an output does not cancel existing work.

Every configured process needs the external key. No admin/configuration/raw-payload API is exposed.
Without bootstrap, a worker/all process refuses startup whenever an active snapshot or unfinished
ingest/output work exists. An unconfigured api still serves workspace behavior and rejects hook admission.

### Publish or restore matcher rules

In a format-version-2 ingest file, set `matcher.language` to `matcher` and `matcher.version` to `1`.
Keep rules in `matcher.rules` in evaluation order. A rule has `id`, `when`, and `actions`. A condition
uses `field`, `op`, and `value`, or one of `all`, `any`, and `not`. Omit `value` for `exists`; null and
missing are absent, but `""` is present.

```yaml
matcher:
  language: matcher
  version: 1
  rules:
    - id: route-platform
      when: {field: labels.team, op: equals, value: platform}
      actions:
        - {type: set_label, key: owner, value: platform-on-call}
```

Set the top-level `expected_active_snapshot` to the current snapshot ID when adding, editing or
removing matcher rules. Use an explicit `null` if there is no active snapshot. If another publication
wins first, review the new active configuration before preparing another file. To roll back only the
rules, copy the earlier matcher section into the current file, preserve the current sources, credentials
and outputs, and publish at a higher revision. An identical restart uses that same file without
publishing again. A `route` action must reference an output in the candidate registry.

Rules read the original event, including when an earlier rule writes the same field. Matcher changes
appear in retained events and their delivery payloads; live alert state uses the original severity.
Matcher routes add to the source routes and follow the same delivery eligibility.

A `classify` action sets a noise class hint. It has exactly `type` and `value`, and `value` is one of
`heartbeat`, `informational`, `test`, `flapping` and `maintenance`:

```yaml
actions:
  - {type: classify, value: heartbeat}
```

It writes the reserved label `correlia.noise_class` with origin `matcher`, follows the same patch,
ordering and failure rules as the other actions (the later rule wins, and a rule that fails discards
its hint with the rest of its patch), and leaves the document at language `matcher`, version `1`. A
hint changes neither the event's `kind`, its identity, alert state nor delivery eligibility. A missing
`value` or a value outside the set fails activation with a field error at
`matcher.rules[i].actions[j].value` that lists the allowed values, and the active snapshot is unchanged.

Only `classify` may write `correlia.noise_class` in new matcher content. A `set_label` or `extract`
action whose `key` is that label fails activation with a field error at `matcher.rules[i].actions[j].key`
(code `reserved_key:correlia.noise_class;use_classify_or_rename_the_label`); use `classify`, or rename the
label. Content equal to the matcher of a snapshot that is still stored is not new: an exact restart with
the same file, and a guarded rollback that republishes earlier matcher content at a higher revision, still
succeed when that content writes the key with `set_label` or `extract`, and a row pinned to such a snapshot
still runs it. A label named `kind` is an ordinary label; matcher rules never change an event's `kind`.

If a rule times out, produces invalid metadata, or would exceed the batch fanout limit, Correlia
discards that rule's whole patch and counts the failure against the pinned snapshot and rule.
The existing activity feed reports one notice for each failing pair. Its detail includes the current
failure count. An event may also include a sanitized `pipeline.enrichment_errors` entry if it fits.
Before the write reserve, Correlia stops optional evaluation and records `matcher_unattempted` on the
raw outcome for rules that did not start. Correlia never publishes a replacement automatically.

### Event kinds before matching

The `kind` of an event is set by its decoder, before any rule runs; rules read it and never change it. The
Icinga 2 webhook table in [Mapping](#mapping) gives the kind for each notification type. The other sources:

| Source | Delivery | Kind |
|---|---|---|
| Alertmanager | each alert, firing or resolved | `alert` |
| Generic webhook | each mapped alert | `alert` |
| Icinga 2 Event Streams | `StateChange`, HARD or `soft_and_hard`, any state; SOFT recovery under `hard_only` | `alert` |
| Icinga 2 Event Streams | `StateChange`, SOFT state other than `OK` or `UP` under `hard_only` | no event; a lag observation only |
| Icinga 2 Event Streams | `AcknowledgementSet`, `AcknowledgementCleared` | `ack` |
| Icinga 2 Event Streams | `DowntimeStarted`, `DowntimeRemoved` | `downtime` |
| Icinga 2 Event Streams | `Flapping` | `state` |
| Icinga 2 Event Streams | any other live stream type | rejected with `unsupported_type` at `type` |
| Icinga 2 reconciliation (sync) | `Host` or `Service` object, HARD or `soft_and_hard`, any state; SOFT recovery under `hard_only` | `alert` |
| Icinga 2 reconciliation (sync) | `Host` or `Service` object, SOFT state other than `OK` or `UP` under `hard_only` | no event |
| Icinga 2 reconciliation (sync) | any other object type | rejected with `unsupported_type` at `type` |

A `classify` action (see above) adds the noise class hint on top of the kind; it never replaces it.

### Simulate rules against an event

The rule simulator shows what the matcher rules would do to one event, rule by rule and condition by condition,
and changes nothing. It is the `ruleSimulator.simulate` endpoint and follows the console access policy: outside
the local console it throws the access error. Its calls write no session log.

The request names the event in exactly one way:

- `eventJson`: a CloudEvent JSON document, decoded and validated like a published event.
- `eventId` and `observedAt`, with an optional `disposition` (`ready`, `late` or `future_dated`): an event the
  pipeline stored. The simulator decodes the stored raw row again and picks the member the pipeline kept: the one
  equal to the stored event in every field the matcher and the pipeline's diagnostics leave alone. When no member
  is, or several differing members are, the result is `ambiguous_member`. Without a `disposition` a `ready` or
  `late` row is preferred over a `future_dated` one.

`draftMatcher` is optional text holding a `matcher` section as JSON (at most 64 KiB). Without it the rules of the
active snapshot run. A draft is checked like a published one, including the reserved `correlia.noise_class` key,
and is always new content. Nothing is published, stored or sent.

The result carries:

- `ruleSource` (`active` or `draft`), and the active snapshot's ID and revision when a snapshot is active. A draft
  result carries them too, because that snapshot supplies the sources and outputs the draft runs against.
  `noRulesActive` is true only for an active-rule simulation with no rules to run: no active matcher, or one with
  no rules. A draft result always reports `false`, so the flag says nothing about the server's configuration.
- `trace`: one entry per rule in order, with the outcome (`matched`, `not matched`, `failed` or `not attempted`),
  a `failureCode` for a failed rule, and each condition's field, operator, outcome and any failure code. Each
  action reports its effect: staged, skipped with the reason, failed with its rule's failure code, or not run. A
  `route` to an output that the baseline or an earlier route already has is `skipped: route already present`.
  A write that a later action of the same rule overwrites (a label key, or a second matching `map_severity`) is
  `skipped: overwritten later in its rule`; a `location` action counts as overwritten only when every label it
  staged is. When only some are, the action stays staged and its detail marks each overwritten label, as in
  `site=eu1 (overwritten later in its rule), environment=prod`. A value that is empty, holds a comma, a parenthesis, a quote or a backslash, or starts or ends with white space is shown as a JSON string, as in `site="eu1 (old)"`, so it cannot read as the marker or as a separator. When a later action fails, the writes before it
  that a later action had already overwritten still show this, and nothing of the rule is applied. A write in a later rule is a separate patch, so both rules' writes are applied. A `map_severity`
  whose target equals the event's current severity is `skipped: severity already <value>`.
- The final labels, label origins, links, severity and `eventKind`, plus `noiseClassHint` when a rule classified
  the event. `finalLabelOrigins` gives every label its effective origin: a label with no recorded origin, as
  Alertmanager leaves its source labels, shows `source`. `storedLabelOrigins` is the stored map as it is, so it
  can leave such labels out. The four label fields are lists of `{key, value}` entries in label order, not JSON
  objects: the generated client reads an object's `__className__` key as a model name, and `__className__` is a
  valid label key.
- `baselineRoutes` (the source's routes in the active snapshot) and `addedRoutes` from `route` actions. Added
  routes are hypothetical: delivery eligibility is not evaluated. `sourceAbsent` is true when the event's source
  is not in the active snapshot.
- For a stored event, what the pipeline stored (`storedLabels`, `storedLabelOrigins`,
  `storedEnrichmentErrors`, `storedSnapshotId`) next to the simulated result. The pipeline shares its regex and
  time budgets across a whole raw row, while a simulation starts fresh budgets, so the result says so in
  `storedBudgetNote`.

An input or lookup failure is a typed `error` in the result with a `code` and the `field` it concerns. The endpoint
throws for the access policy, and an infrastructure failure, such as a database timeout, reaches the caller as an
RPC error.

| Code | Field | Cause |
|---|---|---|
| `invalid_input` | `eventJson`, `eventId`, `observedAt` or `disposition` | Both or neither way of naming the event, a partial or malformed key, an unknown disposition, or an `observedAt` that is not an RFC 3339 timestamp with an offset |
| `too_large` | `eventJson` or `draftMatcher` | Pasted event text over the wire bound of 256 KiB, or a draft over 64 KiB. Text within the bound whose canonical form is over it gets the event's own `event_too_large` error on `event` |
| `invalid_unicode` | `eventJson` | The pasted event text holds a UTF-16 surrogate that is not part of a pair. It is refused before the text is encoded, so the value is never replaced with U+FFFD |
| `invalid_json` | `draftMatcher` | The draft is not JSON |
| an event validation code | the event field path | The pasted event fails validation |
| a matcher validation code | the matcher field path | The draft fails the checks of publication, such as `reserved_key:correlia.noise_class;use_classify_or_rename_the_label` |
| `event_not_found` | `eventId` | No stored event has that key |
| `raw_unavailable` | `eventId` | The stored event's raw row is gone or cannot be decoded again, including when its processing snapshot is gone or its decode settings no longer parse or have the wrong shape (such as a source without its namespace, or a source enabled twice), or when a stream row's admission snapshot is not JSON or lists its source twice |
| `ambiguous_member` | `eventId` | No member of the decoded raw row matches the stored event, or the raw row holds several differing events with that ID and the stored event does not tell which one was kept |

#### Command line

`correlia_server/tool/simulate.dart` calls the endpoint through the generated client against a running server
(`--server <url>`, default `http://localhost:8080/`; the server must run as the local console). The URL must
use `http` or `https` and have no query or fragment; anything else is a usage error. Run it from
`correlia_server`:

```sh
# A stored event: its ID, its observed_at, and optionally --disposition
mise exec -- dart run tool/simulate.dart --event-id <event-id> --observed-at <observed_at>

# A pasted CloudEvent JSON file, optionally with a draft matcher section
mise exec -- dart run tool/simulate.dart --event event.json --draft draft-matcher.json
```

It prints the rule source and snapshot, then each rule with its outcome, the condition tree (each leaf with its
field, operator, outcome and reason), each action's effect, and the final kind, labels with origins, links,
severity, routes (added ones marked hypothetical) and notes; for a stored event it adds the stored labels, errors
and snapshot. `--json` prints the result document instead. The `--observed-at` text goes to the simulator as typed,
so a timestamp it rejects comes back as its `invalid_input` error for `observedAt`. A simulator error prints
`error: <code>` and `field: <field>` on stderr, plus `output: <id>` when a draft routes to an unknown output, and
exits 1; a usage error prints the usage and exits 64. The readable output writes a newline, carriage return and
tab as `\n`, `\r` and `\t`, every other control character as `\u{hex}`, and a backslash as `\\`, so a value
holding the text `\n` reads apart from one holding a newline. `--json` writes DEL and the C1 control characters as
`\u00XX` escapes, so the document decodes to the same values and cannot drive a terminal.

#### Documented examples

The examples below are run by `test/unit/simulator/rul1_docs_test.dart` (blocks marked `yaml rul1-example`), which
simulates each documented event against the documented rules and compares the per-rule outcomes, in rule order,
and the final labels. Each event is an alert with the labels shown. Changing a block without changing the behavior
it documents fails that test.

**Rule priority.** Rules run in order and read the original event: a condition does not see a label that an
earlier rule wrote. When two rules that match write the same label, the later rule wins; a rule that does not match
leaves the label alone.

```yaml rul1-example
name: priority
event:
  labels: {alertname: DiskFull, team: storage}
matcher:
  language: matcher
  version: 1
  rules:
    - id: default-owner
      when: {field: labels.alertname, op: exists}
      actions:
        - {type: set_label, key: owner, value: on-call}
    - id: storage-owner
      when: {field: labels.team, op: equals, value: storage}
      actions:
        - {type: set_label, key: owner, value: storage-team}
    - id: network-owner
      when: {field: labels.team, op: equals, value: network}
      actions:
        - {type: set_label, key: owner, value: network-team}
    - id: owned-already
      when: {field: labels.owner, op: exists}
      actions:
        - {type: set_label, key: reassigned, value: "true"}
expect:
  rules:
    - default-owner: matched
    - storage-owner: matched
    - network-owner: not matched
    - owned-already: not matched
  labels: {alertname: DiskFull, team: storage, owner: storage-team}
```

**Labels.** `set_label` writes a fixed value. `tag` sets the label `tags.<key>` to `"true"`. `extract` copies a capture group of a regular expression applied to
a field; the first match is used, and the pattern dialect has no anchors. Here the pattern matches both `api-12`
and `pod-7`, and `node` takes the first.

```yaml rul1-example
name: labels
event:
  labels: {alertname: HighLatency, instance: "api-12.pod-7.example.org:9100"}
matcher:
  language: matcher
  version: 1
  rules:
    - id: tag-and-extract
      when: {field: labels.alertname, op: equals, value: HighLatency}
      actions:
        - {type: set_label, key: tier, value: frontend}
        - {type: tag, key: latency}
        - {type: extract, field: labels.instance, pattern: "([a-z]+-[0-9]+)", group: 1, key: node}
expect:
  rules:
    - tag-and-extract: matched
  labels:
    alertname: HighLatency
    instance: "api-12.pod-7.example.org:9100"
    tier: frontend
    tags.latency: "true"
    node: api-12
```

**Topology.** A `location` action looks up the value of a field in an ordered table and sets `site` and
`environment` from the first entry that matches by `hostname` or `cidr`. When no entry matches, the rule still
matches and the labels stay as they were. Here both the `10.20.0.0/24` entry and the `10.0.0.0/8` entry
below it match, and the first sets the labels.

```yaml rul1-example
name: topology
event:
  labels: {alertname: HostDown, hostname: 10.20.0.2}
matcher:
  language: matcher
  version: 1
  rules:
    - id: site-of-host
      when: {field: labels.hostname, op: exists}
      actions:
        - type: location
          field: labels.hostname
          entries:
            - {hostname: 10.20.0.1, site: fra1, environment: production}
            - {cidr: 10.20.0.0/24, site: ams2, environment: production}
            - {cidr: 10.0.0.0/8, site: lab1, environment: staging}
expect:
  rules:
    - site-of-host: matched
  labels:
    alertname: HostDown
    hostname: 10.20.0.2
    site: ams2
    environment: production
```

### Upgrade before enabling matcher rules

Live upgrades and mixed-version operation are not supported. Stop admitting new input and manually
drain pending inbox work and the outbox on the old release. Then stop all Correlia processes and
their supervisors before upgrading. Verify all roles start on the new release before resuming
input or publishing matcher rules. Do not edit pins or discard queued deliveries to drain the outbox.

The release that adds `classify` follows the same offline sequence (ADR 0033):

1. Drain pending inbox work and the outbox on the old release, then stop every process of every role.
2. Start the new release. Schema step `0015` (`schema/0015_matcher_content_digest.sql`) creates
   `matcher_content_digest` (primary key `digest`, the SHA-256 of a snapshot's canonical matcher JSON) and
   `matcher_content_digest_fill` (primary key `singleton`, one row). Step `0016`
   (`schema/0016_matcher_digest_watermark.sql`) adds `filled_through` to that row: the snapshot table id
   through which the fill has read. Step `0017` (`schema/0017_matcher_digest_snapshot_fk.sql`) adds the
   foreign key `matcher_content_digest_first_snapshot_fk` from `first_snapshot_id` to the snapshot ID. It
   first deletes digest rows whose snapshot no longer exists and, if it deleted any, resets `filled_through`
   to 0, so the fill in the next step records again the content of every surviving snapshot.
3. Right after the schema steps and before it reads the configuration file, the process fills
   `matcher_content_digest` for every snapshot after `filled_through` (every stored snapshot on the first
   start). It reads snapshots in keyset pages of 100 by table id, in one transaction under the publication
   advisory lock, and writes the new `filled_through` last, so a crash leaves no partial fill and the next start
   redoes it. A second starter waits on the lock and then finds nothing left to read. Every later start and
   publication reads only the snapshots after the watermark, so a snapshot that the old release published during
   an offline downgrade, before any `classify` snapshot, still counts as stored content. The fill waits at most 60 seconds for the lock; past that the process exits non-zero with
   `Schema step 15 failed: lock_timeout`, and the next start retries. The fill decodes snapshot text in the
   server, so a U+0000 escape in a stored plugin configuration cannot block it. A snapshot whose stored text is
   not JSON, or whose matcher holds a value with no JSON encoding (such as the number `1e400`, which decodes
   to infinity), gets no digest, so its matcher content counts as new; the fill goes on and writes the snapshot's ID,
   never its text, to standard error.
4. Publication and startup then reject a non-`classify` write to `correlia.noise_class` only in matcher content
   that no stored snapshot has. Publication first runs the fill for any snapshot after the watermark.

Do not return to the old release after a snapshot that uses `classify` is published: the old binary rejects an
unknown action when it reads that snapshot.

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

Unknown **top-level** fields are processed and flagged, not rejected. Unknown **per-alert** fields and wrong types on known fields still fail the complete delivery. The upgrade does not reprocess failed raw rows automatically. Operators can request replay of eligible failures through the [Operator RPC](#operator-rpc); replay uses the active compatible configuration.

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

## Icinga2 webhook document and mapping

An `icinga2` source accepts one JSON object per delivery on `/hooks/icinga2/<source-uuid>`, in Correlia's own
document format `correlia.icinga2.v1`. Icinga 2 has no webhook; the document is built by the notification command
Correlia ships (see [Icinga2 sender setup](#icinga2-sender-setup)). Every delivery is one command execution and
decodes to exactly one canonical event. A `202` only acknowledges that the delivery was stored; whether that event
is committed is decided later. A document that fails validation is recorded as a pipeline failure and stores no
event, and a repeat of an observation already stored (a reminder, or a retried delivery) completes as a
`duplicate_observation` without storing another. An accepted delivery with no new event is therefore not data
loss: its raw row's outcome says what happened to it.

### Document v1

| Field | Type | Rule |
|---|---|---|
| `format` | string | Required, exactly `correlia.icinga2.v1` |
| `object_type` | string | Required, `host` or `service` |
| `host` | string | Required, never empty, no control character (U+0000-U+001F, U+007F) |
| `service` | string | Required for a service object, same rule as `host`; a host object must not carry it |
| `state` | string | Required. Host: `UP`, `DOWN`, `UNREACHABLE`. Service: `OK`, `WARNING`, `CRITICAL`, `UNKNOWN` |
| `state_type` | string | Required, `HARD` or `SOFT` |
| `last_state_change` | string | Time, see below. Required for `PROBLEM` and `RECOVERY`; optional for every other type, validated when present and unused by its key and source time. The shipped command sends it only for `PROBLEM` and `RECOVERY` |
| `output` | string | Optional check output (every line); no U+0000 |
| `notification_type` | string | Required, Icinga 2's own type: `PROBLEM`, `RECOVERY`, `ACKNOWLEDGEMENT`, `DOWNTIMESTART`, `DOWNTIMEEND`, `DOWNTIMECANCELLED`, `FLAPPINGSTART`, `FLAPPINGEND`, `CUSTOM` |
| `notification_author` | string | Optional; no U+0000 |
| `notification_comment` | string | Optional; no U+0000 |
| `notification_time` | string | Required time, see below |

Any other key fails the delivery. The body is checked against the Alertmanager decoder's nesting bound (32)
before it is parsed, and a body of any length within the source's body limit decodes.

**Time form.** Both times are JSON strings of Unix seconds with exactly six fraction digits,
`^[1-9][0-9]{0,11}\.[0-9]{6}$`, with a value below 253402300800 (before year 10000). The two digit groups are
converted to integer microseconds by integer arithmetic, never through a floating-point number, so distinct texts
are distinct instants over the whole range (`"8589934592.000001"` and `"8589934592.000002"` are two observations).
A JSON number, a sign, an exponent, a leading zero and zero itself are all rejected.

**Error codes.** A failed delivery fails its raw row once, with a code and a bounded path; it is a validation
outcome, not an internal retry, and nothing commits. Paths name only the fields above; an unknown key is reported as
the single structural segment `*`, never by its name, so sender-chosen text (a dotted name such as `state.state_type`
included) never reaches a stored failure or a log.

| Code | Path | Cause |
|---|---|---|
| `invalid_json` | `body` | Not UTF-8 JSON |
| `invalid_type` | `body` or the field | The body is not an object, or a field has the wrong JSON type (a time given as a number, a state given as `2`) |
| `depth_bound` | `body` | Nesting deeper than 32 |
| `missing_field` | the field | A required field is absent |
| `unsupported_version` | `format` | Any other format string |
| `unknown_field` | `*` | A key outside the table |
| `duplicate_field` | the field, or `*` | A member name given twice in the object, escapes decoded (`"state"` and `"st\u0061te"`); the path is `*` unless the name is a field above |
| `invalid_object_type` | `object_type` | Neither `host` nor `service` |
| `unexpected_field` | `service` | A host object carrying `service` |
| `invalid_state` | `state` | A name not valid for the object type (`DEGRADED`, or `CRITICAL` on a host) |
| `invalid_state_type` | `state_type` | Neither `HARD` nor `SOFT` |
| `unsupported_type` | `notification_type` | A type outside the list (`ESCALATION`) |
| `invalid_time` | the time field | A string not in the fixed form (`"1.5"`, `"1e9"`, `"0.000000"`) |
| `out_of_range` | the time field | 253402300800 seconds or more |
| `invalid_text` | the field | An empty or control-character name, U+0000 in a text, or an unpaired surrogate |

### Mapping

State and state type decide status and severity; `notification_type` only selects the kind of event and is never
read for status. Only `PROBLEM` and `RECOVERY` are state observations. Every other type is informational whatever
state it carries.

| Delivery | Kind | Status | Severity |
|---|---|---|---|
| `PROBLEM` or `RECOVERY`, host `UP` or service `OK` (any state type) | `alert` | `resolved` | `info` |
| `PROBLEM` or `RECOVERY`, HARD `DOWN` or `UNREACHABLE` or `CRITICAL` | `alert` | `firing` | `critical` |
| `PROBLEM` or `RECOVERY`, HARD `WARNING` | `alert` | `firing` | `warning` |
| `PROBLEM` or `RECOVERY`, HARD `UNKNOWN` | `alert` | `firing` | `unknown` |
| `PROBLEM` or `RECOVERY`, SOFT state other than `OK` or `UP` | `state` | `info` | `info` |
| `ACKNOWLEDGEMENT` | `ack` | `info` | `info` |
| `DOWNTIMESTART`, `DOWNTIMEEND`, `DOWNTIMECANCELLED` | `downtime` | `info` | `info` |
| `FLAPPINGSTART`, `FLAPPINGEND` | `state` | `info` | `info` |
| `CUSTOM` | `comment` | `info` | `info` |

Icinga 2 sends no notification for a SOFT transition, so a SOFT problem cannot be followed by a recovery
notification and does not create an alert; a recovery reported SOFT still resolves. UNREACHABLE is `critical`,
like DOWN, and keeps its own name. The delivered state name is `severity_original`. Informational events do not
change alert state, and a state observation from a delayed command reports the object's state when the command
ran, which can differ from the transition that queued it.

| Event field | Value |
|---|---|
| Identity | Source namespace, kind `icinga2`, `host`, and `service` for a service object. State, severity, output, times and acknowledgement or downtime flags are never identity inputs; identity uses the complete names |
| Summary | `<host> <STATE>` or `<host>!<service> <STATE>`, UNREACHABLE shown as DOWN, truncated with the marker at 256 characters; no `starts_at`, no generator link |
| Description | State events: `output`, absent when it is absent or empty (4096 characters with the marker). Other events: the comment, with the same bound and rule |
| Annotations | `icinga2.notification_type` always; `icinga2.notification_author` (1024 characters with the marker) when the author is present and not empty |
| Source time | `last_state_change` for a state observation, `notification_time` for every other event |

Because the summary comes from the object and its state only, a new observation of an unchanged state from the same
source records no visible alert change: the fence advances, the version and activity stay.

### Observation keys

The observation key is `ObservationKey.native` over a canonical JSON array of strings (no whitespace; times as
decimal integer microseconds). A state notification is
`["icinga2.notify.v1", state, state_type, last_state_change_us]`: re-notifications and reminders of one state are one
observation, and SOFT and HARD of one change are two. Every other notification is one command execution,
`["icinga2.notify.<TYPE>.v1", "<TYPE>", notification_time_us, author]` (author `""` when absent), with `<TYPE>` the
notification type as delivered. The key uses the delivered author in full, which the shipped command has already
cut to 1 KiB, so two authors equal in that cut and notified in the same microsecond are one event; executions in the
same microsecond coalesce. The domain names are versioned. Committed vectors in
`test/unit/ingest/fixtures/icinga2/key_vectors/` and `icinga2_keys_test.dart` pin the key string, key bytes and
event id of one delivery of each kind, so a change that would alter a published event id fails a test.

### Convergence contract

A webhook-fed alert ends in the state of its highest-ranked committed, eligible, state-bearing observation after
event-id deduplication, in any processing order. That is the object's latest state only when the latest state was
delivered, committed as such, and outranks the rest: coherent, eligible (not late, not future-dated) and unclamped
deliveries whose change times strictly increase. Otherwise the alert can stay stale until a later eligible
observation with a new event id outranks its fence. Tests assert these stale outcomes, not convergence:

- A command that runs late reads the live object, so a delayed `RECOVERY` after a refire reports the refire
  (`CRITICAL`, the refire's time); the refire's own `PROBLEM` is then a `duplicate_observation`.
- The state, state type and change time are read together but not atomically. A torn delivery that arrives after the
  coherent one ties on source time and wins by its later receipt.
- A recovery that is never delivered leaves the alert firing. Icinga 2 does not retry a failed command.
- A passive result whose execution end regresses or repeats yields change times that go backwards or tie: the older
  one is stale, and equal times collapse deliveries of one state into one observation carried by whichever row is
  processed first.
- A first delivery of a problem older than seven days is stored `late` and creates no alert.
- Source times more than five minutes after receipt are clamped for ordering, so two deliveries received in reverse
  order can swap (the clamp is stored in `events.effective_source_time`).
- A late redelivery of a ready observation is a duplicate that leaves `lastObservedAt` alone. If the late one is
  processed first, it is stored `late`, the prompt delivery becomes the duplicate and no alert exists.

Event Streams with state sync (`icinga2-event-streams`) is the path that reconciles these cases.

With Event Streams in `hard_only` mode, a sync can repair a missed HARD recovery only while the
current check result still represents that recovery. If a later SOFT problem superseded it, sync
counts the SOFT result without changing the alert; the alert can remain firing until a newer
eligible result arrives. Shorter disconnects reduce this risk but do not eliminate it.

Two check starts in the same microsecond are ordered by receipt time, then event ID. Different
results with equal starts can leave the alert disagreeing with Icinga 2. Beyond the clock skew
allowance, a stale stream copy keeps its observation key and can block a sync copy from repairing
the alert. A sync counts those disagreements as `diverged`. In a shared namespace, a silent
confirmation keeps the alert's displayed source, which can depend on whether the webhook or the
sync wrote the alert first.

## Icinga2 sender setup

Icinga 2 reaches Correlia through a compiled sender, `correlia-icinga2-notify`, and the command definitions in
`contrib/icinga2/`. Each notification runs the sender once; it builds one `correlia.icinga2.v1` document from its
arguments and POSTs it to `<base url>/hooks/icinga2/<source>`.

### Installation

1. In a checkout with the pinned toolchain (`mise install`), initialise the pinned Flutter SDK
   (`mise exec -- flutter --version`, which writes the SDK version file the workspace resolution needs), then
   resolve the workspace once with network access: `mise exec -- dart pub get`. The release build then resolves the sender offline from that cache, against the
   committed `pubspec.lock`, so it builds the locked dependencies and nothing newer. Run
   `mise run release:icinga2-notify` and install `build/icinga2-notify/release/linux-x64/correlia-icinga2-notify`
   as `/usr/local/bin/correlia-icinga2-notify` (owned by root, mode 0755). The release task publishes only the
   bundle (sender and definitions) that every listed capture of the architecture ran, so only the release directory
   is qualified. The plain build output under `build/icinga2-notify/<architecture>/` and the `contrib/icinga2/`
   sources are unchecked: they are for development and captures, not for installation. Today only linux-x64 is
   published; the linux-arm64 build has no captured release.
2. Copy the three files of `build/icinga2-notify/release/icinga2/` together into `/etc/icinga2/correlia/` and add one line to
   `/etc/icinga2/icinga2.conf`: `include "correlia/correlia.conf"`. Do not copy them into `conf.d`: Icinga 2 loads
   that directory in file-name order, and the commands need the constants and helper functions loaded first.
3. Edit the constants in `correlia.conf`: the sender path, the base URL (scheme and authority only, with an
   explicit port, if any, in 1-65535), the source UUID, exactly one of the token file or the HMAC key file, and
   optionally a CA file. The sender path and every file path must be absolute, and the sender path must not
   contain `=` (`env` would take it as a variable assignment). Only file paths are arguments,
   never a credential. Every value is used as written: a dollar sign in the sender path or a file path is an
   ordinary character, not a macro.
4. Apply the `correlia-host` and `correlia-service` commands to one dedicated user (the commented example in
   `correlia.conf`). Icinga 2 runs a command once per recipient, so each extra user is an extra delivery.
   Deliveries of one state notification (same state, state type and change time) are the same observation:
   the copies are stored as duplicates and publish nothing. A non-state notification (acknowledgement,
   downtime, flapping, custom) has no such key, so each extra copy can publish an extra event.
5. Run `icinga2 daemon -C` and reload Icinga 2.

The commands launch the sender through `/usr/bin/env -i` with Icinga 2's `timeout = 15`. The sender takes every
input from its arguments, refuses a non-empty environment (`environment`), and has its own 10-second deadline.
Exit status 0 means Correlia answered 202; 1 is any other HTTP status, 2 a configuration or argument error, and
3 a connection, TLS or deadline failure.

### Host requirements

- **Loader variables.** Icinga 2's service environment must not set dynamic loader variables (`LD_PRELOAD`,
  `LD_LIBRARY_PATH` or any other `LD_*`). `/usr/bin/env` itself starts with Icinga 2's environment, so the loader
  acts on them before `env -i` clears them.
- **Argument budget.** The sender's arguments take at most 256 KiB (texts cut at 8 KiB, the author at 1 KiB).
  Icinga 2's service environment plus 256 KiB must fit the kernel's `ARG_MAX` (2 MiB with the usual 8 MiB stack).
  A launch that does not fit fails, and Icinga 2 logs it like any failed command.
- **Credential and CA files.** Every component of each credential and CA file's resolved path, symbolic link
  targets included, must be writable only by root or the Icinga 2 user, and the files owned by one of them. The
  token and key files must be readable only by the Icinga 2 user (any group or other bit exits 2 with
  `credential_mode`); a CA file writable by group or others exits 2 with `ca_mode`. The token and key files are at
  most 4 KiB and the CA file at most 1 MiB. A file the sender may not open or read exits 2 with `unreadable`
  and the argument's name. The HMAC key file holds Correlia's 43-character unpadded base64url key.
- **Transport.** The base URL must be `https://`, or `http://` only to a literal loopback address (`127.0.0.0/8`
  or `::1`, not `localhost`). Proxies and redirects are never followed, and trust is exactly the CA file when one
  is set, otherwise the distribution's bundle; no environment variable changes either.
- **Names and settings.** A host or service name that is empty, holds a control character (U+0000-U+001F,
  U+007F) or a byte that is not valid UTF-8, or is longer than 1024 bytes is not delivered: the command exits 2
  with `invalid_name` in Icinga 2's log. A setting that cannot be passed exactly (a base URL over 4 KiB, a file
  path with a NUL or invalid UTF-8) or a relative file path exits 2 naming its argument. Neither is retried.
  A token, key or CA setting that does not start with `/` is never passed: the command gets `""` in its place, so
  a credential pasted where its file path belongs does not appear in the command line or in Icinga 2's log. A
  sender path that is relative, longer than 4 KiB, holds a NUL or holds `=` runs nothing: the command fails
  with exit 127 from `env`, whatever file the bare name, the part before the NUL or the path itself names.

### Text exposure

Host and service names, check output, the author and the comment are sender arguments, so they appear in:

- the process list, for as long as the sender runs;
- Icinga 2's log line for a failed command, which holds the complete command line: the texts, the base URL, the
  source UUID and the credential file paths;
- with Notice logging enabled, Icinga 2's launch log, which records the command line of every notification it
  starts, successful ones included.

The token, the HMAC key and the signature are never arguments or output, so none of these holds a credential.
The sender's stderr line holds only the status or the error class, never Correlia's response body.

### Delivery limits

- **No retry.** Icinga 2 does not retry a failed notification command. A notification that is not delivered
  (Correlia down, a non-202 answer, a deadline) is lost; reminders repeat only open problems.
- **No SOFT states, and suppression.** Icinga 2 sends no notification for SOFT states, nor while downtime,
  acknowledgement, dependencies or flapping suppress it. Correlia sees only what Icinga 2 sends; the
  [convergence contract](#convergence-contract) lists the cases where an alert stays stale.
- **Concurrency cap.** Ingress admits at most two signed requests per source and eight signed requests overall,
  within sixteen request slots, and answers 503 beyond them. A notification answered 503 is lost like any other
  failed one, so an HMAC source with bursts of concurrent notifications loses some. Use bearer mode for such
  sources.
- **Downtime removal.** Supported releases send both the expiry and the manual removal of a triggered downtime as
  `DOWNTIMEEND`, so Correlia cannot tell a cancelled downtime from an expired one. Removing a downtime that
  never triggered sends no notification.

### State change time

The shipped formatter turns Icinga 2 times into microsecond text only for `1 <= seconds < 2^32`, so the
commands never send a time after 2106; a time outside that range is not delivered (exit 2 naming
`--last-state-change` or `--notification-time`).

`PROBLEM` and `RECOVERY` carry the object's state change time: `last_state_change` once the object has had a
real state value change, otherwise, in a HARD state, `last_hard_state_change`. Icinga 2's initial values are
never sent. So the first problem of a new object still in its initial state value, whether loaded at startup or
created through the API, carries the execution end of its first HARD result; a later HARD check and every reminder
carry the same time and are duplicates of it. A new object whose state value already changed (a service going from
its initial UNKNOWN to SOFT CRITICAL, then HARD CRITICAL) carries that change's `last_state_change`, the SOFT
result's time. A first problem still in a SOFT state has no state change time and is not sent (Icinga 2 sends
none for SOFT anyway). Other notification types never carry the field.

A `volatile` object with no state value change yet moves `last_hard_state_change` on every HARD check. Correlia
publishes one event per distinct, eligible HARD time that a command samples, not one per check: two checks that
complete before either command runs give one event, and a reminder with no check in between is a duplicate. The
alert stays one alert.

### Upgrade order

The upgrade is offline. Every older Correlia process, of every role (`api`, `worker` and `all`), stops before
any process of this release starts, and none is restarted afterwards: an older worker decodes every row as
Alertmanager, and an older process overwrites a source's kind when it publishes configuration at startup. Rows
admitted meanwhile wait `pending` and are processed by the upgraded workers.

### Supported Icinga 2 releases

The sender and the shipped definitions are supported on the Icinga 2 minor releases and architectures below, and on
no other. A pair is listed only when the committed captures of a real Icinga 2 pass the six gates (same-second
service and host state, same-second notification time, the production notification clock, downtime removal and the
first problem of a new object), every captured scenario left its file and passes its own check, and that
architecture's exact artifact delivers one real notification with `202` and an event the pipeline decodes. The
scenario checks are one list that `icinga2_versions_test.dart` and the release publisher both run.
`tool/icinga2_capture.sh <release>` makes the captures under
`correlia_server/test/unit/ingest/fixtures/icinga2/<release>/<architecture>/`, and `icinga2_versions_test.dart`
re-evaluates every listed pair on them. Adding a pair means capturing it, committing the capture and listing it
here; a pair that fails a gate is not listed. Each row names a minor release by the patch release that was captured.

`mise run release:icinga2-notify` (`tool/release_icinga2_notify.sh`) first removes the earlier publication, so a
failed build or publisher run leaves none at the installation path. It then builds the sender for linux-x64 and
linux-arm64 and publishes into
`build/icinga2-notify/release/` only the architectures whose listed pairs all pass every check and all ran one
bundle: the same sender SHA-256 and the same `contrib/icinga2/` file hashes, as their manifests record. It publishes
an architecture's sender, and the definitions into `release/icinga2/`, only when the build and the definitions are
exactly that bundle; recapturing one listed release with a new sender or changed definitions refuses the
architecture until every listed release of it is recaptured. With no qualified pair it publishes nothing and fails. linux-arm64 has no captured pair yet, so its build is not
published.

The build (`tool/build_icinga2_notify.sh`) compiles a copy of the sender package at the fixed path
`/tmp/correlia-icinga2-notify-build`, resolved offline against the workspace lock file, because `dart compile exe`
embeds the absolute path of its entry point. A checkout at any path therefore builds the same bytes, and the release
task can match them against the captures. One build runs at a time; an interrupted one leaves that directory, which
the next build names and refuses until it is removed.

<!-- icinga2-supported-releases:begin -->
| Release | Architecture |
|---|---|
| 2.13.14 | linux-x64 |
| 2.14.10 | linux-x64 |
| 2.15.7 | linux-x64 |
| 2.16.6 | linux-x64 |
<!-- icinga2-supported-releases:end -->

## Durable processing and failure inspection

A worker first commits the active immutable configuration pin, then decodes and processes under a separate raw-row lock. A killed worker retains the pin; replacements never substitute the current configuration. If that first-pinned snapshot omits/disables the source, the raw row fails as `source_not_configured`, retaining its bytes.

Processing validates the complete batch before effects, folds repeated observations and inserts observation keys in stable event-id order. It then locks distinct alert fingerprints in ascending order before evaluating state, and finally writes event evidence and unique routed output intents in event-id order. Keys, alert state, activity, output intents and raw completion commit together. Invalid siblings or fanout beyond 16 MiB—including every event and intent payload copy—produce a failed raw delivery without partial effects.

The authoritative alert row is keyed by tenant and fingerprint. Its fence compares effective source time, receipt time and event id at canonical nanosecond precision; effective time is capped at receipt plus five minutes. An observation at or below the fence is stale and cannot change state. Applied observations advance the fence; only visible changes increment the version and append activity. `lastObservedAt` advances monotonically for applied or stale observations and by ready duplicates of originally ready observations (a late or future-dated redelivery of a ready observation does not refresh it), without changing the version or writing activity.

Future-dated evidence (more than 24 hours ahead) has no observation key, state or output. Identical quarantined evidence at equal observed time collapses on the events key and increments `duplicate_quarantine`, not the error budget. Late evidence (older than seven days) retains a key and event but changes no state or output, including on duplicate delivery. Eligible duplicates preserve first evidence and produce no additional event/output effects. Empty routes record an unrouted event with no intent. Raw outcome JSON records committed, applied, stale, unrouted, upstream-omitted, duplicate-observation, future, duplicate-quarantine and late counts.

Serialization, deadlock, lock-timeout and connection-unavailable errors retry indefinitely with capped one-to-thirty-second backoff without spending the internal-error budget. Other internal failures consume five attempts, then produce `processing_exhausted`. Scheduling hints are bounded and process-local; database eligibility, raw bytes, pins and the internal-error budget remain durable. A ten-second total transaction deadline and five-second statement/lock bounds limit work.

Use both time and ID when joining raw, event or delivery evidence. Raw bodies and delivery
payloads are private operational data; do not paste them into diagnostics.

### Operator RPC

The `deadLetter` RPC is off by default. To enable it on an `api` or `all` process, set
`CORRELIA_DEAD_LETTER_CREDENTIALS_FILE` to an owner-only JSON file (`chmod 600`). The file
maps one to eight machine IDs to distinct lowercase SHA-256 digests. IDs start with a
lowercase letter and use at most 64 lowercase letters, digits, underscores or hyphens.
The file is limited to 4 KiB.

Generate 32 random bytes per machine. Store the SHA-256 hex digest of those **bytes**
in the file, and give the machine the 43-character unpadded base64url encoding of the
bytes. Send it in `Authorization: Bearer <token>` to the API port over TLS. Do not put
the token in the URL or RPC arguments. Webhook credentials do not grant this access.
Replace the file and restart each API replica to rotate credentials. A malformed file or a
repeated machine ID stops startup.

Use `Client.deadLetter` from `correlia_client` with the machine bearer:

| Method | Inputs and effects |
|---|---|
| `list` | Select `raw` or `delivery`. Optionally filter by source/output UUID, error class and inclusive failure-time range. Returns sanitized metadata including the occurrence ID, age and error class. A raw result can include its pinned snapshot and safe field path. |
| `replay` | Requeue one occurrence of the specified kind. A later failure of the same row has a new occurrence ID. |
| `replayBatch` | Requeue eligible occurrences in one page of the same filters. Returns queued and refused counts, a reason for each occurrence and a continuation when more matches remain. |
| `status` | Read pending count, oldest pending age, database pressure, output limits and usage, discard counts, overflow episodes, and the last completed maintenance batch. `maintenanceFailures` lists one sanitized failure per job until that job succeeds. Partition retry status is separate. |

Status shows blocking outputs first, up to 64 lanes. `outputsTruncated` indicates that other
lanes are omitted. A failed partition attachment reports `prepare_partition` with zero
affected rows and keeps its retry record. A successful attachment reports one affected partition.

Supply a limit from 1 to 100 for `list` and `replayBatch`. Pass the continuation to the same
method with the same filters. It resumes after the last considered occurrence and keeps
the first page's upper time bound even if the database clock moves back. Start a new listing
to include later failures or revisit refused items. No reply includes raw bodies, delivery
payloads, destinations or signing references. Successful replay records the verified machine
ID and queued count in `activity`.

Plugin dead letters use the `plugin_failure` category for listing and filters. The API does
not return plugin-supplied error text.

Raw replay needs a free pending slot and an enabled source with the same admission mode.
It pins the configuration active at replay, retaining the original bytes, receipt, Icinga 2
origin and generation 0. Queue age alone does not block replay. An unavailable source, full
inbox or expired failure cannot be requeued. A replay of a reconcile row does not change its
original sync run. If it finishes without writing an event, the worker records that outcome
in the ledger before deleting the raw row.

A pre-upgrade Icinga 2 item below the published reclamation boundary counts as late.
If it is also future-dated relative to its original receipt, the worker keeps the quarantine
rules and counts both conditions.

Delivery replay keeps the original payload, event ID, delivery ID, destination, and signing
commitment. It requires the original webhook signing material and room in the live output
inventory if it adds a lane. It starts a fresh 20-attempt allowance; attempt numbers keep
increasing and prior history remains. Replay does not run the pipeline or alter alert state.

An `api` replica can replay webhook deliveries without `CORRELIA_INGEST_CONFIG`. Set
`CORRELIA_SECRET_KEY_FILE` on that replica to the same database encryption key used by the
publisher. The replica does not need the configuration or secret import files.

Change 9's demo uses this API to find and replay a dead delivery and show pressure clearing.
The DUR-4 console check stays with M4: the dead-letter view must identify the failed output,
show its sanitized error class and let an authorized operator replay the exact occurrence.

## Plugin batch delivery

Plugin rows are eligible only while a local instance serves their pinned definition. The relay takes a generation-checked permit before claiming; its last transaction step rechecks that permit before commit. Observed readiness loss before that boundary rolls back acquisition without spending attempts. Unavailable historical definitions do not block ready definitions of the same output. Voluntary stops drain outstanding permits; loss after the boundary makes unanswered events retryable with `plugin_connection_lost`.

One output has at most one delivering set across workers. A plugin batch contains at most 64 events and 1 MiB, further limited by the plugin's negotiated bounds, all from one definition. A monotonic 27-second budget starts before claiming; claim commit is limited to five seconds, delivery to at most twenty seconds while reserving completion time, and each SQL statement/lock timeout to the remaining budget capped at five seconds. The database sets the shared lease to thirty seconds from its own clock.

All per-event outcomes complete in one transaction. Both outbox and attempt updates require the current claim, delivering status, an unexpired `clock_timestamp()` lease and exact affected-row counts; any mismatch rolls everything back. Over-budget completion writes nothing and lease recovery records interruption. Webhooks retain one-row acquisition and their original signing behavior. As with webhooks, every started plugin attempt consumes the twenty-attempt budget; the destination must deduplicate redelivery by event id.

## Signed webhook delivery and recovery

Every routed intent stores its original structured CloudEvents bytes, event id, destination, snapshot and signing-key commitment. Rotation never redirects or re-encodes old work. Relays POST `Content-Type: application/cloudevents+json`, `Idempotency-Key: <event-id>` and `X-Correlia-Signature: sha256=<lowercase HMAC-SHA256 hex over the exact body>`. Receivers must deduplicate the event id: delivery is at least once, not exactly once or ordered per alert. HMAC authenticates bytes, not freshness.

Only 2xx acknowledges. Network errors, total-deadline expiry, 408, 429 and 5xx retry; other statuses, including redirects, are permanent. Redirects are not followed. Destinations require HTTPS except explicit loopback HTTP in development/test; userinfo, query and fragment are rejected. Calls have a ten-second total deadline. Response bodies are discarded up to 64 KiB, then the connection closes; an already received 2xx still acknowledges an oversized response.

One shared discovery loop serves independent lanes, with at most one in-flight request per retained output id. A failing output cannot hold a database transaction over HTTP or block healthy outputs. Acquiring an intent commits a random claim token, database-clock thirty-second lease and started attempt. Finalization is fenced by that current unexpired token. Death after remote success can therefore produce a byte-identical duplicate after restart; stale completions cannot overwrite a successor.

Expired claims mark their unfinished attempts `interrupted` and retry. Every started attempt spends the twenty-attempt budget, including ambiguous outcomes and process death. Backoff is `min(300 seconds, 2^(attempt-1) seconds)` within that allowance. Exhausted or permanent work becomes `dead` with its payload retained; only an explicit operator replay can requeue it.

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
