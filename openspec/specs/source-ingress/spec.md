# source-ingress Specification

## Purpose

Admit authenticated monitoring deliveries durably without exposing credentials or confusing transport retries with distinct observations.

## Requirements

### Requirement: Source scoped authentication

The system SHALL accept POST deliveries only for an enabled registered source whose kind matches the route and with one of its credentials valid at receipt. Credentials SHALL be source-scoped, rotatable and compared without secret-dependent early exit. Bearer authentication SHALL precede body buffering. Unknown sources, kind mismatches and invalid credentials SHALL return 401 without inbox insertion; rejection counts SHALL identify only a known source or the unknown-source bucket.

#### Scenario: Authenticated source delivery
- **WHEN** an enabled source submits a POST with its current bearer token
- **THEN** it is admitted for bounded body reading and durable storage under that source UUID

#### Scenario: SEC-1 another source token
- **WHEN** a source is addressed using another source's token, a revoked token, or no credential
- **THEN** the response is 401, no raw row is created and the addressed known source's rejection count increases

#### Scenario: Route kind mismatch
- **WHEN** a source registered with kind `alertmanager` is addressed with its valid token under a route of another kind
- **THEN** the response is 401, no raw row is created and the response is indistinguishable from an unknown source

### Requirement: Credential safe request handling

The system SHALL support bearer authentication and an explicitly enabled `/hooks/alertmanager/<instance>/<token>` alternative. Path and bearer credentials, query secrets and signing keys SHALL never enter session/request/error logs or stored headers. Credentials SHALL not occur in response bodies. Ambiguous simultaneous credential forms SHALL be rejected. Raw bodies SHALL remain restricted data, never copied into diagnostic messages.

#### Scenario: SEC-5 path token redaction
- **WHEN** valid and invalid path-token deliveries run through success, authentication rejection and injected database/error paths with console and persistent logging enabled
- **THEN** neither token nor query secret appears in logs, diagnostic events, persisted session metadata, stored headers or response bodies; sanitized diagnostics still name the source and outcome

#### Scenario: Conflicting credentials
- **WHEN** a request contains both a path credential and an Authorization credential
- **THEN** it receives 401 with no raw insertion and neither credential is logged

#### Scenario: Unconfigured ingress still protects token paths
- **WHEN** api/all has no ingest configuration and receives a path-token request under /hooks with a query secret
- **THEN** a fixed 503 response or malformed-request rejection is returned without initiating a web session or exposing path/query values in logs or diagnostics

### Requirement: Bounded durable admission

The system SHALL enforce the source body-byte limit while streaming, defaulting to 1 MiB, independently of Content-Length. Only uncompressed JSON requests SHALL be accepted. Unsupported content type/encoding SHALL return 415, overflow 413, malformed transport headers 400, and unavailable persistence 503 with Retry-After. A new accepted delivery SHALL receive 202 only after its raw bytes, digest, observed time and safe metadata commit.

#### Scenario: Accepted body above endpoint default
- **WHEN** an authenticated uncompressed JSON body between 512 KiB and 1 MiB reaches a default source
- **THEN** the HTTP response is 202 and the exact bytes and digest are durably retrievable, proving the custom route is not limited by the RPC endpoint default

#### Scenario: Chunked oversized delivery
- **WHEN** an authenticated request without Content-Length exceeds its source limit or uses unsupported content encoding
- **THEN** it receives respectively 413 or 415 and creates no raw row

#### Scenario: Admission commit fails
- **WHEN** raw persistence fails before commit
- **THEN** the response is 503 with Retry-After and neither a raw row nor a transport-dedup reservation is committed

### Requirement: Atomic transport retry deduplication

Within the configured transport window, default 10 minutes, equal source-scoped Idempotency-Key values or equal source-scoped raw-body hashes when no key is supplied SHALL identify one delivery. Concurrent exact retries SHALL receive 202 and create one raw row total. Reusing a live explicit key for different bytes SHALL return 409. Expired keys SHALL permit new deliveries. Retries SHALL not extend the original window.

