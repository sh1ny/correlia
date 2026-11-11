# Ingest pipeline schema ownership

Serverpod migrations own source and configuration snapshots, the active pointer, secret commitments, transport and observation keys, pipeline failures and delivery attempts. Correlia's ordered `correlia_server/schema/*.sql` steps exclusively own `raw_inbox`, `events` and `outbox`. These tables have no generated table models. They are ordinary PostgreSQL tables with time-qualified composite primary keys; future partition maintenance remains with the SQL schema owner. References to SQL-owned identities always include their time component. Managed tables do not have foreign keys to SQL-owned tables.

## Fresh databases and upgrades

Start the server from `correlia_server`, with its `schema/` directory deployed alongside the package. Serverpod applies managed migrations first. Each process role then initializes the schema before starting its subsystems, even if ingest is not configured. A transaction advisory lock serializes starters, and each step and its version record commit together. Existing steps are immutable: append a new numbered script and register it in the runner for every forward change. Both a fresh installation and an upgrade need the schema steps because Serverpod fresh installs use its latest managed definition rather than replaying every migration SQL file.

The database test helper `test/support/ingest_schema.dart` must receive a non-rollback session and run after managed migrations. Do not change generated test tools or hand-edit generated migration definitions. Failure of a schema step rolls back that step and prevents subsystem startup; fix the underlying problem and restart. The reported error names the step without exposing database details.

## Repair migrations

Serverpod's repair diff sees SQL-owned tables as extraneous and may propose destructive changes. Before applying any generated repair, inspect its entire SQL against the current schema and **remove all operations that drop or alter** `raw_inbox`, `events`, `outbox`, `correlia_schema_versions`, their indexes, constraints and time-qualified references. Review related cascades as well. Preserve data and the version table; never force a destructive repair merely to silence drift. Inspect any other unmanaged exceptions individually. If the desired SQL-owned schema itself needs correction, write a new forward schema step, not an edit to an applied step or a generated definition. Review the resulting repair and schema step together on a populated copy before production use.

## Identity evidence

Alertmanager's upstream fingerprint is retained in raw input and, when present, the `correlia.io/alertmanager_fingerprint` extension. It is not a label or an identity input. Original selected labels determine identity; see ADR 0024. Source-side setup screenshots have not been collected.

## Bootstrap and rotation

Set `CORRELIA_INGEST_CONFIG` to a regular JSON file and `CORRELIA_INGEST_SECRETS` to a separate regular secret file. Each file is limited to 64 KiB. Secret files must belong to the process user and have mode 0600 or stricter; symlinks are rejected. Configuration and secret parsing errors expose only a fixed input kind, field path and code, not file content, credentials or destination URLs.

Generate a separate 32-byte value for every source token and signing-key reference:

```sh
openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
```

The result is exactly 43 unpadded base64url characters. Put these generated values in the secret JSON object under the reference names below, then run `chmod 600` on that file. Never commit either operator file or print the secret file in diagnostics.

Correlia-owned, non-secret configuration example:

```json
{
  "format_version": 1,
  "revision": 1,
  "sources": [{
    "id": "11111111-1111-4111-8111-111111111111",
    "enabled": true,
    "token_ref": "alertmanager-token-v1",
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

Startup atomically publishes immutable public snapshots, token digests and the active pointer. Identical active input is a no-op. Every changed publication must be unseen and have a higher integer revision (1–2147483647). Stale or equal-conflicting input fails without changing active credentials or routes. To revert, republish the desired content under a new higher revision; restarting old files never rolls back configuration. Omitted sources become disabled.

Source rotation has no overlap window: coordinate the higher-revision publication and sender token update; requests carrying the old token then receive 401. Signing-key names are immutable commitments. Rotate signing material under a new reference, retain old material while queued/delivering work uses it, and distribute the updated secret file before restarting workers. A process missing a newly activated signing reference leaves that output queued without spending attempts; restart with current files. Terminal dead/delivered rows retain commitments but need no loaded signing bytes until a future explicit replay. Active plus retained live output lanes cannot exceed 64.

The api process also loads signing keys to validate publication; protect its secret file accordingly. No admin/configuration/raw-payload API is exposed. Without bootstrap, a worker/all process refuses startup whenever an active snapshot or unfinished ingest/output work exists—even after the queue drains. An unconfigured api still serves workspace behavior and securely rejects hook admission.

## Alertmanager sender setup and admission

POST to `/hooks/alertmanager/<source-uuid>` with `Authorization: Bearer <token>` and `Content-Type: application/json`. Prefer this header form. Only when `path_token_enabled` is true, the alternative is `/hooks/alertmanager/<source-uuid>/<token>` with no Authorization header. The token is the generated 43-character unpadded base64url value. Query parameters and simultaneous credential forms are rejected. Configure reverse proxies to omit or redact credential-bearing paths, queries, Authorization and Idempotency-Key; proxy logs are outside this process's privacy proof. Use TLS for sender traffic.

Admission authenticates before reading the body, then rechecks current source credentials in the storage transaction. It stores exact uncompressed bytes, their digest, the receipt time and normalized content type, never raw authorization or idempotency headers. An optional `Idempotency-Key` is source-scoped and limited to 256 UTF-8 bytes; absent that header, the source/body digest identifies transport retries. The ten-minute reservation window is fixed from first admission and does not slide on retries.

Bodies default to—and cannot exceed—1 MiB; a source may select a lower positive limit. A ten-second total body deadline and sixteen request slots bound admission, with a smaller authentication lookup bound protecting the shared connection pool. In-memory source/unknown counters reset on restart and rekey to the active registry; they are not a durable ledger.

| Status | Meaning |
|---|---|
| 202 | Raw bytes committed, or an exact transport retry committed as duplicate |
| 400 | Malformed request metadata or forbidden query |
| 401 | Missing, mismatched, revoked or conflicting credentials |
| 405 | Unsupported method |
| 409 | Live explicit idempotency key reused for different bytes |
| 413 | Source body limit exceeded |
| 415 | Unsupported media type or content encoding |
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
| Description annotation | Description |
| Generator/external URL | Canonical-valid HTTP(S) links; empty omitted, invalid nonempty rejected |
| Upstream fingerprint | Namespaced extension evidence, never canonical identity or labels_origin |

Identity uses complete originals before display projection. Long label/annotation values and display text truncate with a visible marker; originals remain only in restricted raw bytes. Exact supplied timestamp strings determine observation evidence; arrival time is never a fallback. Reversed intervals, missing required time, empty selected identity, invalid field types and unknown fields fail the whole delivery with a bounded field path.

The decoder permits at most 1,000 alerts and JSON depth 32. Canonical map/count/key, original-identity and 256 KiB structured-event bounds still apply; entries are not removed to force acceptance. The pipeline separately bounds aggregate event-plus-fanout storage. Strict upstream-field validation means additive sender fields require a decoder update; retain failed raw bytes for the future replay workflow. Correlia-authored fixtures and their field/provenance notes live beside `test/unit/ingest/alertmanager_decoder_test.dart`; they are documented-format examples, not real captures. Canonical event, CloudEvents and identity contracts are reused unchanged.
