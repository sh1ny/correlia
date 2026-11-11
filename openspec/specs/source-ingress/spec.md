# source-ingress Specification

## Purpose

Admit authenticated monitoring deliveries durably without exposing credentials or confusing transport retries with distinct observations.

## Requirements

### Requirement: Source scoped authentication

The system SHALL accept Alertmanager POST deliveries only for an enabled registered source and its current credential. Credentials SHALL be source-scoped, rotatable and compared without secret-dependent early exit. Authentication SHALL precede body buffering. Unknown sources and invalid credentials SHALL return 401 without inbox insertion; rejection counts SHALL identify only a known source or the unknown-source bucket.

#### Scenario: Authenticated source delivery
- **WHEN** an enabled source submits a POST with its current bearer token
- **THEN** it is admitted for bounded body reading and durable storage under that source UUID

#### Scenario: SEC-1 another source token
- **WHEN** a source is addressed using another source's token, a revoked token, or no credential
- **THEN** the response is 401, no raw row is created and the addressed known source's rejection count increases

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