#### Scenario: ORD-5a concurrent exact retries
- **WHEN** two connections submit the same source and delivery evidence concurrently
- **THEN** both receive 202, only one raw row exists and one delivery is counted as duplicate

#### Scenario: Key conflict and expiry
- **WHEN** a live explicit key is reused with different bytes, then submitted again after its original window expires
- **THEN** the first reuse receives 409 without insertion and the later submission receives 202 with a new raw row

### Requirement: Validated immutable bootstrap configuration

The system SHALL atomically publish immutable source/output snapshots with increasing integer revisions, validate references and retain pins. Credentials SHALL come from separate secret input. Stale or equal-conflicting input SHALL fail startup without changing active state. Without bootstrap, workspace behavior SHALL remain available, but worker/all SHALL fail startup if an active ingest snapshot or unfinished ingest/output work exists.

#### Scenario: Bootstrap publication and rotation
- **WHEN** valid bootstrap files register a source and output, and a subsequent publication rotates the source token
- **THEN** the source UUID remains stable, new admission uses only the new token, and raw rows already pinned retain their original normalization/routing version

#### Scenario: Empty registry and missing secret
- **WHEN** bootstrap input routes to a missing output, including an empty output registry, or references an unavailable secret
- **THEN** activation fails with a bounded field error, the prior active snapshot remains unchanged and no partially configured worker starts

#### Scenario: Stale bootstrap cannot revoke the rotation
- **WHEN** version B rotates a source token and another process restarts with lower-revision version A
- **THEN** that process fails startup naming only snapshot ids/revisions, B stays active, the old token remains rejected and B's routes are unchanged

#### Scenario: Missing config with durable work
- **WHEN** worker/all starts without bootstrap while pending raw or queued/delivering output work exists
- **THEN** startup fails with sanitized counts rather than reporting ready while leaving accepted work unattended

#### Scenario: Dead intent does not require signing material
- **WHEN** startup retains a dead intent signed under a removed old key and all queued/delivering work has its keys
- **THEN** the worker starts, the dead payload and key commitment remain stored, and no old key is required or reconstructed

#### Scenario: Revert by higher revision
- **WHEN** B is active and the operator republishes A's content with a revision greater than B
- **THEN** a new immutable snapshot activates with A's routes and credentials while already pinned B rows retain B

#### Scenario: Conflicting equal revision
- **WHEN** another process presents different snapshot content at the active revision
- **THEN** startup fails naming only the two ids/revisions and active credentials/routes stay unchanged

#### Scenario: Missing worker config after drained queue
- **WHEN** an active ingest snapshot exists and worker/all starts without bootstrap while no unfinished work exists
- **THEN** startup fails with a sanitized active-config/count message and readiness never becomes ready

#### Scenario: Malformed secret or credential-bearing input is not echoed
- **WHEN** the secret file is malformed or contains an invalid value, or an output URL contains userinfo or a query
- **THEN** startup fails with only file kind, field path and code; captured stderr/logs contain no secret bytes, URL, userinfo or parser source excerpt

### Requirement: Source configuration format

The bootstrap configuration SHALL accept format version 2, where each source declares `kind`, `credentials`, an optional `namespace`, `body_limit_bytes` and `rate_limit`, and the root may declare `namespaces`. Format version 1 SHALL still be accepted and read as one bearer credential from `token_ref`, kind `alertmanager` and the default rate limit. Unknown fields, kinds and modes SHALL fail with a bounded field error.

#### Scenario: Version 1 file still starts
- **GIVEN** an M1 database with a format version 1 configuration active at revision N
- **WHEN** the same file is published at revision N with a key file
- **THEN** activation fails with `activation_conflict` and the prior snapshot stays active
- **WHEN** it is published at revision N+1 with its existing secret file and the key file
- **THEN** activation succeeds, the source keeps its UUID and namespace, and its existing token is accepted

#### Scenario: Unsupported kind or field
- **WHEN** a version 2 source declares kind `zabbix`, which is not supported, or carries an undeclared field
- **THEN** activation fails with a field error naming `sources[i].kind` or the field path, and the prior snapshot stays active

