# Spec Delta

## MODIFIED Requirements

### Requirement: Source configuration format

The bootstrap configuration SHALL accept format version 2, where each source declares `kind`, `credentials`, an optional `namespace`, `body_limit_bytes` and `rate_limit`, and the root may declare `namespaces`. An `icinga2` source MAY declare `mode` (`webhook`, the default, or `event_streams`); a stream source declares the stream settings instead of `credentials`, `body_limit_bytes` and `rate_limit`. Format version 1 SHALL still be accepted and read as one bearer credential from `token_ref`, kind `alertmanager` and the default rate limit. Unknown fields, kinds and modes SHALL fail with a bounded field error.

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

## ADDED Requirements

### Requirement: A source's mode never changes

An `icinga2` source UUID SHALL keep the mode it was first published with, also while disabled. A configuration
that gives it another mode SHALL fail activation with `mode_changed`, so a raw row always decodes in the mode it
was admitted under.

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
