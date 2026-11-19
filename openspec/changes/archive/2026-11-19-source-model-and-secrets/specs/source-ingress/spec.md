# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: Source configuration format

The bootstrap configuration SHALL accept format version 2, where each source declares `kind`, `credentials`, an optional `namespace`, `body_limit_bytes` and `rate_limit`, and the root may declare `namespaces`. Format version 1 SHALL still be accepted and read as one bearer credential from `token_ref`, kind `alertmanager` and the default rate limit. Unknown fields and kinds SHALL fail with a bounded field error.

#### Scenario: Version 1 file still starts
- **GIVEN** an M1 database with a format version 1 configuration active at revision N
- **WHEN** the same file is published at revision N with a key file
- **THEN** activation fails with `activation_conflict` and the prior snapshot stays active
- **WHEN** it is published at revision N+1 with its existing secret file and the key file
- **THEN** activation succeeds, the source keeps its UUID and namespace, and its existing token is accepted

#### Scenario: Unsupported kind or field
- **WHEN** a version 2 source declares kind `icinga2` before that kind is supported, or carries an undeclared field
- **THEN** activation fails with a field error naming `sources[i].kind` or the field path, and the prior snapshot stays active

### Requirement: Credential rotation with overlap

A source SHALL hold 1 to 4 credentials, each with a distinct secret reference and an optional `not_before` and `not_after` instant (`not_before` < `not_after`). A credential SHALL authenticate only within its window, evaluated at receipt time. At least one credential SHALL have no `not_after` or a `not_after` in the future at activation.

#### Scenario: Overlapping rotation
- **WHEN** revision B adds a new bearer credential beside the current one, then revision C removes the old one
- **THEN** under B both tokens are accepted, under C only the new token is accepted and the old one returns 401

#### Scenario: Expired and not yet valid credentials
- **WHEN** a request presents a credential whose `not_after` has passed or whose `not_before` is in the future
- **THEN** the response is 401 with no raw row, and the source's rejection count increases

#### Scenario: Rotation during a body read
- **WHEN** a request authenticates with a credential under revision B, and revision C removing that credential (or disabling the source, changing its kind or disabling path tokens) commits while the request body is still being read
- **THEN** the request receives 401 and no raw row or transport key is committed; a request whose credential is still valid at its receipt instant and still present at commit is admitted

#### Scenario: Activation without a usable credential
- **WHEN** a publication gives a source five credentials, two credentials with the same reference, or only credentials already expired
- **THEN** activation fails with a bounded field error and the prior snapshot stays active

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

Each source SHALL have a request-rate budget (`rate_limit.per_second` 1 to 1000, default 20; `rate_limit.burst` 1 to 10000, default 40) enforced per process after successful authentication. A request over budget SHALL receive 429 with a `Retry-After` header in whole seconds and SHALL create no raw row; it SHALL count as rejected for that source.

#### Scenario: Burst within budget
- **WHEN** an authenticated source sends its burst size of requests at once
- **THEN** every request is admitted normally

#### Scenario: Budget exceeded
- **WHEN** an authenticated source sends one request more than its remaining budget
- **THEN** that request receives 429 with `Retry-After` of at least 1, no raw row is created and the source's rejection count increases

#### Scenario: Unauthenticated traffic spends no budget
- **WHEN** a stranger sends many requests with invalid credentials to a source, then the source sends a valid request
- **THEN** the stranger's requests receive 401 and the valid request is admitted

### Requirement: Declared shared namespaces

A source's alert namespace SHALL default to its own instance UUID. A source MAY name another namespace only if the root `namespaces` list declares it; declared names SHALL be 1 to 128 bytes and SHALL NOT have UUID form. Sources with distinct namespaces SHALL never share alert identity.

#### Scenario: ID-2 same names from two sources
- **WHEN** two Alertmanager sources with default namespaces deliver alerts with identical labels through HTTP ingress, then two sources in one declared namespace do the same
- **THEN** the first pair yields two alerts with distinct fingerprints, the second pair yields one alert with one fingerprint, and each delivery keeps its own source instance and observation id

#### Scenario: Undeclared or UUID shaped namespace
- **WHEN** a source names a namespace absent from `namespaces`, or `namespaces` declares a UUID-shaped name
- **THEN** activation fails with a field error naming the path and the prior snapshot stays active