#### Scenario: Supported kinds
- **WHEN** a version 2 file declares one source of kind `alertmanager` and one of kind `icinga2`
- **THEN** activation succeeds and each source accepts deliveries only under its own kind's route

### Requirement: Icinga2 source mode

An `icinga2` source MAY declare `mode`: `webhook`, the default, or `event_streams`. A stream source SHALL
declare the stream settings instead of `credentials`, `body_limit_bytes` and `rate_limit`.

#### Scenario: Webhook mode by default
- **WHEN** an `icinga2` source declares no `mode`
- **THEN** it is a webhook source and behaves as before this change

#### Scenario: Existing snapshot republished after the upgrade
- **WHEN** a database's active version 2 snapshot at revision N has webhook sources, and the same file is published at revision N after the upgrade
- **THEN** the snapshot id is unchanged and activation is a no-op, because webhook mode is not written into the snapshot

#### Scenario: Mode on another kind or unknown mode
- **WHEN** an `alertmanager` source declares `mode`, or an `icinga2` source declares `mode: poll`
- **THEN** activation fails with a field error naming `sources[i].mode`

### Requirement: Credential rotation with overlap

A webhook-mode source SHALL hold 1 to 4 credentials, each with a distinct secret reference and an optional `not_before` and `not_after` instant (`not_before` < `not_after`). A credential SHALL authenticate only within its window, evaluated at receipt time. At least one credential SHALL have no `not_after` or a `not_after` in the future at activation.

#### Scenario: Overlapping rotation
- **WHEN** revision B adds a new bearer credential beside the current one, then revision C removes the old one
- **THEN** under B both tokens are accepted, under C only the new token is accepted and the old one returns 401

#### Scenario: Expired and not yet valid credentials
- **WHEN** a request presents a credential whose `not_after` has passed or whose `not_before` is in the future
- **THEN** the response is 401 with no raw row, and the source's rejection count increases

#### Scenario: Rotation during a body read
- **WHEN** a request authenticates with a credential under revision B, and revision C removing that credential (or disabling the source or disabling path tokens) commits while the request body is still being read
- **THEN** the request receives 401 and no raw row or transport key is committed; a request whose credential is still valid at its receipt instant and still present at commit is admitted

#### Scenario: Activation without a usable credential
- **WHEN** a publication gives a source five credentials, two credentials with the same reference, or only credentials already expired
- **THEN** activation fails with a bounded field error and the prior snapshot stays active

#### Scenario: Stream source holds no credentials
- **WHEN** an `icinga2` source with `mode: event_streams` is published without `credentials`
- **THEN** activation succeeds, and the source has no webhook credential that could authenticate a delivery

### Requirement: HMAC signed deliveries

A credential of type `hmac` SHALL authenticate a request carrying `X-Correlia-Timestamp` (Unix seconds) and `X-Correlia-Signature: sha256=<hex HMAC-SHA256>` over the signing input. The source SHALL be resolved before buffering; the signature SHALL be verified after the bounded read and before any inbox insertion. A timestamp more than 300 seconds from receipt SHALL be rejected. HMAC credentials SHALL not be accepted as bearer or path tokens.

#### Scenario: Valid signature admitted
- **WHEN** a source with an HMAC credential receives a body signed with its key and a current timestamp
- **THEN** the response is 202 and the raw row stores neither the signature nor the timestamp header

#### Scenario: Bad, stale or misplaced signature
- **WHEN** the signature is wrong, the body is altered by one byte, the timestamp is 301 seconds old, a header is duplicated, or the HMAC key is presented as a bearer token
- **THEN** the response is 401, no raw row is created, and neither the signature nor the key appears in logs or diagnostics

### Requirement: HMAC signing input

The signing input SHALL be the exact bytes `<timestamp>.<K>.<body>`: the timestamp header's decimal digits as sent, `.`, K, `.`, then the exact body. K SHALL be `-` when no `Idempotency-Key` header is present, else the 64 lowercase hex characters of SHA-256 over the key's UTF-8 bytes, so no bytes can move between the key and the body.

#### Scenario: Published signing vector
- **WHEN** a sender signs a fixed key, timestamp, idempotency key and body from the published test vector
- **THEN** the computed signature equals the vector's value and the request is admitted

#### Scenario: Signed replay with a new idempotency key
- **WHEN** a captured signed delivery with `Idempotency-Key: k` and body `1.23` is replayed within 300 seconds, once unchanged, once with a different key, and once as key `k.1` with body `23` under the same timestamp and signature
- **THEN** the unchanged replay is a duplicate (202, no new raw row), both altered replays receive 401, and the source has exactly one raw row

### Requirement: Per source request rate

Each webhook-mode source SHALL have a request-rate budget (`rate_limit.per_second` 1 to 1000, default 20; `rate_limit.burst` 1 to 10000, default 40) enforced per process after successful authentication. A request over budget SHALL receive 429 with a `Retry-After` header in whole seconds and SHALL create no raw row; it SHALL count as rejected for that source.

#### Scenario: Burst within budget
- **WHEN** an authenticated source sends its burst size of requests at once
- **THEN** every request is admitted normally

#### Scenario: Budget exceeded
- **WHEN** an authenticated source sends one request more than its remaining budget
- **THEN** that request receives 429 with `Retry-After` of at least 1, no raw row is created and the source's rejection count increases

#### Scenario: Unauthenticated traffic spends no budget
- **WHEN** a stranger sends many requests with invalid credentials to a source, then the source sends a valid request
- **THEN** the stranger's requests receive 401 and the valid request is admitted

#### Scenario: Stream source has no request budget
- **WHEN** an `icinga2` source with `mode: event_streams` is published
- **THEN** it has no request-rate budget, and its ingest is bounded by `max_pending_rows` instead

### Requirement: Declared shared namespaces

A source's alert namespace SHALL default to its own instance UUID. A source MAY name another namespace only if the root `namespaces` list declares it; declared names SHALL be 1 to 128 bytes and SHALL NOT have UUID form. Sources with distinct namespaces SHALL never share alert identity.

#### Scenario: ID-2 same names from two sources
- **WHEN** two Alertmanager sources with default namespaces deliver alerts with identical labels through HTTP ingress, then two sources in one declared namespace do the same
- **THEN** the first pair yields two alerts with distinct fingerprints, the second pair yields one alert with one fingerprint, and each delivery keeps its own source instance and observation id

#### Scenario: Undeclared or UUID shaped namespace
- **WHEN** a source names a namespace absent from `namespaces`, or `namespaces` declares a UUID-shaped name
- **THEN** activation fails with a field error naming the path and the prior snapshot stays active

### Requirement: A source's kind never changes

A source UUID SHALL keep the kind it was first published with. A configuration that gives an existing source
UUID another kind SHALL fail activation with `kind_changed`, so a raw row whose pinned snapshot configures its
source decodes with the kind it was admitted under, also on replay.

#### Scenario: Kind change refused
- **WHEN** a source published as `alertmanager` is republished with the same UUID and kind `icinga2`
- **THEN** activation fails with a field error naming `sources[i].kind` and code `kind_changed`, and the prior snapshot stays active

#### Scenario: Disabled source keeps its kind
- **WHEN** a source is removed from the configuration and later published again with the same UUID and another kind
- **THEN** activation fails with `kind_changed`

#### Scenario: Admitted row decodes with its kind
- **WHEN** an Alertmanager delivery is accepted with 202, then a configuration revision that keeps the source is published, and then the pipeline claims the row
- **THEN** the row decodes as Alertmanager

#### Scenario: Source disabled before the first claim
- **WHEN** a delivery is accepted with 202, then a revision that disables its source is published, and then the pipeline claims the row
- **THEN** the row fails with `source_not_configured`, as for every kind, and no decoder runs

### Requirement: Path tokens stay Alertmanager-only

`path_token_enabled` SHALL be accepted only on `alertmanager` sources. A credential in the URL path of any other
kind's route SHALL be refused.

#### Scenario: Icinga2 source declares a path token
- **WHEN** an `icinga2` source declares `path_token_enabled: true`
- **THEN** activation fails with a field error naming `sources[i].path_token_enabled`

#### Scenario: Path-token request on the Icinga2 route
- **WHEN** a request is sent to `/hooks/icinga2/<id>/<credential>`
- **THEN** Correlia answers 401 and no raw row is inserted

### Requirement: Identity label exclusion stays Alertmanager-only

`excluded_identity_labels` SHALL be accepted only on `alertmanager` sources, because an Icinga2 fingerprint is
built from host and service, not labels.

#### Scenario: Icinga2 source declares excluded identity labels
- **WHEN** an `icinga2` source declares `excluded_identity_labels: ["service"]`
- **THEN** activation fails with a field error naming `sources[i].excluded_identity_labels`, and the prior snapshot stays active

### Requirement: A source's mode never changes

An `icinga2` source UUID SHALL keep the mode it was first published with, also across disable and
re-enable. A configuration that gives it another mode SHALL fail activation with `mode_changed`, so a raw
row always decodes in the mode it was admitted under.

#### Scenario: Mode change refused
- **WHEN** a source published as `webhook` is republished with the same UUID and `mode: event_streams`
- **THEN** activation fails with a field error naming `sources[i].mode` and code `mode_changed`, and the prior snapshot stays active

#### Scenario: New source for the stream
- **WHEN** the operator adds a new source UUID with `mode: event_streams` beside the webhook source
- **THEN** activation succeeds and both sources run

### Requirement: Stream sources refuse webhook deliveries

The webhook route of an `icinga2` source in mode `event_streams` SHALL answer every request with 401, exactly
as for an unknown source, without reading the body or inserting any row.

#### Scenario: Delivery to a stream source
- **WHEN** a request with any bearer token or HMAC signature is sent to `/hooks/icinga2/<stream source id>`
- **THEN** the response is 401 with the same body as for an unknown source, and no raw or transport-key row is written

#### Scenario: Webhook source unaffected
- **WHEN** a valid delivery is sent to a webhook-mode `icinga2` source in the same configuration
- **THEN** it is accepted with 202

### Requirement: New raw admissions honor the reclamation cutoff

The durable admission cutoff SHALL advance monotonically with reclamation and fence all new raw inserts.
Receipts below it SHALL roll back admission. Consumer rows SHALL use their earliest item receipt. Exact
webhook retries within their transport window and retained batch receipts SHALL return the committed
result without inserting. A live explicit key with a different body SHALL still return 409. Terminal
rows below the cutoff SHALL NOT be requeued.

#### Scenario: Webhook reaches admission after its receipt falls behind the cutoff
- **WHEN** a valid webhook read began before the cutoff and attempts a new admission after the cutoff advances past its receipt
- **THEN** it gets 503 and no raw row or transport reservation is committed; a fresh delivery can be admitted

#### Scenario: A buffered stream item falls behind the cutoff
- **WHEN** a new consumer batch contains an item received before the cutoff
- **THEN** no raw row, origin record or batch receipt commits, and the consumer closes, records a gap and resyncs on reconnect

#### Scenario: Committed batch receipt survives advancement of the cutoff
- **WHEN** a consumer retries a batch whose commit acknowledgement was lost and whose earliest receipt is older than the cutoff
- **THEN** while its batch receipt is retained, it gets the committed result without inserting another raw row

#### Scenario: Webhook reservation inside and outside the transport window
- **WHEN** retries of an already committed webhook reach admission with receipts behind the cutoff, one inside the original deduplication window and one after it
- **THEN** the first returns the committed duplicate result and the second returns 503; neither creates a raw row or changes the original reservation

#### Scenario: Conflicting live webhook key behind the cutoff
- **WHEN** a delivery behind the cutoff reuses a still-live explicit key with a different body
- **THEN** admission returns 409 without changing the reservation or inserting a raw row
